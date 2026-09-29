// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FlipperBase} from "./utils/FlipperBase.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {DiceEntropyAdapter} from "../src/randomness/DiceEntropyAdapter.sol";
import {DiceEntropy} from "../src/mocks/dice/DiceEntropy.sol";
import {IDiceEntropy, DiceStatus} from "../src/interfaces/IDiceEntropy.sol";
import {IRandomnessAdapter, IRandomnessConsumer} from "../src/interfaces/IRandomness.sol";
import {IEntropyV2} from "../src/interfaces/IEntropyV2.sol";
import {FlipperDeploy} from "../script/lib/FlipperDeploy.sol";
import {DiceDeploy} from "../script/lib/DiceDeploy.sol";
import {RobinhoodAddresses as RH} from "../script/lib/RobinhoodAddresses.sol";

/// @dev Arbitrum's ArbSys as the adapter uses it: L2 block number + hashes of the last 256 L2 blocks
contract MockArbSys {
    uint256 public arbBlockNumber = 1000;
    mapping(uint256 => bytes32) public hashes;

    error InvalidBlockNumber(uint256 requested, uint256 current);

    function setBlock(uint256 n) external {
        arbBlockNumber = n;
    }

    function setHash(uint256 n, bytes32 h) external {
        hashes[n] = h;
    }

    function arbBlockHash(uint256 n) external view returns (bytes32) {
        if (n >= arbBlockNumber || n + 256 < arbBlockNumber) revert InvalidBlockNumber(n, arbBlockNumber);
        return hashes[n];
    }
}

/// @dev A consumer shaped like the house: burns most of its budget and refuses a market delivery short of it.
contract RecordingConsumer is IRandomnessConsumer {
    IRandomnessAdapter public immutable adapter;
    uint32 public immutable cbGas;
    uint256 public lastId;
    uint256 public lastWord;
    bool public lastSafe;
    uint256 public deliveries;

    constructor(IRandomnessAdapter a, uint32 g) {
        adapter = a;
        cbGas = g;
    }

    function request() external payable returns (uint256) {
        return adapter.request{value: msg.value}(cbGas);
    }

    function onRandomness(uint256 requestId, uint256 word, bool safeMode) external {
        require(msg.sender == address(adapter), "only adapter");
        if (!safeMode) require(gasleft() >= uint256(cbGas) * 31 / 32, "short");
        lastId = requestId;
        lastWord = word;
        lastSafe = safeMode;
        deliveries++;
        // settlement-sized work
        uint256 burn = cbGas * 8 / 10;
        uint256 start = gasleft();
        while (start - gasleft() < burn) {}
    }

    receive() external payable {}
}

/// @dev A player contract that tries to learn its flip's outcome inside the flip transaction.
contract SelectivePlayer {
    function flipAndPeek(FlipperHouse house, DiceEntropyAdapter a, address token, uint256 amount)
        external
        payable
        returns (bool targetReady, bytes32 targetHash)
    {
        IERC20(token).approve(address(house), amount);
        uint256 id = house.flip{value: msg.value}(token, amount, 0, block.timestamp);
        (,,,,,,,,,, uint256 requestId,) = house.flips(id);
        DiceEntropyAdapter.RequestView memory v = a.requestInfo(requestId);
        return (v.targetReady, v.targetHash);
    }
}

