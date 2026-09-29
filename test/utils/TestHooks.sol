// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTestHooks} from "v4-core/test/BaseTestHooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

/// @notice beforeSwap hook that can refuse or gas-grief swaps per direction (simulates a pool that is shut off,
///         upgraded, or griefed between request and settlement).
contract ToggleHook is BaseTestHooks {
    bool public blockZeroForOne;
    bool public blockOneForZero;
    bool public burnZeroForOne;
    bool public burnOneForZero;

    function set(bool _blockZeroForOne, bool _blockOneForZero, bool _burnZeroForOne, bool _burnOneForZero) external {
        blockZeroForOne = _blockZeroForOne;
        blockOneForZero = _blockOneForZero;
        burnZeroForOne = _burnZeroForOne;
        burnOneForZero = _burnOneForZero;
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata p, bytes calldata)
        external
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (p.zeroForOne ? blockZeroForOne : blockOneForZero) revert("ToggleHook: blocked");
        if (p.zeroForOne ? burnZeroForOne : burnOneForZero) {
            uint256 x;
            while (gasleft() > 0) x++;
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
