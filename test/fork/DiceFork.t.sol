// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";

import {DiceEntropyAdapter} from "../../src/randomness/DiceEntropyAdapter.sol";
import {IDiceEntropy, DiceStatus} from "../../src/interfaces/IDiceEntropy.sol";
import {IRandomnessAdapter} from "../../src/interfaces/IRandomness.sol";
import {FlipperDeploy} from "../../script/lib/FlipperDeploy.sol";
import {DiceDeploy} from "../../script/lib/DiceDeploy.sol";
import {RobinhoodAddresses as RH} from "../../script/lib/RobinhoodAddresses.sol";
import {RecordingConsumer} from "../DiceAdapter.t.sol";

/// @dev forge forks have no Arbitrum precompiles: ArbSys over the fork's own (L2) block numbers and hashes
contract ForkArbSys {
    error InvalidBlockNumber(uint256 requested, uint256 current);

    function arbBlockNumber() external view returns (uint256) {
        return block.number;
    }

    function arbBlockHash(uint256 n) external view returns (bytes32) {
        if (n >= block.number || n + 256 < block.number) revert InvalidBlockNumber(n, block.number);
        return blockhash(n);
    }
}

/// @notice The DiceEntropyAdapter against the live DiceEntropy on a Robinhood Chain fork.
///         Run: ROBINHOOD_RPC_URL=https://rpc.ordofi.network forge test --match-contract DiceFork -vv
///         (an archive RPC: the fork is taken at a historical block)
///
///   Real reveals: the fork is taken at block 72,126,189, just before mainnet request 2289, so our request is
///   assigned sequence 2289 and the next one 2290 — whose provider values Tyche later revealed on mainnet
///   (Revealed events). Impersonating the provider with those values reproduces a genuine Dice reveal.
///   Mirror: the dev `dice-mirror` mode re-keys the live provider through the admin's `registerFor` and forces
///   outcomes by rewriting request storage; both techniques are exercised here against the real contract code.
contract DiceForkTest is Test {
    IDiceEntropy internal constant DICE = IDiceEntropy(RH.DICE_ENTROPY);
    address internal constant PROVIDER = RH.DICE_PROVIDER;
    uint256 internal constant FORK_BLOCK = 72_126_189;
    uint64 internal constant S = 2289;
    /// provider values revealed on mainnet (Revealed.providerContribution for 2288 / 2289 / 2290)
    bytes32 internal constant X_2288 = 0x7f50676ef27ee041f7bf7cbd5a01f77fa63771752abd6c3a9de9bc4f60ea44cc;
    bytes32 internal constant X_2289 = 0xe1ad05e59792f5e98d3504634c12a1c4f3d8a9f9229c17e3ad687a77dbd0acc2;
    bytes32 internal constant X_2290 = 0xc709244d1de9e5116469c8eb7ffbc7551ea11841af41d06ae5eb4e937f4ddd0a;
    /// a mainnet request Tyche skipped on 2026-09-08 and that is still open (user contribution from its Requested log)
    uint64 internal constant STRAGGLER = 1284;
    bytes32 internal constant STRAGGLER_U = 0xae6fc9c2639197381c8af354bf7477836872f89c983112f035e3dca166e598b5;
    /// 2026-09-25: 1284 still open, the provider long past it (latest revealed 2324)
    uint256 internal constant STRAGGLER_FORK_BLOCK = 72_640_000;
    uint32 internal constant CB_GAS = 900_000; // Robinhood callbackGasLimit

    // DiceEntropy storage (verified source; checked against live state 2026-09-25)
    uint256 internal constant SLOT_REQUESTS = 4; // Request[32], 4 slots each
    uint256 internal constant SLOT_OVERFLOW = 132; // mapping(bytes32 => Request)
    uint256 internal constant SLOT_PROVIDERS = 133; // mapping(address => ProviderInfo)
    address internal constant DICE_ADMIN = RH.DICE_ADMIN;

    string internal rpc;
    bool internal forked;
    DiceEntropyAdapter internal a;
    RecordingConsumer internal consumer;
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);
        forked = true;
        _deploy();
    }

    function _deploy() internal {
        vm.etch(RH.ARB_SYS, type(ForkArbSys).runtimeCode);
        FlipperDeploy.Config memory c;
        c.deployer = address(this);
        c.proxyAdminOwner = makeAddr("proxyAdminOwner");
        a = DiceEntropyAdapter(address(DiceDeploy.deployAdapter(c, DICE, address(0), true, RH.diceAdapterConfig())));
        consumer = new RecordingConsumer(IRandomnessAdapter(address(a)), CB_GAS);
        a.bind(address(consumer));
        vm.deal(address(this), 10 ether);
    }

    function _hashN(bytes32 v, uint256 n) internal pure returns (bytes32) {
        for (uint256 i; i < n; ++i) v = keccak256(abi.encodePacked(v));
        return v;
    }

    function _u(uint256 seq) internal view returns (bytes32) {
        return a.userRandom(a.requestInfo(seq).targetBlock);
    }

    function _word(bytes32 u, bytes32 x, bytes32 h) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(keccak256(abi.encodePacked(u, x, bytes32(0))), h)));
    }

    function _revealAs(address origin, uint64 seq, bytes32 x) internal {
        bytes32 u = _u(seq); // before the prank: an argument's external call would consume it
        vm.prank(origin, origin);
        DICE.revealWithCallback{gas: 3_000_000}(PROVIDER, seq, u, x);
    }

    // ── live contract facts ─────────────────────────────────────────────────────────────────────────

    function testFork_liveFacts() public {
        if (!forked) return;
        assertEq(DICE.getDefaultProvider(), PROVIDER);
        assertEq(DICE.getFeeV2(PROVIDER, 0), RH.DICE_FEE);
        assertEq(DICE.getFeeV2(PROVIDER, 30_000_000), RH.DICE_FEE, "flat fee whatever the gas");
        assertEq(DICE.getRefundDelayBlocks(), RH.DICE_REFUND_DELAY_BLOCKS);
        IDiceEntropy.ProviderInfo memory p = DICE.getProviderInfoV2(PROVIDER);
        assertEq(p.sequenceNumber, S);
        assertEq(p.currentCommitmentSequenceNumber, S - 1);
        assertEq(p.currentCommitment, X_2288);
        assertEq(p.defaultGasLimit, 200_000);
        // hash chain: each later value hashes down to the earlier ones
        assertEq(keccak256(abi.encodePacked(X_2289)), X_2288);
        assertEq(_hashN(X_2290, 2), X_2288);
        // not a proxy: no EIP-1967 implementation / admin slots
        assertEq(vm.load(address(DICE), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc), bytes32(0));
        assertEq(vm.load(address(DICE), 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103), bytes32(0));
        assertEq(address(uint160(uint256(vm.load(address(DICE), 0)))), DICE_ADMIN);
        // the legacy overloads revert: only requestV2(provider, userRandom, gasLimit) works
        (bool ok,) = address(DICE).call{value: RH.DICE_FEE}(abi.encodeWithSignature("requestV2(address,uint32)", PROVIDER, 200_000));
        assertFalse(ok);
    }

    // ── request / fee / refund wiring ───────────────────────────────────────────────────────────────

    function testFork_request_feeCommitmentAndRefundGuard() public {
        if (!forked) return;
        assertEq(a.provider(), PROVIDER);
        assertEq(a.fee(CB_GAS), RH.DICE_FEE);
        vm.expectRevert(abi.encodeWithSelector(DiceEntropyAdapter.WrongFee.selector, RH.DICE_FEE + 1, RH.DICE_FEE));
        consumer.request{value: RH.DICE_FEE + 1}();

        vm.recordLogs();
        uint256 seq = consumer.request{value: RH.DICE_FEE}();
        assertEq(seq, S);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(DICE) && logs[i].topics[0] == IDiceEntropy.Requested.selector) {
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(a));
                (bytes32 user, uint32 gasLimit,) = abi.decode(logs[i].data, (bytes32, uint32, bytes));
                assertEq(user, a.userRandom(uint64(FORK_BLOCK)));
                assertEq(gasLimit, CB_GAS + 100_000);
                seen = true;
            }
        }
        assertTrue(seen);
        IDiceEntropy.Request memory r = DICE.getRequestV2(PROVIDER, S);
        assertEq(r.requester, address(a));
        assertEq(r.numHashes, 1);
        assertEq(r.gasLimit10k, 100);
        assertEq(r.feePaid, RH.DICE_FEE);
        assertEq(r.callbackStatus, DiceStatus.CALLBACK_NOT_STARTED);
        assertEq(r.commitment, keccak256(abi.encodePacked(keccak256(abi.encodePacked(_u(S))), X_2288)));
        assertEq(a.commitmentOf(S), r.commitment);
        assertTrue(a.isPending(S));
        // past Dice's refund delay nobody can void it: only the requester may refund, and the adapter never does
        vm.roll(vm.getBlockNumber() + 10);
        vm.prank(stranger);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        DICE.refundRequest(PROVIDER, S);
        assertTrue(a.isPending(S));
    }

    // ── a genuine provider reveal (mainnet's value for 2289) ─────────────────────────────────────────

    function testFork_providerReveal_settlesThroughMarkets() public {
        if (!forked) return;
        uint256 seq = consumer.request{value: RH.DICE_FEE}();
        vm.roll(vm.getBlockNumber() + 5);
        bytes32 h = blockhash(FORK_BLOCK); // the real hash of the flip's block
        assertTrue(h != bytes32(0));
        uint256 g = gasleft();
        _revealAs(PROVIDER, uint64(seq), X_2289);
        emit log_named_uint("reveal gas (live Dice + adapter + 900k consumer)", g - gasleft());
        assertEq(consumer.deliveries(), 1);
        assertFalse(consumer.lastSafe());
        assertEq(consumer.lastWord(), _word(_u(seq), X_2289, h));
        IDiceEntropy.ProviderInfo memory p = DICE.getProviderInfoV2(PROVIDER);
        assertEq(p.currentCommitmentSequenceNumber, S);
        assertEq(a.openCount(), 0);
    }

    // ── withholding: a later reveal makes the withheld request recoverable by anyone ────────────────

    function testFork_withheld_recoveredByAnyone() public {
        if (!forked) return;
        uint256 s1 = consumer.request{value: RH.DICE_FEE}();
        uint256 s2 = consumer.request{value: RH.DICE_FEE}();
        assertEq(s2, s1 + 1);
        vm.roll(vm.getBlockNumber() + 10); // also past the refund window
        _revealAs(PROVIDER, uint64(s2), X_2290); // serves 2290, withholds 2289
        assertEq(consumer.lastId(), s2);
        assertFalse(a.isPending(s1));
        assertTrue(a.requestInfo(s1).computable);
        vm.prank(stranger);
        a.recoverFromChain(s1); // hashes the on-chain commitment (x_2290) down to x_2289
        assertEq(consumer.lastId(), s1);
        assertTrue(consumer.lastSafe());
        assertEq(consumer.lastWord(), _word(_u(s1), X_2289, blockhash(FORK_BLOCK)));
        // the provider's late reveal is now a no-op for us (Dice just clears it)
        _revealAs(PROVIDER, uint64(s1), X_2289);
        assertEq(consumer.deliveries(), 2);
    }

    /// @notice On live state: a request Tyche skipped weeks ago is revealable by anyone from public values.
    function testFork_publicRecovery_liveStraggler() public {
        if (bytes(rpc).length == 0) return;
        // recent state on the archive node (it lags its own head; the public RPC rate-limits forks)
        vm.createSelectFork(rpc, STRAGGLER_FORK_BLOCK);
        IDiceEntropy.Request memory r = DICE.getRequestV2(PROVIDER, STRAGGLER);
        if (r.sequenceNumber != STRAGGLER) {
            emit log("straggler 1284 not open at the pinned block");
            return;
        }
        IDiceEntropy.ProviderInfo memory p = DICE.getProviderInfoV2(PROVIDER);
        bytes32 x = _hashN(p.currentCommitment, p.currentCommitmentSequenceNumber - STRAGGLER);
        vm.recordLogs();
        vm.prank(stranger, stranger);
        DICE.revealWithCallback{gas: 5_000_000}(PROVIDER, STRAGGLER, STRAGGLER_U, x);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool revealed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(DICE) && logs[i].topics[0] == IDiceEntropy.Revealed.selector) revealed = true;
        }
        assertTrue(revealed, "a stranger revealed a skipped request from public data");
        // delivered and cleared, or (if its consumer's callback failed) marked CALLBACK_FAILED with the number public
        r = DICE.getRequestV2(PROVIDER, STRAGGLER);
        assertTrue(r.sequenceNumber != STRAGGLER || r.callbackStatus == DiceStatus.CALLBACK_FAILED);
    }

    // ── dice-mirror: re-key the live provider, then keeper-style reveals ─────────────────────────────

    bytes32 internal constant MIRROR_SECRET = keccak256("dev keeper chain");
    uint256 internal constant MIRROR_LEN = 64;
    uint64 internal mirrorOrigin;

    /// @dev what `register-provider` does in dice-mirror mode: the admin's own registerFor, as an impersonated tx
    function _mirrorRekey() internal {
        vm.prank(DICE_ADMIN);
        DICE.registerFor(PROVIDER, 0, _hashN(MIRROR_SECRET, MIRROR_LEN), "flipper-keeper", uint64(MIRROR_LEN), "");
        mirrorOrigin = DICE.getProviderInfoV2(PROVIDER).originalCommitmentSequenceNumber;
    }

    function _mx(uint64 seq) internal view returns (bytes32) {
        return _hashN(MIRROR_SECRET, MIRROR_LEN - (seq - mirrorOrigin));
    }

    /// @dev forced outcome, as the dev keeper does it: point the request's stored commitment at a chosen value, and
    ///      first move the provider's current commitment to the request's real value so the chain stays intact
    function _forceValue(uint64 seq, bytes32 forced) internal {
        IDiceEntropy.Request memory r = DICE.getRequestV2(PROVIDER, seq);
        uint256 base = _requestSlot(seq);
        bytes32 commitment = keccak256(abi.encodePacked(keccak256(abi.encodePacked(_u(seq))), _hashN(forced, r.numHashes)));
        vm.store(address(DICE), bytes32(base + 1), commitment);
        uint256 p = uint256(keccak256(abi.encode(PROVIDER, SLOT_PROVIDERS)));
        uint256 packed = uint256(vm.load(address(DICE), bytes32(p + 7)));
        if (uint64(packed) < seq) {
            vm.store(address(DICE), bytes32(p + 6), _mx(seq));
            vm.store(address(DICE), bytes32(p + 7), bytes32((packed & ~uint256(type(uint64).max)) | seq));
        }
    }

    function _requestSlot(uint64 seq) internal view returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(PROVIDER, seq));
        uint256 slot = SLOT_REQUESTS + (uint8(key[0]) & 0x1f) * 4;
        uint256 w = uint256(vm.load(address(DICE), bytes32(slot)));
        if (address(uint160(w)) == PROVIDER && uint64(w >> 160) == seq) return slot;
        return uint256(keccak256(abi.encode(key, SLOT_OVERFLOW)));
    }

    function testFork_mirror_rekeyAndReveal() public {
        if (!forked) return;
        _mirrorRekey();
        assertEq(mirrorOrigin, S, "re-keyed at the next sequence number");
        uint256 seq = consumer.request{value: RH.DICE_FEE}();
        assertEq(seq, S + 1);
        vm.roll(vm.getBlockNumber() + 3);
        _revealAs(PROVIDER, uint64(seq), _mx(uint64(seq))); // the keeper reveals as the (impersonated) provider
        assertFalse(consumer.lastSafe());
        assertEq(consumer.lastWord(), _word(_u(seq), _mx(uint64(seq)), blockhash(FORK_BLOCK)));
    }

    function testFork_mirror_forcedOutcome_chainStaysIntact() public {
        if (!forked) return;
        _mirrorRekey();
        uint64 s1 = uint64(consumer.request{value: RH.DICE_FEE}());
        vm.roll(vm.getBlockNumber() + 2);
        bytes32 h = blockhash(FORK_BLOCK);
        // grind a provider value whose final word has the roll we want (the keeper matches the requested word's roll)
        uint256 wantRoll = 9_321;
        bytes32 u1 = _u(s1);
        bytes32 forced;
        for (uint256 i;; ++i) {
            forced = keccak256(abi.encode("forced", i));
            if (_word(u1, forced, h) % 10_000 == wantRoll) break;
        }
        _forceValue(s1, forced);
        _revealAs(PROVIDER, s1, forced);
        assertEq(consumer.lastWord() % 10_000, wantRoll);
        assertFalse(consumer.lastSafe());
        // later requests still reveal from the real chain
        uint64 s2 = uint64(consumer.request{value: RH.DICE_FEE}());
        vm.roll(vm.getBlockNumber() + 2);
        vm.setBlockhash(a.requestInfo(s2).targetBlock, keccak256("a block past the fork")); // no mainnet hash here
        _revealAs(PROVIDER, s2, _mx(s2));
        assertEq(consumer.lastId(), s2);
        assertFalse(consumer.lastSafe());
    }

    function testFork_mirror_scenarios_withholdLateThirdPartyStall() public {
        if (!forked) return;
        _mirrorRekey();
        // withhold s1 past Dice's refund window, serve s2, recover s1
        uint64 s1 = uint64(consumer.request{value: RH.DICE_FEE}());
        vm.roll(vm.getBlockNumber() + 1);
        uint64 s2 = uint64(consumer.request{value: RH.DICE_FEE}());
        vm.roll(vm.getBlockNumber() + DICE.getRefundDelayBlocks() + 1);
        vm.prank(stranger);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        DICE.refundRequest(PROVIDER, s1);
        _revealAs(PROVIDER, s2, _mx(s2));
        vm.prank(stranger);
        a.recoverFromChain(s1);
        assertEq(consumer.lastId(), s1);
        assertTrue(consumer.lastSafe());
        // late first attempt → safe
        uint64 s3 = uint64(consumer.request{value: RH.DICE_FEE}());
        vm.roll(vm.getBlockNumber() + 2);
        vm.warp(vm.getBlockTimestamp() + RH.diceAdapterConfig().promptWindow + 1);
        _revealAs(PROVIDER, s3, _mx(s3));
        assertTrue(consumer.lastSafe());
        // third-party first attempt → safe
        uint64 s4 = uint64(consumer.request{value: RH.DICE_FEE}());
        vm.roll(vm.getBlockNumber() + 2);
        _revealAs(stranger, s4, _mx(s4));
        assertTrue(consumer.lastSafe());
        // total stall → requests refused, breaker latched until the owner resumes
        uint64 s5 = uint64(consumer.request{value: RH.DICE_FEE}());
        vm.warp(vm.getBlockTimestamp() + RH.diceAdapterConfig().stallTimeout + 1);
        vm.roll(vm.getBlockNumber() + 2);
        assertTrue(a.stalled());
        vm.expectRevert(DiceEntropyAdapter.ProviderStalled.selector);
        consumer.request{value: RH.DICE_FEE}();
        a.trip();
        _revealAs(PROVIDER, s5, _mx(s5));
        vm.expectRevert(DiceEntropyAdapter.ProviderStalled.selector);
        consumer.request{value: RH.DICE_FEE}();
        a.resume();
        consumer.request{value: RH.DICE_FEE}();
    }
}
