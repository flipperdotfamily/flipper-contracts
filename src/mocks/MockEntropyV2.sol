// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IEntropyV2, EntropyStatus} from "../interfaces/IEntropyV2.sol";

interface IEntropyConsumerCallback {
    function _entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) external;
}

/// @notice Test double for Pyth Entropy v2 that reproduces the deployed `revealWithCallback` semantics:
///   - first attempt: status IN_PROGRESS during the call, gas-limited, failure-tolerant; on failure the request
///     moves to CALLBACK_FAILED and the random number is public (event);
///   - recovery: anyone may re-deliver a FAILED request; the request is cleared *before* the callback, which is
///     invoked directly (reverts bubble up) with all remaining gas.
/// The random number is chosen by the revealer (tests pick outcomes); a recovery must reuse the same number.
contract MockEntropyV2 {
    uint32 internal constant TEN_THOUSAND = 10_000;
    uint256 internal constant PROVIDER_DEFAULT_GAS_LIMIT = 500_000;

    address public immutable defaultProvider;
    uint128 public baseFee;
    uint128 public feePerGas;
    uint64 public nextSequence = 1;

    mapping(address => mapping(uint64 => IEntropyV2.Request)) internal _requests;
    mapping(address => mapping(uint64 => bytes32)) public failedNumber;

    event Requested(address indexed provider, address indexed requester, uint64 indexed sequenceNumber, uint32 gasLimit);
    event Revealed(address indexed provider, uint64 indexed sequenceNumber, bytes32 randomNumber, bool callbackFailed);
    event CallbackFailed(address indexed provider, uint64 indexed sequenceNumber, bytes32 randomNumber, bytes ret);

    error InsufficientFee();
    error NoSuchRequest();
    error InvalidRevealCall();
    error InsufficientGas();
    error WrongNumber();

    constructor(address _defaultProvider, uint128 _baseFee, uint128 _feePerGas) {
        defaultProvider = _defaultProvider;
        baseFee = _baseFee;
        feePerGas = _feePerGas;
    }

    function getDefaultProvider() external view returns (address) {
        return defaultProvider;
    }

    /// @dev like a per-gas-priced Entropy provider: gas is charged at a fixed rate for max(gasLimit, the provider's
    ///      500k default) plus a base fee (feePerGas = 0 gives a flat fee, as Dice charges today)
    function getFeeV2(address, uint32 gasLimit) public view returns (uint128) {
        uint256 g = _round10k(gasLimit) * uint256(TEN_THOUSAND);
        if (g < PROVIDER_DEFAULT_GAS_LIMIT) g = PROVIDER_DEFAULT_GAS_LIMIT;
        return uint128(baseFee + g * feePerGas);
    }

    function requestV2(address provider, uint32 gasLimit) external payable returns (uint64 seq) {
        if (msg.value < getFeeV2(provider, gasLimit)) revert InsufficientFee();
        seq = nextSequence++;
        _requests[provider][seq] = IEntropyV2.Request({
            provider: provider,
            sequenceNumber: seq,
            numHashes: 1,
            commitment: keccak256(abi.encode(provider, seq)),
            blockNumber: uint64(block.number),
            requester: msg.sender,
            useBlockhash: false,
            callbackStatus: EntropyStatus.CALLBACK_NOT_STARTED,
            gasLimit10k: _round10k(gasLimit)
        });
        emit Requested(provider, msg.sender, seq, gasLimit);
    }

    function getRequestV2(address provider, uint64 seq) external view returns (IEntropyV2.Request memory) {
        return _requests[provider][seq];
    }

    /// @notice Equivalent of `revealWithCallback` with the combined random number supplied directly.
    function reveal(address provider, uint64 seq, bytes32 randomNumber) external {
        IEntropyV2.Request storage req = _requests[provider][seq];
        if (req.sequenceNumber == 0) revert NoSuchRequest();
        uint8 status = req.callbackStatus;
        if (status != EntropyStatus.CALLBACK_NOT_STARTED && status != EntropyStatus.CALLBACK_FAILED) {
            revert InvalidRevealCall();
        }

        if (status == EntropyStatus.CALLBACK_NOT_STARTED) {
            req.callbackStatus = EntropyStatus.CALLBACK_IN_PROGRESS;
            uint256 gasLimit = uint256(req.gasLimit10k) * TEN_THOUSAND;
            address requester = req.requester;
            uint256 startingGas = gasleft();
            (bool success, bytes memory ret) = requester.call{gas: gasLimit}(
                abi.encodeCall(IEntropyConsumerCallback._entropyCallback, (seq, provider, randomNumber))
            );
            req.callbackStatus = EntropyStatus.CALLBACK_NOT_STARTED;
            if (success) {
                delete _requests[provider][seq];
                emit Revealed(provider, seq, randomNumber, false);
            } else if (startingGas * 31 / 32 > gasLimit) {
                req.callbackStatus = EntropyStatus.CALLBACK_FAILED;
                failedNumber[provider][seq] = randomNumber;
                emit CallbackFailed(provider, seq, randomNumber, ret);
                emit Revealed(provider, seq, randomNumber, true);
            } else {
                revert InsufficientGas();
            }
        } else {
            if (failedNumber[provider][seq] != randomNumber) revert WrongNumber();
            address requester = req.requester;
            delete _requests[provider][seq];
            IEntropyConsumerCallback(requester)._entropyCallback(seq, provider, randomNumber);
            emit Revealed(provider, seq, randomNumber, false);
        }
    }

    /// @notice Simulate a first delivery attempt that failed (e.g. the consumer reverted): the request moves to
    ///         CALLBACK_FAILED and the number becomes public; `reveal` then performs the recovery path.
    function failFirstAttempt(address provider, uint64 seq, bytes32 randomNumber) external {
        IEntropyV2.Request storage req = _requests[provider][seq];
        if (req.sequenceNumber == 0) revert NoSuchRequest();
        if (req.callbackStatus != EntropyStatus.CALLBACK_NOT_STARTED) revert InvalidRevealCall();
        req.callbackStatus = EntropyStatus.CALLBACK_FAILED;
        failedNumber[provider][seq] = randomNumber;
        emit CallbackFailed(provider, seq, randomNumber, "");
        emit Revealed(provider, seq, randomNumber, true);
    }

    function _round10k(uint32 gas) internal pure returns (uint16) {
        uint32 g = gas / TEN_THOUSAND;
        if (g * TEN_THOUSAND < gas) g += 1;
        return uint16(g);
    }
}
