// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {V4SwapEngine} from "../base/V4SwapEngine.sol";

/// @notice Dev-only: exact-input swaps along any v4 path (native ETH or ERC20 in), for seeding local accounts on
///         a fork without depending on a chain-specific router. Not part of the protocol.
contract DevSwapRouter is V4SwapEngine {
    using SafeERC20 for IERC20;

    constructor(IPoolManager _poolManager) V4SwapEngine(_poolManager) {}

    receive() external payable {}

    function swapExactIn(PoolKey[] calldata path, address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        payable
        returns (uint256 out)
    {
        if (tokenIn == address(0)) {
            require(msg.value == amountIn, "value");
        } else {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }
        bool ok;
        (ok,, out) = _trySwap(
            _request(EXACT_IN, path, Currency.wrap(tokenIn), Currency.wrap(tokenOut), amountIn, minOut), gasleft()
        );
        require(ok, "swap failed");
        if (tokenOut == address(0)) {
            (bool sent,) = to.call{value: out}("");
            require(sent, "eth");
        } else {
            IERC20(tokenOut).safeTransfer(to, out);
        }
    }
}
