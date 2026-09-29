// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3SwapCallback} from "../../src/interfaces/IUniswapV3.sol";

/// @notice Constant-price stand-in for a Uniswap v3 pool with v3's swap/callback semantics: the output is sent first,
///         then `uniswapV3SwapCallback` must pay the input (checked by balance). `price` = token1 per token0 (1e18),
///         the fee is taken on the input like v3, and `maxOut` caps a swap's output to simulate running out of
///         liquidity at the price limit (a partial fill).
contract MockV3Pool {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    uint256 public price; // token1 per token0, 1e18
    uint128 public liquidity;
    uint160 public sqrtPriceX96;
    uint256 public maxOut = type(uint256).max;

    constructor(address _t0, address _t1, uint24 _fee, int24 _ts, uint256 _price) {
        factory = msg.sender;
        token0 = _t0;
        token1 = _t1;
        fee = _fee;
        tickSpacing = _ts;
        price = _price;
    }

    function setState(uint128 _liquidity, uint160 _sqrtPriceX96) external {
        liquidity = _liquidity;
        sqrtPriceX96 = _sqrtPriceX96;
    }

    function setMaxOut(uint256 m) external {
        maxOut = m;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 1, 1, 0, true);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 limit, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        // v3's own bounds on the price limit (TickMath.MIN_SQRT_RATIO / MAX_SQRT_RATIO, exclusive)
        require(
            limit > 4295128739 && limit < 1461446703485210103287273052203988822378723970342, "SPL"
        );
        bool exactIn = amountSpecified > 0;
        uint256 spec = exactIn ? uint256(amountSpecified) : uint256(-amountSpecified);
        uint256 amountIn;
        uint256 amountOut;
        if (exactIn) {
            amountIn = spec;
            amountOut = _out(zeroForOne, spec * (1e6 - fee) / 1e6);
        } else {
            amountOut = spec;
            amountIn = _in(zeroForOne, spec) * 1e6 / (1e6 - fee) + 1;
        }
        if (amountOut > maxOut) {
            // like v3 hitting the price limit: fill what liquidity allows
            amountOut = maxOut;
            if (exactIn) amountIn = amountIn / 2;
        }
        (address tIn, address tOut) = zeroForOne ? (token0, token1) : (token1, token0);
        IERC20(tOut).transfer(recipient, amountOut);
        uint256 before = IERC20(tIn).balanceOf(address(this));
        (amount0, amount1) = zeroForOne
            ? (int256(amountIn), -int256(amountOut))
            : (-int256(amountOut), int256(amountIn));
        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(IERC20(tIn).balanceOf(address(this)) >= before + amountIn, "IIA");
    }

    function _out(bool zeroForOne, uint256 amountIn) internal view returns (uint256) {
        return zeroForOne ? amountIn * price / 1e18 : amountIn * 1e18 / price;
    }

    function _in(bool zeroForOne, uint256 amountOut) internal view returns (uint256) {
        return zeroForOne ? amountOut * 1e18 / price + 1 : amountOut * price / 1e18 + 1;
    }
}

contract MockV3Factory {
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;

    function createPool(address a, address b, uint24 fee, int24 ts, uint256 priceToken1PerToken0)
        external
        returns (MockV3Pool pool)
    {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        pool = new MockV3Pool(t0, t1, fee, ts, priceToken1PerToken0);
        getPool[t0][t1][fee] = address(pool);
        getPool[t1][t0][fee] = address(pool);
    }
}
