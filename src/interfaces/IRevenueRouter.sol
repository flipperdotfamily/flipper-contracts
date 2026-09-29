// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRevenueRouter {
    /// @notice Called by the house right after transferring `amount` $FLIPPER of skimmed profit that is
    ///         earmarked 100% for launchpad-token rewards.
    function onHouseRewards(uint256 amount) external;
}
