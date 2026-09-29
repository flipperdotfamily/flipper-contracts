// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FlipperHouseBase} from "../../src/house/FlipperHouseBase.sol";
import {FlipperHouse} from "../../src/FlipperHouse.sol";
import {TreasuryVault} from "../../src/TreasuryVault.sol";
import {FlipperRewardToken} from "../../src/FlipperRewardToken.sol";
import {PrincipalLock} from "../../src/PrincipalLock.sol";
import {SimDriver} from "./SimDriver.sol";

/// @notice The dev-buy lockup (PrincipalLock) under real volume, deployed as Deploy.s.sol deploys it: the opening buy
///         (12.5% of the supply) is the lock's principal and, with the whole supply in the pool, the entire bankroll.
///   Run: nice -n 10 forge test --match-path test/sim/PrincipalLockVolume.t.sol -vv --gas-limit 9223372036854775807
contract PrincipalLockVolumeTest is SimDriver {
    uint256 internal constant Q = 1e27; // the vault's PPS_SCALE

    function setUp() public {
        // (seed 11 opens with an extreme player streak that trips the breaker by itself: NaturalBreakerTripTest)
        _start(vm.envOr("SIM_LOCK_SEED", uint256(12)));
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────────────────

    /// @dev the vault's post-crystallisation price per depositor share, computed here from its stored state
    ///      (independent of `_accrue`): above the mark depositors keep (1 − fee) of the gain
    function _modelPps() internal view returns (uint256 pps, uint256 prePps, uint256 hwm) {
        uint256 a = house.treasury();
        uint256 s = vault.totalSupply() + vault.protocolShares();
        hwm = vault.hwm();
        prePps = a * Q / s;
        pps = prePps <= hwm || vault.totalSupply() == 0
            ? prePps
            : hwm + (prePps - hwm) * (BPS - vault.performanceFeeBps()) / BPS;
    }

    function _modelLockValue() internal view returns (uint256) {
        (uint256 pps,,) = _modelPps();
        return vault.balanceOf(address(lock)) * pps / Q;
    }

    function _crystallize() internal {
        vm.prank(harvester);
        vault.crystallize();
    }

    // ── after each volume level ─────────────────────────────────────────────────────────────────────────

    /// $10k → $100k → $1M: at each level anyone's sweep pays devAddress only, others can't request, devAddress takes
    /// the excess after the cooldown (both reward sources swept with it), and the principal never moves. A level can
    /// land in a house drawdown (about 1 run in 4 at $10k, whatever the opening buy's size): the lock is then worth
    /// less than its principal, and nothing may leave it
    function test_lock_at_each_volume_level() public {
        _logHeader();
        uint256[3] memory lv = [uint256(10_000e18), 100_000e18, 1_000_000e18];
        string[3] memory nm = ["10k", "100k", "1M"];
        uint256 top = vm.envOr("SIM_LOCK_LEVELS", uint256(3));
        for (uint256 i; i < top; ++i) {
            _driveTo(lv[i], 40_000, 2 days);
            assertGe(st.volUsd, lv[i], "level reached");
            uint256 devBefore = token.balanceOf(dev);
            uint256 excessBefore = lock.withdrawableExcess();
            uint256 takenBefore = st.devExcess;
            _checkpoint(nm[i]); // sweeps (anyone) and takes the excess (devAddress), asserting as it goes
            assertEq(lock.principal(), principal0, "principal never moves");
            if (lock.value() < principal0) {
                // under water at this level: nothing is withdrawable, and nothing was taken
                assertEq(lock.withdrawableExcess(), 0, "under water: nothing withdrawable");
                assertEq(st.devExcess, takenBefore, "under water: no excess taken");
                console2.log("level under water (a house drawdown): value / principal", nm[i], lock.value(), principal0);
            }
            assertGe(token.balanceOf(dev), devBefore, "devAddress only ever receives");
            console2.log("level / excess before / dev received", nm[i], excessBefore, token.balanceOf(dev) - devBefore);
        }
        assertGt(st.devExcess, 0, "the lock earned an excess");
        assertGt(st.devVaultRewards, 0, "and vault rewards");
    }

    // ── under water ──────────────────────────────────────────────────────────────────────────────────────

    /// A house losing streak takes the lock under its principal: nothing is withdrawable, requests fail, sweeps still
    /// pay the rewards. Recovery up to the vault's high-water mark is fee-free; the excess only returns above it.
    function test_under_water_then_recovery() public {
        _driveTo(10_000e18, 40_000, 2 days);
        uint256 u = vault.unlockAt(address(lock));
        if (vm.getBlockTimestamp() < u) _advance(u - vm.getBlockTimestamp()); // past the vault's 7-day lock
        _checkpoint("10k"); // excess taken: the lock sits at (about) its principal at the mark
        {
            // unless the house is in a drawdown at this level (about 1 run in 4): then win back up to the vault's mark
            // and take the excess there, so the test starts where it means to
            (, uint256 pre0,) = _modelPps();
            if (pre0 < vault.hwm()) {
                while (pre0 < vault.hwm()) {
                    _streak(false, 1, BPS);
                    _crystallize();
                    (, pre0,) = _modelPps();
                }
                _upkeep();
                _takeExcess();
            }
        }
        _crystallize();
        uint256 hwm0 = vault.hwm();
        uint256 v0 = lock.value(); // at the mark
        assertApproxEqRel(v0, principal0, 0.01e18, "about the principal after taking the excess");
        uint256 pol0 = vault.protocolShares();

        uint256 made = _sinkLockTo(9_700, 400); // 3% under water
        assertFalse(house.locked(), "no breaker trip at -3%");
        assertLt(lock.value(), principal0, "under water");
        assertEq(lock.withdrawableExcess(), 0, "nothing withdrawable");
        console2.log("house-losing flips to go 3% under water", made);

        vm.startPrank(dev);
        vm.expectRevert(); // ExceedsExcess
        lock.requestExcess(1 ether);
        vm.expectRevert(TreasuryVault.ZeroAmount.selector); // nothing at all to queue
        lock.requestExcess(type(uint256).max);
        vm.stopPrank();
        _upkeep();
        _advance(3 days);
        uint256 got = _sweep(players[3]);
        console2.log("rewards swept while under water", got);

        // recovery with the house winning: no fee below the mark, the value returns to the principal at the mark
        while (true) {
            (, uint256 pre,) = _modelPps();
            if (pre >= hwm0) break;
            _streak(false, 1, BPS);
            _crystallize();
            (, pre,) = _modelPps();
            if (pre <= hwm0) {
                assertEq(vault.protocolShares(), pol0, "no performance fee below the mark");
                assertLe(lock.value(), v0, "below the mark the lock is worth less than at it");
            }
        }
        // above the mark: 20% of the lock's gain above it is excess
        _streak(false, 20, BPS);
        (uint256 pps, uint256 pre2, uint256 h) = _modelPps();
        uint256 lockShares = vault.balanceOf(address(lock));
        uint256 expectedExcess = lockShares * (pps - h) / Q + (lockShares * h / Q) - principal0;
        assertApproxEqRel(
            lock.withdrawableExcess(), Math.min(expectedExcess, vault.freeBankroll()), 1e12, "excess = 20% of the gain above the mark"
        );
        assertApproxEqRel(
            lock.value() - lockShares * h / Q, (lockShares * (pre2 - h) / Q) / 5, 1e10, "the lock keeps a fifth"
        );
        uint256 taken = _takeExcess();
        assertGt(taken, 0);
        assertGe(lock.value(), principal0);
    }

    /// The price falls during the cooldown: the queued withdrawal would breach the principal and reverts; cancel,
    /// request what is left over the principal, withdraw.
    function test_drawdown_during_cooldown() public {
        _driveTo(100_000e18, 40_000, 2 days);
        _upkeep();
        _advance(7 days);
        if (vm.getBlockTimestamp() < vault.unlockAt(address(lock))) _advance(vault.unlockAt(address(lock)) - vm.getBlockTimestamp());
        uint256 x = lock.withdrawableExcess();
        assertGt(x, 0, "an excess to request");
        vm.prank(dev);
        lock.requestExcess(type(uint256).max);
        (uint256 qs, uint256 qa,) = lock.pendingWithdrawal();
        assertGt(qs, 0);
        assertApproxEqRel(qa, x, 1e12);
        // losses during the cooldown: the position falls below principal + queued
        uint256 made;
        while (lock.value() >= principal0 + qa / 2 && made < 400 && !house.locked()) {
            made += _streak(true, 1, BPS);
            (, qa,) = lock.pendingWithdrawal();
        }
        (, qa,) = lock.pendingWithdrawal();
        _advance(vault.withdrawCooldown());
        if (lock.value() < principal0 + qa) {
            vm.prank(dev);
            vm.expectRevert(); // PrincipalBreach
            lock.withdrawExcess();
        }
        vm.prank(dev);
        lock.cancelExcess();
        uint256 x2 = lock.withdrawableExcess();
        if (vault.previewDeposit(x2) != 0) {
            vm.prank(dev);
            lock.requestExcess(x2);
            _advance(vault.withdrawCooldown());
            vm.prank(dev);
            lock.withdrawExcess();
        }
        assertGe(lock.value(), principal0, "never below the principal after a withdrawal");
        assertEq(lock.principal(), principal0);
    }

    // ── breaker ──────────────────────────────────────────────────────────────────────────────────────────

    /// A drawdown past half the NAV high trips the breaker: flips are refused, a delivery in flight is deferred, and
    /// every lock call reverts ProtocolLocked (sweeps included) while the pending rewards stay intact. After the
    /// unlocker lifts it the deferred flip settles, the sweep pays everything that was pending, and the lock's excess
    /// waits for the vault's high-water mark (the breaker's ATH reset doesn't move the vault's mark).
    function test_breaker_freezes_the_lock_and_keeps_its_rewards() public {
        _driveTo(10_000e18, 40_000, 2 days);
        _checkpoint("10k");
        _upkeep(); // a fresh stream
        _advance(2 days);
        uint256 hwmBefore = vault.hwm();

        // house losses until the breaker trips; a flip made just before is still in flight when it does
        uint256 tripsBefore = trips.length;
        uint256 made;
        uint256 inFlight;
        while (!house.locked() && made < 2_000) {
            if (inFlight == 0 && _nav() * 100 < uint256(house.navAth()) * 53) {
                address q = players[5];
                uint256 a = Math.max(_flipperCap(q, "") / 4, _minFlipperStake());
                if (token.balanceOf(q) < a) _buyExact(q, a - token.balanceOf(q));
                a = Math.min(a, token.balanceOf(q));
                inFlight = _flipOnly(q, address(token), a, "");
            }
            made += _streak(true, 1, BPS);
        }
        assertTrue(house.locked(), "breaker tripped");
        assertGt(inFlight, 0, "a flip in flight");
        _deliver(inFlight, Force.Random, false); // arrives while locked: deferred
        assertEq(uint8(_status(inFlight)), uint8(FlipperHouseBase.Status.Pending), "deferred, not settled");
        assertEq(trips.length, tripsBefore + 1, "one trip");
        Trip memory tr = trips[trips.length - 1];
        console2.log("house-losing max flips to trip the breaker", made);
        console2.log("NAV / ATH at the trip", tr.nav, tr.ath);
        assertLt(tr.nav * 2, tr.ath, "tripped below half the ATH");

        uint256 pv = lock.pendingVaultRewards();
        uint256 ph = lock.pendingHolderRewards();
        console2.log("lock rewards pending when it tripped (vault / holder)", pv, ph);
        address p = players[0];
        vm.startPrank(p);
        vm.expectRevert(TreasuryVault.ProtocolLocked.selector);
        lock.sweepRewards();
        vm.expectRevert(TreasuryVault.ProtocolLocked.selector);
        lock.sweepVaultRewards();
        vm.expectRevert(FlipperRewardToken.ProtocolLocked.selector);
        lock.sweepHolderRewards();
        vm.stopPrank();
        vm.startPrank(dev);
        vm.expectRevert(TreasuryVault.ProtocolLocked.selector);
        lock.requestExcess(type(uint256).max);
        vm.expectRevert(TreasuryVault.ProtocolLocked.selector);
        lock.withdrawExcess();
        vm.expectRevert(TreasuryVault.ProtocolLocked.selector);
        lock.cancelExcess();
        vm.stopPrank();
        // flips are refused
        FlipperHouseBase.Preview memory pvw = _preview(p, address(token), 1 ether, "");
        assertEq(pvw.code, 8, "REJECT_LOCKED");
        // upkeep halts
        vm.expectRevert();
        router.harvest();
        vm.prank(holders[0]);
        vm.expectRevert(FlipperRewardToken.ProtocolLocked.selector);
        token.claim();
        vm.expectRevert(FlipperHouseBase.ProtocolLocked.selector);
        house.settleDeferred(inFlight);

        _advance(10 days);
        assertGe(lock.pendingVaultRewards(), pv, "vault rewards kept (the stream keeps accruing)");
        assertGe(lock.pendingHolderRewards(), ph);
        pv = lock.pendingVaultRewards();

        // the unlocker (the deployer) lifts it, re-basing the breaker's ATH
        _unlockReset();
        _wasLocked = false;
        house.settleDeferred(inFlight); // anyone; market-free
        assertTrue(uint8(_status(inFlight)) > uint8(FlipperHouseBase.Status.Pending), "deferred flip settled");
        uint256 got = _sweep(players[1]);
        assertGe(got, pv, "the frozen rewards arrive in full");
        assertEq(vault.hwm(), hwmBefore, "the vault's mark is not reset by the breaker");
        assertEq(lock.withdrawableExcess(), 0, "under water until the vault's mark is regained");
        _driveTo(st.volUsd + 20_000e18, 40_000, 2 days);
        _checkAll(principal0);
    }

    // ── the performance fee with the lock as the main depositor ─────────────────────────────────────────

    /// The lock starts as the vault's only depositor (the whole bankroll): 80% of every gain above the mark becomes
    /// POL and the lock keeps 20%. Checked against an independent model at every step, alone and with other stakers.
    function test_excess_after_the_performance_fee() public {
        assertEq(vault.totalSupply(), vault.balanceOf(address(lock)), "the lock is the only depositor at launch");
        assertEq(vault.protocolShares(), 0, "no POL at launch");
        for (uint256 step; step < 12; ++step) {
            _driveTo(st.volUsd + (step < 6 ? 2_000e18 : 20_000e18), 40_000, 1 days);
            uint256 lockShares = vault.balanceOf(address(lock));
            (uint256 pps,, uint256 hwm) = _modelPps();
            uint256 v = lock.value();
            assertApproxEqRel(v, lockShares * pps / Q, 1e9, "lock value = shares x post-fee price");
            uint256 expX = v > principal0 ? v - principal0 : 0;
            uint256 free = vault.freeBankroll();
            assertEq(lock.withdrawableExcess(), expX < free ? expX : free, "excess = min(value - principal, free bankroll)");
            // crystallise and check the POL minted: the protocol's shares absorb exactly the fee
            uint256 a = house.treasury();
            uint256 pol0 = vault.protocolShares();
            uint256 s0 = vault.totalSupply() + pol0;
            _crystallize();
            uint256 pol1 = vault.protocolShares();
            uint256 ppsAfter = a * Q / (s0 + pol1 - pol0);
            assertApproxEqRel(ppsAfter, pps, 1e9, "POL minted to the post-fee price");
            assertGe(vault.hwm(), hwm, "the mark never falls");
            if (step % 3 == 2) _takeExcess();
            if (step == 4) {
                // another staker joins: the lock is no longer alone, the fee still applies to depositors only
                _buyExact(stakers[1], 20_000_000 ether);
                uint256 st1 = token.balanceOf(stakers[1]);
                vm.prank(stakers[1]);
                vault.deposit(st1, 0);
                staker1Phase = 99; // held for the rest of the test
            }
        }
        (,, uint256 polShares,,, uint256 polAssets, uint256 depAssets) = vault.stats();
        console2.log("POL shares / POL assets / depositor assets", polShares, polAssets, depAssets);
        console2.log("dev excess taken", st.devExcess);
    }

    // ── fuzz ─────────────────────────────────────────────────────────────────────────────────────────────

    /// forge-config: default.fuzz.runs = 48
    /// Random paths (fair play, then a forced streak either way, a partial request, time, another streak): a request
    /// above the excess always fails, a withdrawal never leaves the value under the principal, every payout goes to
    /// devAddress, and the principal never moves.
    function testFuzz_lock_paths(uint256 s, uint8 streak1, bool houseLoses1, uint16 fracBps, uint8 streak2, uint32 gap)
        public
    {
        seed = uint256(keccak256(abi.encode(s)));
        _driveTo(st.volUsd + 3_000e18, 2_000, 1 days);
        _streak(houseLoses1, bound(streak1, 0, 40), BPS);
        _upkeep();
        if (vm.getBlockTimestamp() < vault.unlockAt(address(lock))) _advance(vault.unlockAt(address(lock)) - vm.getBlockTimestamp());
        uint256 x = lock.withdrawableExcess();
        // above the excess: refused
        vm.prank(dev);
        vm.expectRevert();
        lock.requestExcess(x + x / 100 + 1e18);
        uint256 amt = x * bound(fracBps, 0, BPS) / BPS;
        uint256 d0 = token.balanceOf(dev);
        bool requested;
        if (house.locked()) return;
        if (vault.previewDeposit(amt) != 0) {
            vm.prank(dev);
            lock.requestExcess(amt);
            requested = true;
        }
        _advance(bound(gap, 0, 10 days));
        _streak(!houseLoses1, bound(streak2, 0, 30), BPS);
        if (house.locked()) return;
        _advance(vault.withdrawCooldown());
        (uint256 qs, uint256 qa,) = lock.pendingWithdrawal();
        if (requested && qs != 0) {
            bool fits = lock.value() >= principal0 + qa && qa <= house.treasury() - house.reserved();
            vm.prank(dev);
            if (!fits) vm.expectRevert();
            lock.withdrawExcess();
        }
        assertGe(token.balanceOf(dev), d0, "devAddress only receives");
        if (requested && qs != 0) {
            (uint256 qs2,,) = lock.pendingWithdrawal();
            if (qs2 == 0) assertGe(lock.value(), principal0, "a withdrawal never breaches the principal");
        }
        _checkAll(principal0);
    }
}

/// @notice Seed 11 opens with an extreme player streak (about 60% wins over the first 200 flips against 45% expected,
///         z ≈ 4.4): the treasury halves in fair play and the drawdown breaker trips on its own. The trip must come
///         exactly below half the NAV high, freeze the lock (and everything else), and after the unlocker lifts it
///         (re-basing the ATH) play resumes with the lock's accounting intact.
contract NaturalBreakerTripTest is SimDriver {
    function setUp() public {
        _start(11);
        autoUnlock = false;
    }

    function test_seed11_natural_trip() public {
        while (!house.locked() && st.flips < 1_000) _batch(type(uint256).max, 2 days);
        if (!house.locked()) {
            // under the drawdown-scaled Kelly (quarter Kelly near a 50% drawdown) this seed's opening streak no longer
            // trips the breaker (it did under plain half Kelly): record it
            console2.log("seed 11: no breaker trip in 1,000 flips under the drawdown-scaled Kelly; NAV / ATH", _nav(), house.navAth());
            assertEq(trips.length, 0);
            assertGe(_nav() * 2, uint256(house.navAth()), "and the NAV stayed above half its high");
            _checkAll(principal0);
            return;
        }
        assertEq(trips.length, 1);
        console2.log("flips / wins at the trip", st.flips, st.wins);
        console2.log("NAV / ATH at the trip (1e18)", trips[0].nav, trips[0].ath);
        assertLt(trips[0].nav * 2, trips[0].ath, "below half the ATH");
        assertGt(trips[0].nav * 2 * 100, trips[0].ath * 97, "and not far below: the check runs after every settlement");
        uint256 pv = lock.pendingVaultRewards();
        vm.expectRevert(TreasuryVault.ProtocolLocked.selector);
        lock.sweepRewards();
        vm.prank(dev);
        vm.expectRevert(TreasuryVault.ProtocolLocked.selector);
        lock.requestExcess(type(uint256).max);
        assertLt(lock.value(), principal0, "the lock is under water");
        assertEq(lock.withdrawableExcess(), 0);

        _advance(3 days);
        _unlockReset();
        _wasLocked = false;
        uint256 got = _sweep(players[2]);
        assertGe(got, pv, "rewards kept through the lock");
        _driveTo(st.volUsd + 10_000e18, 40_000, 2 days);
        _checkAll(principal0);
        _checkShadow(true);
        assertEq(lock.principal(), principal0);
        console2.log("after unlock + $10k more: lock value / principal", lock.value(), principal0);
    }
}
