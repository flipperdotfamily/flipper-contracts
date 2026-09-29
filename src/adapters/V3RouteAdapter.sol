// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {IRouteAdapter} from "../interfaces/IRouteAdapter.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3.sol";
import {V3BridgeHook} from "./V3BridgeHook.sol";
import {ListingPolicy} from "../ListingPolicy.sol";

interface IHouseListingV3 {
    function listToken(address token, IRouteAdapter adapter) external;
    function flipper() external view returns (address);
    function tokenConfig(address token)
        external
        view
        returns (bool enabled, bool blocked, address adapter, PoolKey[] memory route);
}

interface IV4AdapterDepth {
    function poolOf(address token) external view returns (PoolKey memory);
    function check(address token, PoolKey memory key) external view returns (uint8 reason, uint256 depth);
}

/// @title V3RouteAdapter
/// @notice Makes tokens whose liquidity sits in Uniswap v3 flippable. Anyone may register a token's canonical v3 pool
///         and list it in one call; the house then swaps through it like any v4 pool, via the V3BridgeHook.
///
///   Route: [token/WETH v3 pool (bridged), ETH/$FLIPPER] or, for owner-allowlisted quote currencies (USDG),
///   [token/USDG v3 pool (bridged), USDG→ETH quote pool (a v4 pool, e.g. the hookless ETH/USDG one), ETH/$FLIPPER].
///   The house applies the same checks as for every adapter: the listing probe (a probe-sized round trip must cost
///   ≤ `listingMaxRouteCostBps`), per-flip pricing of the actual stake, and every swap gas-capped inside settlement.
///
///   Same `check()` reason codes as V4RouteAdapter (5, HOOK_NOT_ALLOWED, never applies) plus:
///     9  NOT_V3_POOL       not the canonical v3 factory's pool for its tokens and fee
///     10 LISTED_ELSEWHERE  the house already lists the token through another adapter (or the owner); only the
///                          owner can move it (`setTokenRoute`)
///     11 IS_WETH           WETH itself (the bridge trades it as native ETH; WETH flips route through v4)
///   Deepest pool: a registration is replaced only by a deeper v3 pool on the same pairing currency, and when the
///   V4RouteAdapter has a registered pool for the token on the same pairing that is at least as deep, v3 defers to it
///   (DEEPER_REGISTERED): v4 is the default venue, v3 only fills in where v4 liquidity is missing or shallower.
///
///   Listing policy: the shared ListingPolicy decides (the v3 pool whitelisted, an attached verifier approving the
///   token on the bridged pool, or the token allowlisted; the bridge hook is our own immutable contract, so it needs
///   no pin). Otherwise `check` reports NOT_VETTED (12), `register` / `routeFor` revert `NotVetted`. `register` emits
///   which path approved (`ListingVetted`). The guardian can block any token.
///   Deployed behind a TransparentUpgradeableProxy; storage is append-only.
contract V3RouteAdapter is IRouteAdapter, Ownable2StepUpgradeable {
    using PoolIdLibrary for PoolKey;

    uint8 public constant OK = 0;
    uint8 public constant NO_CODE = 1;
    uint8 public constant IS_FLIPPER = 2;
    uint8 public constant NOT_IN_POOL = 3;
    uint8 public constant UNSUPPORTED_QUOTE = 4;
    uint8 public constant NOT_INITIALIZED = 6;
    uint8 public constant NO_LIQUIDITY = 7;
    uint8 public constant DEEPER_REGISTERED = 8;
    uint8 public constant NOT_V3_POOL = 9;
    uint8 public constant LISTED_ELSEWHERE = 10;
    uint8 public constant IS_WETH = 11;
    uint8 public constant NOT_VETTED = 12;

    V3BridgeHook public bridge;
    address public house;
    address public weth;
    PoolKey internal _flipperPool; // ETH / $FLIPPER (v4)
    mapping(address token => address v3Pool) internal _pools;
    mapping(address quote => PoolKey) internal _quoteToEth; // v4 pool from the quote currency to ETH
    address[] internal _quotes;
    IV4AdapterDepth public v4Adapter; // optional: defer to a deeper v4 registration
    /// @notice the shared listing policy (appended in the listing-policy upgrade)
    ListingPolicy public listingPolicy;

    event PoolRegistered(address indexed token, address indexed v3Pool, uint256 depth, address indexed by);
    event QuoteSet(address indexed quote, bytes32 poolId);
    event FlipperPoolSet(bytes32 poolId);
    event V4AdapterSet(address adapter);
    event ListingPolicySet(address policy);
    /// @notice which ListingPolicy path approved a registration (1 pool, 2 launchpad, 3 token) and the launchpad
    event ListingVetted(address indexed token, address indexed v3Pool, uint8 path, bytes32 launchpadId);

    error Rejected(uint8 reason);
    error NotRegistered(address token);
    error InvalidPool();
    /// @notice the ListingPolicy refused: NOT_VETTED, and the last launchpad verifier's reason
    error NotVetted(uint8 reason, uint8 detail);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(V3BridgeHook _bridge, address _house, address _owner) external initializer {
        __Ownable_init(_owner);
        bridge = _bridge;
        house = _house;
        weth = _bridge.weth();
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Permissionless
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Validate and store `token`'s v3 pool (bridging it to v4 if it isn't yet).
    function register(address token, address v3Pool) public {
        (uint8 reason, uint256 depth) = check(token, v3Pool);
        if (reason == NOT_VETTED) _vetted(token, bridge.keyFor(v3Pool), v3Pool); // reverts with the detail
        if (reason != OK) revert Rejected(reason);
        (uint8 path, bytes32 launchpadId) = _vetted(token, bridge.keyFor(v3Pool), v3Pool);
        emit ListingVetted(token, v3Pool, path, launchpadId);
        bridge.bridge(v3Pool);
        _pools[token] = v3Pool;
        emit PoolRegistered(token, v3Pool, depth, msg.sender);
    }

    /// @notice Register and list on the house in one transaction (the house's liquidity probe still applies).
    function registerAndList(address token, address v3Pool) external {
        register(token, v3Pool);
        IHouseListingV3(house).listToken(token, this);
    }

    /// @notice Non-reverting validation for UIs. `depth` is the pool's in-range virtual reserve of the pairing
    ///         currency (wei of WETH for WETH pairs), used to prefer deeper pools.
    function check(address token, address v3Pool) public view returns (uint8 reason, uint256 depth) {
        if (token.code.length == 0) return (NO_CODE, 0);
        if (token == IHouseListingV3(house).flipper()) return (IS_FLIPPER, 0);
        if (token == weth) return (IS_WETH, 0); // the bridge shows WETH as native ETH: flip WETH via a v4 pool
        if (!bridge.isCanonical(v3Pool)) return (NOT_V3_POOL, 0);
        address t0 = IUniswapV3Pool(v3Pool).token0();
        address t1 = IUniswapV3Pool(v3Pool).token1();
        if (t0 != token && t1 != token) return (NOT_IN_POOL, 0);
        address other = t0 == token ? t1 : t0;
        if (other != weth && _quoteToEth[other].tickSpacing == 0) return (UNSUPPORTED_QUOTE, 0);
        if (_policyReason(token, bridge.keyFor(v3Pool), v3Pool) != OK) return (NOT_VETTED, 0);
        depth = _depth(v3Pool, other == t0);
        if (depth == type(uint256).max) return (NOT_INITIALIZED, 0);
        if (depth == 0) return (NO_LIQUIDITY, 0);

        (,, address listedBy, PoolKey[] memory route) = IHouseListingV3(house).tokenConfig(token);
        if (route.length != 0 && listedBy != address(this)) return (LISTED_ELSEWHERE, depth);

        address cur = _pools[token];
        if (cur != address(0) && cur != v3Pool) {
            address ct0 = IUniswapV3Pool(cur).token0();
            address curOther = ct0 == token ? IUniswapV3Pool(cur).token1() : ct0;
            if (curOther != other) return (DEEPER_REGISTERED, depth); // cross-currency switches are owner-only
            if (_depth(cur, curOther == ct0) >= depth) return (DEEPER_REGISTERED, depth);
        }
        if (_v4Deeper(token, other, depth)) return (DEEPER_REGISTERED, depth);
        return (OK, depth);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // IRouteAdapter
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function routeFor(address token, address flipper) external view returns (PoolKey[] memory route) {
        if (token == flipper) revert Rejected(IS_FLIPPER);
        address p = _pools[token];
        if (p == address(0)) revert NotRegistered(token);
        if (_flipperPool.tickSpacing == 0) revert InvalidPool();
        PoolKey memory key = bridge.keyFor(p);
        // enforced here too: `house.listToken` is permissionless and relies on this
        _vetted(token, key, p);
        address t0 = IUniswapV3Pool(p).token0();
        address other = t0 == token ? IUniswapV3Pool(p).token1() : t0;
        if (other == weth) {
            route = new PoolKey[](2);
            route[0] = key;
            route[1] = _flipperPool;
        } else {
            PoolKey memory q = _quoteToEth[other];
            if (q.tickSpacing == 0) revert Rejected(UNSUPPORTED_QUOTE);
            route = new PoolKey[](3);
            route[0] = key;
            route[1] = q;
            route[2] = _flipperPool;
        }
    }

    function poolOf(address token) external view returns (address) {
        return _pools[token];
    }

    function flipperPool() external view returns (PoolKey memory) {
        return _flipperPool;
    }

    function quoteCurrencies() external view returns (address[] memory) {
        return _quotes;
    }

    function quotePool(address quote) external view returns (PoolKey memory) {
        return _quoteToEth[quote];
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function setFlipperPool(PoolKey calldata key) external onlyOwner {
        address f = IHouseListingV3(house).flipper();
        if (!key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != f) revert InvalidPool();
        _flipperPool = key;
        emit FlipperPoolSet(PoolId.unwrap(key.toId()));
    }

    /// @notice Allow `quote`-paired v3 pools, routed on to ETH through the v4 pool `quoteEthPool`.
    function setQuote(address quote, PoolKey calldata quoteEthPool) external onlyOwner {
        if (
            quote == address(0) || quote == weth || !quoteEthPool.currency0.isAddressZero()
                || Currency.unwrap(quoteEthPool.currency1) != quote
        ) revert InvalidPool();
        if (_quoteToEth[quote].tickSpacing == 0) _quotes.push(quote);
        _quoteToEth[quote] = quoteEthPool;
        emit QuoteSet(quote, PoolId.unwrap(quoteEthPool.toId()));
    }

    /// @notice Owner override (e.g. switching a token to a pool on a different pairing currency).
    function setPool(address token, address v3Pool) external onlyOwner {
        if (!bridge.isCanonical(v3Pool)) revert InvalidPool();
        bridge.bridge(v3Pool);
        _pools[token] = v3Pool;
        emit PoolRegistered(token, v3Pool, 0, msg.sender);
    }

    function setListingPolicy(ListingPolicy policy) external onlyOwner {
        listingPolicy = policy;
        emit ListingPolicySet(address(policy));
    }

    function setV4Adapter(IV4AdapterDepth a) external onlyOwner {
        v4Adapter = a;
        emit V4AdapterSet(address(a));
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function _policyReason(address token, PoolKey memory key, address v3Pool) internal view returns (uint8 reason) {
        ListingPolicy p = listingPolicy;
        if (address(p) == address(0)) return NOT_VETTED;
        (reason,,,) = p.evaluate(token, key, v3Pool);
    }

    function _vetted(address token, PoolKey memory key, address v3Pool)
        internal
        view
        returns (uint8 path, bytes32 launchpadId)
    {
        ListingPolicy p = listingPolicy;
        if (address(p) == address(0)) revert NotVetted(NOT_VETTED, 0);
        uint8 reason;
        uint8 detail;
        (reason, path, launchpadId, detail) = p.evaluate(token, key, v3Pool);
        if (reason != OK) revert NotVetted(reason, detail);
    }

    /// @return depth in-range virtual reserve of the pairing currency; max uint if the pool isn't initialized
    function _depth(address v3Pool, bool pairIsToken0) internal view returns (uint256 depth) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(v3Pool).slot0();
        if (sqrtPriceX96 == 0) return type(uint256).max;
        uint128 liquidity = IUniswapV3Pool(v3Pool).liquidity();
        if (liquidity == 0) return 0;
        depth = pairIsToken0
            ? FullMath.mulDiv(liquidity, 1 << 96, sqrtPriceX96)
            : FullMath.mulDiv(liquidity, sqrtPriceX96, 1 << 96);
    }

    /// @dev true if the V4RouteAdapter has a registered pool for `token` on the same pairing (WETH ↔ native ETH)
    ///      whose depth is at least `depth` (both are in-range virtual reserves of the pairing currency)
    function _v4Deeper(address token, address other, uint256 depth) internal view returns (bool) {
        IV4AdapterDepth a = v4Adapter;
        if (address(a) == address(0)) return false;
        try a.poolOf(token) returns (PoolKey memory k) {
            if (k.tickSpacing == 0) return false;
            address c0 = Currency.unwrap(k.currency0);
            address v4Other = c0 == token ? Currency.unwrap(k.currency1) : c0;
            if (v4Other != (other == weth ? address(0) : other)) return false;
            try a.check(token, k) returns (uint8 r, uint256 d) {
                return r == 0 && d >= depth;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }
}