/// @notice Shared Dice setup: a local copy of the verified DiceEntropy with a hash chain the test holds.
abstract contract DiceFixture is Test {
    uint256 internal constant CHAIN_LEN = 256;
    bytes32 internal constant SECRET = keccak256("dice provider secret");

    DiceEntropy internal dice;
    address internal diceAdmin = makeAddr("diceAdmin");
    address internal diceVault = makeAddr("diceVault");
    address internal diceProvider = makeAddr("diceProvider");

    function _deployDice() internal {
        dice = new DiceEntropy(
            diceAdmin, uint128(RH.DICE_FEE), diceProvider, false, diceVault, _hashN(SECRET, CHAIN_LEN), uint64(CHAIN_LEN), "", 6
        );
        vm.prank(diceProvider);
        dice.setDefaultGasLimit(200_000); // live provider default
    }

    /// @dev the provider's value for sequence `seq` (auto-registered at sequence 0: chain[0] is the commitment)
    function _x(uint256 seq) internal pure returns (bytes32) {
        return _hashN(SECRET, CHAIN_LEN - seq);
    }

    function _hashN(bytes32 v, uint256 n) internal pure returns (bytes32) {
        for (uint256 i; i < n; ++i) v = keccak256(abi.encodePacked(v));
        return v;
    }

    function _u(DiceEntropyAdapter a, uint256 seq) internal view returns (bytes32) {
        return a.userRandom(a.requestInfo(seq).targetBlock);
    }

    /// @dev Dice's combined number for `seq` (combineRandomValues(user, provider, 0))
    function _diceNumber(DiceEntropyAdapter a, uint256 seq) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_u(a, seq), _x(seq), bytes32(0)));
    }

    function _word(DiceEntropyAdapter a, uint256 seq, bytes32 h) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(_diceNumber(a, seq), h)));
    }

    /// @dev a target-block hash under which `seq` wins (or loses) at `winChanceBps`
    function _hashFor(DiceEntropyAdapter a, uint256 seq, bool win, uint256 winChanceBps) internal view returns (bytes32 h) {
        for (uint256 i = 1;; ++i) {
            h = keccak256(abi.encode("target", seq, i));
            bool w = _word(a, seq, h) % 10_000 >= 10_000 - winChanceBps;
            if (w == win) return h;
        }
    }

    function _reveal(address origin, uint256 seq, bytes32 u) internal {
        vm.prank(origin, origin);
        dice.revealWithCallback{gas: 6_000_000}(diceProvider, uint64(seq), u, _x(seq));
    }
}

