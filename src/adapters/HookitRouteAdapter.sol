// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IRouteAdapter} from "../interfaces/IRouteAdapter.sol";
import {IHookitLaunchFactory, IHookitMasterHook} from "../interfaces/IHookit.sol";
import {ListingPolicy} from "../ListingPolicy.sol";

interface IHookitHouse {
    function listToken(address token, IRouteAdapter adapter) external;
}

/// @title HookitRouteAdapter
/// @notice Vouches for tokens launched on hookit.fun and derives their canonical route to $FLIPPER:
///         [token/ETH hookit pool, ETH/$FLIPPER hookit pool].
///
///         Nothing is taken from the caller: provenance is proven by an allowlisted (factory, hook) "rail"
///         (`factory.tokenLaunchId(token) != 0`), the PoolKey is read from that factory, and the hook's own launch
///         state must confirm it. Only the factory can initialize a pool with a hookit master hook, so a matching
///         key is necessarily the launchpad's locked-liquidity pool. hookit launch tokens are plain fixed-supply
///         ERC20s (no tax, pause, blacklist or proxy).
///
///         Only ETH-quoted launches are eligible (the route must reach $FLIPPER through ETH); multi-market and
///         ERC-20-quoted launches revert `UnsupportedQuote`.
///
///         Listing policy: provenance alone isn't enough — a launch's frozen module flags can break settlement
///         (ANTI_MEV, MAX_TX) and some tokens call out on every transfer (holder airdrops). The shared ListingPolicy
///         decides (the HookitVerifier attached there checks modules, code template and pinned hook); `routeFor`
///         reverts `NotVetted` otherwise, `check` reports it, and `registerAndList` emits which path approved.
///
///         Deployed behind a TransparentUpgradeableProxy; storage is append-only.
contract HookitRouteAdapter is IRouteAdapter, Ownable2StepUpgradeable {
    using PoolIdLibrary for PoolKey;

    struct Rail {
        IHookitLaunchFactory factory;
        IHookitMasterHook hook;
    }

    Rail[] internal _rails;
    /// @notice the shared listing policy (appended in the listing-policy upgrade)
    ListingPolicy public listingPolicy;
    /// @notice the house (for `registerAndList`; appended in the listing-policy upgrade)
    address public house;
    /// @dev the ETH/$FLIPPER pool for the route's second hop when $FLIPPER isn't a hookit launch (our own v4 token);
    ///      unset = $FLIPPER's hookit pool (appended in the listing-policy upgrade)
    PoolKey internal _flipperPool;

    event RailAdded(address indexed factory, address indexed hook);
    event RailRemoved(address indexed factory, address indexed hook);

    error NotHookitToken(address token);
    error UnsupportedQuote(address token);
    error InvalidRail();
    error SameToken();
    /// @notice the ListingPolicy refused: NOT_VETTED / HOOK_NOT_PINNED, and the last launchpad verifier's reason
    error NotVetted(uint8 reason, uint8 detail);

    event ListingPolicySet(address policy, address house);
    /// @notice which ListingPolicy path approved a listing (1 pool, 2 launchpad, 3 token) and the launchpad
    event ListingVetted(address indexed token, bytes32 indexed poolId, uint8 path, bytes32 launchpadId);

    /// @notice check() reasons: not an ETH-quoted launch on an allowlisted rail; not vetted by the ListingPolicy
    uint8 public constant NOT_HOOKIT = 3;
    uint8 public constant NOT_VETTED = 12;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner) external initializer {
        __Ownable_init(_owner);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // IRouteAdapter
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function routeFor(address token, address flipper) external view returns (PoolKey[] memory route) {
        if (token == flipper) revert SameToken();
        route = new PoolKey[](2);
        route[0] = ethPoolOf(token);
        route[1] = _flipperPool.tickSpacing != 0 ? _flipperPool : ethPoolOf(flipper);
        _vetted(token, route[0]);
    }

    /// @notice The launchpad's ETH pool for `token`; reverts if `token` is not an ETH-quoted hookit launch.
    function ethPoolOf(address token) public view returns (PoolKey memory key) {
        uint256 n = _rails.length;
        for (uint256 i; i < n; ++i) {
            Rail memory r = _rails[i];
            uint256 id = r.factory.tokenLaunchId(token);
            if (id == 0) continue;
            key = r.factory.poolKeyOf(id);
            if (address(key.hooks) != address(r.hook)) revert InvalidRail();
            if (!key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != token) {
                revert UnsupportedQuote(token);
            }
            IHookitMasterHook.LaunchState memory st = r.hook.launchState(PoolId.unwrap(key.toId()));
            if (!st.initialized || st.token != token || st.quote != address(0)) revert UnsupportedQuote(token);
            return key;
        }
        revert NotHookitToken(token);
    }

    /// @notice Non-reverting listing check for UIs: 0 = listable, NOT_HOOKIT, or the ListingPolicy's reason.
    function check(address token) external view returns (uint8 reason) {
        try this.ethPoolOf(token) returns (PoolKey memory key) {
            ListingPolicy p = listingPolicy;
            if (address(p) == address(0)) return NOT_VETTED;
            (reason,,,) = p.evaluate(token, key, address(0));
        } catch {
            return NOT_HOOKIT;
        }
    }

    /// @notice List a vetted hookit launch on the house (anyone), recording which path approved it.
    function registerAndList(address token) external {
        PoolKey memory key = ethPoolOf(token);
        (uint8 path, bytes32 launchpadId) = _vetted(token, key);
        IHookitHouse(house).listToken(token, this);
        emit ListingVetted(token, PoolId.unwrap(key.toId()), path, launchpadId);
    }

    /// @notice The ETH/$FLIPPER pool used as the route's second hop (needed when $FLIPPER isn't a hookit launch).
    function setFlipperPool(PoolKey calldata key) external onlyOwner {
        _flipperPool = key;
    }

    function flipperPool() external view returns (PoolKey memory) {
        return _flipperPool;
    }

    function setListingPolicy(ListingPolicy policy, address house_) external onlyOwner {
        listingPolicy = policy;
        house = house_;
        emit ListingPolicySet(address(policy), house_);
    }

    function _vetted(address token, PoolKey memory key) internal view returns (uint8 path, bytes32 launchpadId) {
        ListingPolicy p = listingPolicy;
        if (address(p) == address(0)) revert NotVetted(NOT_VETTED, 0);
        uint8 reason;
        uint8 detail;
        (reason, path, launchpadId, detail) = p.evaluate(token, key, address(0));
        if (reason != 0) revert NotVetted(reason, detail);
    }

    /// @notice Non-reverting provenance check for UIs (ignores the listing policy; see `check`).
    function isEligible(address token) external view returns (bool) {
        try this.ethPoolOf(token) returns (PoolKey memory) {
            return true;
        } catch {
            return false;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function addRail(IHookitLaunchFactory factory, IHookitMasterHook hook) external onlyOwner {
        if (factory.masterHook() != address(hook) || hook.factory() != address(factory)) revert InvalidRail();
        for (uint256 i; i < _rails.length; ++i) {
            if (address(_rails[i].factory) == address(factory)) revert InvalidRail();
        }
        _rails.push(Rail(factory, hook));
        emit RailAdded(address(factory), address(hook));
    }

    function removeRail(uint256 index) external onlyOwner {
        Rail memory r = _rails[index];
        _rails[index] = _rails[_rails.length - 1];
        _rails.pop();
        emit RailRemoved(address(r.factory), address(r.hook));
    }

    function rails() external view returns (Rail[] memory) {
        return _rails;
    }
}
