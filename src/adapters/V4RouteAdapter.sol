// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {IRouteAdapter} from "../interfaces/IRouteAdapter.sol";
import {ListingPolicy} from "../ListingPolicy.sol";

interface IHouseListing {
    function listToken(address token, IRouteAdapter adapter) external;
    function flipper() external view returns (address);
}

/// @title V4RouteAdapter
/// @notice Makes vetted Uniswap v4 tokens flippable. Anyone may register a vetted token's pool and list it in one call.
///
///   Route: [token/ETH pool, ETH/$FLIPPER pool], or [token/quote pool, quote/ETH pool, ETH/$FLIPPER pool] for
///   owner-allowlisted quote currencies (e.g. USDC). The house then applies its own checks on top: a probe-sized
///   round trip must cost ≤ `listingMaxRouteCostBps`, and every flip re-prices the actual stake.
///
///   Listing policy: the shared ListingPolicy decides (pool whitelist, attached launchpad verifiers, token allowlist
///   with pinned hooks), because a token whose behaviour can change after listing (proxy, blacklist, pause, tax
///   switches) could fail only the house's sales. `check` reports NOT_VETTED (12) / HOOK_NOT_PINNED (13); `register`
///   emits which path approved (`ListingVetted`); `routeFor` enforces the same, so a direct `house.listToken` can't
///   bypass it. With no policy set, nothing lists permissionlessly.
///
///   Also:
///     - payouts are denominated in the staked token, win and loss branches realise the same settle-time prices,
///       and the $FLIPPER fallback is valued by a *settled* simulation (tokens really move), so a token that
///       blocks or taxes our transfers can't make a win pay more than a loss would realise;
///     - wins pay what actually arrived; entry rejects fee-on-transfer tokens.
///   The guardian can still block any listed token.
///
///   Deployed behind a TransparentUpgradeableProxy; storage is append-only.
contract V4RouteAdapter is IRouteAdapter, Ownable2StepUpgradeable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint8 public constant OK = 0;
    uint8 public constant NO_CODE = 1;
    uint8 public constant IS_FLIPPER = 2;
    uint8 public constant NOT_IN_POOL = 3;
    uint8 public constant UNSUPPORTED_QUOTE = 4;
    uint8 public constant HOOK_NOT_ALLOWED = 5;
    uint8 public constant NOT_INITIALIZED = 6;
    uint8 public constant NO_LIQUIDITY = 7;
    uint8 public constant DEEPER_REGISTERED = 8;
    uint8 public constant NOT_VETTED = 12;
    uint8 public constant HOOK_NOT_PINNED = 13;
    uint256 public constant CUSTOM_CURVE_DEPTH = type(uint128).max;

    IPoolManager public poolManager;
    address public house;
    PoolKey internal _flipperPool; // ETH / $FLIPPER
    mapping(address hook => bool) public isHookAllowed;
    mapping(address token => PoolKey) internal _pools;
    mapping(address quote => PoolKey) internal _quoteToEth;
    address[] internal _quotes;
    /// @notice the shared listing policy (appended in the listing-policy upgrade)
    ListingPolicy public listingPolicy;

    event PoolRegistered(address indexed token, bytes32 indexed poolId, uint256 depth, address indexed by);
    event HookAllowed(address indexed hook, bool allowed);
    event QuoteSet(address indexed quote, bytes32 poolId);
    event FlipperPoolSet(bytes32 poolId);
    event ListingPolicySet(address policy);
    /// @notice which ListingPolicy path approved a registration (1 pool, 2 launchpad, 3 token) and the launchpad
    event ListingVetted(address indexed token, bytes32 indexed poolId, uint8 path, bytes32 launchpadId);

    error Rejected(uint8 reason);
    /// @notice the ListingPolicy refused: NOT_VETTED / HOOK_NOT_PINNED, and the last launchpad verifier's reason
    error NotVetted(uint8 reason, uint8 detail);
    error NotRegistered(address token);
    error InvalidPool();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IPoolManager _poolManager, address _house, address _owner) external initializer {
        __Ownable_init(_owner);
        poolManager = _poolManager;
        house = _house;
        isHookAllowed[address(0)] = true;
        emit HookAllowed(address(0), true);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Permissionless
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Validate and store `token`'s pool. Replaces an earlier registration only with a deeper pool on the
    ///         same pairing currency.
    function register(address token, PoolKey calldata key) public {
        (uint8 path, bytes32 launchpadId) = _vetted(token, key);
        (uint8 reason, uint256 depth) = check(token, key);
        if (reason != OK) revert Rejected(reason);
        _pools[token] = key;
        emit ListingVetted(token, PoolId.unwrap(key.toId()), path, launchpadId);
        emit PoolRegistered(token, PoolId.unwrap(key.toId()), depth, msg.sender);
    }

    /// @notice Register and list on the house in one transaction (the house's liquidity probe still applies).
    function registerAndList(address token, PoolKey calldata key) external {
        register(token, key);
        IHouseListing(house).listToken(token, this);
    }

    /// @notice Non-reverting validation for UIs. `depth` is the pool's in-range virtual reserve of the pairing
    ///         currency (wei of ETH for ETH pairs), used to prefer deeper pools.
    function check(address token, PoolKey memory key) public view returns (uint8 reason, uint256 depth) {
        if (token.code.length == 0) return (NO_CODE, 0);
        if (token == IHouseListing(house).flipper()) return (IS_FLIPPER, 0);
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 != token && c1 != token) return (NOT_IN_POOL, 0);
        address other = c0 == token ? c1 : c0;
        if (other != address(0) && _quoteToEth[other].tickSpacing == 0) return (UNSUPPORTED_QUOTE, 0);
        reason = _policyReason(token, key);
        if (reason != OK) return (reason, 0);
        depth = _depth(key, other == c0);
        if (depth == type(uint256).max) return (NOT_INITIALIZED, 0);
        if (depth == 0) return (NO_LIQUIDITY, 0);

        PoolKey memory cur = _pools[token];
        if (cur.tickSpacing != 0 && PoolId.unwrap(cur.toId()) != PoolId.unwrap(key.toId())) {
            address curOther = Currency.unwrap(cur.currency0) == token
                ? Currency.unwrap(cur.currency1)
                : Currency.unwrap(cur.currency0);
            if (curOther == other && _depth(cur, curOther == Currency.unwrap(cur.currency0)) >= depth) {
                return (DEEPER_REGISTERED, depth);
            }
            if (curOther != other) return (DEEPER_REGISTERED, depth); // cross-currency swaps are owner-only
        }
        return (OK, depth);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // IRouteAdapter
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function routeFor(address token, address flipper) external view returns (PoolKey[] memory route) {
        if (token == flipper) revert Rejected(IS_FLIPPER);
        PoolKey memory key = _pools[token];
        if (key.tickSpacing == 0) revert NotRegistered(token);
        if (_flipperPool.tickSpacing == 0) revert InvalidPool();
        // the listing policy is enforced here too: `house.listToken` is permissionless and relies on this
        _vetted(token, key);
        address c0 = Currency.unwrap(key.currency0);
        address other = c0 == token ? Currency.unwrap(key.currency1) : c0;
        if (other == address(0)) {
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

    function poolOf(address token) external view returns (PoolKey memory) {
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
        address f = IHouseListing(house).flipper();
        if (!key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != f) revert InvalidPool();
        _flipperPool = key;
        emit FlipperPoolSet(PoolId.unwrap(key.toId()));
    }

    /// @notice Hooks allowed on quote → ETH pools (`setQuote`). Pool hooks for listings are the ListingPolicy's call.
    function setHookAllowed(address hook, bool allowed) external onlyOwner {
        isHookAllowed[hook] = allowed;
        emit HookAllowed(hook, allowed);
    }

    function setListingPolicy(ListingPolicy policy) external onlyOwner {
        listingPolicy = policy;
        emit ListingPolicySet(address(policy));
    }

    /// @notice Allow `quote`-paired pools, routed to ETH through `quoteEthPool`.
    function setQuote(address quote, PoolKey calldata quoteEthPool) external onlyOwner {
        if (
            quote == address(0) || !quoteEthPool.currency0.isAddressZero()
                || Currency.unwrap(quoteEthPool.currency1) != quote || !isHookAllowed[address(quoteEthPool.hooks)]
        ) revert InvalidPool();
        if (_quoteToEth[quote].tickSpacing == 0) _quotes.push(quote);
        _quoteToEth[quote] = quoteEthPool;
        emit QuoteSet(quote, PoolId.unwrap(quoteEthPool.toId()));
    }

    /// @notice Owner override (e.g. switching a token to a pool on a different pairing currency).
    function setPool(address token, PoolKey calldata key) external onlyOwner {
        _pools[token] = key;
        emit PoolRegistered(token, PoolId.unwrap(key.toId()), 0, msg.sender);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev the ListingPolicy's verdict (fails closed without a policy)
    function _policyReason(address token, PoolKey memory key) internal view returns (uint8 reason) {
        ListingPolicy p = listingPolicy;
        if (address(p) == address(0)) return NOT_VETTED;
        (reason,,,) = p.evaluate(token, key, address(0));
    }

    function _vetted(address token, PoolKey memory key) internal view returns (uint8 path, bytes32 launchpadId) {
        ListingPolicy p = listingPolicy;
        if (address(p) == address(0)) revert NotVetted(NOT_VETTED, 0);
        uint8 reason;
        uint8 detail;
        (reason, path, launchpadId, detail) = p.evaluate(token, key, address(0));
        if (reason != OK) revert NotVetted(reason, detail);
    }

    /// @return depth in-range virtual reserve of the pairing currency; max uint if the pool isn't initialized. A
    ///         liquidity-free hooked pool the ListingPolicy whitelists is a custom curve (e.g. the 1:1 WETH wrapper):
    ///         unbounded depth (`CUSTOM_CURVE_DEPTH`), so no AMM pool can displace it; the house's probe still prices it.
    function _depth(PoolKey memory key, bool pairIsCurrency0) internal view returns (uint256 depth) {
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) return type(uint256).max;
        uint128 liquidity = poolManager.getLiquidity(id);
        if (liquidity == 0) {
            ListingPolicy p = listingPolicy;
            bool custom = address(key.hooks) != address(0) && address(p) != address(0)
                && p.isPoolWhitelisted(PoolId.unwrap(id));
            return custom ? CUSTOM_CURVE_DEPTH : 0;
        }
        // virtual reserves at the current price: x = L / √P, y = L·√P  (Q96)
        depth = pairIsCurrency0
            ? FullMath.mulDiv(liquidity, 1 << 96, sqrtPriceX96)
            : FullMath.mulDiv(liquidity, sqrtPriceX96, 1 << 96);
    }
}
