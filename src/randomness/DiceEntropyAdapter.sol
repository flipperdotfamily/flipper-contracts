// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IDiceEntropy, DiceStatus, IArbSys} from "../interfaces/IDiceEntropy.sol";
import {IRandomnessAdapter, IRandomnessConsumer} from "../interfaces/IRandomness.sol";

/// @title DiceEntropyAdapter
/// @notice Randomness for the house from Dice Protocol (a Pyth Entropy v2 fork; the only VRF-style oracle on Robinhood
///         Chain). Analysis and evidence: research/DICE_INTEGRATION.md.
///
///   Fee: Dice charges one flat, admin-set fee (0.000025 ETH), paid exactly inside the player's flip transaction.
///
///   Dice is commit-reveal over one provider's hash chain. The provider knows every value of its chain, and the
///   requester's "user randomness" is public the moment it is requested, so the provider (or anyone holding its seed)
///   knows each Dice number as soon as the request exists. This adapter therefore never lets a Dice number alone
///   decide a flip, and never lets a request disappear:
///
///   1. No selection. The word the house receives is keccak(dice number, hash of the L2 block the flip was made in).
///      No transaction can read its own block's hash, so a player who knows the Dice number in advance (collusion,
///      a leaked seed) still cannot tell whether a flip wins before it is irrevocably made. The hash is read from
///      ArbSys on Arbitrum/Robinhood (where `block.number` is L1) and from `blockhash` elsewhere, and stays readable for
///      256 blocks; `snapshot` (anyone; the upkeep worker, and every new request for its predecessor) stores it for
///      slower deliveries. If it expired unsnapshotted, the delivery mixes in zero, in safe mode, and says so.
///   2. No voided requests. The adapter never calls Dice's `refundRequest` (only the requester may) and cannot
///      receive ETH, so a Dice request stays open until revealed. Revealing any later value of the provider's chain
///      makes every earlier one computable (the chain runs backwards: x_n = keccak^(m-n)(x_m)), so a provider cannot
///      withhold one losing flip and keep serving: `recover` / `recoverFromChain` let anyone settle a withheld
///      request as soon as a later value is public, verified against the commitment Dice stored for it.
///   3. Market-free when timing was chosen. A delivery settles through markets (`safeMode = false`) only when it is
///      Dice's first attempt, arrives within `promptWindow` of the request and is sent by the provider's own revealer.
///      Anything else — a recovery, Dice's retry path, a late or third-party reveal, a stale block hash — settles in
///      safe mode: whoever picked that moment could already know the outcome.
///   4. Stalls stop new flips. While a request that is neither revealed nor computable is older than `stallTimeout`,
///      `request` reverts (flips are refused); `trip` latches that until the owner `resume`s. `isPending` is true only
///      while nobody but the provider can know the number, so a player can cancel only a flip that genuinely stalled.
///   Exposure caps: `maxOpen` unresolved requests and `maxFee`.
///
///   Deployed behind a TransparentUpgradeableProxy; storage is append-only.
contract DiceEntropyAdapter is IRandomnessAdapter, Ownable2StepUpgradeable {
    /// @dev gas the adapter's callback itself needs on top of the consumer's budget (Dice's fee is flat: headroom is
    ///      free to us; test/DiceAdapter.t.sol measures the real use)
    uint256 internal constant CALLBACK_OVERHEAD = 100_000;
    /// @dev a Dice gas limit above this could never be revealed within a block (Arbitrum's per-tx cap is 32M)
    uint256 internal constant MAX_DICE_GAS = 30_000_000;
    /// @dev blocks for which a block hash stays readable (EVM `blockhash` and ArbSys `arbBlockHash` alike)
    uint256 internal constant HASH_WINDOW = 256;
    address internal constant ARB_SYS = address(100);
    /// @dev resolved requests the stall queue skips per `request`
    uint256 internal constant ADVANCE_STEPS = 8;
    /// @dev computable-but-unrecovered requests a stall check looks past
    uint256 internal constant STALL_SCAN = 32;

    uint8 internal constant PENDING = 1;
    uint8 internal constant DELIVERED = 2;

    struct Config {
        uint32 promptWindow; // seconds: a first-attempt delivery later than this settles in safe mode
        uint32 stallTimeout; // seconds: an unrevealed, non-computable request older than this refuses new requests
        uint32 maxOpen; // unresolved requests allowed at once (0 = no cap)
        uint128 maxFee; // refuse requests while Dice's fee exceeds this (0 = no cap)
        address revealer; // tx.origin of trusted first-attempt reveals (0 = the provider address itself)
    }

    /// @dev one slot
    struct Req {
        uint40 requestedAt;
        uint64 targetBlock; // L2 block the request was made in: its hash is mixed into the word
        uint32 numHashes; // Dice's numHashes for the request (verification in `recover`)
        uint8 state;
        uint32 epoch; // stall-tracking epoch (see `resume`)
        uint64 next; // next request in issue order
    }

    struct RequestView {
        uint8 state; // 0 unknown, 1 pending, 2 delivered
        uint40 requestedAt;
        uint64 targetBlock;
        bytes32 targetHash; // readable or snapshotted hash of the target block (0 = not yet / expired)
        bool targetReady; // a delivery now would have its target hash (or would be stale)
        bool stale; // the target hash expired unsnapshotted: a delivery would mix in 0
        bool diceOpen; // Dice still holds the request (not revealed-and-cleared)
        uint8 diceStatus; // Dice callbackStatus while open
        bool computable; // a later value of the provider's chain is public: `recoverFromChain` works
    }

    struct Health {
        uint32 open; // unresolved requests counted against maxOpen
        uint64 oldestPending; // oldest tracked unresolved request (0 = none)
        uint256 oldestAge; // its age in seconds
        bool stalled;
        bool tripped;
        uint64 providerNextSeq; // Dice: next sequence number it will assign
        uint64 providerRevealedSeq; // Dice: latest revealed sequence number of the provider's chain
        uint256 fee;
        uint256 blockNumber; // the block number the adapter uses (L2 on Arbitrum)
    }

    IDiceEntropy public dice;
    address public provider;
    /// @notice the house; bound once after deployment (the house holds this adapter's address immutably)
    address public consumer;
    /// @notice block source: ArbSys L2 blocks (Arbitrum / Robinhood Chain) instead of `block.number` / `blockhash`
    bool public arbitrum;
    /// @notice latched by `trip` while stalled; cleared by the owner's `resume`
    bool public tripped;
    uint32 public epoch;
    uint32 public openCount;
    uint64 internal _head;
    uint64 internal _tail;
    Config internal _cfg;
    mapping(uint256 requestId => Req) internal _reqs;
    /// @notice Dice's stored commitment for each request: keccak(keccak(userRandom), providerCommitment)
    mapping(uint256 requestId => bytes32) public commitmentOf;
    /// @notice snapshotted hash of each request's target block
    mapping(uint256 requestId => bytes32) public targetHashOf;

    error OnlyConsumer();
    error OnlyEntropy();
    error AlreadyBound();
    error InvalidAddress();
    error InvalidConfig();
    error WrongFee(uint256 sent, uint256 required);
    error FeeAboveMax(uint256 fee, uint256 maxFee);
    error ProviderStalled();
    error TooManyOpen();
    error ProviderMisconfigured();
    error NotPending();
    error TargetNotReady();
    error IncorrectRevelation();
    error NotComputable();
    error NotStalled();

    event ConsumerBound(address consumer);
    event ConfigUpdated(Config config);
    event RandomnessRequested(uint256 indexed requestId, uint32 gasLimit, uint64 targetBlock, bytes32 userRandom);
    /// @param stale the target block hash had expired unsnapshotted (zero was mixed in)
    event RandomnessDelivered(uint256 indexed requestId, bool safeMode, bool stale);
    event RandomnessRecovered(uint256 indexed requestId, address indexed by);
    event StallTripped(uint256 indexed requestId, uint256 age);
    event Resumed(uint32 epoch);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param _provider Dice provider; address(0) selects Dice's default provider (production)
    /// @param _arbitrum read L2 blocks from ArbSys (Robinhood Chain); false on OP-stack / anvil
    function initialize(IDiceEntropy _dice, address _provider, bool _arbitrum, Config calldata c, address _owner)
        external
        initializer
    {
        if (address(_dice) == address(0)) revert InvalidAddress();
        __Ownable_init(_owner);
        dice = _dice;
        address p = _provider == address(0) ? _dice.getDefaultProvider() : _provider;
        if (p == address(0)) revert InvalidAddress();
        provider = p;
        arbitrum = _arbitrum;
        if (_arbitrum) IArbSys(ARB_SYS).arbBlockNumber(); // reverts where there is no ArbSys
        _setConfig(c);
    }

    /// @notice One-time binding to the house proxy.
    function bind(address _consumer) external onlyOwner {
        if (consumer != address(0)) revert AlreadyBound();
        if (_consumer == address(0)) revert InvalidAddress();
        consumer = _consumer;
        emit ConsumerBound(_consumer);
    }

    function setConfig(Config calldata c) external onlyOwner {
        _setConfig(c);
    }

    function _setConfig(Config memory c) internal {
        if (c.promptWindow < 5 || c.promptWindow > 1 hours) revert InvalidConfig();
        if (c.stallTimeout < 1 minutes || c.stallTimeout > 7 days) revert InvalidConfig();
        _cfg = c;
        emit ConfigUpdated(c);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // IRandomnessAdapter
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function fee(uint32 callbackGasLimit) public view returns (uint256) {
        return dice.getFeeV2(provider, _gasLimit(callbackGasLimit));
    }

    function request(uint32 callbackGasLimit) external payable returns (uint256 requestId) {
        if (msg.sender != consumer) revert OnlyConsumer();
        Config memory c = _cfg;
        _checkLive(c);
        uint32 gasLimit = _gasLimit(callbackGasLimit);
        uint256 required = dice.getFeeV2(provider, gasLimit);
        if (c.maxFee != 0 && required > c.maxFee) revert FeeAboveMax(required, c.maxFee);
        if (msg.value != required) revert WrongFee(msg.value, required);

        uint256 cur = _blockNumber();
        uint64 target = uint64(cur);
        bytes32 u = userRandom(target);
        uint64 seq = dice.requestV2{value: required}(provider, u, gasLimit);
        IDiceEntropy.Request memory r = dice.getRequestV2(provider, seq);
        // a zero gas limit (provider default 0) takes Dice's unbounded, failure-swallowing callback path; an
        // unrevealable one would stall every flip: refuse both loudly instead of settling degraded
        uint256 diceGas = uint256(r.gasLimit10k) * 10_000;
        if (r.sequenceNumber != seq || r.requester != address(this) || diceGas < gasLimit || diceGas > MAX_DICE_GAS) {
            revert ProviderMisconfigured();
        }

        uint64 prev = _tail;
        if (prev != 0) {
            Req storage p = _reqs[prev];
            p.next = seq;
            if (p.state == PENDING) _snapshotOne(prev, p, cur); // keeps a slow predecessor's hash past the window
        }
        _reqs[seq] = Req({
            requestedAt: uint40(block.timestamp),
            targetBlock: target,
            numHashes: r.numHashes,
            state: PENDING,
            epoch: epoch,
            next: 0
        });
        commitmentOf[seq] = r.commitment;
        if (_head == 0) _head = seq;
        _tail = seq;
        openCount += 1;
        requestId = seq;
        emit RandomnessRequested(requestId, gasLimit, target, u);
    }

    /// @notice True while nobody but the provider can know the request's number: not delivered, still open at Dice
    ///         and never attempted, and no later value of the provider's chain is public. (Once it is, the request is
    ///         recoverable by anyone and must be settled, not cancelled.)
    function isPending(uint256 requestId) external view returns (bool) {
        if (_reqs[requestId].state != PENDING) return false;
        (, uint64 revealed) = _currentCommitment();
        if (revealed >= requestId) return false;
        IDiceEntropy.Request memory r = dice.getRequestV2(provider, uint64(requestId));
        return r.sequenceNumber == requestId && r.requester == address(this)
            && r.callbackStatus == DiceStatus.CALLBACK_NOT_STARTED;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Delivery
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Dice callback (IEntropyConsumer ABI). Dice calls it from `revealWithCallback`: a first attempt
    ///         (request still stored, IN_PROGRESS, exact gas limit, failure recorded as CALLBACK_FAILED), or a retry /
    ///         no-limit delivery (request cleared first, failure swallowed). Reverts bubble up on purpose: a failed first
    ///         attempt becomes CALLBACK_FAILED with its number public, and a swallowed retry leaves the request pending
    ///         here; either way `recover` settles it in safe mode.
    function _entropyCallback(uint64 sequence, address _provider, bytes32 randomNumber) external {
        if (msg.sender != address(dice) || _provider != provider) revert OnlyEntropy();
        Req storage q = _reqs[sequence];
        if (q.state != PENDING) return; // already recovered: let Dice clear the request
        (bool ready, bytes32 h, bool stale) = _targetHash(sequence, q, _blockNumber());
        if (!ready) revert TargetNotReady(); // revealed within the request's own block
        IDiceEntropy.Request memory r = dice.getRequestV2(_provider, sequence);
        bool firstAttempt = r.sequenceNumber == sequence && r.requester == address(this)
            && r.callbackStatus == DiceStatus.CALLBACK_IN_PROGRESS;
        Config storage c = _cfg;
        bool trusted = firstAttempt && !stale && block.timestamp <= uint256(q.requestedAt) + c.promptWindow
            && tx.origin == _revealer(c.revealer);
        _deliver(sequence, q, randomNumber, h, stale, !trusted);
    }

    /// @notice Settle a request whose provider value is known (withheld while a later value was revealed, a failed or
    ///         griefed Dice callback, …) in safe mode. `value` is the provider's chain value for sequence `valueSeq`
    ///         (>= requestId; any later value works: it is hashed down), verified against Dice's commitment.
    function recover(uint256 requestId, bytes32 value, uint64 valueSeq) public {
        Req storage q = _reqs[requestId];
        if (q.state != PENDING) revert NotPending();
        if (valueSeq < requestId) revert IncorrectRevelation();
        bytes32 x = _hashN(value, valueSeq - requestId);
        bytes32 u = userRandom(q.targetBlock);
        bytes32 providerCommitment = _hashN(x, q.numHashes);
        if (keccak256(abi.encodePacked(keccak256(abi.encodePacked(u)), providerCommitment)) != commitmentOf[requestId]) {
            revert IncorrectRevelation();
        }
        (bool ready, bytes32 h, bool stale) = _targetHash(requestId, q, _blockNumber());
        if (!ready) revert TargetNotReady();
        emit RandomnessRecovered(requestId, msg.sender);
        // Dice's combineRandomValues(user, provider, 0)
        _deliver(requestId, q, keccak256(abi.encodePacked(u, x, bytes32(0))), h, stale, true);
    }

    /// @notice `recover` from the provider's current on-chain commitment (the latest revealed value). Fails after a
    ///         provider re-registration: pass an older chain value to `recover` instead.
    function recoverFromChain(uint256 requestId) external {
        (bytes32 c, uint64 s) = _currentCommitment();
        if (s < requestId) revert NotComputable();
        recover(requestId, c, s);
    }

    /// @notice Store the target block hash of pending requests while it is still readable (anyone).
    function snapshot(uint256[] calldata requestIds) external {
        uint256 cur = _blockNumber();
        for (uint256 i; i < requestIds.length; ++i) {
            Req storage q = _reqs[requestIds[i]];
            if (q.state == PENDING) _snapshotOne(requestIds[i], q, cur);
        }
    }

    function _deliver(uint256 requestId, Req storage q, bytes32 diceRandom, bytes32 h, bool stale, bool safe) internal {
        q.state = DELIVERED;
        if (q.epoch == epoch && openCount != 0) openCount -= 1;
        emit RandomnessDelivered(requestId, safe, stale);
        IRandomnessConsumer(consumer).onRandomness(requestId, uint256(keccak256(abi.encode(diceRandom, h))), safe);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Stalls
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Latch the stall breaker (anyone, while `stalled()`): new requests stay refused until the owner resumes.
    function trip() external {
        (bool s, uint64 id, uint256 age) = _stallView();
        if (!s) revert NotStalled();
        tripped = true;
        emit StallTripped(id, age);
    }

    /// @notice Owner, or the consumer's guardian (the house's operator key, so an outage doesn't need the owner's cold
    ///         key): accept requests again. Requests made so far stop counting towards stalls and `maxOpen` (they
    ///         remain deliverable and recoverable).
    function resume() external {
        if (msg.sender != owner() && msg.sender != _consumerGuardian()) revert OwnableUnauthorizedAccount(msg.sender);
        tripped = false;
        uint32 e = epoch + 1;
        epoch = e;
        openCount = 0;
        _head = 0;
        _tail = 0;
        emit Resumed(e);
    }

    /// @dev the bound consumer's `guardian()` (the house's), or 0 when unbound or it has none
    function _consumerGuardian() internal view returns (address g) {
        address c = consumer;
        if (c == address(0)) return address(0);
        (bool ok, bytes memory r) = c.staticcall(abi.encodeWithSignature("guardian()"));
        if (ok && r.length == 32) g = abi.decode(r, (address));
    }

    /// @notice A request that is neither revealed nor computable from public values is older than `stallTimeout`.
    function stalled() external view returns (bool s) {
        (s,,) = _stallView();
    }

    function _checkLive(Config memory c) internal {
        if (tripped) revert ProviderStalled();
        uint64 h = _skipResolved(_head, ADVANCE_STEPS);
        if (h != _head) _head = h;
        if (h != 0 && block.timestamp > uint256(_reqs[h].requestedAt) + c.stallTimeout) {
            // an old head: look past requests that are already computable (recovery jobs, not a provider stall;
            // they stay queued for the upkeep worker)
            (, uint64 revealed) = _currentCommitment();
            (uint64 first, bool found) = _firstUncomputable(h, revealed);
            if (found && block.timestamp > uint256(_reqs[first].requestedAt) + c.stallTimeout) revert ProviderStalled();
        }
        if (c.maxOpen != 0 && openCount >= c.maxOpen) revert TooManyOpen();
    }

    function _stallView() internal view returns (bool s, uint64 id, uint256 age) {
        uint64 h = _skipResolved(_head, STALL_SCAN);
        if (h == 0) return (false, 0, 0);
        (, uint64 revealed) = _currentCommitment();
        (uint64 first, bool found) = _firstUncomputable(h, revealed);
        if (!found) return (false, 0, 0);
        age = block.timestamp - _reqs[first].requestedAt;
        return (age > _cfg.stallTimeout, first, age);
    }

    /// @dev first request from `h` that still counts (pending, this epoch), within `steps`
    function _skipResolved(uint64 h, uint256 steps) internal view returns (uint64) {
        uint32 e = epoch;
        for (uint256 i; h != 0 && i < steps; ++i) {
            Req storage q = _reqs[h];
            if (q.state == PENDING && q.epoch == e) return h;
            h = q.next;
        }
        return h;
    }

    /// @dev first counting request from `h` whose number is not computable yet (seq > revealed)
    function _firstUncomputable(uint64 h, uint64 revealed) internal view returns (uint64, bool) {
        uint32 e = epoch;
        for (uint256 i; h != 0 && i < STALL_SCAN; ++i) {
            Req storage q = _reqs[h];
            if (q.state == PENDING && q.epoch == e && h > revealed) return (h, true);
            h = q.next;
        }
        return (h, false);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function config() external view returns (Config memory) {
        return _cfg;
    }

    /// @notice tx.origin whose prompt first-attempt reveals settle through markets
    function trustedRevealer() external view returns (address) {
        return _revealer(_cfg.revealer);
    }

    /// @notice The user randomness sent to Dice for a request made in `targetBlock` (public by design: the entropy
    ///         Dice cannot know in advance is the target block's hash, mixed in at delivery).
    function userRandom(uint64 targetBlock) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), block.chainid, targetBlock));
    }

    function requestInfo(uint256 requestId) external view returns (RequestView memory v) {
        Req storage q = _reqs[requestId];
        v.state = q.state;
        v.requestedAt = q.requestedAt;
        v.targetBlock = q.targetBlock;
        if (q.state == 0) return v;
        (v.targetReady, v.targetHash, v.stale) = _targetHash(requestId, q, _blockNumber());
        IDiceEntropy.Request memory r = dice.getRequestV2(provider, uint64(requestId));
        v.diceOpen = r.sequenceNumber == requestId && r.requester == address(this);
        if (v.diceOpen) v.diceStatus = r.callbackStatus;
        (, uint64 revealed) = _currentCommitment();
        v.computable = revealed >= requestId;
    }

    function health() external view returns (Health memory hv) {
        hv.open = openCount;
        hv.tripped = tripped;
        hv.blockNumber = _blockNumber();
        uint64 h = _skipResolved(_head, STALL_SCAN);
        if (h != 0 && _reqs[h].state == PENDING) {
            hv.oldestPending = h;
            hv.oldestAge = block.timestamp - _reqs[h].requestedAt;
        }
        (hv.stalled,,) = _stallView();
        IDiceEntropy.ProviderInfo memory p = dice.getProviderInfoV2(provider);
        hv.providerNextSeq = p.sequenceNumber;
        hv.providerRevealedSeq = p.currentCommitmentSequenceNumber;
        hv.fee = dice.getFeeV2(provider, uint32(CALLBACK_OVERHEAD));
    }

    /// @notice Up to `max` unresolved requests of the current epoch, oldest first (for the upkeep worker).
    function pendingRequests(uint256 max) external view returns (uint256[] memory ids) {
        ids = new uint256[](max);
        uint256 n;
        uint32 e = epoch;
        uint64 h = _head;
        for (uint256 i; h != 0 && n < max && i < max * 8 + 64; ++i) {
            Req storage q = _reqs[h];
            if (q.state == PENDING && q.epoch == e) ids[n++] = h;
            h = q.next;
        }
        assembly ("memory-safe") {
            mstore(ids, n)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function _gasLimit(uint32 callbackGasLimit) internal pure returns (uint32) {
        return callbackGasLimit + uint32(CALLBACK_OVERHEAD);
    }

    function _revealer(address r) internal view returns (address) {
        return r == address(0) ? provider : r;
    }

    function _blockNumber() internal view returns (uint256) {
        return arbitrum ? IArbSys(ARB_SYS).arbBlockNumber() : block.number;
    }

    /// @dev hash of block `n` if readable at `cur`, else 0
    function _blockHashAt(uint256 n, uint256 cur) internal view returns (bytes32) {
        if (n >= cur || cur - n > HASH_WINDOW) return 0;
        if (!arbitrum) return blockhash(n);
        try IArbSys(ARB_SYS).arbBlockHash(n) returns (bytes32 h) {
            return h;
        } catch {
            return 0;
        }
    }

    /// @return ready false while the target block is the current one (its hash does not exist yet)
    /// @return h the target block's hash (snapshotted or readable), 0 when stale
    /// @return stale the hash expired without a snapshot
    function _targetHash(uint256 requestId, Req storage q, uint256 cur)
        internal
        view
        returns (bool ready, bytes32 h, bool stale)
    {
        h = targetHashOf[requestId];
        if (h != 0) return (true, h, false);
        uint256 t = q.targetBlock;
        if (cur <= t) return (false, 0, false);
        h = _blockHashAt(t, cur);
        return (true, h, h == 0);
    }

    function _snapshotOne(uint256 requestId, Req storage q, uint256 cur) internal {
        if (targetHashOf[requestId] != 0) return;
        bytes32 h = _blockHashAt(q.targetBlock, cur);
        if (h != 0) targetHashOf[requestId] = h;
    }

    /// @return value the provider's latest revealed chain value, and its sequence number
    function _currentCommitment() internal view returns (bytes32 value, uint64 seq) {
        IDiceEntropy.ProviderInfo memory p = dice.getProviderInfoV2(provider);
        return (p.currentCommitment, p.currentCommitmentSequenceNumber);
    }

    /// @dev keccak applied `n` times (Dice's hash chain step)
    function _hashN(bytes32 v, uint256 n) internal pure returns (bytes32) {
        assembly ("memory-safe") {
            for {} gt(n, 0) { n := sub(n, 1) } {
                mstore(0x00, v)
                v := keccak256(0x00, 0x20)
            }
        }
        return v;
    }
}
