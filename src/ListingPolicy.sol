// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {ILaunchpadVerifier} from "./interfaces/ILaunchpadVerifier.sol";

/// @title ListingPolicy
/// @notice The one place that decides which tokens may be listed on the house permissionlessly. Every route adapter
///         (Uniswap v4, the v3 bridge) asks it before handing the house a route. The reason: a token whose
///         behaviour can change after listing (upgradeable proxy, owner switches: blacklist, pause, tax, trading
///         toggles) can fail only the house's sales, turning losses into worthless inventory while wins still pay.
///
///   A listing passes on the first of these paths that approves it:
///     1. POOL — the exact pool is whitelisted by the owner (a v4 PoolId, or a Uniswap v3 pool address);
///     2. LAUNCHPAD — an attached launchpad verifier approves the token on that pool. Each verifier carries its own
///        analysis (registry provenance, canonical pool, pinned hook code, token code, module flags). Attaching a
///        new launchpad is one deployment and one `attach`. Verifier calls are gas-capped and a verifier that
///        reverts, runs out of gas or returns garbage simply doesn't approve: it can never brick listings;
///     3. TOKEN — the token is on the owner's allowlist (trusted issuers and majors). Its pool must be hookless, a
///        v3 pool (bridged by our own immutable hook), or use a hook pinned here by address and runtime codehash.
///   Otherwise NOT_VETTED, with the last verifier's reason as detail.
///
///   The owner can still list anything directly on the house (`setTokenRoute`); tokens listed earlier stay listed and
///   the guardian can disable any of them. Not upgradeable: adapters can be pointed at a new policy by their owner.
contract ListingPolicy is Ownable2Step {
    using PoolIdLibrary for PoolKey;

    uint8 public constant OK = 0;
    /// not approved by any path; `detail` carries the last verifier's reason
    uint8 public constant NOT_VETTED = 12;
    /// allowlisted token, but its pool uses a hook that isn't pinned (or whose code changed)
    uint8 public constant HOOK_NOT_PINNED = 13;

    uint8 public constant PATH_NONE = 0;
    uint8 public constant PATH_POOL = 1;
    uint8 public constant PATH_LAUNCHPAD = 2;
    uint8 public constant PATH_TOKEN = 3;

    /// @notice gas each verifier may use per evaluation
    uint256 public constant VERIFIER_GAS = 500_000;
    uint256 public constant MAX_VERIFIERS = 8;

    mapping(bytes32 poolId => bool) public isPoolWhitelisted;
    mapping(address v3Pool => bool) public isV3PoolWhitelisted;
    mapping(address token => bool) public isTokenAllowlisted;
    mapping(address hook => bytes32) public pinnedCodehash;
    ILaunchpadVerifier[] internal _verifiers;

    event PoolWhitelisted(bytes32 indexed poolId, PoolKey key, bool whitelisted);
    event V3PoolWhitelisted(address indexed pool, bool whitelisted);
    event TokenAllowlisted(address indexed token, bool allowlisted);
    event HookPinned(address indexed hook, bytes32 codehash);
    event VerifierAttached(address indexed verifier);
    event VerifierDetached(address indexed verifier);

    error AlreadyAttached();
    error NotAttached();
    error TooManyVerifiers();

    constructor(address owner_) Ownable(owner_) {}

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Owner
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function setPoolWhitelisted(PoolKey calldata key, bool whitelisted) external onlyOwner {
        bytes32 id = PoolId.unwrap(key.toId());
        isPoolWhitelisted[id] = whitelisted;
        emit PoolWhitelisted(id, key, whitelisted);
    }

    function setV3PoolWhitelisted(address pool, bool whitelisted) external onlyOwner {
        isV3PoolWhitelisted[pool] = whitelisted;
        emit V3PoolWhitelisted(pool, whitelisted);
    }

    function setTokenAllowlisted(address token, bool allowlisted) external onlyOwner {
        isTokenAllowlisted[token] = allowlisted;
        emit TokenAllowlisted(token, allowlisted);
    }

    /// @notice Pin `hook` at its current runtime code, after auditing it and checking offchain that its EIP-1967 /
    ///         beacon slots are empty (a proxy's runtime is its stub, so a pinned audited hook can't be a proxy).
    function pinHook(address hook, bool pin) external onlyOwner {
        bytes32 h = pin && hook.code.length != 0 ? hook.codehash : bytes32(0);
        pinnedCodehash[hook] = h;
        emit HookPinned(hook, h);
    }

    function attach(ILaunchpadVerifier verifier) external onlyOwner {
        uint256 n = _verifiers.length;
        if (n >= MAX_VERIFIERS) revert TooManyVerifiers();
        for (uint256 i; i < n; ++i) {
            if (_verifiers[i] == verifier) revert AlreadyAttached();
        }
        _verifiers.push(verifier);
        emit VerifierAttached(address(verifier));
    }

    function detach(ILaunchpadVerifier verifier) external onlyOwner {
        uint256 n = _verifiers.length;
        for (uint256 i; i < n; ++i) {
            if (_verifiers[i] == verifier) {
                _verifiers[i] = _verifiers[n - 1];
                _verifiers.pop();
                emit VerifierDetached(address(verifier));
                return;
            }
        }
        revert NotAttached();
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function verifiers() external view returns (ILaunchpadVerifier[] memory) {
        return _verifiers;
    }

    /// @notice True for no hook, or a pinned hook whose runtime code is unchanged.
    function isHookPinned(address hook) public view returns (bool) {
        if (hook == address(0)) return true;
        bytes32 h = pinnedCodehash[hook];
        return h != bytes32(0) && hook.codehash == h;
    }

    /// @notice May `token` be listed permissionlessly through `key`?
    /// @param v3Pool the Uniswap v3 pool behind `key` when `key` is our bridge's key for it, else address(0)
    /// @return reason OK, NOT_VETTED or HOOK_NOT_PINNED
    /// @return path which path approved (PATH_POOL / PATH_LAUNCHPAD / PATH_TOKEN), PATH_NONE when refused
    /// @return launchpadId the approving verifier's launchpad id (PATH_LAUNCHPAD only)
    /// @return detail the last verifier's refusal reason when NOT_VETTED
    function evaluate(address token, PoolKey memory key, address v3Pool)
        public
        view
        returns (uint8 reason, uint8 path, bytes32 launchpadId, uint8 detail)
    {
        if (isPoolWhitelisted[PoolId.unwrap(key.toId())] || (v3Pool != address(0) && isV3PoolWhitelisted[v3Pool])) {
            return (OK, PATH_POOL, bytes32(0), 0);
        }
        uint256 n = _verifiers.length;
        bytes memory callData = abi.encodeCall(ILaunchpadVerifier.verify, (token, key));
        for (uint256 i; i < n; ++i) {
            (bool success, bytes memory ret) = address(_verifiers[i]).staticcall{gas: VERIFIER_GAS}(callData);
            if (!success || ret.length != 96) continue;
            (uint256 ok, uint256 r, bytes32 id) = abi.decode(ret, (uint256, uint256, bytes32));
            if (ok == 1) return (OK, PATH_LAUNCHPAD, id, 0);
            detail = uint8(r);
        }
        if (isTokenAllowlisted[token]) {
            if (v3Pool != address(0) || isHookPinned(address(key.hooks))) return (OK, PATH_TOKEN, bytes32(0), 0);
            return (HOOK_NOT_PINNED, PATH_NONE, bytes32(0), 0);
        }
        return (NOT_VETTED, PATH_NONE, bytes32(0), detail);
    }
}
