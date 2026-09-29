// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ILaunchpadVerifier} from "../interfaces/ILaunchpadVerifier.sol";
import {IHookitLaunchFactory, IHookitMasterHook, IHookitLaunchToken} from "../interfaces/IHookit.sol";
import {CodeTemplate} from "../libraries/CodeTemplate.sol";

/// @title HookitVerifier
/// @notice ListingPolicy verifier for hookit.fun Master-rail launches (Ink). Immutable: rails, pinned hook code and the
///         module policy are fixed at deployment (deploy and attach a new verifier to change them).
///
///   Approves a token on its canonical launch pool when
///     - a rail's factory registry has it (`tokenLaunchId(token) != 0`) and the factory's key for that launch is
///       `key`, using the rail's master hook whose runtime code is still the audited one;
///     - the launch is ETH-quoted, its pool initialized, and the hook's launch state names this token;
///     - its module bitmask (written once at launch, never changeable) has none of `forbiddenFlags` — by default
///       ANTI_MEV (one swap per tx.origin per pool per block fails every second settlement in a block), MAX_TX
///       (caps the house's trades) and HOLDER_AIRDROP (every transfer calls out to the airdrop vault) — and any
///       anti-snipe window has ended;
///     - its runtime code is the audited `LaunchToken` template (solmate ERC20: no owner, pause, blacklist or tax;
///       immutables masked) and it has no holder tracker.
///
///   Trust note: hookit's owner can repoint the vaults every hookit swap calls (`setAirdropVault`, `setHktDropVault`)
///   and so halt or grief swaps on all hookit pools. Settlements then degrade to inventory / pending wins; this is a
///   launchpad-operator trust assumption no verifier can remove.
contract HookitVerifier is ILaunchpadVerifier {
    using PoolIdLibrary for PoolKey;

    bytes32 public constant LAUNCHPAD_ID = "hookit";

    // verify() reasons
    uint8 public constant NOT_A_LAUNCH = 1;
    uint8 public constant HOOK_CODE_CHANGED = 2;
    uint8 public constant NOT_ETH_QUOTED = 3;
    uint8 public constant NOT_INITIALIZED = 4;
    uint8 public constant FORBIDDEN_MODULES = 5;
    uint8 public constant SNIPE_WINDOW_LIVE = 6;
    uint8 public constant TOKEN_CODE = 7;
    uint8 public constant HOLDER_TRACKER = 8;
    uint8 public constant NOT_CANONICAL_POOL = 9;

    uint256 public constant ANTI_SNIPE = 1 << 0;
    uint256 public constant ANTI_MEV = 1 << 2;
    uint256 public constant MAX_TX = 1 << 3;
    uint256 public constant HOLDER_AIRDROP = 1 << 145;
    uint256 internal constant SNIPE_DURATION_SHIFT = 23;

    struct Rail {
        IHookitLaunchFactory factory;
        address hook;
        bytes32 hookCodehash;
    }

    Rail[] internal _rails;
    uint256 public immutable forbiddenFlags;
    bytes32 public immutable tokenTemplate;
    uint256 public immutable tokenSize;
    uint256 public immutable tokenImmutables;

    constructor(
        Rail[] memory rails_,
        uint256 _forbiddenFlags,
        bytes32 _tokenTemplate,
        uint256 _tokenSize,
        uint256 _tokenImmutables
    ) {
        for (uint256 i; i < rails_.length; ++i) {
            _rails.push(rails_[i]);
        }
        forbiddenFlags = _forbiddenFlags;
        tokenTemplate = _tokenTemplate;
        tokenSize = _tokenSize;
        tokenImmutables = _tokenImmutables;
    }

    function rails() external view returns (Rail[] memory) {
        return _rails;
    }

    function verify(address token, PoolKey calldata key) external view returns (bool, uint8, bytes32) {
        uint256 n = _rails.length;
        for (uint256 i; i < n; ++i) {
            Rail memory r = _rails[i];
            uint256 id = r.factory.tokenLaunchId(token);
            if (id == 0) continue;
            uint8 reason = _verify(r, id, token, key);
            return (reason == 0, reason, LAUNCHPAD_ID);
        }
        return (false, NOT_A_LAUNCH, LAUNCHPAD_ID);
    }

    function _verify(Rail memory r, uint256 id, address token, PoolKey calldata key) internal view returns (uint8) {
        PoolKey memory k = r.factory.poolKeyOf(id);
        if (address(k.hooks) != r.hook || r.hook.codehash != r.hookCodehash) return HOOK_CODE_CHANGED;
        if (!k.currency0.isAddressZero() || Currency.unwrap(k.currency1) != token) return NOT_ETH_QUOTED;
        if (keccak256(abi.encode(k)) != keccak256(abi.encode(key))) return NOT_CANONICAL_POOL;
        bytes32 pid = PoolId.unwrap(k.toId());
        IHookitMasterHook.LaunchState memory st = IHookitMasterHook(r.hook).launchState(pid);
        if (!st.initialized || st.token != token) return NOT_INITIALIZED;
        uint256 flags = IHookitMasterHook(r.hook).configs(pid);
        if (flags & forbiddenFlags != 0) return FORBIDDEN_MODULES;
        if (flags & ANTI_SNIPE != 0) {
            uint256 window = (flags >> SNIPE_DURATION_SHIFT) & 0xffff;
            if (block.timestamp < uint256(st.launchTimestamp) + window) return SNIPE_WINDOW_LIVE;
        }
        if (CodeTemplate.maskedHash(token, tokenSize, tokenImmutables) != tokenTemplate) return TOKEN_CODE;
        if (IHookitLaunchToken(token).holderTracker() != address(0)) return HOLDER_TRACKER;
        return 0;
    }
}
