// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {IUniswapV3Factory, IUniswapV3Pool, IUniswapV3SwapCallback, IWETH9} from "../interfaces/IUniswapV3.sol";

/// @title V3BridgeHook
/// @notice A Uniswap v4 hook that turns a canonical Uniswap v3 pool into a v4 pool, so v4-only routers (the house's
///         V4SwapEngine) can swap through v3 liquidity unchanged.
///
///   - Each bridged v3 pool gets one v4 pool: the same two currencies (WETH shown as native ETH), the v3 fee and
///     tick spacing, and this hook. It is created only through `bridge` (permissionless, checked against the v3
///     factory) and never holds liquidity.
///   - `beforeSwap` consumes the whole swap ("custom curve"): it takes the input from the PoolManager, swaps it in
///     the v3 pool (wrapping / unwrapping ETH), settles the output back and returns the matching delta, so the v4
///     AMM step is a no-op. Exact input and exact output are both supported and must fill completely.
///   - Quotes: the house reverts the whole unlock, the v3 swap included. A pure quote never pays its input, so when
///     the PoolManager doesn't hold the input the v3 swap is priced and reverted (QuoterV2-style) instead.
///   - The hook keeps no balances between calls and only pays a v3 pool from inside that pool's own callback.
contract V3BridgeHook is IHooks, IUniswapV3SwapCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    /// transient slot holding the v3 pool of the swap in progress (its callback is the only one accepted)
    bytes32 internal constant ACTIVE_POOL_SLOT = keccak256("flipper.v3bridge.activePool");

    IPoolManager public immutable poolManager;
    IUniswapV3Factory public immutable v3Factory;
    address public immutable weth;

    /// v4 bridge pool → the v3 pool it swaps through
    mapping(PoolId => address) public v3PoolOf;
    /// v3 pool → its v4 bridge key's id (0 until bridged)
    mapping(address => PoolId) public bridgeIdOf;

    event Bridged(address indexed v3Pool, bytes32 indexed poolId, PoolKey key);

    error NotPoolManager();
    error NotV3Pool();
    error NotActivePool();
    error Unsupported();
    error PartialFill();
    /// @dev raised from the v3 callback to price a swap without moving anything (see beforeSwap)
    error QuoteOnly(int256 amount0, int256 amount1);

    constructor(IPoolManager _poolManager, IUniswapV3Factory _v3Factory, address _weth) {
        poolManager = _poolManager;
        v3Factory = _v3Factory;
        weth = _weth;
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    /// ETH arrives only from the PoolManager (`take` of a native input) or WETH (`withdraw` of a native output)
    receive() external payable {
        if (msg.sender != weth && msg.sender != address(poolManager)) revert Unsupported();
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Bridging
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice The v4 key that bridges `v3Pool` (whether or not it has been created yet).
    function keyFor(address v3Pool) public view returns (PoolKey memory key) {
        IUniswapV3Pool p = IUniswapV3Pool(v3Pool);
        Currency a = _v4Currency(p.token0());
        Currency b = _v4Currency(p.token1());
        (Currency c0, Currency c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        key = PoolKey(c0, c1, p.fee(), p.tickSpacing(), IHooks(address(this)));
    }

    /// @notice Create (once) the v4 pool that bridges a canonical v3 pool. Permissionless.
    function bridge(address v3Pool) external returns (PoolKey memory key) {
        if (!isCanonical(v3Pool)) revert NotV3Pool();
        key = keyFor(v3Pool);
        PoolId id = key.toId();
        if (v3PoolOf[id] != address(0)) return key;
        v3PoolOf[id] = v3Pool;
        bridgeIdOf[v3Pool] = id;
        poolManager.initialize(key, SQRT_PRICE_1_1);
        emit Bridged(v3Pool, PoolId.unwrap(id), key);
    }

    /// @notice True if `v3Pool` is the v3 factory's pool for its own (token0, token1, fee).
    function isCanonical(address v3Pool) public view returns (bool) {
        if (v3Pool.code.length == 0) return false;
        try this.canonicalPool(v3Pool) returns (address p) {
            return p == v3Pool;
        } catch {
            return false;
        }
    }

    /// @dev external so `isCanonical` can treat a non-pool contract (reverting getters) as "not canonical"
    function canonicalPool(address v3Pool) external view returns (address) {
        IUniswapV3Pool p = IUniswapV3Pool(v3Pool);
        return v3Factory.getPool(p.token0(), p.token1(), p.fee());
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Hooks
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// only `bridge` creates pools with this hook
    function beforeInitialize(address sender, PoolKey calldata, uint160) external view onlyPoolManager returns (bytes4) {
        if (sender != address(this)) revert Unsupported();
        return IHooks.beforeInitialize.selector;
    }

    /// bridge pools hold no liquidity
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert Unsupported();
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address v3Pool = v3PoolOf[key.toId()];
        if (v3Pool == address(0)) revert Unsupported();
        (Currency cIn, Currency cOut) = params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        address tIn = _v3Token(cIn);
        bool v3ZeroForOne = tIn < _v3Token(cOut);
        bool exactIn = params.amountSpecified < 0;
        uint256 specified = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        address prev = _active(); // token code may nest another bridge swap inside this one
        _setActive(v3Pool);
        int256 a0;
        int256 a1;
        bool moved = true;
        try IUniswapV3Pool(v3Pool).swap(
            address(this),
            v3ZeroForOne,
            exactIn ? int256(specified) : -int256(specified),
            v3ZeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
            abi.encode(cIn)
        ) returns (int256 x0, int256 x1) {
            (a0, a1) = (x0, x1);
        } catch (bytes memory reason) {
            // the PoolManager doesn't hold the input (a pure quote, whose swapper never pays): the callback
            // reverted with the v3 amounts and nothing moved. The delta below still prices the swap; in anything
            // but a quote the hook is left owed an input only it could collect, so the unlock can't settle.
            if (reason.length != 68 || bytes4(reason) != QuoteOnly.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
            assembly ("memory-safe") {
                a0 := mload(add(reason, 36))
                a1 := mload(add(reason, 68))
            }
            moved = false;
        }
        _setActive(prev);
        (int256 dIn, int256 dOut) = v3ZeroForOne ? (a0, a1) : (a1, a0);
        uint256 amountIn = uint256(dIn);
        uint256 amountOut = uint256(-dOut);
        // a partial fill (the v3 pool ran out of liquidity at the price limit) fails the whole swap
        if (exactIn ? amountIn != specified : amountOut != specified) revert PartialFill();

        // hand the output to the PoolManager (the swapper takes it)
        if (moved) {
            if (cOut.isAddressZero()) {
                IWETH9(weth).withdraw(amountOut);
                poolManager.settle{value: amountOut}();
            } else {
                poolManager.sync(cOut);
                IERC20(Currency.unwrap(cOut)).safeTransfer(address(poolManager), amountOut);
                poolManager.settle();
            }
        }

        // the hook took the input and provided the output: the swapper's delta is (-amountIn, +amountOut)
        BeforeSwapDelta delta = exactIn
            ? toBeforeSwapDelta(int128(int256(specified)), -int128(int256(amountOut)))
            : toBeforeSwapDelta(-int128(int256(specified)), int128(int256(amountIn)));
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    /// @notice v3 swap callback: pay the pool its input, taken from the PoolManager (wrapped if it is ETH).
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != _active() || msg.sender == address(0)) revert NotActivePool();
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        Currency cIn = abi.decode(data, (Currency));
        if (cIn.balanceOf(address(poolManager)) < owed) revert QuoteOnly(amount0Delta, amount1Delta);
        poolManager.take(cIn, address(this), owed);
        if (cIn.isAddressZero()) {
            IWETH9(weth).deposit{value: owed}();
            IERC20(weth).safeTransfer(msg.sender, owed);
        } else {
            IERC20(Currency.unwrap(cIn)).safeTransfer(msg.sender, owed);
        }
    }

    // ── unused hooks (not in the permission bits: the PoolManager never calls them) ──────────────────────

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert Unsupported();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert Unsupported();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert Unsupported();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert Unsupported();
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert Unsupported();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert Unsupported();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert Unsupported();
    }

    // ── internal ─────────────────────────────────────────────────────────────────────────────────────────

    function _v4Currency(address token) internal view returns (Currency) {
        return Currency.wrap(token == weth ? address(0) : token);
    }

    function _v3Token(Currency c) internal view returns (address) {
        return c.isAddressZero() ? weth : Currency.unwrap(c);
    }

    function _setActive(address pool) internal {
        bytes32 slot = ACTIVE_POOL_SLOT;
        assembly ("memory-safe") {
            tstore(slot, pool)
        }
    }

    function _active() internal view returns (address pool) {
        bytes32 slot = ACTIVE_POOL_SLOT;
        assembly ("memory-safe") {
            pool := tload(slot)
        }
    }
}
