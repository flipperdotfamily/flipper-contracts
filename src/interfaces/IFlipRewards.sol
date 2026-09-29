// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IFlipRewards {
    /// @notice Credit settled flip volume (denominated in $FLIPPER) to `player` for the current epoch.
    function recordVolume(address player, uint256 points) external;
}
