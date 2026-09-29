// SPDX-License-Identifier: Apache-2.0
// Derived from Pyth Entropy (https://github.com/pyth-network/pyth-crosschain), Apache-2.0
// Copyright 2024 Pyth Network — original architecture and interfaces
// Copyright 2026 Dice Protocol — modifications for Robinhood Chain deployment
//
// VENDORED, UNMODIFIED CODE — the local Dice double for tests and `dice-mock` dev mode.
// Source: the verified source of DiceEntropy v10 on Robinhood Chain (4663)
//   0xd8A0680e7699526B57140ED4EAfdCc7219Dc0A0c (Blockscout, verified 2026-07-23, solc 0.8.24, via-IR, 200 runs),
//   files src/sdk/{DiceStructsV2,DiceErrors,DiceEventsV2,DiceStatusConstants,IEntropyV2,IEntropy,IEntropyConsumer}.sol,
//   src/DiceState.sol, lib/ExcessivelySafeCall/src/ExcessivelySafeCall.sol (MIT OR Apache-2.0), src/DiceEntropy.sol.
// Flattened into one file in that order; the only changes are merged pragma/import lines (SafeCast now comes from
// this repo's OpenZeppelin). Every contract body is byte-for-byte the verified source. See NOTICE.
pragma solidity ^0.8.0;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// ───── src/sdk/DiceStructsV2.sol ─────

/// @notice Struct definitions for Dice Protocol V2 storage.
/// Dice Protocol component.
contract DiceStructsV2 {
    struct ProviderInfo {
        uint128 feeInWei;
        uint128 accruedFeesInWei;
        // The commitment that the provider posted to the blockchain, and the sequence number
        // where they committed to this. This value is not advanced after the provider commits,
        // and instead is stored to help providers track where they are in the hash chain.
        bytes32 originalCommitment;
        uint64 originalCommitmentSequenceNumber;
        // Metadata for the current commitment. Providers may optionally use this field to help
        // manage rotations (i.e., to pick the sequence number from the correct hash chain).
        bytes commitmentMetadata;
        // Optional URI where clients can retrieve revelations for the provider.
        bytes uri;
        // The first sequence number that is *not* included in the current commitment (exclusive end).
        // The contract maintains the invariant that sequenceNumber <= endSequenceNumber.
        // If sequenceNumber == endSequenceNumber, the provider must rotate their commitment.
        uint64 endSequenceNumber;
        // The sequence number that will be assigned to the next inbound user request.
        uint64 sequenceNumber;
        // The current commitment represents an index/value in the provider's hash chain.
        // These values are used to verify requests for future sequence numbers.
        // currentCommitmentSequenceNumber < sequenceNumber.
        bytes32 currentCommitment;
        uint64 currentCommitmentSequenceNumber;
        // An address that is authorized to set / withdraw fees on behalf of this provider.
        address feeManager;
        // Maximum number of hashes to record in a request.
        uint32 maxNumHashes;
        // Default gas limit to use for callbacks.
        uint32 defaultGasLimit;
    }

    struct Request {
        // Storage slot 1 //
        address provider;
        uint64 sequenceNumber;
        // The number of hashes required to verify the provider revelation.
        uint32 numHashes;
        // Storage slot 2 //
        // The commitment is keccak256(userCommitment, providerCommitment).
        // Storing the hash instead of both saves 20k gas by eliminating 1 store.
        bytes32 commitment;
        // Storage slot 3 //
        // The number of the block where this request was created.
        uint64 blockNumber;
        // The address that requested this random number.
        address requester;
        // If true, incorporate the blockhash of blockNumber into the generated random value.
        bool useBlockhash;
        // Status flag for requests with callbacks. See DiceStatusConstants for possible values.
        uint8 callbackStatus;
        // The gasLimit in units of 10k gas. (i.e., 2 = 20k gas).
        uint16 gasLimit10k;
        // Storage slot 4 //
        // Fee paid for this request at creation time. Stored so refunds remain correct
        // even if the protocol fee changes later.
        uint128 feePaid;
    }
}

// ───── src/sdk/DiceErrors.sol ─────

/// @notice Error definitions for Dice Protocol.
/// Dice Protocol component.
library DiceErrors {
    // An invariant of the contract failed to hold. This error indicates a software logic bug.
    error AssertionFailure();
    // The requested provider does not exist.
    error NoSuchProvider();
    // The specified request does not exist.
    error NoSuchRequest();
    // The randomness provider is out of committed random numbers.
    // The provider needs to rotate their on-chain commitment to resolve this error.
    error OutOfRandomness();
    // The transaction fee was not sufficient.
    error InsufficientFee();
    // Either the user's or the provider's revealed random values did not match their commitment.
    error IncorrectRevelation();
    // The msg.sender is not allowed to invoke this call.
    error Unauthorized();
    // The blockhash is 0.
    error BlockhashUnavailable();
    // If a request was made using `requestWithCallback`, request should be fulfilled using `revealWithCallback`
    // else if a request was made using `request`, request should be fulfilled using `reveal`
    error InvalidRevealCall();
    // The last random number revealed from the provider is too old. Therefore, too many hashes
    // are required for any new reveal. Please update the currentCommitment before making more requests.
    error LastRevealedTooOld();
    // A more recent commitment is already revealed on-chain.
    error UpdateTooOld();
    // Not enough gas was provided to the function to execute the callback with the desired amount of gas.
    error InsufficientGas();
    // A gas limit value was provided that was greater than the maximum possible limit of 655,350,000.
    error MaxGasLimitExceeded();
    // Refund is not available yet (timeout not elapsed) or the request is not refundable.
    error RefundNotAvailable();
}

// ───── src/sdk/DiceEventsV2.sol ─────

/// @notice Events for Dice Protocol V2.
/// Dice Protocol component.
interface DiceEventsV2 {
    /// @notice Emitted when a new provider registers with the Dice Protocol system
    /// @param provider The address of the registered provider
    /// @param extraArgs A field for extra data for forward compatibility
    event Registered(address indexed provider, bytes extraArgs);

    /// @notice Emitted when a user requests a random number from a provider
    /// @param provider The address of the provider handling the request
    /// @param caller The address of the user requesting the random number
    /// @param sequenceNumber A unique identifier for this request
    /// @param userContribution The user's contribution to the random number
    /// @param gasLimit The gas limit for the callback
    /// @param extraArgs A field for extra data for forward compatibility
    event Requested(
        address indexed provider,
        address indexed caller,
        uint64 indexed sequenceNumber,
        bytes32 userContribution,
        uint32 gasLimit,
        bytes extraArgs
    );

