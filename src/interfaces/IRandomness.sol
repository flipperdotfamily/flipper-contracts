// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Provider-agnostic randomness source used by the house (Dice / Pyth Entropy v2, Chainlink VRF v2.5).
interface IRandomnessAdapter {
    /// @notice Native fee for a request whose consumer callback needs `callbackGasLimit` gas.
    function fee(uint32 callbackGasLimit) external view returns (uint256);

    /// @notice Request one random word; only the bound consumer may call. `msg.value` must equal `fee()`.
    /// @return requestId globally unique id echoed back in `onRandomness`
    function request(uint32 callbackGasLimit) external payable returns (uint256 requestId);

    /// @notice True while the randomness for `requestId` is provably not yet revealed onchain.
    function isPending(uint256 requestId) external view returns (bool);
}

interface IRandomnessConsumer {
    /// @param safeMode true when this delivery can't be trusted to be un-timed: a retry of a failed (therefore
    ///        publicly revealed) delivery. The consumer must then settle without touching any market.
    function onRandomness(uint256 requestId, uint256 randomWord, bool safeMode) external;
}
