// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Subset of the Pyth Entropy v2 interface (Dice on Robinhood Chain implements the same).
interface IEntropyV2 {
    struct Request {
        address provider;
        uint64 sequenceNumber;
        uint32 numHashes;
        bytes32 commitment;
        uint64 blockNumber;
        address requester;
        bool useBlockhash;
        uint8 callbackStatus;
        uint16 gasLimit10k;
    }

    function requestV2(address provider, uint32 gasLimit) external payable returns (uint64 assignedSequenceNumber);

    function getFeeV2(address provider, uint32 gasLimit) external view returns (uint128 feeAmount);

    function getRequestV2(address provider, uint64 sequenceNumber) external view returns (Request memory req);

    function getDefaultProvider() external view returns (address provider);
}

library EntropyStatus {
    uint8 internal constant CALLBACK_NOT_NECESSARY = 0;
    uint8 internal constant CALLBACK_NOT_STARTED = 1;
    uint8 internal constant CALLBACK_IN_PROGRESS = 2;
    uint8 internal constant CALLBACK_FAILED = 3;
}
