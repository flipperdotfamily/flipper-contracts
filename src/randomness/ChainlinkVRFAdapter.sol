// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IVRFV2PlusWrapper} from "../interfaces/IVRFV2PlusWrapper.sol";
import {IRandomnessAdapter, IRandomnessConsumer} from "../interfaces/IRandomness.sol";
import {VRFV2PlusClient} from "../libraries/VRFV2PlusClient.sol";

/// @title ChainlinkVRFAdapter
/// @notice Randomness from Chainlink VRF v2.5 direct funding (VRFV2PlusWrapper), paid in native ETH inside the
///         player's flip transaction. For chains where Chainlink VRF v2.5 is deployed.
///
///         Chainlink never re-delivers: the wrapper calls the consumer exactly once with exactly the requested
///         gas and swallows failures, so every delivery is a first attempt (`safeMode = false`). The house's
///         callback is designed never to revert, which is what makes that acceptable.
///
///         Deployed behind a TransparentUpgradeableProxy; storage is append-only.
contract ChainlinkVRFAdapter is IRandomnessAdapter, Ownable2StepUpgradeable {
    uint256 internal constant CALLBACK_OVERHEAD = 40_000;

    IVRFV2PlusWrapper public wrapper;
    uint16 public requestConfirmations;
    address public consumer;
    bytes internal extraArgs;

    error OnlyConsumer();
    error OnlyWrapper();
    error AlreadyBound();
    error InvalidAddress();
    error WrongFee(uint256 sent, uint256 required);

    event ConsumerBound(address consumer);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IVRFV2PlusWrapper _wrapper, uint16 _requestConfirmations, address _owner)
        external
        initializer
    {
        if (address(_wrapper) == address(0)) revert InvalidAddress();
        __Ownable_init(_owner);
        wrapper = _wrapper;
        requestConfirmations = _requestConfirmations;
        extraArgs = VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true}));
    }

    /// @notice One-time binding to the house proxy.
    function bind(address _consumer) external onlyOwner {
        if (consumer != address(0)) revert AlreadyBound();
        if (_consumer == address(0)) revert InvalidAddress();
        consumer = _consumer;
        emit ConsumerBound(_consumer);
    }

    /// @dev depends on tx.gasprice (the wrapper prices the callback at the requester's gas price)
    function fee(uint32 callbackGasLimit) public view returns (uint256) {
        return wrapper.calculateRequestPriceNative(_gasLimit(callbackGasLimit), 1);
    }

    function request(uint32 callbackGasLimit) external payable returns (uint256 requestId) {
        if (msg.sender != consumer) revert OnlyConsumer();
        uint256 required = fee(callbackGasLimit);
        if (msg.value != required) revert WrongFee(msg.value, required);
        requestId = wrapper.requestRandomWordsInNative{value: required}(
            _gasLimit(callbackGasLimit), requestConfirmations, 1, extraArgs
        );
    }

    function isPending(uint256 requestId) external view returns (bool) {
        (address cb,,) = wrapper.s_callbacks(requestId);
        return cb == address(this);
    }

    /// @notice VRFV2PlusWrapperConsumerBase ABI.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(wrapper)) revert OnlyWrapper();
        IRandomnessConsumer(consumer).onRandomness(requestId, randomWords[0], false);
    }

    function _gasLimit(uint32 callbackGasLimit) internal pure returns (uint32) {
        return callbackGasLimit + uint32(CALLBACK_OVERHEAD);
    }
}