/// @notice The DiceEntropyAdapter behind the real FlipperHouse, on a local DiceEntropy (verified source, vendored).
contract DiceAdapterTest is FlipperBase, DiceFixture {
    DiceEntropyAdapter internal dadapter;
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp(); // pools, tokens and users from FlipperBase (its Pyth-based house is replaced below)
        _deployDice();
        FlipperDeploy.Config memory c = FlipperDeploy.Config({
            poolManager: manager,
            entropy: IEntropyV2(address(0)),
            entropyProvider: address(0),
            deployer: address(this),
            owner: address(this),
            proxyAdminOwner: proxyAdminOwner,
            params: defaultParams()
        });
        RevenueRouter r = FlipperDeploy.deployRouter(c);
        dadapter = DiceEntropyAdapter(
            address(DiceDeploy.deployAdapter(c, IDiceEntropy(address(dice)), address(0), false, RH.diceAdapterConfig()))
        );
        sys = FlipperDeploy.deployCore(c, r, IERC20(address(flipperToken)), IRandomnessAdapter(address(dadapter)));
        house = sys.house;
        router = sys.router;
        house.setTokenRoute(address(tokenT), _route1(tPool, flipperPool));
        flipperToken.approve(address(house), type(uint256).max);
        house.depositTreasury(100_000_000 ether);
        for (uint256 i; i < 3; ++i) {
            address u = [alice, bob, mallory][i];
            vm.startPrank(u);
            flipperToken.approve(address(house), type(uint256).max);
            tokenT.approve(address(house), type(uint256).max);
            vm.stopPrank();
        }
        vm.roll(100);
        vm.warp(1_800_000_000);
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────────────

    function _winChance(uint256 flipId) internal view returns (uint256 w) {
        (,, w,,,,,,,,,) = house.flips(flipId);
    }

    /// @dev move one block on and make the flip's target block hash decide `win`
    function _steer(uint256 flipId, bool win) internal returns (uint256 seq) {
        seq = _seq(flipId);
        DiceEntropyAdapter.RequestView memory v = dadapter.requestInfo(seq);
        if (vm.getBlockNumber() <= v.targetBlock) vm.roll(v.targetBlock + 1);
        vm.setBlockhash(v.targetBlock, _hashFor(dadapter, seq, win, _winChance(flipId)));
    }

    function _settled(Vm.Log[] memory logs) internal view returns (bool found, bool won, FlipperHouseBase.Status st, bool safe) {
        bytes32 sig = FlipperHouseBase.FlipSettled.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(house) && logs[i].topics[0] == sig) {
                uint256 roll;
                uint256 a;
                uint256 b;
                uint256 c;
                (won, roll, st, a, b, c, safe) =
                    abi.decode(logs[i].data, (bool, uint256, FlipperHouseBase.Status, uint256, uint256, uint256, bool));
                return (true, won, st, safe);
            }
        }
    }

    function _revealFlip(address origin, uint256 flipId)
        internal
        returns (bool found, bool won, FlipperHouseBase.Status st, bool safe)
    {
        uint256 seq = _seq(flipId);
        vm.recordLogs();
        _reveal(origin, seq, _u(dadapter, seq));
        return _settled(vm.getRecordedLogs());
    }

    // ── fee and wiring ──────────────────────────────────────────────────────────────────────────────

    function test_fee_isDiceFlatFee_andExcessRefunded() public {
        assertEq(dadapter.fee(0), RH.DICE_FEE);
        assertEq(house.randomnessFeeFor(address(tokenT)), RH.DICE_FEE);
        assertEq(house.randomnessFeeFor(address(flipperToken)), RH.DICE_FEE);
        uint256 before = alice.balance;
        vm.prank(alice);
        house.flip{value: 1 ether}(address(tokenT), 1_000_000 ether, 0, block.timestamp);
        assertEq(before - alice.balance, RH.DICE_FEE, "exactly the Dice fee is kept");
        assertEq(address(dice).balance, RH.DICE_FEE);
        assertEq(address(dadapter).balance, 0);
        assertEq(dadapter.provider(), diceProvider);
        assertEq(dadapter.trustedRevealer(), diceProvider);
    }

    function test_request_storesDiceCommitment() public {
        uint256 id = _flip(alice, address(tokenT), 1_000_000 ether);
        uint256 seq = _seq(id);
        IDiceEntropy.Request memory r = IDiceEntropy(address(dice)).getRequestV2(diceProvider, uint64(seq));
        assertEq(r.requester, address(dadapter));
        assertEq(dadapter.commitmentOf(seq), r.commitment);
        assertEq(uint256(r.gasLimit10k) * 10_000, uint256(defaultParams().callbackGasLimit) + 100_000);
        assertEq(r.feePaid, RH.DICE_FEE);
        assertTrue(dadapter.isPending(seq));
        assertEq(dadapter.openCount(), 1);
    }

    function test_onlyConsumerRequests_onlyDiceCallsBack() public {
        vm.expectRevert(DiceEntropyAdapter.OnlyConsumer.selector);
        dadapter.request{value: RH.DICE_FEE}(100_000);
        vm.expectRevert(DiceEntropyAdapter.OnlyEntropy.selector);
        dadapter._entropyCallback(1, diceProvider, bytes32(0));
    }

    // ── normal delivery ─────────────────────────────────────────────────────────────────────────────

    function test_normalDelivery_win() public {
        uint256 id = _flip(alice, address(tokenT), 1_000_000 ether);
        _steer(id, true);
        (bool found, bool won, FlipperHouseBase.Status st, bool safe) = _revealFlip(diceProvider, id);
        assertTrue(found && won && !safe);
        assertEq(uint8(st), uint8(FlipperHouseBase.Status.Won));
        assertEq(dadapter.openCount(), 0);
        _assertSolvent();
    }

    function test_normalDelivery_loss() public {
        uint256 id = _flip(alice, address(tokenT), 1_000_000 ether);
        _steer(id, false);
        (bool found, bool won, FlipperHouseBase.Status st, bool safe) = _revealFlip(diceProvider, id);
        assertTrue(found && !won && !safe);
        assertEq(uint8(st), uint8(FlipperHouseBase.Status.Lost));
        _assertSolvent();
    }

    function test_normalDelivery_flipperToken() public {
        uint256 id = _flip(alice, address(flipperToken), 100_000 ether);
        _steer(id, true);
        (bool found, bool won, FlipperHouseBase.Status st, bool safe) = _revealFlip(diceProvider, id);
        assertTrue(found && won && !safe);
        assertEq(uint8(st), uint8(FlipperHouseBase.Status.Won));
    }

    function test_word_isDiceNumberMixedWithTargetHash() public {
        uint256 id = _flip(alice, address(flipperToken), 100_000 ether);
        uint256 seq = _steer(id, true);
        bytes32 h = blockhash(dadapter.requestInfo(seq).targetBlock);
        uint256 expected = _word(dadapter, seq, h);
        _reveal(diceProvider, seq, _u(dadapter, seq));
        (,,, uint16 roll,,,,,,,,) = house.flips(id);
        assertEq(roll, expected % 10_000);
    }

    // ── selection: the outcome is unknowable inside the flip transaction ──────────────────────────────

    function test_selection_outcomeUnknowableInFlipTx() public {
        SelectivePlayer p = new SelectivePlayer();
        tokenT.mint(address(p), 1_000_000 ether);
        (bool ready, bytes32 h) = p.flipAndPeek{value: RH.DICE_FEE}(house, dadapter, address(tokenT), 1_000_000 ether);
        assertFalse(ready, "the target block is the flip's own block");
        assertEq(h, bytes32(0));
    }

    function test_selection_sameDiceNumberEitherOutcome() public {
        uint256 id = _flip(alice, address(tokenT), 1_000_000 ether);
        uint256 seq = _seq(id);
        uint256 w = _winChance(id);
        // one fixed Dice number (the provider knows it at request time), both outcomes still possible
        bytes32 hw = _hashFor(dadapter, seq, true, w);
        bytes32 hl = _hashFor(dadapter, seq, false, w);
        assertTrue(_word(dadapter, seq, hw) % 10_000 >= 10_000 - w);
        assertTrue(_word(dadapter, seq, hl) % 10_000 < 10_000 - w);
    }

    // ── safe mode ───────────────────────────────────────────────────────────────────────────────────

    function test_lateFirstAttempt_settlesSafe() public {
        uint256 id = _flip(alice, address(tokenT), 1_000_000 ether);
        _steer(id, true);
        vm.warp(vm.getBlockTimestamp() + RH.diceAdapterConfig().promptWindow + 1);
        (bool found, bool won, FlipperHouseBase.Status st, bool safe) = _revealFlip(diceProvider, id);
        assertTrue(found && won && safe);
        assertEq(uint8(st), uint8(FlipperHouseBase.Status.WinPending));
    }

    function test_thirdPartyFirstAttempt_settlesSafe() public {
        uint256 id = _flip(alice, address(tokenT), 1_000_000 ether);
        _steer(id, false);
        (bool found, bool won, FlipperHouseBase.Status st, bool safe) = _revealFlip(stranger, id);
        assertTrue(found && !won && safe);
        assertEq(uint8(st), uint8(FlipperHouseBase.Status.LostInventory));
    }

    function test_revealInRequestBlock_failsThenRecoversSafe() public {
        uint256 id = _flip(alice, address(tokenT), 1_000_000 ether);
        uint256 seq = _seq(id);
        _reveal(diceProvider, seq, _u(dadapter, seq)); // same block: TargetNotReady → Dice records CALLBACK_FAILED
        IDiceEntropy.Request memory r = IDiceEntropy(address(dice)).getRequestV2(diceProvider, uint64(seq));
        assertEq(r.callbackStatus, DiceStatus.CALLBACK_FAILED);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Pending));
        assertFalse(dadapter.isPending(seq), "a failed attempt made the number public");
        _steer(id, true);
        vm.prank(stranger);
        dadapter.recoverFromChain(seq);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.WinPending));
    }

    function test_diceRetryGriefed_thenRecover() public {
        uint256 id = _flip(alice, address(tokenT), 1_000_000 ether);
        uint256 seq = _seq(id);
        bytes32 u = _u(dadapter, seq);
        _reveal(diceProvider, seq, u); // first attempt fails (same block)
        _steer(id, false);
        // Dice's retry path clears the request first and swallows a failing callback: starve it
        bool griefed;
        for (uint256 g = 40_000; g < 400_000 && !griefed; g += 5_000) {
            uint256 snap = vm.snapshotState();
            try dice.revealWithCallback{gas: g}(diceProvider, uint64(seq), u, _x(seq)) {
                IDiceEntropy.Request memory r = IDiceEntropy(address(dice)).getRequestV2(diceProvider, uint64(seq));
                griefed = r.sequenceNumber != seq && uint8(_status(id)) == uint8(FlipperHouseBase.Status.Pending);
            } catch {}
            if (!griefed) vm.revertToState(snap);
        }
        assertTrue(griefed, "request cleared at Dice, flip still pending");
        vm.prank(stranger);
        dadapter.recover(seq, _x(seq), uint64(seq));
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.LostInventory));
    }

    // ── withholding ─────────────────────────────────────────────────────────────────────────────────

    function test_withheld_becomesRecoverableOnLaterReveal_noCancel() public {
        uint256 a = _flip(alice, address(tokenT), 1_000_000 ether);
        // separate target blocks, so each outcome can be steered on its own; steer a's before b's request, which
        // snapshots its predecessor's target hash
        _steer(a, false);
        uint256 b = _flip(bob, address(tokenT), 1_000_000 ether);
        uint256 sa = _seq(a);
        uint256 sb = _seq(b);
        assertEq(sb, sa + 1);
        assertTrue(dadapter.targetHashOf(sa) != bytes32(0), "b's request snapshotted a's target hash");
        _steer(b, true);
        // the provider serves b and withholds a (a would lose)
        _reveal(diceProvider, sb, _u(dadapter, sb));
        assertEq(uint8(_status(b)), uint8(FlipperHouseBase.Status.Won));
        assertFalse(dadapter.isPending(sa), "a is computable from b's value");
        assertTrue(dadapter.requestInfo(sa).computable);
        // a's player cannot void it, even after the cancel delay
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        vm.prank(alice);
        vm.expectRevert(FlipperHouseBase.RandomnessRevealed.selector);
        house.cancelFlip(a);
        // anyone settles it from the provider's latest on-chain value: the committed (losing) outcome, market-free
        vm.prank(stranger);
        dadapter.recoverFromChain(sa);
        assertEq(uint8(_status(a)), uint8(FlipperHouseBase.Status.LostInventory));
        // a late reveal of a is a no-op
        _reveal(diceProvider, sa, _u(dadapter, sa));
        assertEq(uint8(_status(a)), uint8(FlipperHouseBase.Status.LostInventory));
        _assertSolvent();
    }

    function test_recover_rejectsWrongValue() public {
        uint256 a = _flip(alice, address(tokenT), 1_000_000 ether);
        uint256 sa = _seq(a);
        _steer(a, true);
        vm.expectRevert(DiceEntropyAdapter.IncorrectRevelation.selector);
        dadapter.recover(sa, keccak256("guess"), uint64(sa));
        vm.expectRevert(DiceEntropyAdapter.IncorrectRevelation.selector);
        dadapter.recover(sa, _x(sa + 1), uint64(sa)); // a later value claimed for the wrong sequence
        vm.expectRevert(DiceEntropyAdapter.NotComputable.selector);
        dadapter.recoverFromChain(sa);
        dadapter.recover(sa, _x(sa + 3), uint64(sa + 3)); // any later value, hashed down
        assertEq(uint8(_status(a)), uint8(FlipperHouseBase.Status.WinPending));
        vm.expectRevert(DiceEntropyAdapter.NotPending.selector);
        dadapter.recover(sa, _x(sa), uint64(sa));
    }

    function test_adapterNeverRefunds() public {
        uint256 a = _flip(alice, address(tokenT), 1_000_000 ether);
        uint64 sa = uint64(_seq(a));
        vm.roll(vm.getBlockNumber() + 10); // past Dice's refund delay (6)
        vm.prank(stranger);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        dice.refundRequest(diceProvider, sa);
        // even the adapter itself could not be refunded: it has no receive()
        vm.prank(address(dadapter));
        vm.expectRevert(bytes("refund transfer failed"));
        dice.refundRequest(diceProvider, sa);
        assertTrue(dadapter.isPending(sa));
    }

    // ── stalls, cancel and caps ─────────────────────────────────────────────────────────────────────

    function test_totalHalt_stallRefusesFlips_tripLatches_cancelAfterDelay() public {
        uint256 a = _flip(alice, address(tokenT), 1_000_000 ether);
        uint256 sa = _seq(a);
        assertFalse(dadapter.stalled());
        vm.expectRevert(DiceEntropyAdapter.NotStalled.selector);
        dadapter.trip();
        vm.warp(vm.getBlockTimestamp() + RH.diceAdapterConfig().stallTimeout + 1);
        vm.roll(vm.getBlockNumber() + 5);
        assertTrue(dadapter.stalled());
        assertTrue(dadapter.health().stalled);
        uint256 fee = house.randomnessFeeFor(address(tokenT));
        vm.prank(bob);
        vm.expectRevert(DiceEntropyAdapter.ProviderStalled.selector);
        house.flip{value: fee}(address(tokenT), 1_000_000 ether, 0, block.timestamp);
        vm.prank(stranger);
        dadapter.trip();
        assertTrue(dadapter.tripped());
        // the provider is silent for the whole cancel delay: the player may cancel (stake back)
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 balBefore = tokenT.balanceOf(alice);
        assertTrue(dadapter.isPending(sa));
        vm.prank(alice);
        house.cancelFlip(a);
        assertEq(uint8(_status(a)), uint8(FlipperHouseBase.Status.Refunded));
        assertEq(tokenT.balanceOf(alice) - balBefore, 1_000_000 ether);
        // the provider comes back: the cancelled flip's delivery is ignored, the breaker stays latched
        vm.setBlockhash(dadapter.requestInfo(sa).targetBlock, keccak256("h"));
        _reveal(diceProvider, sa, _u(dadapter, sa));
        assertEq(uint8(_status(a)), uint8(FlipperHouseBase.Status.Refunded));
        assertFalse(dadapter.stalled());
        vm.prank(bob);
        vm.expectRevert(DiceEntropyAdapter.ProviderStalled.selector);
        house.flip{value: fee}(address(tokenT), 1_000_000 ether, 0, block.timestamp);
        // only the owner or the house's guardian (the operator key) resumes
        vm.prank(stranger);
        vm.expectRevert();
        dadapter.resume();
        address op = makeAddr("operator");
        vm.prank(house.owner());
        house.setGuardian(op);
        vm.prank(op);
        dadapter.resume();
        _flip(bob, address(tokenT), 1_000_000 ether);
    }

    function test_stall_ignoresComputableRequests() public {
        uint256 a = _flip(alice, address(tokenT), 1_000_000 ether);
        uint256 b = _flip(bob, address(tokenT), 1_000_000 ether);
        _steer(b, true);
        _reveal(diceProvider, _seq(b), _u(dadapter, _seq(b))); // a skipped, b served: a is computable
        vm.warp(vm.getBlockTimestamp() + RH.diceAdapterConfig().stallTimeout + 1);
        assertFalse(dadapter.stalled(), "a skipped request is a recovery job, not a stall");
        _flip(mallory, address(tokenT), 1_000_000 ether);
        assertEq(uint8(_status(a)), uint8(FlipperHouseBase.Status.Pending));
        uint256[] memory open = dadapter.pendingRequests(10);
        assertEq(open.length, 2); // a (computable, awaiting recovery) and mallory's
    }

    function test_maxOpenCap() public {
        DiceEntropyAdapter.Config memory c = RH.diceAdapterConfig();
        c.maxOpen = 2;
        dadapter.setConfig(c);
        uint256 a = _flip(alice, address(tokenT), 1_000_000 ether);
        _flip(bob, address(tokenT), 1_000_000 ether);
        uint256 fee = house.randomnessFeeFor(address(tokenT));
        vm.prank(mallory);
        vm.expectRevert(DiceEntropyAdapter.TooManyOpen.selector);
        house.flip{value: fee}(address(tokenT), 1_000_000 ether, 0, block.timestamp);
        _steer(a, true);
        _reveal(diceProvider, _seq(a), _u(dadapter, _seq(a)));
        _flip(mallory, address(tokenT), 1_000_000 ether);
    }

    function test_maxFeeCap() public {
        vm.prank(diceAdmin);
        IDiceEntropy(address(dice)).setFee(uint128(RH.DICE_FEE * 11));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(DiceEntropyAdapter.FeeAboveMax.selector, RH.DICE_FEE * 11, RH.DICE_FEE * 10)
        );
        house.flip{value: 1 ether}(address(tokenT), 1_000_000 ether, 0, block.timestamp);
    }

    function test_providerZeroDefaultGas_refused() public {
        vm.prank(diceProvider);
        dice.setDefaultGasLimit(0);
        vm.prank(alice);
        vm.expectRevert(DiceEntropyAdapter.ProviderMisconfigured.selector);
        house.flip{value: RH.DICE_FEE}(address(tokenT), 1_000_000 ether, 0, block.timestamp);
    }

    // ── target-block hash lifetime ──────────────────────────────────────────────────────────────────

    function test_expiredTargetHash_deliversStaleSafe() public {
        uint256 a = _flip(alice, address(tokenT), 1_000_000 ether);
        uint256 sa = _seq(a);
        vm.roll(vm.getBlockNumber() + 300); // > 256 blocks, never snapshotted
        assertTrue(dadapter.requestInfo(sa).stale);
        vm.recordLogs();
        _reveal(diceProvider, sa, _u(dadapter, sa));
        (bool found,,, bool safe) = _settled(vm.getRecordedLogs());
        assertTrue(found && safe, "stale: safe mode");
    }

    function test_snapshot_keepsTargetHash_andRequestSnapshotsPredecessor() public {
        uint256 a = _flip(alice, address(tokenT), 1_000_000 ether);
        uint256 sa = _seq(a);
        _steer(a, true);
        vm.roll(vm.getBlockNumber() + 1);
        _flip(bob, address(tokenT), 1_000_000 ether); // snapshots a's target hash
        assertTrue(dadapter.targetHashOf(sa) != bytes32(0));
        uint256 b = _flip(mallory, address(tokenT), 1_000_000 ether);
        uint256 sb = _seq(b);
        _steer(b, false);
        uint256[] memory ids = new uint256[](1);
        ids[0] = sb;
        dadapter.snapshot(ids);
        vm.roll(vm.getBlockNumber() + 400);
        (bool found, bool won,, bool safe) = _revealFlip(diceProvider, a);
        assertTrue(found && won && !safe, "snapshotted: prompt provider reveal still settles through markets");
        (found, won,, safe) = _revealFlip(diceProvider, b);
        assertTrue(found && !won && !safe);
    }

    // ── provider re-registration ────────────────────────────────────────────────────────────────────

    function test_reRegistration_needsInFlightDisclosed_oldChainStillRecovers() public {
        uint256 a = _flip(alice, address(tokenT), 1_000_000 ether);
        uint256 sa = _seq(a);
        _steer(a, true);
        bytes32 fresh = keccak256("fresh chain");
        vm.prank(diceAdmin);
        vm.expectRevert(bytes("in-flight requests exist"));
        IDiceEntropy(address(dice)).registerFor(diceProvider, 0, fresh, "", 100, "");
        // the in-flight request must be disclosed (revealed or advanced past) before a new chain can be registered
        IDiceEntropy(address(dice)).advanceProviderCommitment(diceProvider, uint64(sa), _x(sa));
        vm.prank(diceAdmin);
        IDiceEntropy(address(dice)).registerFor(diceProvider, 0, fresh, "", 100, "");
        assertFalse(dadapter.isPending(sa));
        vm.expectRevert(DiceEntropyAdapter.IncorrectRevelation.selector);
        dadapter.recoverFromChain(sa); // the current commitment is the new chain's
        dadapter.recover(sa, _x(sa), uint64(sa)); // the disclosed old-chain value
        assertEq(uint8(_status(a)), uint8(FlipperHouseBase.Status.WinPending));
    }

    // ── config ──────────────────────────────────────────────────────────────────────────────────────

    function test_config_bounds_onlyOwner() public {
        DiceEntropyAdapter.Config memory c = RH.diceAdapterConfig();
        c.promptWindow = 1;
        vm.expectRevert(DiceEntropyAdapter.InvalidConfig.selector);
        dadapter.setConfig(c);
        c = RH.diceAdapterConfig();
        c.stallTimeout = 10;
        vm.expectRevert(DiceEntropyAdapter.InvalidConfig.selector);
        dadapter.setConfig(c);
        vm.prank(stranger);
        vm.expectRevert();
        dadapter.setConfig(RH.diceAdapterConfig());
    }
}

