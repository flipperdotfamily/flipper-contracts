// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FlipperHouseBase} from "../../src/house/FlipperHouseBase.sol";
import {TreasuryVault} from "../../src/TreasuryVault.sol";
import {FlipperRewardToken} from "../../src/FlipperRewardToken.sol";
import {PrincipalLock} from "../../src/PrincipalLock.sol";
import {RevenueRouter} from "../../src/RevenueRouter.sol";
import {SimDriver} from "./SimDriver.sol";

/// @notice Fee claims after volume: holder rewards (balance × time), the vault's pass-through to stakers and the lock,
///         partner accrual and `claimPartner`, the LP-fee harvest and its bounty, and nothing left stuck (dust,
///         rounding, gas floors) at high flip counts.
///   Run: nice -n 10 forge test --match-path test/sim/FeeClaims.t.sol -vv --gas-limit 9223372036854775807
contract FeeClaimsTest is SimDriver {
    function setUp() public {
        _start(21);
    }

    // ── holder rewards ───────────────────────────────────────────────────────────────────────────────────

    /// Holders claiming every batch, rarely, only at checkpoints, one that trades, players whose balance moves on
    /// every flip, the stakers and the lock: after $10k and $100k every lifetime reward equals its balance-time share
    /// (the shadow), and holders with constant balances earn the same per token whatever their claim cadence.
    function test_holder_rewards_match_balance_time_share() public {
        _driveTo(10_000e18, 40_000, 2 days);
        _checkpoint("10k"); // strict shadow check inside
        _driveTo(100_000e18, 40_000, 2 days);
        _checkpoint("100k");
        _upkeep();
        _advance(8 days);
        _upkeep();
        _advance(8 days);
        _checkShadow(true);
        // everyone claims what is left: total claimed = the balance-time share
        for (uint256 i; i < holders.length; ++i) {
            _claim(holders[i]);
            uint256 exp = expectedMag[holders[i]] / MAG;
            assertApproxEqAbs(token.claimed(holders[i]), exp, 1e12 + exp / 1e9, "claimed = balance-time share");
        }
        // per token of the launch balance (20M claiming every batch, 5M rarely, 50M only now): claimed rewards join
        // the balance and earn too, so frequent claimers compound slightly more
        uint256[3] memory start = [uint256(20_000_000 ether), 5_000_000 ether, 50_000_000 ether];
        for (uint256 i; i < 3; ++i) {
            console2.log("rewards per 1M held since launch (every batch / rarely / once)", i, token.claimed(holders[i]) * 1e24 / start[i]);
        }
        assertGe(token.claimed(holders[0]) * 1e18 / start[0], token.claimed(holders[2]) * 1e18 / start[2], "compounding");
    }

    // ── vault staking rewards ────────────────────────────────────────────────────────────────────────────

    /// Stakers joining and leaving at different times (and the lock, the main depositor) each earn the share-time
    /// share of what the vault's virtual balance earned; a claim pays exactly what `pendingRewards` shows.
    function test_vault_staking_rewards() public {
        _driveTo(100_000e18, 40_000, 2 days);
        if (st.flips < 1700) _driveTo(type(uint256).max, 1700, 2 days); // staker 1 starts cycling after 1500 flips
        _checkpoint("100k");
        assertTrue(staker0In, "staker 0 in");
        assertGt(staker1Phase, 0, "staker 1 cycled");
        _checkShadow(true);
        for (uint256 i; i < stakers.length; ++i) {
            uint256 exp = expectedVaultMag[stakers[i]] / MAG;
            uint256 act = vault.rewardsClaimed(stakers[i]) + vault.pendingRewards(stakers[i]);
            console2.log("staker vault rewards / expected", act, exp);
            if (vault.balanceOf(stakers[i]) != 0) _claimVault(stakers[i]);
        }
        uint256 lockExp = expectedVaultMag[address(lock)] / MAG;
        console2.log("lock vault rewards (swept + pending) / expected", st.devVaultRewards + lock.pendingVaultRewards(), lockExp);
        assertApproxEqAbs(vault.rewardsClaimed(address(lock)) + lock.pendingVaultRewards(), lockExp, 1e12 + lockExp / 1e9);
    }

    // ── partners ─────────────────────────────────────────────────────────────────────────────────────────

    bytes32 internal constant SETTLED =
        keccak256("FlipSettled(uint256,address,address,bool,uint256,uint8,uint256,uint256,uint256,bool)");

    uint256[3] internal expPartner;

    /// Every attributed flip's partner share, recomputed here from its flip-time terms (tag, odds, quotes) and its
    /// realized proceeds, adds up exactly to what the house accrued; `claimPartner` (anyone) pays the payout address.
    function test_partner_accrual_and_claims() public {
        partnerBps = 6000; // most flips attributed
        uint256 payout = house.params().flipperPayoutBps;
        uint256 mem = _fmp();
        for (uint256 b; b < 40; ++b) {
            _resetFmp(mem);
            uint256 n = _randBetween(20, 50);
            for (uint256 i; i < n; ++i) {
                vm.recordLogs();
                uint256 id = _randomFlip();
                Vm.Log[] memory logs = vm.getRecordedLogs();
                if (id == 0) continue;
                _expectPartner(id, logs, payout);
                _advance(_randBetween(2, 40));
            }
            _upkeep();
            if (b % 7 == 3) _claimPartners();
            _advance(_randBetween(1 hours, 1 days));
        }
        for (uint256 id = 1; id <= 2; ++id) {
            assertEq(house.partnerAccrued(id) + _claimedOf(id), expPartner[id], "partner accrual = recomputed shares");
            console2.log("partner / accrued in all", id, expPartner[id]);
        }
        _claimPartners();
        assertEq(house.partnerAccruedTotal(), 0);
        assertGt(expPartner[2], 0, "p2 earned");
    }

    uint256[3] internal claimedOfPartner;

    function _claimedOf(uint256 id) internal view returns (uint256) {
        return claimedOfPartner[id];
    }

    function _claimPartners() internal override {
        for (uint256 id = 1; id <= 2; ++id) {
            claimedOfPartner[id] += house.partnerAccrued(id);
        }
        super._claimPartners();
    }

    function _expectPartner(uint256 id, Vm.Log[] memory logs, uint256 payout) internal {
        (uint32 pid, uint16 shareBps) = house.flipPartner(id);
        if (pid == 0) return;
        (,, uint16 wc,, FlipperHouseBase.Status s, address t, uint128 amount,, uint128 sq, uint128 bq,, uint16 fpay) =
            house.flips(id);
        payout = fpay; // the flip's own payout (the edge schedule moves it)
        if (s != FlipperHouseBase.Status.Lost) return; // shares are paid out of realized losses only
        uint256 proceeds;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(house) && logs[i].topics[0] == SETTLED && uint256(logs[i].topics[1]) == id) {
                (,,,,, uint256 received,) =
                    abi.decode(logs[i].data, (bool, uint256, uint8, uint256, uint256, uint256, bool));
                proceeds = received;
            }
        }
        bool isF = t == address(token);
        uint256 edge;
        if (isF) {
            edge = BPS - Math.mulDiv(wc, payout, BPS, Math.Rounding.Ceil);
        } else {
            uint256 h = bq > sq ? Math.mulDiv(bq - sq, BPS, uint256(bq) + sq, Math.Rounding.Ceil) : 0;
            edge = BPS > h + 2 * uint256(wc) ? BPS - h - 2 * uint256(wc) : 0;
        }
        uint256 basis = isF ? amount : (uint256(sq) + bq) / 2;
        uint256 base = Math.min(basis, proceeds);
        uint256 share = shareBps < edge ? shareBps : edge;
        if (share == 0) return;
        expPartner[pid] += Math.mulDiv(base, share * BPS, BPS * (BPS - wc));
    }

    // ── LP fees and the harvest bounty ───────────────────────────────────────────────────────────────────

    bytes32 internal constant HARVESTED_ = keccak256("Harvested(address,uint256,uint256,uint256,uint256)");
    bytes32 internal constant LPFEES_ = keccak256("Collected(uint256,uint256)"); // the LiquidityKeeper's

    /// Each harvest pays its caller min(0.1% × what it brought in, cap) per asset — nothing on the house's profit
    /// share — and every LP fee the protocol-owned position earned is harvested (the pool's fee growth).
    function test_lp_fee_harvest_bounties() public {
        address caller = makeAddr("bountyHunter");
        tracked.push(caller); // it receives the bounties
        uint256 capEth = router.bountyCapEth();
        uint256 capFl = router.bountyCapFlipper();
        uint256 bps = router.bountyBps();
        for (uint256 r; r < 12; ++r) {
            _driveTo(st.volUsd + (r < 6 ? 2_000e18 : 30_000e18), 40_000, 1 days);
            uint256 house0 = house.rewardsAccrued();
            uint256 e0 = caller.balance;
            uint256 f0 = token.balanceOf(caller);
            vm.recordLogs();
            vm.prank(caller, caller);
            (uint256 bE, uint256 bF) = router.harvest();
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 ethIn;
            uint256 flIn;
            uint256 lpE;
            uint256 lpF;
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter == address(router) && logs[i].topics[0] == HARVESTED_) {
                    (ethIn, flIn,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                } else if (logs[i].emitter == d.liquidityKeeper && logs[i].topics[0] == LPFEES_) {
                    (lpE, lpF) = abi.decode(logs[i].data, (uint256, uint256));
                }
            }
            st.lpFeesEth += lpE;
            st.lpFeesFlipper += lpF;
            ++st.harvests;
            assertEq(ethIn, lpE, "ETH in = the position's ETH fees (no other ETH source on the v4 path)");
            assertEq(flIn, lpF, "$FLIPPER in = the position's $FLIPPER fees: the house share carries no bounty");
            assertEq(bE, Math.min(ethIn * bps / BPS, capEth), "ETH bounty");
            assertEq(bF, Math.min(flIn * bps / BPS, capFl), "$FLIPPER bounty");
            assertEq(caller.balance - e0, bE, "ETH bounty paid to the caller");
            assertEq(token.balanceOf(caller) - f0, bF, "$FLIPPER bounty paid to the caller");
            assertEq(house.rewardsAccrued(), 0, "house share flushed");
            console2.log("harvest: ETH fees / FLIPPER fees / house share", lpE, lpF, house0);
        }
        _checkLpFees();
    }

    // ── nothing stuck ────────────────────────────────────────────────────────────────────────────────────

    /// Thousands of small flips (dust-sized shares, many distributions): after everyone claims, the reward reserve,
    /// the vault, the router and the house hold dust only; and each claim still pays in full when sent with exactly
    /// its gas estimate (the gasleft floors make a starved call revert rather than skip its swallowed calls).
    function test_nothing_stuck_at_high_flip_counts() public {
        maxSizeBps = 1500; // small flips: many more of them per dollar
        uint256 flips = vm.envOr("SIM_STUCK_FLIPS", uint256(6_000));
        _driveTo(type(uint256).max, flips, 12 hours);
        console2.log("flips", st.flips);
        _upkeep();
        _advance(3 days);

        // claims at their estimate
        _atEstimate_holderClaim(holders[1]);
        if (staker0In) _atEstimate_vaultClaim(stakers[0]);
        _atEstimate_sweep();
        _atEstimate_harvest();

        _finish(); // everyone claims; asserts dust bounds
    }

    function _estimate(address from, address target, bytes memory data) internal returns (uint256 hi) {
        uint256 lo;
        hi = 5_000_000;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(from, from);
            (bool ok,) = target.call{gas: mid}(data);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
    }

    function _atEstimate_holderClaim(address h) internal {
        uint256 due = token.claimable(h);
        uint256 g = _estimate(h, address(token), abi.encodeCall(FlipperRewardToken.claim, ()));
        uint256 b0 = token.balanceOf(h);
        vm.prank(h, h);
        (bool ok,) = address(token).call{gas: g}(abi.encodeCall(FlipperRewardToken.claim, ()));
        assertTrue(ok);
        assertEq(token.balanceOf(h) - b0, due, "holder claim at its estimate pays in full");
        claimedBy[h] += due;
        console2.log("token.claim estimate", g);
    }

    function _atEstimate_vaultClaim(address s) internal {
        uint256 due = vault.pendingRewards(s);
        uint256 g = _estimate(s, address(vault), abi.encodeCall(TreasuryVault.claimRewards, ()));
        uint256 b0 = token.balanceOf(s);
        vm.prank(s, s);
        (bool ok,) = address(vault).call{gas: g}(abi.encodeCall(TreasuryVault.claimRewards, ()));
        assertTrue(ok);
        assertEq(token.balanceOf(s) - b0, due, "vault claim at its estimate pulls and pays in full");
        assertEq(token.vaultBalance(), vault.depositorAssets(), "and re-syncs the virtual balance");
        console2.log("vault.claimRewards estimate", g);
    }

    function _atEstimate_sweep() internal {
        uint256 vr = lock.pendingVaultRewards();
        uint256 hr = lock.pendingHolderRewards();
        uint256 g = _estimate(arb, address(lock), abi.encodeCall(PrincipalLock.sweepRewards, ()));
        uint256 d0 = token.balanceOf(dev);
        vm.prank(arb, arb);
        (bool ok,) = address(lock).call{gas: g}(abi.encodeCall(PrincipalLock.sweepRewards, ()));
        assertTrue(ok);
        assertEq(token.balanceOf(dev) - d0, vr + hr, "sweep at its estimate pays both sources in full");
        st.devVaultRewards += vr;
        st.devHolderRewards += hr;
        console2.log("lock.sweepRewards estimate", g);
    }

    function _atEstimate_harvest() internal {
        // make sure there is a house share and LP fees to move
        for (uint256 i; i < 30; ++i) {
            _randomFlip();
            _advance(10);
        }
        assertGt(house.rewardsAccrued(), 0, "a house share to flush");
        uint256 g = _estimate(harvester, address(router), abi.encodeCall(RevenueRouter.harvest, ()));
        vm.prank(harvester, harvester);
        (bool ok,) = address(router).call{gas: g}(abi.encodeCall(RevenueRouter.harvest, ()));
        assertTrue(ok);
        assertEq(house.rewardsAccrued(), 0, "harvest at its estimate flushes the house share");
        assertEq(router.rewardsFlipperPending(), 0, "and distributes it");
        assertEq(token.vaultBalance(), vault.depositorAssets(), "and syncs the vault");
        console2.log("router.harvest estimate", g);
    }
}