    /// @notice Emitted when a provider reveals the generated random number
    /// @param provider The address of the provider that generated the random number
    /// @param caller The address of the user who requested the random number
    /// @param sequenceNumber The unique identifier of the request
    /// @param randomNumber The generated random number
    /// @param userContribution The user's contribution to the random number
    /// @param providerContribution The provider's contribution to the random number
    /// @param callbackFailed Whether the callback to the caller failed
    /// @param callbackReturnValue Return value from the callback
    /// @param callbackGasUsed How much gas the callback used
    /// @param extraArgs A field for extra data for forward compatibility
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

    /// @notice Emitted when a provider updates their fee
    event ProviderFeeUpdated(
        address indexed provider,
        uint128 oldFee,
        uint128 newFee,
        bytes extraArgs
    );

    /// @notice Emitted when a provider updates their default gas limit
    event ProviderDefaultGasLimitUpdated(
        address indexed provider,
        uint32 oldDefaultGasLimit,
        uint32 newDefaultGasLimit,
        bytes extraArgs
    );

    /// @notice Emitted when a provider updates their URI
    event ProviderUriUpdated(
        address indexed provider,
        bytes oldUri,
        bytes newUri,
        bytes extraArgs
    );

    /// @notice Reserved for backward-compatible interface/event support in the single-fee model
    event ProviderFeeManagerUpdated(
        address indexed provider,
        address oldFeeManager,
        address newFeeManager,
        bytes extraArgs
    );

    /// @notice Emitted when a provider updates their maximum number of hashes
    event ProviderMaxNumHashesAdvanced(
        address indexed provider,
        uint32 oldMaxNumHashes,
        uint32 newMaxNumHashes,
        bytes extraArgs
    );

    /// @notice Emitted when a provider withdraws their accumulated fees
    event Withdrawal(
        address indexed provider,
        address indexed recipient,
        uint128 withdrawnAmount,
        bytes extraArgs
    );

    /// @notice Emitted when a requester refunds a stuck request after the timeout
    /// @param provider The provider associated with the request
    /// @param requester The original requester receiving the refund
    /// @param sequenceNumber The request sequence number
    /// @param amount The refunded fee amount in wei
    /// @param extraArgs Forward-compatibility field
    event RequestRefunded(
        address indexed provider,
        address indexed requester,
        uint64 indexed sequenceNumber,
        uint128 amount,
        bytes extraArgs
    );
}

// ───── src/sdk/DiceStatusConstants.sol ─────

/// @notice Callback status constants for Dice Protocol requests.
/// Dice Protocol component.
library DiceStatusConstants {
    // Not a request with callback.
    uint8 public constant CALLBACK_NOT_NECESSARY = 0;
    // A request with callback where the callback hasn't been invoked yet.
    uint8 public constant CALLBACK_NOT_STARTED = 1;
    // A request with callback where the callback is currently in flight (reentry guard).
    uint8 public constant CALLBACK_IN_PROGRESS = 2;
    // A request with callback where the callback has been invoked and failed.
    uint8 public constant CALLBACK_FAILED = 3;
}

// ───── src/sdk/IEntropyV2.sol ─────

/// @notice V2 interface for Dice Protocol — the commit-reveal randomness oracle.
/// Dice Protocol component.
interface IEntropyV2 is DiceEventsV2 {
    /// @notice Request a random number using the default provider with default gas limit
    /// @return assignedSequenceNumber A unique identifier for this request
    function requestV2() external payable returns (uint64 assignedSequenceNumber);

    /// @notice Request a random number using the default provider with specified gas limit
    /// @param gasLimit The gas limit for the callback function
    /// @return assignedSequenceNumber A unique identifier for this request
    function requestV2(uint32 gasLimit) external payable returns (uint64 assignedSequenceNumber);

    /// @notice Request a random number from a specific provider with specified gas limit
    /// @param provider The address of the provider to request from
    /// @param gasLimit The gas limit for the callback function
    /// @return assignedSequenceNumber A unique identifier for this request
    function requestV2(address provider, uint32 gasLimit)
        external
        payable
        returns (uint64 assignedSequenceNumber);

    /// @notice Request a random number from a specific provider with a user-provided random number and gas limit
    /// @param provider The address of the provider to request from
    /// @param userRandomNumber A random number provided by the user for additional entropy
    /// @param gasLimit The gas limit for the callback function. Pass 0 for provider default.
    /// @return assignedSequenceNumber A unique identifier for this request
    function requestV2(address provider, bytes32 userRandomNumber, uint32 gasLimit)
        external
        payable
        returns (uint64 assignedSequenceNumber);

    /// @notice Get information about a specific provider
    function getProviderInfoV2(address provider)
        external
        view
        returns (DiceStructsV2.ProviderInfo memory info);

    /// @notice Get the address of the default provider
    function getDefaultProvider() external view returns (address provider);

    /// @notice Get information about a specific request
    function getRequestV2(address provider, uint64 sequenceNumber)
        external
        view
        returns (DiceStructsV2.Request memory req);

    /// @notice Get the fee charged by the default provider for the default gas limit
    function getFeeV2() external view returns (uint128 feeAmount);

    /// @notice Get the fee charged by the default provider for a specific gas limit
    function getFeeV2(uint32 gasLimit) external view returns (uint128 feeAmount);

    /// @notice Get the fee charged by a specific provider for a request with a given gas limit
    function getFeeV2(address provider, uint32 gasLimit) external view returns (uint128 feeAmount);
}

// ───── src/sdk/IEntropy.sol ─────

/// @notice Full Dice Protocol interface — combines V2 interface with provider management.
interface IEntropy is IEntropyV2 {
    /// @notice Admin-only: register a provider at a specific address.
    /// Exclusive mode — no permissionless registration.
    /// @param providerAddress The address of the provider to register
    /// @param feeInWei The per-request fee the provider charges
    /// @param commitment The provider's initial hash chain commitment (x0)
    /// @param commitmentMetadata Optional metadata for commitment management
    /// @param chainLength The number of values in the hash chain including the commitment (>= 1)
    /// @param uri Optional URI where clients can retrieve revelations
    function registerFor(
        address providerAddress,
        uint128 feeInWei,
        bytes32 commitment,
        bytes calldata commitmentMetadata,
        uint64 chainLength,
        bytes calldata uri
    ) external;

