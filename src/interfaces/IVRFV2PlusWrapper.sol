// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Subset of Chainlink's VRFV2PlusWrapper (VRF v2.5 direct funding).
interface IVRFV2PlusWrapper {
    function calculateRequestPriceNative(uint32 callbackGasLimit, uint32 numWords) external view returns (uint256);

    function requestRandomWordsInNative(
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        uint32 numWords,
        bytes calldata extraArgs
    ) external payable returns (uint256 requestId);

    /// @dev zeroed once the request is fulfilled
    function s_callbacks(uint256 requestId)
        external
        view
        returns (address callbackAddress, uint32 callbackGasLimit, uint64 requestGasPrice);
}
