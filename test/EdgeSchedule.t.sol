// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PartnerBase} from "./Partner.t.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {MockEntropyV2} from "../src/mocks/MockEntropyV2.sol";

/// @dev pump a token, let a settlement land, dump it — all in one transaction
contract Sandwich {
    function run(
        PoolSwapTest swapper,
        PoolKey calldata pool,
        MockERC20 token,
        uint256 ethIn,
        MockEntropyV2 entropy,
        address provider,
        uint64 seq,
        bytes32 word
    ) external payable {
        token.approve(address(swapper), type(uint256).max);
        uint256 t0 = token.balanceOf(address(this));
        swapper.swap{value: ethIn}(
            pool, IPoolManager.SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
        );
        entropy.reveal{gas: 5_000_000}(provider, seq, word);
        uint256 got = token.balanceOf(address(this)) - t0;
        swapper.swap(
            pool, IPoolManager.SwapParams(false, -int256(got), TickMath.MAX_SQRT_PRICE - 1), PoolSwapTest.TestSettings(false, false), ""
        );
    }

    receive() external payable {}
}

/// @notice The edge schedule keyed on the house's own net buybacks: the base odds and the $FLIPPER payout step from
///         45% × 2.05× down to 47.5% × 2.0× as the ratcheted net ETH the house's settlement swaps moved through the
///         $FLIPPER pool grows from 25 to 250 ETH (here scaled: 0.25 → 2.5 ETH).
contract EdgeScheduleTest is PartnerBase {
    uint96 internal constant FROM = 0.25 ether;
    uint96 internal constant TO = 2.5 ether;

    MockERC20 internal t0; // a free route straight to $FLIPPER (no ETH leg: never counted)
    MockERC20 internal t10; // ~9.8% route cost

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        house.setEdgeSchedule(_schedule());
        t0 = _direct("T0", 0);
        t10 = _direct("T10", 94_000);
    }

    function _schedule() internal pure returns (FlipperHouseBase.EdgeSchedule memory s) {
        s = FlipperHouseBase.EdgeSchedule(FROM, TO, 4500, 4750, 20_500, 20_000);
    }

    /// @dev a token whose only route is one deep pool straight to $FLIPPER with `fee` (1 token = 1 $FLIPPER)
    function _direct(string memory sym, uint24 fee) internal returns (MockERC20 t) {
        t = new MockERC20(sym, sym, 18);
        (address a, address b) = address(t) < address(flipperToken)
            ? (address(t), address(flipperToken))
            : (address(flipperToken), address(t));
        PoolKey memory key = PoolKey(Currency.wrap(a), Currency.wrap(b), fee, TS, IHooks(address(0)));
        manager.initialize(key, uint160(1 << 96));
        t.mint(address(this), 1e40);
        flipperToken.mint(address(this), 1e40);
        t.approve(address(lp), type(uint256).max);
        flipperToken.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(TickMath.minUsableTick(TS), TickMath.maxUsableTick(TS), int256(uint256(1e33)), 0),
            ""
        );
        vm.prank(owner);
        house.setTokenRoute(address(t), _single(key));
        t.mint(alice, 1e30);
        vm.prank(alice);
        t.approve(address(house), type(uint256).max);
    }

    function _terms() internal view returns (uint256 w, uint256 p) {
        return (house.currentBaseWinChanceBps(), house.currentFlipperPayoutBps());
    }

    function _high(int128 h) internal {
        vm.prank(owner);
        house.setBuybackHigh(h);
    }

    /// @dev settle `id` with `word`, returning the change in `netBuybackEth` and the house's real hop ETH (from the
    ///      PoolManager's own Swap events)
    function _settle(uint256 id, uint256 word) internal returns (int256 dNet, int256 hop) {
        int256 n0 = house.netBuybackEth();
        vm.recordLogs();
        _reveal(id, word);
        hop = _houseHopEth(vm.getRecordedLogs());
        dNet = int256(house.netBuybackEth()) - n0;
    }

    // ── the accumulator ──────────────────────────────────────────────────────────────────────────────────

    function test_loss_books_the_sale_hop_and_win_the_buy_hop() public {
        uint256 id = _flip(alice, address(tokenT), 10_000_000 ether); // ≈ 1 ETH of T
        (int256 dNet, int256 hop) = _settle(id, LOSS_WORD);
        assertGt(dNet, 0.9 ether);
        assertEq(dNet, hop, "loss: + exactly the ETH the house sold into the $FLIPPER pool");
        assertEq(house.buybackHigh(), house.netBuybackEth());

        id = _flip(alice, address(tokenT), 10_000_000 ether);
        (dNet, hop) = _settle(id, WIN_WORD);
        assertLt(dNet, -0.9 ether);
        assertEq(dNet, hop, "win: - exactly the ETH the house took out of the $FLIPPER pool to buy the winnings");
        assertGt(house.buybackHigh(), house.netBuybackEth(), "the ratchet keeps the high");
    }

    function test_resolve_pending_win_books_its_buy() public {
        uint256 id = _flip(alice, address(tokenT), 10_000_000 ether);
        toggle.set(true, true, false, false); // the pool refuses both ways: the win is left pending
        _reveal(id, WIN_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.WinPending));
        assertEq(house.netBuybackEth(), 0, "nothing moved");
        toggle.set(false, false, false, false);
        int256 n0 = house.netBuybackEth();
        vm.recordLogs();
        house.resolvePendingWin(id);
        int256 hop = _houseHopEth(vm.getRecordedLogs());
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Won));
        assertLt(hop, 0);
        assertEq(int256(house.netBuybackEth()) - n0, hop);
    }

    function test_flipper_flips_and_routes_without_an_eth_leg_dont_count() public {
        uint256 id = _flip(alice, address(flipperToken), 1_000_000 ether);
        _reveal(id, LOSS_WORD);
        id = _flip(alice, address(t0), 10_000 ether); // token → $FLIPPER directly: no ETH hop
        _reveal(id, LOSS_WORD);
        assertEq(house.netBuybackEth(), 0);
    }

    function test_safe_mode_and_fallbacks_dont_count() public {
        uint256 id = _flip(alice, address(tokenT), 10_000_000 ether);
        entropy.failFirstAttempt(provider, _seq(id), bytes32(LOSS_WORD)); // a later delivery settles in safe mode
        entropy.reveal(provider, _seq(id), bytes32(LOSS_WORD));
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.LostInventory));
        assertEq(house.netBuybackEth(), 0);
    }

    // ── the ratchet and the schedule ─────────────────────────────────────────────────────────────────────

    function test_ratchet_never_steps_back() public {
        for (uint256 i; i < 4; ++i) {
            _settle(_flip(alice, address(tokenT), 1_000_000 ether), LOSS_WORD); // ≈ 0.1 ETH each
        }
        int128 high = house.buybackHigh();
        (uint256 w1, uint256 p1) = _terms();
        assertGt(w1, 4500, "stepped down past 0.25 ETH");
        for (uint256 i; i < 3; ++i) {
            _settle(_flip(alice, address(tokenT), 1_000_000 ether), WIN_WORD);
        }
        assertLt(house.netBuybackEth(), high);
        assertEq(house.buybackHigh(), high, "a losing streak doesn't move the high");
        (uint256 w2, uint256 p2) = _terms();
        assertEq(w2, w1);
        assertEq(p2, p1, "nor the edge back up");
    }

    function test_endpoints_midpoint_and_rounding() public {
        int128[6] memory h = [int128(0), 0.1 ether, int128(int96(FROM)), int128(1.375 ether), int128(int96(TO)), int128(int96(TO))];
        uint256[6] memory win = [uint256(4500), 4500, 4500, 4625, 4750, 4750];
        uint256[6] memory pay = [uint256(20_500), 20_500, 20_500, 20_250, 20_000, 20_000];
        for (uint256 i; i < 6; ++i) {
            _high(h[i]);
            (uint256 w, uint256 p) = _terms();
            assertEq(w, win[i], "win chance");
            assertEq(p, pay[i], "payout");
            FlipperHouseBase.Preview memory pv = house.previewFlip(address(flipperToken), 1 ether);
            assertEq(pv.winChanceBps, w);
            assertEq(pv.liability, Math.mulDiv(1 ether, p - BPS, BPS, Math.Rounding.Ceil));
        }
        // a thousandth of the way: 0.25 bps of win chance rounds down to none, 0.5 bps of payout rounds down to 1
        _high(int128(int96(FROM)) + int128(int96(TO - FROM)) / 1000 + 1);
        (uint256 w1, uint256 p1) = _terms();
        assertEq(w1, 4500);
        assertEq(p1, 20_499);
        (,, uint256 f, uint256 t, uint256 wv, uint256 pvv) = house.edgeProgress();
        assertEq(f, FROM);
        assertEq(t, TO);
        assertEq(wv, w1);
        assertEq(pvv, p1);
    }

    function test_flips_keep_their_flip_time_terms() public {
        uint256 amt = 1_000_000 ether;
        uint256 id = _flip(alice, address(flipperToken), amt); // 45% × 2.05×
        _high(int128(int96(TO)));
        uint256 b0 = flipperToken.balanceOf(alice);
        _reveal(id, WIN_WORD);
        assertEq(flipperToken.balanceOf(alice) - b0, amt * 20_500 / BPS, "paid at its own 2.05x");
        uint256 id2 = _flip(alice, address(flipperToken), amt);
        (,, uint16 w2,,,,,,,,, uint16 p2) = house.flips(id2);
        assertEq(w2, 4750);
        assertEq(p2, 20_000);
        _assertSolvent();
    }

    function test_lens_max_stake_at_base_odds_follows_the_schedule() public {
        _high(1.375 ether); // base 46.25%
        (uint256 amt, FlipperHouseBase.Preview memory pv) = lens.maxStake(house, address(tokenT), 1e30, true);
        assertGt(amt, 0, "found at the scheduled base odds");
        assertEq(pv.winChanceBps, 4625);
    }

    function test_min_edge_binds_on_a_costly_route_at_the_end() public {
        _high(int128(int96(TO)));
        FlipperHouseBase.Preview memory free = house.previewFlip(address(t0), 10_000 ether);
        assertEq(free.winChanceBps, 4750, "a free route gets the full end odds");
        FlipperHouseBase.Preview memory costly = house.previewFlip(address(t10), 10_000 ether);
        assertEq(costly.code, 0);
        assertGt(costly.routeCostBps, 900);
        assertGe(BPS - costly.routeCostBps - 2 * costly.winChanceBps, 200, "the chance-based fee holds 2%");
    }

    function test_partner_discount_on_top() public {
        _high(int128(int96(TO)));
        uint256 id = _flipWith(alice, address(flipperToken), 1_000_000 ether, _suffix("demo"));
        assertGt(_winChance(id), 4750);
        (, uint256 kept) = _edges(id);
        assertGe(kept + 1, 200, "the house keeps its floor after the partner");
    }

    function test_preview_equals_acceptance_at_the_boundary() public {
        _high(1.375 ether); // the midpoint
        uint256 lo = 1;
        uint256 hi = 1e30;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (house.previewFlip(address(flipperToken), mid).code == 0) lo = mid;
            else hi = mid;
        }
        assertEq(house.previewFlip(address(flipperToken), lo + 1).code, 7);
        uint256 fee = house.randomnessFeeFor(address(flipperToken));
        flipperToken.mint(alice, lo + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FlipperHouseBase.FlipRejected.selector, uint8(7)));
        house.flip{value: fee}(address(flipperToken), lo + 1, 0, block.timestamp);
        uint256 id = _flip(alice, address(flipperToken), lo);
        (,, uint16 w,,,,,,,,, uint16 p) = house.flips(id);
        assertEq(w, 4625);
        assertEq(p, 20_250);
    }

    function test_inflows_dont_move_the_edge() public {
        flipperToken.mint(address(this), 1_000 * 1_000_000 ether);
        house.depositTreasury(1_000 * 1_000_000 ether); // a 10x donation
        vault.crystallize();
        flipperToken.mint(mallory, 500 * 1_000_000 ether);
        vm.startPrank(mallory);
        flipperToken.approve(address(vault), type(uint256).max);
        vault.deposit(500 * 1_000_000 ether, 0);
        vm.stopPrank();
        (uint256 w, uint256 p) = _terms();
        assertEq(w, 4500);
        assertEq(p, 20_500);
        assertEq(house.netBuybackEth(), 0);
    }

    // ── manipulation ─────────────────────────────────────────────────────────────────────────────────────

    /// A pump before a loss's sale and a dump after it, in the same transaction as the settlement: the accumulator
    /// moves by exactly the house's real hop amount, and whatever extra the pump got the house was paid by the pumper.
    function test_pump_and_dump_around_a_settlement() public {
        uint256 id = _flip(alice, address(tokenT), 10_000_000 ether);
        // the baseline: the same loss, untouched
        uint256 snap = vm.snapshotState();
        (int256 base,) = _settle(id, LOSS_WORD);
        vm.revertToState(snap);

        Sandwich s = new Sandwich();
        vm.deal(address(s), 20 ether);
        int256 n0 = house.netBuybackEth();
        uint256 e0 = address(s).balance;
        vm.recordLogs();
        s.run(swapper, tPool, tokenT, 10 ether, entropy, provider, _seq(id), bytes32(LOSS_WORD));
        int256 hop = _houseHopEth(vm.getRecordedLogs());
        int256 dNet = int256(house.netBuybackEth()) - n0;
        assertEq(dNet, hop, "only the house's own hop counts, never the attacker's swaps");
        uint256 attackerLoss = e0 - address(s).balance;
        emit log_named_int("net booked, untouched", base);
        emit log_named_int("net booked, sandwiched", dNet);
        emit log_named_uint("attacker's ETH cost", attackerLoss);
        if (dNet > base) assertGe(int256(attackerLoss), dNet - base, "every extra wei of net was paid by the attacker");
    }

    // ── bounds ───────────────────────────────────────────────────────────────────────────────────────────

    function test_schedule_bounds() public {
        FlipperHouseBase.EdgeSchedule memory s = _schedule();
        vm.startPrank(owner);
        s.toEth = s.fromEth;
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setEdgeSchedule(s);
        s = _schedule();
        s.winEndBps = 3999; // under minWinChanceBps
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setEdgeSchedule(s);
        s = _schedule();
        s.payoutEndBps = 19_999; // under 2x
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setEdgeSchedule(s);
        s = _schedule();
        s.winEndBps = 4900;
        s.payoutEndBps = 20_100; // 49% × 2.01 = a 1.5% edge
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setEdgeSchedule(s);
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setBuybackHigh(-1);
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setBuybackHigh(int128(int96(TO)) + 1);
        vm.expectEmit(address(house));
        emit FlipperHouseBase.BuybackHighSet(1 ether);
        house.setBuybackHigh(1 ether);
        // off: Params' odds
        s = _schedule();
        s.toEth = 0;
        house.setEdgeSchedule(s);
        vm.stopPrank();
        (uint256 w, uint256 pay) = _terms();
        assertEq(w, house.params().baseWinChanceBps);
        assertEq(pay, house.params().flipperPayoutBps);
        vm.prank(alice);
        vm.expectRevert();
        house.setBuybackHigh(0);
    }
}