    /// @notice Legacy provider withdrawal path (disabled in the single-fee model)
    /// @param amount The amount to withdraw in wei
    function withdraw(uint128 amount) external;

    /// @notice Legacy fee-manager withdrawal path (disabled in the single-fee model)
    /// @param provider The provider address
    /// @param amount The amount to withdraw in wei
    function withdrawAsFeeManager(address provider, uint128 amount) external;

    /// @notice Reveal the provider's random number for a request (no callback)
    /// @param provider The provider address
    /// @param sequenceNumber The request's sequence number
    /// @param userRevelation The user's revealed random number
    /// @param providerRevelation The provider's revealed random number
    /// @return randomNumber The generated random number
    function reveal(
        address provider,
        uint64 sequenceNumber,
        bytes32 userRevelation,
        bytes32 providerRevelation
    ) external returns (bytes32 randomNumber);

    /// @notice Reveal the provider's random number and trigger the requester's callback
    /// @param provider The provider address
    /// @param sequenceNumber The request's sequence number
    /// @param userRandomNumber The user's random number
    /// @param providerRevelation The provider's revealed random number
    function revealWithCallback(
        address provider,
        uint64 sequenceNumber,
        bytes32 userRandomNumber,
        bytes32 providerRevelation
    ) external;

    /// @notice Refund a stuck active request after the refund timeout has elapsed.
    /// @dev Only the original requester can call this. Clears the request and returns feePaid.
    /// @param provider The provider address
    /// @param sequenceNumber The request sequence number
    function refundRequest(address provider, uint64 sequenceNumber) external;

    /// @notice Get the L1-block delay required before a stuck request can be refunded
    function getRefundDelayBlocks() external view returns (uint64 delayBlocks);

    /// @notice Get provider info (V1 struct format, kept for compatibility)
    function getProviderInfo(address provider)
        external
        view
        returns (DiceStructsV2.ProviderInfo memory info);

    /// @notice Get a request by provider and sequence number (V1 struct format)
    function getRequest(address provider, uint64 sequenceNumber)
        external
        view
        returns (DiceStructsV2.Request memory req);

    /// @notice Get the fee for a request with the default gas limit
    function getFee(address provider) external view returns (uint128 feeAmount);

    /// @notice Get total accrued protocol fees
    function getAccruedTreasuryFees() external view returns (uint128 accruedFeesInWei);

    /// @notice Set the provider's per-request fee
    function setProviderFee(uint128 newFeeInWei) external;

    /// @notice Legacy fee-manager fee update path (disabled in the single-fee model)
    function setProviderFeeAsFeeManager(address provider, uint128 newFeeInWei) external;

    /// @notice Set the provider's URI
    function setProviderUri(bytes calldata newUri) external;

    /// @notice Legacy fee-manager configuration path (disabled in the single-fee model)
    function setFeeManager(address manager) external;

    /// @notice Set the maximum number of hashes to record in a request
    function setMaxNumHashes(uint32 maxNumHashes) external;

    /// @notice Set the default gas limit for callback requests
    function setDefaultGasLimit(uint32 gasLimit) external;

    /// @notice Advance the provider commitment to reduce numHashes for future requests
    function advanceProviderCommitment(
        address provider,
        uint64 advancedSequenceNumber,
        bytes32 providerRevelation
    ) external;

    /// @notice Construct a user commitment from a random number
    function constructUserCommitment(bytes32 userRandomness) external pure returns (bytes32 userCommitment);

    /// @notice Combine user and provider random values (with optional blockhash)
    function combineRandomValues(
        bytes32 userRandomness,
        bytes32 providerRandomness,
        bytes32 blockHash
    ) external pure returns (bytes32 combinedRandomness);
}

// ───── src/sdk/IEntropyConsumer.sol ─────

/// @notice Abstract contract for consuming Dice Protocol randomness.
///         Consumer contracts inherit this and implement entropyCallback().
/// Dice Protocol component.
abstract contract IEntropyConsumer {
    /// @notice Called by the DiceEntropy contract to deliver the random number
    /// @dev Asserts msg.sender is the DiceEntropy contract. Not meant to be overridden.
    function _entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) external {
        address entropy = getEntropy();
        require(entropy != address(0), "Entropy address not set");
        require(msg.sender == entropy, "Only Entropy can call this function");
        entropyCallback(sequence, provider, randomNumber);
    }

    /// @notice Returns the DiceEntropy contract address. Must be implemented by the consumer.
    function getEntropy() internal view virtual returns (address);

    /// @notice Handles the random number. Must be implemented by the consumer.
    function entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) internal virtual;
}

// ───── src/DiceState.sol ─────

/// @notice Internal storage layout for Dice Protocol.
/// Dice Protocol component.
contract DiceInternalStructs {
    struct State {
        // Admin can set the default provider, change fee, and transfer ownership.
        address admin;
        // Single fee per request in wei. All revenue goes to vault.
        uint128 feeInWei;
        // Total accrued fees currently held in the contract.
        uint128 accruedFeesInWei;
        // Vault address that receives all protocol fees.
        address vault;
        // The protocol sets a provider as default to simplify integration for developers.
        address defaultProvider;
        // Hash table for in-flight requests. Two-level: array + overflow mapping.
        DiceStructsV2.Request[32] requests;
        mapping(bytes32 => DiceStructsV2.Request) requestsOverflow;
        // Mapping from randomness providers to their information.
        mapping(address => DiceStructsV2.ProviderInfo) providers;
        // proposedAdmin is the new admin's address pending acceptance.
        address proposedAdmin;
        // L1 blocks that must elapse before a stuck request can be refunded.
        // On Robinhood/Arbitrum Nitro, block.number is L1 (~12s). Default 6 ≈ ~72s.
        uint64 refundDelayBlocks;
    }
}

/// @notice Storage contract for Dice Protocol.
contract DiceState {
    /// @notice Size of the requests hash table array. Must be a power of 2.
    uint8 public constant NUM_REQUESTS = 32;
    /// @notice Bitmask for the requests array index (NUM_REQUESTS - 1).
    bytes1 public constant NUM_REQUESTS_MASK = 0x1f;
    DiceInternalStructs.State _state;
}

// ───── lib/ExcessivelySafeCall/src/ExcessivelySafeCall.sol ─────

