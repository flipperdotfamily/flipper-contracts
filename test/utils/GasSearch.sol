// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice eth_estimateGas in a test: the least gas at which a call from `from` succeeds (binary search, state
///         restored after every probe). Running a call at exactly that gas is what a wallet or relayer does.
abstract contract GasSearch is Test {
    function _estimate(address from, address target, bytes memory data, uint256 value) internal returns (uint256 hi) {
        uint256 lo;
        hi = 20_000_000;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(from, from);
            (bool ok,) = target.call{gas: mid, value: value}(data);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
    }

    /// @dev run `data` from `from` with exactly the estimated gas; reverts if it fails
    function _callAtEstimate(address from, address target, bytes memory data, uint256 value)
        internal
        returns (uint256 gasUsed)
    {
        gasUsed = _estimate(from, target, data, value);
        vm.prank(from, from);
        (bool ok,) = target.call{gas: gasUsed, value: value}(data);
        require(ok, "call at the estimate failed");
    }
}
