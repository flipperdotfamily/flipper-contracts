// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {IWETH9} from "../interfaces/IUniswapV3.sol";

/// @title WethWrapperHook
/// @notice A Uniswap v4 hook that makes one liquidity-free pool, (native ETH, WETH, fee 0, tick spacing 1, this hook),
///         swap 1:1 by wrapping and unwrapping — in the style of v4-periphery's `WETHHook` / `BaseTokenWrapperHook`.
///         It gives WETH a zero-slippage, zero-fee route to native ETH, so WETH lists and flips through the ordinary
///         route [WETH/ETH wrapper pool, ETH/$FLIPPER] without a WETH pool of its own.
///
///   - Exactly one pool uses this hook: it is created only through `initialize()` and never holds liquidity.
///   - `beforeSwap` consumes the whole swap ("custom curve"): it takes the input from the PoolManager, wraps or
///     unwraps it, settles the same amount of the other currency back and returns the matching delta, so the v4 AMM
///     step is a no-op. Exact input and exact output both clear 1:1.
///   - Pure quotes (the swapper never pays) whose input the PoolManager doesn't hold are priced 1:1 without moving
///     anything; such an unlock can't settle, which only a reverting quote tolerates.
///   - No owner, no fee, no state: the hook keeps no balances between calls.
contract WethWrapperHook is IHooks {
    using SafeERC20 for IERC20;

    uint24 public constant FEE = 0;
    int24 public constant TICK_SPACING = 1;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    IPoolManager public immutable poolManager;
    address public immutable weth;

    error NotPoolManager();
    error Unsupported();

    constructor(IPoolManager _poolManager, address _weth) {
        poolManager = _poolManager;
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

    /// ETH arrives only from WETH (`withdraw`) or the PoolManager (`take` of a native input)
    receive() external payable {
        if (msg.sender != weth && msg.sender != address(poolManager)) revert Unsupported();
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @notice The wrapper pool's key: currency0 native ETH, currency1 WETH.
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(weth), FEE, TICK_SPACING, IHooks(address(this)));
    }

    /// @notice Create the wrapper pool (once; permissionless).
    function initialize() external returns (PoolKey memory key) {
        key = poolKey();
        poolManager.initialize(key, SQRT_PRICE_1_1);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Hooks
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// only `initialize` creates a pool with this hook
    function beforeInitialize(address sender, PoolKey calldata, uint160) external view onlyPoolManager returns (bytes4) {
        if (sender != address(this)) revert Unsupported();
        return IHooks.beforeInitialize.selector;
    }

    /// the wrapper pool holds no liquidity
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert Unsupported();
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool exactIn = params.amountSpecified < 0;
        uint256 amount = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        if (amount > uint128(type(int128).max)) revert Unsupported();
        // zeroForOne: ETH in → WETH out (wrap); else WETH in → ETH out (unwrap)
        Currency cIn = params.zeroForOne ? Currency.wrap(address(0)) : Currency.wrap(weth);
        if (cIn.balanceOf(address(poolManager)) >= amount) {
            poolManager.take(cIn, address(this), amount);
            if (params.zeroForOne) {
                IWETH9(weth).deposit{value: amount}();
                poolManager.sync(Currency.wrap(weth));
                IERC20(weth).safeTransfer(address(poolManager), amount);
                poolManager.settle();
            } else {
                IWETH9(weth).withdraw(amount);
                poolManager.settle{value: amount}();
            }
        }
        // the hook took the input and provided the same amount of output
        int128 a = int128(int256(amount));
        BeforeSwapDelta delta = exactIn ? toBeforeSwapDelta(a, -a) : toBeforeSwapDelta(-a, a);
        return (IHooks.beforeSwap.selector, delta, 0);
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
}