library ExcessivelySafeCall {
    uint256 constant LOW_28_MASK =
        0x00000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    /// @notice Use when you _really_ really _really_ don't trust the called
    /// contract. This prevents the called contract from causing reversion of
    /// the caller in as many ways as we can.
    /// @dev The main difference between this and a solidity low-level call is
    /// that we limit the number of bytes that the callee can cause to be
    /// copied to caller memory. This prevents stupid things like malicious
    /// contracts returning 10,000,000 bytes causing a local OOG when copying
    /// to memory.
    /// @param _target The address to call
    /// @param _gas The amount of gas to forward to the remote contract
    /// @param _value The value in wei to send to the remote contract
    /// @param _maxCopy The maximum number of bytes of returndata to copy
    /// to memory.
    /// @param _calldata The data to send to the remote contract
    /// @return success and returndata, as `.call()`. Returndata is capped to
    /// `_maxCopy` bytes.
    function excessivelySafeCall(
        address _target,
        uint256 _gas,
        uint256 _value,
        uint16 _maxCopy,
        bytes memory _calldata
    ) internal returns (bool, bytes memory) {
        // set up for assembly call
        uint256 _toCopy;
        bool _success;
        bytes memory _returnData = new bytes(_maxCopy);
        // dispatch message to recipient
        // by assembly calling "handle" function
        // we call via assembly to avoid memcopying a very large returndata
        // returned by a malicious contract
        assembly {
            _success := call(
                _gas, // gas
                _target, // recipient
                _value, // ether value
                add(_calldata, 0x20), // inloc
                mload(_calldata), // inlen
                0, // outloc
                0 // outlen
            )
            // limit our copy to 256 bytes
            _toCopy := returndatasize()
            if gt(_toCopy, _maxCopy) {
                _toCopy := _maxCopy
            }
            // Store the length of the copied bytes
            mstore(_returnData, _toCopy)
            // copy the bytes from returndata[0:_toCopy]
            returndatacopy(add(_returnData, 0x20), 0, _toCopy)
        }
        return (_success, _returnData);
    }

    /// @notice Use when you _really_ really _really_ don't trust the called
    /// contract. This prevents the called contract from causing reversion of
    /// the caller in as many ways as we can.
    /// @dev The main difference between this and a solidity low-level call is
    /// that we limit the number of bytes that the callee can cause to be
    /// copied to caller memory. This prevents stupid things like malicious
    /// contracts returning 10,000,000 bytes causing a local OOG when copying
    /// to memory.
    /// @param _target The address to call
    /// @param _gas The amount of gas to forward to the remote contract
    /// @param _maxCopy The maximum number of bytes of returndata to copy
    /// to memory.
    /// @param _calldata The data to send to the remote contract
    /// @return success and returndata, as `.call()`. Returndata is capped to
    /// `_maxCopy` bytes.
    function excessivelySafeStaticCall(
        address _target,
        uint256 _gas,
        uint16 _maxCopy,
        bytes memory _calldata
    ) internal view returns (bool, bytes memory) {
        // set up for assembly call
        uint256 _toCopy;
        bool _success;
        bytes memory _returnData = new bytes(_maxCopy);
        // dispatch message to recipient
        // by assembly calling "handle" function
        // we call via assembly to avoid memcopying a very large returndata
        // returned by a malicious contract
        assembly {
            _success := staticcall(
                _gas, // gas
                _target, // recipient
                add(_calldata, 0x20), // inloc
                mload(_calldata), // inlen
                0, // outloc
                0 // outlen
            )
            // limit our copy to 256 bytes
            _toCopy := returndatasize()
            if gt(_toCopy, _maxCopy) {
                _toCopy := _maxCopy
            }
            // Store the length of the copied bytes
            mstore(_returnData, _toCopy)
            // copy the bytes from returndata[0:_toCopy]
            returndatacopy(add(_returnData, 0x20), 0, _toCopy)
        }
        return (_success, _returnData);
    }

    /**
     * @notice Swaps function selectors in encoded contract calls
     * @dev Allows reuse of encoded calldata for functions with identical
     * argument types but different names. It simply swaps out the first 4 bytes
     * for the new selector. This function modifies memory in place, and should
     * only be used with caution.
     * @param _newSelector The new 4-byte selector
     * @param _buf The encoded contract args
     */
    function swapSelector(bytes4 _newSelector, bytes memory _buf)
        internal
        pure
    {
        require(_buf.length >= 4);
        uint256 _mask = LOW_28_MASK;
        assembly {
            // load the first word of
            let _word := mload(add(_buf, 0x20))
            // mask out the top 4 bytes
            // /x
            _word := and(_word, _mask)
            _word := or(_newSelector, _word)
            mstore(add(_buf, 0x20), _word)
        }
    }
}

// ───── src/DiceEntropy.sol ─────

