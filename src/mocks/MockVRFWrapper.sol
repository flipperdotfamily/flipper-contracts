// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IRawFulfill {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

/// @notice Local stand-in for Chainlink's VRFV2PlusWrapper (VRF v2.5 direct funding, native payment), used by the
///         dev stack (RANDOMNESS_MODE=chainlink) and tests. Same external interface the ChainlinkVRFAdapter uses:
///         `calculateRequestPriceNative`, `estimateRequestPriceNative`, `requestRandomWordsInNative`, `s_callbacks`,
///         and the consumer callback `rawFulfillRandomWords(uint256,uint256[])`.
///
/// Mirrors the production semantics that matter to the house:
///   - price: VRFV2PlusWrapper 1.0.0's native formula, at the requester's `tx.gasprice`
///       gp·wrapperGasOverhead + (gp·(callbackGas + coordinatorGasOverheadNative + perWord·numWords) + l1CostWei)
///       · (100 + nativePremiumPercentage)/100 + fulfillmentFlatFeeNativePPM·1e12
///     `arbitrumOne()` is the live Arbitrum One wrapper's config (read on-chain 2026-09-23); `l1CostWei` is the L1
///     posting cost of a fulfillment tx on the chain being simulated (the dev stack keeps it in sync).
///   - requests above `maxGasLimit` revert, like the real wrapper
///   - the consumer is called with exactly `callbackGasLimit` gas, and a reverting / out-of-gas consumer does
///     NOT revert the fulfillment (the commitment is still consumed, like VRFCoordinatorV2_5)
///   - `s_requestCommitments(id)` is non-zero until fulfilled
///
/// Fulfillment is permissioned to `fulfiller` (the local dev daemon); `fulfillWithWord` lets tests pick the outcome.
contract MockVRFWrapper {
    struct Config {
        uint32 wrapperGasOverhead;
        uint32 coordinatorGasOverheadNative;
        uint16 coordinatorGasOverheadPerWord;
        uint8 nativePremiumPercentage;
        uint32 fulfillmentFlatFeeNativePPM;
        uint32 maxGasLimit; // 0 = unlimited
        uint256 l1CostWei;
    }

    struct Request {
        address consumer;
        uint32 callbackGasLimit;
        uint32 numWords;
    }

    address public owner;
    mapping(address => bool) public isFulfiller;
    Config public config;
    uint256 public lastRequestId;
    mapping(uint256 => Request) public requests;
    mapping(uint256 => bytes32) public s_requestCommitments;
    uint256[] internal _pending;
    mapping(uint256 => uint256) internal _pendingIndex; // 1-based

    event RandomWordsRequested(uint256 indexed requestId, address indexed consumer, uint32 callbackGasLimit);
    event RandomWordsFulfilled(uint256 indexed requestId, uint256 outputSeed, bool success);

    error NotFulfiller();
    error UnknownRequest();
    error InsufficientPayment();
    error GasLimitTooBig(uint32 have, uint32 want);

    constructor(Config memory c) {
        owner = msg.sender;
        isFulfiller[msg.sender] = true;
        config = c;
    }

    /// @notice VRF v2.5 wrapper config live on Arbitrum One (0x14632CD5…BaaB), with the L1 posting cost left to
    ///         the caller (it depends on the chain being simulated).
    function arbitrumOne(uint256 l1CostWei) external pure returns (Config memory) {
        return Config(13_400, 104_500, 435, 60, 0, 2_500_000, l1CostWei);
    }

    function setFulfiller(address f, bool allowed) external {
        require(msg.sender == owner, "owner");
        isFulfiller[f] = allowed;
    }

    function setConfig(Config calldata c) external {
        require(msg.sender == owner, "owner");
        config = c;
    }

    /// @notice L1 posting cost of a fulfillment tx (kept in sync with the simulated chain by the dev stack)
    function setL1CostWei(uint256 wei_) external {
        require(msg.sender == owner || isFulfiller[msg.sender], "owner");
        config.l1CostWei = wei_;
    }

    /// @dev like the real wrapper, prices at the caller's gas price (an eth_call without one prices at zero)
    function calculateRequestPriceNative(uint32 callbackGasLimit, uint32 numWords) public view returns (uint256) {
        return estimateRequestPriceNative(callbackGasLimit, numWords, tx.gasprice);
    }

    function estimateRequestPriceNative(uint32 callbackGasLimit, uint32 numWords, uint256 gasPrice)
        public
        view
        returns (uint256)
    {
        Config memory c = config;
        uint256 coordinatorGas = uint256(callbackGasLimit) + c.coordinatorGasOverheadNative
            + uint256(c.coordinatorGasOverheadPerWord) * numWords;
        uint256 coordinatorCost = gasPrice * coordinatorGas + c.l1CostWei;
        return gasPrice * c.wrapperGasOverhead + coordinatorCost * (100 + uint256(c.nativePremiumPercentage)) / 100
            + uint256(c.fulfillmentFlatFeeNativePPM) * 1e12;
    }

    function requestRandomWordsInNative(uint32 callbackGasLimit, uint16, uint32 numWords, bytes calldata)
        external
        payable
        returns (uint256 requestId)
    {
        uint32 maxGas = config.maxGasLimit;
        if (maxGas != 0 && callbackGasLimit > maxGas) revert GasLimitTooBig(callbackGasLimit, maxGas);
        if (msg.value < calculateRequestPriceNative(callbackGasLimit, numWords)) revert InsufficientPayment();
        requestId = uint256(keccak256(abi.encode(address(this), ++lastRequestId)));
        requests[requestId] = Request(msg.sender, callbackGasLimit, numWords == 0 ? 1 : numWords);
        s_requestCommitments[requestId] = keccak256(abi.encode(requestId, block.number));
        _pending.push(requestId);
        _pendingIndex[requestId] = _pending.length;
        emit RandomWordsRequested(requestId, msg.sender, callbackGasLimit);
    }

    /// @notice VRFV2PlusWrapper-compatible view; zeroed once fulfilled.
    function s_callbacks(uint256 requestId) external view returns (address, uint32, uint64) {
        if (s_requestCommitments[requestId] == bytes32(0)) return (address(0), 0, 0);
        Request memory r = requests[requestId];
        return (r.consumer, r.callbackGasLimit, 0);
    }

    function pendingRequests() external view returns (uint256[] memory) {
        return _pending;
    }

    /// @notice Fulfill with pseudo-randomness derived from `seed` (dev daemon passes fresh entropy).
    function fulfill(uint256 requestId, uint256 seed) external returns (bool) {
        return _fulfill(requestId, uint256(keccak256(abi.encode(seed, requestId, block.prevrandao))));
    }

    /// @notice Fulfill with an exact first word (tests).
    function fulfillWithWord(uint256 requestId, uint256 word) external returns (bool) {
        return _fulfill(requestId, word);
    }

    function _fulfill(uint256 requestId, uint256 firstWord) internal returns (bool success) {
        if (!isFulfiller[msg.sender]) revert NotFulfiller();
        Request memory r = requests[requestId];
        if (s_requestCommitments[requestId] == bytes32(0)) revert UnknownRequest();
        delete s_requestCommitments[requestId];
        _removePending(requestId);

        uint256[] memory words = new uint256[](r.numWords);
        words[0] = firstWord;
        for (uint256 i = 1; i < words.length; ++i) {
            words[i] = uint256(keccak256(abi.encode(firstWord, i)));
        }
        // like the coordinator: require enough gas, then call with exactly callbackGasLimit and swallow failure
        require(gasleft() >= uint256(r.callbackGasLimit) * 64 / 63 + 50_000, "gas");
        (success,) = r.consumer.call{gas: r.callbackGasLimit}(
            abi.encodeCall(IRawFulfill.rawFulfillRandomWords, (requestId, words))
        );
        emit RandomWordsFulfilled(requestId, firstWord, success);
    }

    function _removePending(uint256 requestId) internal {
        uint256 idx = _pendingIndex[requestId];
        if (idx == 0) return;
        uint256 last = _pending[_pending.length - 1];
        _pending[idx - 1] = last;
        _pendingIndex[last] = idx;
        _pending.pop();
        delete _pendingIndex[requestId];
    }

    function withdraw(address payable to) external {
        require(msg.sender == owner, "owner");
        to.transfer(address(this).balance);
    }
}
