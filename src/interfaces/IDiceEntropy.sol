// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Subset of Dice Protocol's DiceEntropy (Robinhood Chain 4663: 0xd8A0680e7699526B57140ED4EAfdCc7219Dc0A0c,
///         verified on Blockscout 2026-07-23; see research/DICE_INTEGRATION.md). A Pyth Entropy v2 fork with an
///         identical storage/event shape, but: only `requestV2(provider, userRandomNumber, gasLimit)` works (the other
///         overloads revert), the fee is one flat admin-set amount paid exactly, `Request` carries `feePaid`, and the
///         requester may `refundRequest` an unrevealed request after `getRefundDelayBlocks()` blocks.
interface IDiceEntropy {
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
        uint128 feePaid;
    }

    struct ProviderInfo {
        uint128 feeInWei;
        uint128 accruedFeesInWei;
        bytes32 originalCommitment;
        uint64 originalCommitmentSequenceNumber;
        bytes commitmentMetadata;
        bytes uri;
        uint64 endSequenceNumber;
        uint64 sequenceNumber;
        bytes32 currentCommitment;
        uint64 currentCommitmentSequenceNumber;
        address feeManager;
        uint32 maxNumHashes;
        uint32 defaultGasLimit;
    }

    event Requested(
        address indexed provider,
        address indexed caller,
        uint64 indexed sequenceNumber,
        bytes32 userContribution,
        uint32 gasLimit,
        bytes extraArgs
    );
    event Revealed(
        address indexed provider,
        address indexed caller,
        uint64 indexed sequenceNumber,
        bytes32 randomNumber,
        bytes32 userContribution,
        bytes32 providerContribution,
        bool callbackFailed,
        bytes callbackReturnValue,
        uint32 callbackGasUsed,
        bytes extraArgs
    );
    event RequestRefunded(
        address indexed provider, address indexed requester, uint64 indexed sequenceNumber, uint128 amount, bytes extraArgs
    );

    function requestV2(address provider, bytes32 userRandomNumber, uint32 gasLimit)
        external
        payable
        returns (uint64 assignedSequenceNumber);

    function getFeeV2(address provider, uint32 gasLimit) external view returns (uint128 feeAmount);

    function getRequestV2(address provider, uint64 sequenceNumber) external view returns (Request memory req);

    function getProviderInfoV2(address provider) external view returns (ProviderInfo memory info);

    function getDefaultProvider() external view returns (address provider);

    function getRefundDelayBlocks() external view returns (uint64 delayBlocks);

    function revealWithCallback(
        address provider,
        uint64 sequenceNumber,
        bytes32 userContribution,
        bytes32 providerContribution
    ) external;

    function refundRequest(address provider, uint64 sequenceNumber) external;

    function advanceProviderCommitment(address provider, uint64 advancedSequenceNumber, bytes32 providerRevelation)
        external;

    function registerFor(
        address providerAddress,
        uint128 feeInWei,
        bytes32 commitment,
        bytes calldata commitmentMetadata,
        uint64 chainLength,
        bytes calldata uri
    ) external;

    function setDefaultGasLimit(uint32 gasLimit) external;

    function setMaxNumHashes(uint32 maxNumHashes) external;

    function setFee(uint128 feeInWei) external;
}

library DiceStatus {
    uint8 internal constant CALLBACK_NOT_NECESSARY = 0;
    uint8 internal constant CALLBACK_NOT_STARTED = 1;
    uint8 internal constant CALLBACK_IN_PROGRESS = 2;
    uint8 internal constant CALLBACK_FAILED = 3;
}

/// @notice Arbitrum's ArbSys precompile (0x…64): L2 block numbers and hashes (on Nitro, `block.number` is the L1
///         block number and `blockhash` is not an L2 block hash).
interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
    function arbBlockHash(uint256 arbBlockNum) external view returns (bytes32);
}