/// @title DiceEntropy
/// @notice Trustless commit-reveal randomness oracle for Robinhood Chain.
///         Dice Protocol RNG contract. Key features:
///         - Immutable (no proxy, no upgradability)
///         - V2 API only (V1 deprecated methods removed)
///         - No governance contract (simple admin role)
///         - Single flat protocol fee, configured on-chain, with vault withdrawal by admin
///         - Exclusive provider registration (admin-only via registerFor)
///         - No blockhash in result (useBlockHash always false for V2)
/// @dev Security: unbiased as long as either the provider or the user is honest.
///      The provider cannot bias because the user's commit is hidden at request time.
///      The user cannot bias because the provider's value is locked in the hash chain.
contract DiceEntropy is IEntropy, DiceState {
    using ExcessivelySafeCall for address;

    uint32 public constant TEN_THOUSAND = 10000;
    uint32 public constant MAX_GAS_LIMIT = uint32(type(uint16).max) * TEN_THOUSAND;

    // ============================================================
    //                        CONSTRUCTOR
    // ============================================================

    /// @param admin The admin address (can set default provider, change fee, transfer ownership)
    /// @param feeInWei Fee per request in wei (all goes to vault)
    /// @param defaultProvider The initial default provider address
    /// @param prefillRequestStorage If true, pre-writes request storage slots for gas consistency
    /// @param vault The vault address that receives all protocol fees
    /// @param providerCommitment The hash chain commitment to auto-register the default provider
    /// @param providerChainLength The chain length for the default provider
    /// @param providerCommitmentMetadata Bincode-serialized CommitmentMetadata {seed, chain_length}
    /// @param refundDelayBlocks L1 blocks that must elapse before a stuck request can be refunded
    constructor(
        address admin,
        uint128 feeInWei,
        address defaultProvider,
        bool prefillRequestStorage,
        address vault,
        bytes32 providerCommitment,
        uint64 providerChainLength,
        bytes memory providerCommitmentMetadata,
        uint64 refundDelayBlocks
    ) {
        require(admin != address(0), "admin is zero address");
        require(defaultProvider != address(0), "defaultProvider is zero address");
        require(vault != address(0), "vault is zero address");
        if (providerChainLength > 0) {
            require(providerCommitment != bytes32(0), "commitment is zero");
        }

        _state.admin = admin;
        _state.feeInWei = feeInWei;
        _state.accruedFeesInWei = 0;
        _state.vault = vault;
        _state.defaultProvider = defaultProvider;
        _state.refundDelayBlocks = refundDelayBlocks;

        if (prefillRequestStorage) {
            for (uint8 i = 0; i < NUM_REQUESTS; i++) {
                DiceStructsV2.Request storage req = _state.requests[i];
                req.provider = address(1);
                req.blockNumber = 1234;
                req.commitment = hex"0123";
            }
        }

        // Auto-register default provider if commitment + chain length provided
        if (providerChainLength > 0) {
            DiceStructsV2.ProviderInfo storage provider = _state.providers[defaultProvider];
            provider.originalCommitment = providerCommitment;
            provider.originalCommitmentSequenceNumber = 0;
            provider.currentCommitment = providerCommitment;
            provider.currentCommitmentSequenceNumber = 0;
            provider.endSequenceNumber = providerChainLength;
            provider.sequenceNumber = 1;
            provider.commitmentMetadata = providerCommitmentMetadata;
            emit DiceEventsV2.Registered(defaultProvider, bytes(""));
        }
    }

    // ============================================================
    //                     PROVIDER REGISTRATION
    // ============================================================

    /// @inheritdoc IEntropy
    function registerFor(
        address providerAddress,
        uint128 feeInWei,
        bytes32 commitment,
        bytes calldata commitmentMetadata,
        uint64 chainLength,
        bytes calldata uri
    ) external override {
        if (msg.sender != _state.admin) revert DiceErrors.Unauthorized();
        if (chainLength == 0) revert DiceErrors.AssertionFailure();
        if (providerAddress == address(0)) revert DiceErrors.AssertionFailure();

        DiceStructsV2.ProviderInfo storage provider = _state.providers[providerAddress];

        // Guard: cannot re-register while requests are in-flight.
        // If the provider already exists, all outstanding requests must be
        // settled before re-registration to avoid making them unfulfillable.
        // "Settled" means the last assigned sequence number has been revealed
        // or commitment advanced to it.
        if (provider.sequenceNumber != 0) {
            require(
                provider.currentCommitmentSequenceNumber >= provider.sequenceNumber - 1,
                "in-flight requests exist"
            );
        }

        // feeInWei parameter is retained for interface compatibility but ignored in the single-fee model
        provider.feeInWei = 0; // per-provider fee is unused in the single-fee model
        provider.originalCommitment = commitment;
        provider.originalCommitmentSequenceNumber = provider.sequenceNumber;
        provider.currentCommitment = commitment;
        provider.currentCommitmentSequenceNumber = provider.sequenceNumber;
        provider.commitmentMetadata = commitmentMetadata;
        provider.endSequenceNumber = provider.sequenceNumber + chainLength;
        provider.uri = uri;
        provider.sequenceNumber += 1;

        emit DiceEventsV2.Registered(providerAddress, bytes(""));
    }

    // ============================================================
    //                       FEE MANAGEMENT
    // ============================================================

    /// @notice Withdraw accrued fees to the vault address.
    /// @dev Only callable by the admin.
    function withdrawFees(uint128 amount) external {
        require(msg.sender == _state.admin, "Only admin");
        require(_state.accruedFeesInWei >= amount, "Insufficient balance");
        _state.accruedFeesInWei -= amount;
        (bool sent,) = _state.vault.call{value: amount}("");
        require(sent, "vault withdrawal failed");
    }

    // ============================================================
    //                       REQUEST HANDLING
    // ============================================================

    /// @dev Internal helper that allocates and stores a new request.
    function requestHelper(
        address provider,
        bytes32 userCommitment,
        bool useBlockhash,
        bool isRequestWithCallback,
        uint32 callbackGasLimit
    ) internal returns (DiceStructsV2.Request storage req) {
        DiceStructsV2.ProviderInfo storage providerInfo = _state.providers[provider];
        if (_state.providers[provider].sequenceNumber == 0) revert DiceErrors.NoSuchProvider();

        // Assign a sequence number
        uint64 assignedSequenceNumber = providerInfo.sequenceNumber;
        if (assignedSequenceNumber >= providerInfo.endSequenceNumber) revert DiceErrors.OutOfRandomness();
        providerInfo.sequenceNumber += 1;

        // Single flat fee, exact payment only
        uint128 requiredFee = getFeeV2(provider, callbackGasLimit);
        if (msg.value != requiredFee) revert DiceErrors.InsufficientFee();
        _state.accruedFeesInWei += requiredFee;

        // Store the request
        req = allocRequest(provider, assignedSequenceNumber);
        req.provider = provider;
        req.sequenceNumber = assignedSequenceNumber;
        req.numHashes = SafeCast.toUint32(assignedSequenceNumber - providerInfo.currentCommitmentSequenceNumber);
        if (providerInfo.maxNumHashes != 0 && req.numHashes > providerInfo.maxNumHashes) {
            revert DiceErrors.LastRevealedTooOld();
        }
        req.commitment = keccak256(bytes.concat(userCommitment, providerInfo.currentCommitment));
        req.requester = msg.sender;
        req.blockNumber = SafeCast.toUint64(block.number);
        req.useBlockhash = useBlockhash;
        req.callbackStatus = isRequestWithCallback
            ? DiceStatusConstants.CALLBACK_NOT_STARTED
            : DiceStatusConstants.CALLBACK_NOT_NECESSARY;
        req.feePaid = requiredFee;

        if (providerInfo.defaultGasLimit == 0) {
            req.gasLimit10k = 0;
        } else {
            req.gasLimit10k = roundTo10kGas(
                callbackGasLimit < providerInfo.defaultGasLimit ? providerInfo.defaultGasLimit : callbackGasLimit
            );
        }
    }

    /// @inheritdoc IEntropyV2
    /// @dev Disabled legacy overload retained for interface compatibility. Users must supply their own entropy through the explicit requestV2(address,bytes32,uint32) path.
    function requestV2() external payable override returns (uint64 assignedSequenceNumber) {
        revert DiceErrors.AssertionFailure();
    }

    /// @inheritdoc IEntropyV2
    /// @dev Disabled legacy overload retained for interface compatibility. Users must supply their own entropy through the explicit requestV2(address,bytes32,uint32) path.
    function requestV2(uint32 gasLimit) external payable override returns (uint64 assignedSequenceNumber) {
        revert DiceErrors.AssertionFailure();
    }

    /// @inheritdoc IEntropyV2
    /// @dev Disabled legacy overload retained for interface compatibility. Users must supply their own entropy through the explicit requestV2(address,bytes32,uint32) path.
    function requestV2(address provider, uint32 gasLimit)
        external
        payable
        override
        returns (uint64 assignedSequenceNumber)
    {
        revert DiceErrors.AssertionFailure();
    }

    /// @inheritdoc IEntropyV2
    function requestV2(address provider, bytes32 userRandomNumber, uint32 gasLimit)
        public
        payable
        override
        returns (uint64)
    {
        DiceStructsV2.Request storage req = requestHelper(
            provider,
            constructUserCommitment(userRandomNumber),
            false,
            true,
            gasLimit
        );

        emit DiceEventsV2.Requested(
            provider,
            req.requester,
            req.sequenceNumber,
            userRandomNumber,
            uint32(req.gasLimit10k) * TEN_THOUSAND,
            bytes("")
        );
        return req.sequenceNumber;
    }

    // ============================================================
    //                        REVEAL
    // ============================================================

    /// @dev Internal: validates revelations and computes the random number.
    function revealHelper(
        DiceStructsV2.Request storage req,
        bytes32 userContribution,
        bytes32 providerContribution
    ) internal returns (bytes32 randomNumber, bytes32 blockHash) {
        bytes32 providerCommitment = constructProviderCommitment(req.numHashes, providerContribution);
        bytes32 userCommitment = constructUserCommitment(userContribution);
        if (keccak256(bytes.concat(userCommitment, providerCommitment)) != req.commitment) {
            revert DiceErrors.IncorrectRevelation();
        }

        blockHash = bytes32(uint256(0));
        if (req.useBlockhash) {
            bytes32 _blockHash = blockhash(req.blockNumber);
            if (_blockHash == bytes32(uint256(0))) revert DiceErrors.BlockhashUnavailable();
            blockHash = _blockHash;
        }

        randomNumber = combineRandomValues(userContribution, providerContribution, blockHash);

        // Advance the provider's current commitment
        DiceStructsV2.ProviderInfo storage providerInfo = _state.providers[req.provider];
        if (providerInfo.currentCommitmentSequenceNumber < req.sequenceNumber) {
            providerInfo.currentCommitmentSequenceNumber = req.sequenceNumber;
            providerInfo.currentCommitment = providerContribution;
        }
    }

    /// @inheritdoc IEntropy
    function reveal(
        address provider,
        uint64 sequenceNumber,
        bytes32 userContribution,
        bytes32 providerContribution
    ) public override returns (bytes32 randomNumber) {
        DiceStructsV2.Request storage req = findActiveRequest(provider, sequenceNumber);
        if (req.callbackStatus != DiceStatusConstants.CALLBACK_NOT_NECESSARY) revert DiceErrors.InvalidRevealCall();
        if (req.requester != msg.sender) revert DiceErrors.Unauthorized();

        bytes32 blockHash;
        (randomNumber, blockHash) = revealHelper(req, userContribution, providerContribution);

        emit DiceEventsV2.Revealed(
            provider, req.requester, sequenceNumber, randomNumber, userContribution, providerContribution, false, "", 0, bytes("")
        );
        clearRequest(provider, sequenceNumber);
    }

    /// @inheritdoc IEntropy
    function revealWithCallback(
        address provider,
        uint64 sequenceNumber,
        bytes32 userContribution,
        bytes32 providerContribution
    ) public override {
        DiceStructsV2.Request storage req = findActiveRequest(provider, sequenceNumber);
        if (
            !(req.callbackStatus == DiceStatusConstants.CALLBACK_NOT_STARTED
                || req.callbackStatus == DiceStatusConstants.CALLBACK_FAILED)
        ) revert DiceErrors.InvalidRevealCall();

        bytes32 randomNumber;
        (randomNumber,) = revealHelper(req, userContribution, providerContribution);

        if (req.gasLimit10k != 0 && req.callbackStatus == DiceStatusConstants.CALLBACK_NOT_STARTED) {
            req.callbackStatus = DiceStatusConstants.CALLBACK_IN_PROGRESS;

            bool success;
            bytes memory ret;
            uint256 startingGas = gasleft();

            (success, ret) = req.requester.excessivelySafeCall(
                uint256(req.gasLimit10k) * TEN_THOUSAND,
                0,
                256,
                abi.encodeWithSelector(
                    IEntropyConsumer._entropyCallback.selector, sequenceNumber, provider, randomNumber
                )
            );

            uint32 gasUsed = SafeCast.toUint32(startingGas - gasleft());
            req.callbackStatus = DiceStatusConstants.CALLBACK_NOT_STARTED;

            if (success) {
                emit DiceEventsV2.Revealed(
                    provider, req.requester, sequenceNumber, randomNumber, userContribution, providerContribution, false, ret, gasUsed, bytes("")
                );
                clearRequest(provider, sequenceNumber);
            } else if ((startingGas * 31) / 32 > uint256(req.gasLimit10k) * TEN_THOUSAND) {
                emit DiceEventsV2.Revealed(
                    provider, req.requester, sequenceNumber, randomNumber, userContribution, providerContribution, true, ret, gasUsed, bytes("")
                );
                req.callbackStatus = DiceStatusConstants.CALLBACK_FAILED;
            } else {
                revert DiceErrors.InsufficientGas();
            }
        } else {
            address callAddress = req.requester;
            clearRequest(provider, sequenceNumber);

            uint len;
            assembly { len := extcodesize(callAddress) }
            bool callbackFailed = false;
            uint256 startingGas = gasleft();
            if (len != 0) {
                // Use excessivelySafeCall for the no-gas-limit / retry path too.
                // This prevents a reverting consumer callback from reverting the
                // entire reveal transaction, which would leave the request stuck.
                (bool callbackSuccess,) = callAddress.excessivelySafeCall(
                    gasleft() * 15 / 16,
                    0,
                    256,
                    abi.encodeWithSelector(
                        IEntropyConsumer._entropyCallback.selector, sequenceNumber, provider, randomNumber
                    )
                );
                callbackFailed = !callbackSuccess;
            }
            uint32 gasUsed = SafeCast.toUint32(startingGas - gasleft());

            emit DiceEventsV2.Revealed(
                provider, callAddress, sequenceNumber, randomNumber, userContribution, providerContribution, callbackFailed, "", gasUsed, bytes("")
            );
        }
    }

    // ============================================================
    //                         REFUNDS
    // ============================================================

    /// @inheritdoc IEntropy
    function refundRequest(address provider, uint64 sequenceNumber) external override {
        DiceStructsV2.Request storage req = findActiveRequest(provider, sequenceNumber);
        if (req.requester != msg.sender) revert DiceErrors.Unauthorized();
        // On Robinhood/Arbitrum Nitro, block.number is L1 (~12s/block). Default 6 ≈ ~72s.
        if (block.number < uint256(req.blockNumber) + uint256(_state.refundDelayBlocks)) {
            revert DiceErrors.RefundNotAvailable();
        }

        address requester = req.requester;
        uint128 amount = req.feePaid;

        // Clear first to prevent reentrancy / double-refund.
        clearRequest(provider, sequenceNumber);

        if (amount > 0) {
            require(_state.accruedFeesInWei >= amount, "Insufficient accrued fees");
            _state.accruedFeesInWei -= amount;
            (bool sent,) = requester.call{value: amount}("");
            require(sent, "refund transfer failed");
        }

        emit DiceEventsV2.RequestRefunded(provider, requester, sequenceNumber, amount, bytes(""));
    }

    /// @inheritdoc IEntropy
    function getRefundDelayBlocks() external view override returns (uint64 delayBlocks) {
        delayBlocks = _state.refundDelayBlocks;
    }

    // ============================================================
    //                  COMMITMENT ADVANCEMENT
    // ============================================================

    /// @inheritdoc IEntropy
    function advanceProviderCommitment(
        address provider,
        uint64 advancedSequenceNumber,
        bytes32 providerRevelation
    ) public override {
        DiceStructsV2.ProviderInfo storage providerInfo = _state.providers[provider];
        if (advancedSequenceNumber <= providerInfo.currentCommitmentSequenceNumber) revert DiceErrors.UpdateTooOld();
        if (advancedSequenceNumber >= providerInfo.endSequenceNumber) revert DiceErrors.AssertionFailure();

        uint32 numHashes = SafeCast.toUint32(advancedSequenceNumber - providerInfo.currentCommitmentSequenceNumber);
        bytes32 providerCommitment = constructProviderCommitment(numHashes, providerRevelation);
        if (providerCommitment != providerInfo.currentCommitment) revert DiceErrors.IncorrectRevelation();

        providerInfo.currentCommitmentSequenceNumber = advancedSequenceNumber;
        providerInfo.currentCommitment = providerRevelation;

        // If the advancement passes the sequence number, bump it to prevent
        // assigning sequence numbers that are already revealed.
        if (providerInfo.currentCommitmentSequenceNumber >= providerInfo.sequenceNumber) {
            providerInfo.sequenceNumber = providerInfo.currentCommitmentSequenceNumber + 1;
        }
    }

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================

    /// @inheritdoc IEntropy
    function getProviderInfo(address provider) public view override returns (DiceStructsV2.ProviderInfo memory info) {
        info = _state.providers[provider];
    }

    /// @inheritdoc IEntropyV2
    function getProviderInfoV2(address provider) public view override returns (DiceStructsV2.ProviderInfo memory info) {
        info = _state.providers[provider];
    }

    /// @inheritdoc IEntropyV2
    function getDefaultProvider() public view override returns (address provider) {
        provider = _state.defaultProvider;
    }

    /// @inheritdoc IEntropy
    function getRequest(address provider, uint64 sequenceNumber)
        public
        view
        override
        returns (DiceStructsV2.Request memory req)
    {
        req = findRequest(provider, sequenceNumber);
    }

    /// @inheritdoc IEntropyV2
    function getRequestV2(address provider, uint64 sequenceNumber)
        public
        view
        override
        returns (DiceStructsV2.Request memory req)
    {
        req = findRequest(provider, sequenceNumber);
    }

    /// @inheritdoc IEntropy
    function getFee(address provider) public view override returns (uint128 feeAmount) {
        return _state.feeInWei;
    }

    /// @inheritdoc IEntropyV2
    function getFeeV2() external view override returns (uint128 feeAmount) {
        return _state.feeInWei;
    }

    /// @inheritdoc IEntropyV2
    function getFeeV2(uint32 gasLimit) external view override returns (uint128 feeAmount) {
        return _state.feeInWei;
    }

    /// @inheritdoc IEntropyV2
    function getFeeV2(address provider, uint32 gasLimit) public view override returns (uint128 feeAmount) {
        return _state.feeInWei;
    }

    /// @notice Get total fees accrued in the contract.
    function getAccruedFees() public view returns (uint128) {
        return _state.accruedFeesInWei;
    }

    /// @notice Get the current fee per request.
    function getProtocolFee() public view returns (uint128) {
        return _state.feeInWei;
    }

    // ============================================================
    //                   PROVIDER CONFIGURATION
    // ============================================================

    /// @inheritdoc IEntropy
    function setProviderFee(uint128 newFeeInWei) external override {
        // Disabled in the single-fee model; admin manages protocol fee via setFee()
        revert DiceErrors.Unauthorized();
    }

    /// @inheritdoc IEntropy
    function setProviderFeeAsFeeManager(address provider, uint128 newFeeInWei) external override {
        revert DiceErrors.Unauthorized();
    }

    /// @inheritdoc IEntropy
    function setProviderUri(bytes calldata newUri) external override {
        DiceStructsV2.ProviderInfo storage provider = _state.providers[msg.sender];
        if (provider.sequenceNumber == 0) revert DiceErrors.NoSuchProvider();
        bytes memory oldUri = provider.uri;
        provider.uri = newUri;
        emit DiceEventsV2.ProviderUriUpdated(msg.sender, oldUri, newUri, bytes(""));
    }

    /// @inheritdoc IEntropy
    function setFeeManager(address manager) external override {
        // Fee manager model removed — single fee to vault
        revert DiceErrors.Unauthorized();
    }

    /// @inheritdoc IEntropy
    function setMaxNumHashes(uint32 maxNumHashes) external override {
        DiceStructsV2.ProviderInfo storage provider = _state.providers[msg.sender];
        if (provider.sequenceNumber == 0) revert DiceErrors.NoSuchProvider();
        uint32 oldMaxNumHashes = provider.maxNumHashes;
        provider.maxNumHashes = maxNumHashes;
        emit DiceEventsV2.ProviderMaxNumHashesAdvanced(msg.sender, oldMaxNumHashes, maxNumHashes, bytes(""));
    }

    /// @inheritdoc IEntropy
    function setDefaultGasLimit(uint32 gasLimit) external override {
        DiceStructsV2.ProviderInfo storage provider = _state.providers[msg.sender];
        if (provider.sequenceNumber == 0) revert DiceErrors.NoSuchProvider();
        roundTo10kGas(gasLimit);
        uint32 oldGasLimit = provider.defaultGasLimit;
        provider.defaultGasLimit = gasLimit;
        emit DiceEventsV2.ProviderDefaultGasLimitUpdated(msg.sender, oldGasLimit, gasLimit, bytes(""));
    }

    /// @inheritdoc IEntropy
    function withdraw(uint128 amount) public override {
        // Per-provider withdrawal removed — admin uses withdrawFees() to send to vault
        revert DiceErrors.Unauthorized();
    }

    /// @inheritdoc IEntropy
    function withdrawAsFeeManager(address provider, uint128 amount) external override {
        revert DiceErrors.Unauthorized();
    }

    /// @notice Get accrued protocol fees via the legacy backward-compatible interface method.
    function getAccruedTreasuryFees() public view override returns (uint128) {
        return _state.accruedFeesInWei;
    }

    // ============================================================
    //                    ADMIN FUNCTIONS
    // ============================================================

    /// @notice Propose a new admin. Must be accepted by the new admin.
    function proposeAdmin(address newAdmin) external {
        require(msg.sender == _state.admin, "Only admin");
        require(newAdmin != address(0), "admin is zero address");
        _state.proposedAdmin = newAdmin;
    }

    /// @notice Accept the admin role. Must be called by the proposed admin.
    function acceptAdmin() external {
        require(msg.sender == _state.proposedAdmin, "Not proposed");
        _state.admin = _state.proposedAdmin;
        _state.proposedAdmin = address(0);
    }

    /// @notice Set the default provider. Only admin.
    function setDefaultProvider(address provider) external {
        require(msg.sender == _state.admin, "Only admin");
        _state.defaultProvider = provider;
    }

    /// @notice Set the protocol fee per request. Only admin.
    function setFee(uint128 feeInWei) external {
        require(msg.sender == _state.admin, "Only admin");
        _state.feeInWei = feeInWei;
    }

    // ============================================================
    //                    PURE FUNCTIONS
    // ============================================================

    /// @inheritdoc IEntropy
    function constructUserCommitment(bytes32 userRandomness) public pure override returns (bytes32 userCommitment) {
        userCommitment = keccak256(bytes.concat(userRandomness));
    }

    /// @inheritdoc IEntropy
    function combineRandomValues(
        bytes32 userRandomness,
        bytes32 providerRandomness,
        bytes32 blockHash
    ) public pure override returns (bytes32 combinedRandomness) {
        combinedRandomness = keccak256(abi.encodePacked(userRandomness, providerRandomness, blockHash));
    }

    // ============================================================
    //                   INTERNAL HELPERS
    // ============================================================

    function roundTo10kGas(uint32 gas) internal pure returns (uint16) {
        if (gas > MAX_GAS_LIMIT) revert DiceErrors.MaxGasLimitExceeded();
        uint32 gas10k = gas / TEN_THOUSAND;
        if (gas10k * TEN_THOUSAND < gas) gas10k += 1;
        return SafeCast.toUint16(gas10k);
    }

    function requestKey(address provider, uint64 sequenceNumber)
        internal
        pure
        returns (bytes32 hash, uint8 shortHash)
    {
        hash = keccak256(abi.encodePacked(provider, sequenceNumber));
        shortHash = uint8(hash[0] & NUM_REQUESTS_MASK);
    }

    function constructProviderCommitment(uint64 numHashes, bytes32 revelation)
        internal
        pure
        returns (bytes32 currentHash)
    {
        currentHash = revelation;
        while (numHashes > 0) {
            currentHash = keccak256(bytes.concat(currentHash));
            numHashes -= 1;
        }
    }

    function findActiveRequest(address provider, uint64 sequenceNumber)
        internal
        view
        returns (DiceStructsV2.Request storage req)
    {
        req = findRequest(provider, sequenceNumber);
        if (!isActive(req) || req.provider != provider || req.sequenceNumber != sequenceNumber) {
            revert DiceErrors.NoSuchRequest();
        }
    }

    function findRequest(address provider, uint64 sequenceNumber)
        internal
        view
        returns (DiceStructsV2.Request storage req)
    {
        (bytes32 key, uint8 shortKey) = requestKey(provider, sequenceNumber);
        req = _state.requests[shortKey];
        if (req.provider == provider && req.sequenceNumber == sequenceNumber) {
            return req;
        } else {
            req = _state.requestsOverflow[key];
        }
    }

    function clearRequest(address provider, uint64 sequenceNumber) internal {
        (bytes32 key, uint8 shortKey) = requestKey(provider, sequenceNumber);
        DiceStructsV2.Request storage req = _state.requests[shortKey];
        if (req.provider == provider && req.sequenceNumber == sequenceNumber) {
            req.sequenceNumber = 0;
        } else {
            delete _state.requestsOverflow[key];
        }
    }

    function allocRequest(address provider, uint64 sequenceNumber)
        internal
        returns (DiceStructsV2.Request storage req)
    {
        (, uint8 shortKey) = requestKey(provider, sequenceNumber);
        req = _state.requests[shortKey];
        if (isActive(req)) {
            (bytes32 reqKey,) = requestKey(req.provider, req.sequenceNumber);
            _state.requestsOverflow[reqKey] = req;
        }
    }

    function isActive(DiceStructsV2.Request storage req) internal view returns (bool) {
        return req.sequenceNumber != 0;
    }
}
