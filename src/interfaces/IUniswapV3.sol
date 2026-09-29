// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Subset of Uniswap v3 core used by the v3 bridge (Robinhood Chain factory 0x1f7d7550…5FD2EfA).
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniswapV3Pool {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function liquidity() external view returns (uint128);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    /// @param amountSpecified > 0 exact input, < 0 exact output
    /// @return amount0 amount1 the pool's deltas (> 0 received by the pool, < 0 sent)
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

interface IUniswapV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
}