/// @notice The adapter alone, in ArbSys (Robinhood) block mode, against a gas-hungry consumer.
contract DiceAdapterArbSysTest is DiceFixture {
    MockArbSys internal arb;
    DiceEntropyAdapter internal a;
    RecordingConsumer internal consumer;
    uint32 internal constant CB_GAS = 900_000; // RobinhoodAddresses.defaultParams().callbackGasLimit

    function setUp() public {
        vm.etch(RH.ARB_SYS, type(MockArbSys).runtimeCode);
        arb = MockArbSys(RH.ARB_SYS);
        arb.setBlock(5_000_000);
        _deployDice();
        FlipperDeploy.Config memory c;
        c.deployer = address(this);
        c.proxyAdminOwner = makeAddr("proxyAdminOwner");
        a = DiceEntropyAdapter(
            address(DiceDeploy.deployAdapter(c, IDiceEntropy(address(dice)), address(0), true, RH.diceAdapterConfig()))
        );
        consumer = new RecordingConsumer(IRandomnessAdapter(address(a)), CB_GAS);
        a.bind(address(consumer));
        vm.deal(address(this), 1 ether);
    }

    function test_arbSys_targetIsL2Block_normalDelivery() public {
        vm.roll(26_000_000); // L1 block number: irrelevant to the adapter on Arbitrum
        uint256 seq = consumer.request{value: RH.DICE_FEE}();
        assertEq(a.requestInfo(seq).targetBlock, 5_000_000);
        bytes32 h = keccak256("l2 block 5000000");
        arb.setHash(5_000_000, h);
        arb.setBlock(5_000_007);
        bytes32 u = a.userRandom(5_000_000);
        uint256 g = gasleft();
        vm.prank(diceProvider, diceProvider);
        dice.revealWithCallback{gas: 3_000_000}(diceProvider, uint64(seq), u, _x(seq));
        emit log_named_uint("reveal gas (Dice + adapter + 900k consumer)", g - gasleft());
        assertEq(consumer.deliveries(), 1);
        assertFalse(consumer.lastSafe(), "exact Dice gas limit leaves the consumer its full budget");
        assertEq(consumer.lastWord(), _word(a, seq, h));
    }

    function test_arbSys_expiredWindow_stale() public {
        uint256 seq = consumer.request{value: RH.DICE_FEE}();
        arb.setBlock(5_000_000 + 257);
        bytes32 u = a.userRandom(5_000_000);
        vm.prank(diceProvider, diceProvider);
        dice.revealWithCallback{gas: 3_000_000}(diceProvider, uint64(seq), u, _x(seq));
        assertTrue(consumer.lastSafe());
        assertEq(consumer.lastWord(), _word(a, seq, bytes32(0)));
    }

    function test_arbSys_initRequiresArbSys() public {
        vm.etch(RH.ARB_SYS, "");
        address impl = address(new DiceEntropyAdapter());
        bytes memory init = abi.encodeCall(
            DiceEntropyAdapter.initialize, (IDiceEntropy(address(dice)), address(0), true, RH.diceAdapterConfig(), address(this))
        );
        vm.expectRevert();
        FlipperDeploy.proxy(impl, makeAddr("pao"), init);
    }
}
