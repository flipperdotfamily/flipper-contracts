// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {PartnerBase} from "./Partner.t.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {TreasuryVault} from "../src/TreasuryVault.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {DutchAuctionConverter} from "../src/DutchAuctionConverter.sol";
import {IRouteAdapter} from "../src/interfaces/IRouteAdapter.sol";

/// @notice The drawdown circuit breaker (NAV per bankroll unit below half its all-time high → complete lock until the
///         unlocker unlocks), the guardian-cancel rule and the reserved-liability cap.
contract DrawdownTest is PartnerBase {
    using stdStorage for StdStorage;

    StdStorage internal store;
    uint256 internal constant ONE = 1e18;

    function _nav() internal view returns (uint256) {
        return house.treasury() * ONE / house.navUnits();
    }

    /// @dev set the treasury directly (tests of the threshold arithmetic only)
    function _setTreasury(uint256 t) internal {
        store.target(address(house)).sig("treasury()").checked_write(t);
    }

    function _lock() internal {
        _setTreasury(house.treasury() / 2 - 1);
        house.checkDrawdown();
        assertTrue(house.locked());
    }

    // ── measure ──────────────────────────────────────────────────────────────────────────────────────────

    function test_seed_bootstraps_units_and_ath() public view {
        assertEq(house.navUnits(), 100_000_000 ether, "1 unit per $FLIPPER at the seed");
        assertEq(house.navAth(), ONE);
        assertEq(house.unlocker(), address(this), "the deployer, not the owner");
        assertTrue(house.owner() != house.unlocker());
    }

    function test_lock_trips_strictly_below_half_the_ath() public {
        uint256 u = house.navUnits();
        _setTreasury(u / 2); // NAV exactly 0.5
        house.checkDrawdown();
        assertFalse(house.locked(), "exactly half: still open");
        _setTreasury(u / 2 - 1);
        vm.expectEmit(address(house));
        emit FlipperHouseBase.DrawdownLocked((u / 2 - 1) * ONE / u, ONE);
        house.checkDrawdown();
        assertTrue(house.locked());
    }

    /// Real wins: $FLIPPER flips paid out one after another trip the breaker once the NAV halves, not before.
    function test_consecutive_wins_trip_the_breaker() public {
        flipperToken.mint(alice, 1_000_000_000 ether);
        uint256 wins;
        while (!house.locked() && wins < 100) {
            FlipperHouseBase.Preview memory pv = house.previewFlip(address(flipperToken), 1);
            uint256 amount = pv.maxLiability * BPS / WIN_COST; // liability = 1.05 × stake
            uint256 id = _flip(alice, address(flipperToken), amount);
            uint256 navBefore = _nav();
            _reveal(id, WIN_WORD);
            wins++;
            if (!house.locked()) assertGe(_nav() * 2, house.navAth(), "open while NAV >= half");
            else assertLt(_nav() * 2, house.navAth(), "locked below half");
            navBefore;
        }
        assertTrue(house.locked(), "tripped");
        emit log_named_uint("max-size wins to trip", wins);
    }

    function test_capital_flows_do_not_move_the_nav() public {
        vault.crystallize();
        uint256 nav0 = _nav();
        vm.startPrank(alice);
        flipperToken.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(40_000_000 ether, 0);
        vm.stopPrank();
        assertApproxEqAbs(_nav(), nav0, 1, "deposit");
        vm.warp(vault.unlockAt(alice));
        vm.prank(alice);
        vault.requestWithdraw(shares);
        vm.warp(vm.getBlockTimestamp() + vault.withdrawCooldown());
        vm.prank(alice);
        vault.withdraw(0);
        assertApproxEqAbs(_nav(), nav0, 2, "withdrawal");
        house.checkDrawdown();
        assertFalse(house.locked());
    }

    function test_income_raises_the_nav_and_the_ath() public {
        uint256 nav0 = _nav();
        flipperToken.mint(address(router), 10_000_000 ether);
        router.process(); // creator revenue: half to the bankroll as income
        assertGt(_nav(), nav0);
        assertEq(house.navAth(), _nav());
    }

    function test_price_moves_cannot_trip_or_dodge() public {
        // inventory at zero value and nothing priced: dumping $FLIPPER or the flipped token moves no NAV
        uint256 id = _flip(alice, address(tokenT), 1_000_000 ether);
        uint256 nav0 = _nav();
        _sellForEth(flipperPool, 1_000_000_000 ether);
        _sellForEth(tPool, 400_000_000 ether);
        house.checkDrawdown();
        assertEq(_nav(), nav0);
        assertFalse(house.locked());
        id;
    }

    function test_dust_guard() public {
        uint128 min = uint128(house.treasury());
        vm.prank(owner);
        house.setLockMinTreasury(min);
        _setTreasury(house.treasury() / 4);
        house.checkDrawdown();
        assertFalse(house.locked(), "below the minimum treasury the check doesn't run");
    }

    // ── lock ─────────────────────────────────────────────────────────────────────────────────────────────

    function test_lock_halts_every_user_facing_path() public {
        uint256 pendingId = _flip(alice, address(tokenT), 1_000_000 ether);
        vm.startPrank(alice);
        flipperToken.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000 ether, 0);
        vm.stopPrank();
        _lock();

        FlipperHouseBase.Preview memory pv = house.previewFlip(address(tokenT), 1_000_000 ether);
        assertEq(pv.code, 8, "REJECT_LOCKED");
        uint256 fee = house.randomnessFeeFor(address(tokenT));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FlipperHouseBase.FlipRejected.selector, uint8(8)));
        house.flip{value: fee}(address(tokenT), 1_000_000 ether, 0, block.timestamp);

        bytes4 L = FlipperHouseBase.ProtocolLocked.selector;
        vm.expectRevert(L);
        house.listToken(address(tokenT), IRouteAdapter(address(sys.v4)));
        vm.warp(vm.getBlockTimestamp() + 8 days);
        vm.prank(alice);
        vm.expectRevert(L);
        house.cancelFlip(pendingId);
        vm.expectRevert(L);
        house.resolvePendingWin(pendingId);
        vm.expectRevert(L);
        house.sweepInventory(address(tokenT), 1);
        vm.expectRevert(L);
        house.claim(address(tokenT));
        vm.expectRevert(L);
        house.claimPartner(demoId);
        vm.expectRevert(L);
        house.depositTreasury(1);
        vm.expectRevert(L);
        house.flushRewards();
        vm.expectRevert(L);
        house.settleDeferred(pendingId);

        vm.startPrank(alice);
        vm.expectRevert(TreasuryVault.ProtocolLocked.selector);
        vault.deposit(1 ether, 0);
        vm.expectRevert(TreasuryVault.ProtocolLocked.selector);
        vault.requestWithdraw(1);
        vm.expectRevert(TreasuryVault.ProtocolLocked.selector);
        vault.withdraw(0);
        vm.expectRevert(TreasuryVault.ProtocolLocked.selector);
        vault.claimRewards();
        vm.stopPrank();
        vm.expectRevert(TreasuryVault.ProtocolLocked.selector);
        vault.crystallize();

        vm.expectRevert(RevenueRouter.ProtocolLocked.selector);
        router.harvest();
        vm.expectRevert(RevenueRouter.ProtocolLocked.selector);
        router.process();
        vm.expectRevert(DutchAuctionConverter.ProtocolLocked.selector);
        converter.take(0, 1, 0);

        // governance still works (e.g. to pause or fix params while locked)
        vm.prank(owner);
        house.setGuardian(bob);
    }

    /// Randomness delivered during the lock is recorded; it settles market-free after unlock, never cancels.
    function test_in_flight_flips_settle_after_unlock() public {
        uint256 w = _flip(alice, address(tokenT), 1_000_000 ether);
        uint256 l = _flip(bob, address(tokenT), 1_000_000 ether);
        uint256 f = _flip(alice, address(flipperToken), 1_000_000 ether);
        _lock();
        vm.expectEmit(address(house));
        emit FlipperHouseBase.SettlementDeferred(w);
        _reveal(w, WIN_WORD);
        _reveal(l, LOSS_WORD);
        _reveal(f, WIN_WORD);
        assertEq(uint8(_status(w)), uint8(FlipperHouseBase.Status.Pending), "recorded, not settled");
        assertEq(uint8(_status(l)), uint8(FlipperHouseBase.Status.Pending));

        house.unlock(true);
        vm.warp(vm.getBlockTimestamp() + 8 days);
        vm.prank(alice);
        vm.expectRevert(FlipperHouseBase.BadStatus.selector); // a recorded outcome can't be cancelled
        house.cancelFlip(w);

        uint256 tBefore = tokenT.balanceOf(alice);
        vm.prank(mallory);
        house.settleDeferred(w);
        assertEq(uint8(_status(w)), uint8(FlipperHouseBase.Status.WinPending), "market-free: winnings reserved");
        assertEq(tokenT.balanceOf(alice) - tBefore, 0);
        assertEq(house.claimable(alice, address(tokenT)), 1_000_000 ether, "stake back as a claimable");
        house.settleDeferred(l);
        assertEq(uint8(_status(l)), uint8(FlipperHouseBase.Status.LostInventory));
        house.settleDeferred(f);
        assertEq(uint8(_status(f)), uint8(FlipperHouseBase.Status.Won));
        vm.expectRevert(FlipperHouseBase.BadStatus.selector);
        house.settleDeferred(f);
        _assertSolvent();
    }

    // ── unlock ───────────────────────────────────────────────────────────────────────────────────────────

    function test_only_the_unlocker_unlocks_and_the_role_moves_in_two_steps() public {
        _lock();
        vm.prank(owner);
        vm.expectRevert(FlipperHouseBase.Unauthorized.selector);
        house.unlock(true);
        vm.prank(bob);
        vm.expectRevert(FlipperHouseBase.Unauthorized.selector);
        house.unlock(true);

        house.transferUnlocker(bob);
        assertEq(house.unlocker(), address(this), "not until accepted");
        vm.prank(mallory);
        vm.expectRevert(FlipperHouseBase.Unauthorized.selector);
        house.acceptUnlocker();
        vm.prank(bob);
        house.acceptUnlocker();
        assertEq(house.unlocker(), bob);
        vm.expectRevert(FlipperHouseBase.Unauthorized.selector);
        house.unlock(true);
        // ownership moving doesn't move the role
        vm.prank(owner);
        house.transferOwnership(mallory);
        assertEq(house.unlocker(), bob);
        vm.prank(bob);
        house.unlock(false);
        assertFalse(house.locked());
    }

    /// the unlocker is an operator key: the owner can name a new one at any time (a lost or compromised key never
    /// orphans the breaker), and doing so drops a pending hand-over
    function test_owner_reassigns_the_unlocker_at_any_time() public {
        _lock();
        address carol = makeAddr("carol");
        house.transferUnlocker(bob); // a hand-over is pending when the operator key (this) is lost
        vm.prank(mallory);
        vm.expectRevert();
        house.setUnlocker(carol);
        vm.prank(address(this));
        vm.expectRevert();
        house.setUnlocker(carol); // not the unlocker itself either: only the owner
        vm.prank(owner);
        vm.expectRevert(FlipperHouseBase.Unauthorized.selector);
        house.setUnlocker(address(0));
        vm.prank(owner);
        house.setUnlocker(carol);
        assertEq(house.unlocker(), carol);
        assertEq(house.pendingUnlocker(), address(0), "the pending hand-over is dropped");
        vm.prank(bob);
        vm.expectRevert(FlipperHouseBase.Unauthorized.selector);
        house.acceptUnlocker();
        vm.expectRevert(FlipperHouseBase.Unauthorized.selector);
        house.unlock(true); // the old unlocker is out
        vm.prank(carol);
        house.unlock(true);
        assertFalse(house.locked());
    }

    function test_unlock_keeping_the_ath_relocks_resetting_resumes() public {
        _lock();
        house.unlock(false);
        house.checkDrawdown();
        assertTrue(house.locked(), "still below half of the kept high");
        house.unlock(true);
        assertEq(house.navAth(), _nav(), "re-based");
        house.checkDrawdown();
        assertFalse(house.locked());
        _flip(alice, address(tokenT), 1_000_000 ether); // open again
    }

    // ── manual reference reset (cold streak) ───────────────────────────────────────────────────────────

    function test_reset_ath_is_the_unlockers() public {
        _setTreasury(house.navUnits() * 8 / 10); // NAV 0.8
        vm.prank(owner);
        vm.expectRevert(FlipperHouseBase.Unauthorized.selector);
        house.resetNavAth(0);
        vm.prank(alice);
        vm.expectRevert(FlipperHouseBase.Unauthorized.selector);
        house.resetNavAth(0);
        house.resetNavAth(0); // this contract deployed the house: the unlocker
        assertEq(house.navAth(), _nav());
    }

    function test_reset_ath_bounds() public {
        _setTreasury(house.navUnits() * 8 / 10);
        uint256 nav = _nav();
        uint256 ath = house.navAth();
        vm.expectRevert(abi.encodeWithSelector(FlipperHouseBase.AthOutOfBounds.selector, nav, ath, nav - 1));
        house.resetNavAth(nav - 1);
        vm.expectRevert(abi.encodeWithSelector(FlipperHouseBase.AthOutOfBounds.selector, nav, ath, ath + 1));
        house.resetNavAth(ath + 1);
        uint256 snap = vm.snapshotState();
        house.resetNavAth(ath); // exactly the high: a no-op, allowed
        assertEq(house.navAth(), ath);
        vm.revertToState(snap);
        house.resetNavAth(nav); // exactly today's NAV
        assertEq(house.navAth(), nav);
        // NAV above the recorded high (no check yet): nothing to lower
        _setTreasury(house.navUnits() * 9 / 10);
        uint256 nav2 = _nav();
        vm.expectRevert(abi.encodeWithSelector(FlipperHouseBase.AthOutOfBounds.selector, nav2, nav, nav2));
        house.resetNavAth(0);
    }

    function test_reset_ath_moves_the_threshold_and_new_highs_raise_it() public {
        uint256 u = house.navUnits();
        _setTreasury(u * 6 / 10); // a cold streak: NAV 0.6 of the 1.0 high (the lock would come at 0.5)
        house.checkDrawdown();
        assertFalse(house.locked());
        vm.expectEmit(address(house));
        emit FlipperHouseBase.NavAthReset(ONE, ONE * 6 / 10, ONE * 6 / 10, address(this));
        house.resetNavAth(0);
        // 0.45 would have locked against the old high; against the new 0.6 the line is 0.3
        _setTreasury(u * 45 / 100);
        house.checkDrawdown();
        assertFalse(house.locked(), "above half the new reference");
        _setTreasury(u * 3 / 10);
        house.checkDrawdown();
        assertFalse(house.locked(), "exactly half: open");
        _setTreasury(u * 3 / 10 - 1);
        house.checkDrawdown();
        assertTrue(house.locked(), "below half the new reference");
        // new highs raise the reference again as usual
        house.unlock(true);
        _setTreasury(u * 7 / 10);
        house.checkDrawdown();
        assertEq(house.navAth(), ONE * 7 / 10, "a new high");
    }

    function test_reset_ath_not_while_locked() public {
        _lock();
        vm.expectRevert(FlipperHouseBase.ProtocolLocked.selector);
        house.resetNavAth(0);
    }

    // ── guardian cancel ──────────────────────────────────────────────────────────────────────────────────

    function test_guardian_cancels_only_unrevealed_until_the_emergency_delay() public {
        uint256 id = _flip(alice, address(tokenT), 1_000_000 ether);
        // the first delivery fails: the number is public, the request is no longer pending
        entropy.failFirstAttempt(provider, _seq(id), bytes32(WIN_WORD));
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(owner);
        vm.expectRevert(FlipperHouseBase.RandomnessRevealed.selector);
        house.cancelFlip(id);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.prank(owner);
        house.cancelFlip(id); // emergency
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Refunded));

        uint256 id2 = _flip(alice, address(tokenT), 1_000_000 ether);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(owner);
        house.cancelFlip(id2); // provably unrevealed: fine after the guardian delay
        assertEq(uint8(_status(id2)), uint8(FlipperHouseBase.Status.Refunded));
    }

    // ── reserved cap ─────────────────────────────────────────────────────────────────────────────────────

    function test_max_reserved_caps_pending_liability() public {
        FlipperHouseBase.Params memory p = defaultParams();
        p.maxReservedBps = 1000; // 10% of the treasury
        vm.prank(owner);
        house.setParams(p);
        uint256 n;
        while (house.previewFlip(address(flipperToken), 4_000_000 ether).code == 0 && n < 20) {
            _flip(alice, address(flipperToken), 4_000_000 ether);
            n++;
        }
        assertLe(house.reserved() * BPS, house.treasury() * 1000);
        assertEq(house.previewFlip(address(flipperToken), 4_000_000 ether).code, 7);
        assertLt(n, 20);
    }
}
