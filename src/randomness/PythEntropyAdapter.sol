// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IEntropyV2, EntropyStatus} from "../interfaces/IEntropyV2.sol";
import {IRandomnessAdapter, IRandomnessConsumer} from "../interfaces/IRandomness.sol";

/// @title PythEntropyAdapter
/// @notice Randomness for the house from Pyth Entropy v2 or a fork of it with the same interface (Dice on Robinhood
///         Chain).
///
///   Fee: paid in native ETH inside the player's flip transaction (exactly `getFeeV2`, which Entropy does not
///   refund if exceeded).
///
///   Delivery modes. Entropy invokes the callback in one of two ways:
///     - first attempt: during `revealWithCallback`, with the stored request still present and marked
///       CALLBACK_IN_PROGRESS, gas-limited and failure-tolerant;
///     - recovery: after a first attempt failed (randomness already public in `CallbackFailed`), anyone may call
///       `revealWithCallback` again; the request is cleared *before* the callback runs.
///   A recovery is therefore detectable from inside the callback, and is delivered with `safeMode = true` so the
///   consumer settles without touching markets — whoever triggers a recovery already knows the outcome and
///   picks the moment, so nothing about that moment may be allowed to matter.
///
///   Trust: the provider (and anyone who learns its revelation) can see an outcome before it is delivered and can
///   withhold it; it cannot bias it. The house never lets a withheld request be cancelled while it is still
///   revealable (`isPending`).
///
///   Deployed behind a TransparentUpgradeableProxy; storage is append-only.
contract PythEntropyAdapter is IRandomnessAdapter, Ownable2StepUpgradeable {
    uint256 internal constant CALLBACK_OVERHEAD = 60_000;

    IEntropyV2 public entropy;
    address public provider;
    /// @notice the house; bound once after deployment (the house holds this adapter's address immutably)
    address public consumer;

    error OnlyConsumer();
    error OnlyEntropy();
    error AlreadyBound();
    error InvalidAddress();
    error WrongFee(uint256 sent, uint256 required);

    event ConsumerBound(address consumer);
    event RandomnessRequested(uint256 indexed requestId, uint64 sequenceNumber, uint32 gasLimit);
    event RandomnessDelivered(uint256 indexed requestId, bool safeMode);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param _provider Entropy provider; address(0) selects Entropy's default provider (production)
    function initialize(IEntropyV2 _entropy, address _provider, address _owner) external initializer {
        if (address(_entropy) == address(0)) revert InvalidAddress();
        __Ownable_init(_owner);
        entropy = _entropy;
        provider = _provider == address(0) ? _entropy.getDefaultProvider() : _provider;
    }

    /// @notice One-time binding to the house proxy.
    function bind(address _consumer) external onlyOwner {
        if (consumer != address(0)) revert AlreadyBound();
        if (_consumer == address(0)) revert InvalidAddress();
        consumer = _consumer;
        emit ConsumerBound(_consumer);
    }

    function fee(uint32 callbackGasLimit) public view returns (uint256) {
        return entropy.getFeeV2(provider, _gasLimit(callbackGasLimit));
    }

    function request(uint32 callbackGasLimit) external payable returns (uint256 requestId) {
        if (msg.sender != consumer) revert OnlyConsumer();
        uint32 gasLimit = _gasLimit(callbackGasLimit);
        uint256 required = entropy.getFeeV2(provider, gasLimit);
        if (msg.value != required) revert WrongFee(msg.value, required);
        uint64 seq = entropy.requestV2{value: required}(provider, gasLimit);
        requestId = uint256(seq);
        emit RandomnessRequested(requestId, seq, gasLimit);
    }

    function isPending(uint256 requestId) external view returns (bool) {
        IEntropyV2.Request memory r = entropy.getRequestV2(provider, uint64(requestId));
        return r.sequenceNumber == uint64(requestId) && r.requester == address(this)
            && r.callbackStatus == EntropyStatus.CALLBACK_NOT_STARTED;
    }

    /// @notice Entropy callback (IEntropyConsumer ABI).
    function _entropyCallback(uint64 sequence, address _provider, bytes32 randomNumber) external {
        if (msg.sender != address(entropy) || _provider != provider) revert OnlyEntropy();
        IEntropyV2.Request memory r = entropy.getRequestV2(_provider, sequence);
        bool firstAttempt = r.sequenceNumber == sequence && r.requester == address(this)
            && r.callbackStatus == EntropyStatus.CALLBACK_IN_PROGRESS;
        uint256 requestId = uint256(sequence);
        emit RandomnessDelivered(requestId, !firstAttempt);
        // reverts bubble up on purpose: a failed first attempt must become an Entropy CALLBACK_FAILED so that
        // it can be recovered (in safe mode) instead of silently disappearing
        IRandomnessConsumer(consumer).onRandomness(requestId, uint256(randomNumber), !firstAttempt);
    }

    function _gasLimit(uint32 callbackGasLimit) internal pure returns (uint32) {
        return callbackGasLimit + uint32(CALLBACK_OVERHEAD);
    }
}
