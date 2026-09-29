// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FlipperBase} from "./utils/FlipperBase.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {TreasuryVault} from "../src/TreasuryVault.sol";
import {PrincipalLock, IStakingVault} from "../src/PrincipalLock.sol";

/// @notice The team's stake: principal locked in the TreasuryVault for good; earnings (its share of treasury gains
///         after the performance fee, and holder rewards) withdrawable, only ever to the dev address (the claim wallet,
///         which only the lock's owner can change).
contract PrincipalLockTest is FlipperBase {
    using stdStorage for StdStorage;

    StdStorage internal store;
    uint256 internal constant M = 1_000_000 ether;
    uint256 internal constant P = 50 * M; // the lock's principal (the bankroll's POL seed is 100M)

    PrincipalLock internal lock;
    address internal team = makeAddr("team"); // the dev payout address (claim wallet)

    function setUp() public override {
        super.setUp();
        vault.crystallize(); // FlipperBase's 100M seed becomes protocol-owned
        lock = new PrincipalLock(IStakingVault(address(vault)), team, owner);
        flipperToken.mint(address(this), P);
        flipperToken.approve(address(lock), P);
        lock.stake(P);
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────────────

    /// @dev treasury income (router revenue, donations): a gain for every share
    function _gain(uint256 amount) internal {
        flipperToken.mint(address(this), amount);
        house.depositTreasury(amount);
    }

    /// @dev won $FLIPPER flips staking `amount` in all (≤ 1M each: within the half-Kelly cap); the bankroll pays
    ///      payout − stake on each
    function _loss(uint256 amount) internal {
        for (uint256 left = amount; left != 0;) {
            uint256 a = left < M ? left : M;
            _reveal(_flip(alice, address(flipperToken), a), WIN_WORD);
            left -= a;
        }
    }

    function _unlockPeriod() internal {
        uint256 until = vault.unlockAt(address(lock));
        if (vm.getBlockTimestamp() < until) vm.warp(until);
    }

    /// @dev request the whole excess, wait out the cooldown, withdraw it; returns what the team received
    function _takeExcess() internal returns (uint256 got) {
        _unlockPeriod();
        if (vault.previewDeposit(lock.withdrawableExcess()) == 0) return 0;
        vm.prank(team);
        lock.requestExcess(type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + vault.withdrawCooldown());
        uint256 before = flipperToken.balanceOf(team);
        vm.prank(team);
        lock.withdrawExcess();
        got = flipperToken.balanceOf(team) - before;
        assertGe(lock.value(), P, "a withdrawal never leaves the position under the principal");
    }

    function _setTreasury(uint256 t) internal {
        store.target(address(house)).sig("treasury()").checked_write(t);
    }

    // ── principal ────────────────────────────────────────────────────────────────────────────────────

    function test_stake_records_the_principal_once() public {
        assertEq(lock.principal(), P);
        assertEq(lock.devAddress(), team);
        assertApproxEqAbs(lock.value(), P, 2, "worth the principal (rounded down)");
        assertEq(lock.withdrawableExcess(), 0);
        assertEq(flipperToken.balanceOf(address(lock)), 0, "all of it in the vault");
        assertEq(vault.unlockAt(address(lock)), vm.getBlockTimestamp() + vault.lockDuration());
        flipperToken.mint(address(this), 1 ether);
        flipperToken.approve(address(lock), 1 ether);
        vm.expectRevert(PrincipalLock.AlreadyStaked.selector);
        lock.stake(1 ether);
        vm.prank(team);
        vm.expectRevert(PrincipalLock.Unauthorized.selector);
        lock.stake(1 ether);
    }

    function test_nothing_withdrawable_at_par_or_under_water() public {
        _unlockPeriod();
        vm.prank(team);
        vm.expectRevert();
        lock.requestExcess(1 ether);
        // the principal itself can never be requested
        vm.prank(team);
        vm.expectRevert();
        lock.requestExcess(P);

        _loss(3 * M); // under water
        assertLt(lock.value(), P);
        assertEq(lock.withdrawableExcess(), 0);
        vm.prank(team);
        vm.expectRevert();
        lock.requestExcess(1 ether);
        vm.prank(team);
        vm.expectRevert(); // nothing at all to queue
        lock.requestExcess(type(uint256).max);
    }

    function test_excess_after_gains_and_the_performance_fee() public {
        // 150M of shares: the lock owns 1/3. A 15M gain is 5M for the lock's shares, of which the vault's 80%
        // performance fee goes to POL: the lock keeps 1M
        _gain(15 * M);
        assertApproxEqAbs(lock.withdrawableExcess(), 1 * M, 1e6);
        uint256 got = _takeExcess();
        assertApproxEqAbs(got, 1 * M, 1e6);
        assertLt(lock.value() - P, 1e9, "the excess is gone");
        // under the new mark, more gains: again 20% of the lock's share
        _gain(15 * M);
        uint256 share = Math.mulDiv(15 * M, vault.balanceOf(address(lock)), vault.totalShares());
        assertApproxEqRel(lock.withdrawableExcess(), share / 5, 1e15);
    }

    function test_withdrawal_that_would_breach_the_principal_reverts() public {
        _gain(15 * M);
        _unlockPeriod();
        vm.prank(team);
        lock.requestExcess(type(uint256).max);
        (uint256 qs, uint256 qa,) = lock.pendingWithdrawal();
        assertGt(qs, 0);
        assertApproxEqAbs(qa, 1 * M, 1e6);
        _loss(2 * M); // the price falls during the cooldown
        vm.warp(vm.getBlockTimestamp() + vault.withdrawCooldown());
        vm.prank(team);
        vm.expectRevert(); // PrincipalBreach
        lock.withdrawExcess();
        // cancel; a smaller request fits what is left over the principal
        vm.prank(team);
        lock.cancelExcess();
        uint256 got = _takeExcess();
        assertGe(lock.value(), P);
        emit log_named_uint("excess taken after the dip", got);
    }

    /// Any sequence of gains, losses, fee crystallisations and maximal withdrawals: nothing ever comes out of the
    /// principal (losses can take the position under it; withdrawals never can).
    function test_principal_survives_a_long_sequence() public {
        uint256 taken;
        for (uint256 i; i < 12; ++i) {
            if (i % 3 == 0) _loss(2 * M);
            else _gain((i + 1) * M);
            if (i % 4 == 1) vault.crystallize();
            taken += _takeExcess(); // asserts value ≥ P after every withdrawal
        }
        emit log_named_uint("earnings taken", taken);
        assertGt(taken, 0);
        assertEq(lock.principal(), P);
    }

    // ── rewards, role, breaker ───────────────────────────────────────────────────────────────────────

    /// (holder rewards stream only with the reward-bearing token: see RewardSystem.t.sol for both sources; here a
    /// sweep forwards whatever $FLIPPER sits in the lock)
    function test_sweeps_are_anyones_and_pay_only_the_dev_address() public {
        flipperToken.mint(address(lock), 7 ether);
        uint256 aliceBefore = flipperToken.balanceOf(alice);
        vm.prank(alice);
        lock.sweepRewards();
        assertEq(flipperToken.balanceOf(team), 7 ether, "paid to devAddress");
        assertEq(flipperToken.balanceOf(alice), aliceBefore, "not to the caller");
        flipperToken.mint(address(lock), 3 ether);
        vm.prank(mallory);
        lock.sweepVaultRewards();
        flipperToken.mint(address(lock), 2 ether);
        vm.prank(bob);
        lock.sweepHolderRewards(); // a plain token has no holder rewards: sweeps the balance only
        assertEq(flipperToken.balanceOf(team), 12 ether);
        assertEq(lock.pendingHolderRewards(), 0);
    }

    function test_only_the_dev_address_requests_and_withdraws() public {
        _gain(15 * M);
        _unlockPeriod();
        address[4] memory others = [alice, address(this), mallory, owner];
        for (uint256 i; i < 4; ++i) {
            vm.startPrank(others[i]);
            vm.expectRevert(PrincipalLock.Unauthorized.selector);
            lock.requestExcess(1 ether);
            vm.expectRevert(PrincipalLock.Unauthorized.selector);
            lock.withdrawExcess();
            vm.expectRevert(PrincipalLock.Unauthorized.selector);
            lock.cancelExcess();
            vm.stopPrank();
        }
        uint256 got = _takeExcess();
        assertGt(got, 0);
        assertEq(flipperToken.balanceOf(team), got);
    }

    // ── the claim wallet (owner-changeable) ──────────────────────────────────────────────────────────

    function test_only_the_owner_changes_the_claim_wallet() public {
        address hot = makeAddr("hot");
        address[3] memory others = [team, alice, address(this)];
        for (uint256 i; i < 3; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", others[i]));
            lock.setDevAddress(hot);
        }
        vm.prank(owner);
        vm.expectRevert(PrincipalLock.InvalidAddress.selector);
        lock.setDevAddress(address(0));
        vm.prank(owner);
        lock.setDevAddress(hot);
        assertEq(lock.devAddress(), hot);
        // ownership can't be renounced (the claim wallet must stay replaceable)
        vm.prank(owner);
        vm.expectRevert(PrincipalLock.Unauthorized.selector);
        lock.renounceOwnership();
        assertEq(lock.owner(), owner);
    }

    function test_new_claim_wallet_takes_over_a_queued_withdrawal_and_the_sweeps() public {
        address hot = makeAddr("hot");
        _gain(15 * M);
        _unlockPeriod();
        vm.prank(team);
        lock.requestExcess(type(uint256).max);
        (uint256 queued,,) = lock.pendingWithdrawal();
        assertGt(queued, 0);

        vm.prank(owner);
        lock.setDevAddress(hot);
        vm.warp(vm.getBlockTimestamp() + vault.withdrawCooldown());

        // the old wallet is out: it can neither withdraw nor cancel
        vm.startPrank(team);
        vm.expectRevert(PrincipalLock.Unauthorized.selector);
        lock.withdrawExcess();
        vm.expectRevert(PrincipalLock.Unauthorized.selector);
        lock.cancelExcess();
        vm.stopPrank();

        uint256 teamBefore = flipperToken.balanceOf(team);
        vm.prank(hot);
        uint256 got = lock.withdrawExcess();
        assertGt(got, 0);
        assertGe(flipperToken.balanceOf(hot), got, "the queued excess is paid to the new wallet");
        assertEq(flipperToken.balanceOf(team), teamBefore, "nothing more to the old wallet");
        assertGe(lock.value(), P, "the principal stays");
        assertEq(lock.principal(), P);
    }

    function test_claim_wallet_ownership_hands_over_in_two_steps() public {
        address cold2 = makeAddr("cold2");
        vm.prank(owner);
        lock.transferOwnership(cold2);
        assertEq(lock.owner(), owner, "pending until accepted");
        vm.prank(cold2);
        lock.acceptOwnership();
        assertEq(lock.owner(), cold2);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", owner));
        lock.setDevAddress(alice);
        vm.prank(cold2);
        lock.setDevAddress(alice);
        assertEq(lock.devAddress(), alice);
    }

    function test_breaker_freezes_the_lock() public {
        _gain(15 * M);
        _unlockPeriod();
        uint256 half = lock.withdrawableExcess() / 2;
        vm.prank(team);
        lock.requestExcess(half);
        _setTreasury(house.treasury() / 3); // NAV per unit well under half its high
        house.checkDrawdown();
        assertTrue(house.locked());
        vm.warp(vm.getBlockTimestamp() + vault.withdrawCooldown());
        vm.startPrank(team);
        vm.expectRevert(TreasuryVault.ProtocolLocked.selector);
        lock.withdrawExcess();
        vm.expectRevert(); // (a locked house has lost half its NAV: there is no excess either)
        lock.requestExcess(1);
        vm.expectRevert(TreasuryVault.ProtocolLocked.selector);
        lock.cancelExcess();
        vm.stopPrank();
        vm.expectRevert(TreasuryVault.ProtocolLocked.selector);
        lock.sweepRewards();
        vm.expectRevert(TreasuryVault.ProtocolLocked.selector);
        lock.sweepVaultRewards();
    }

    // ── fuzz ─────────────────────────────────────────────────────────────────────────────────────────

    /// the excess is exactly max(0, value − P), a maximal withdrawal never takes the value under P, and asking for
    /// more than the excess always fails
    function testFuzz_excess_never_exceeds_value_minus_principal(uint256 gain, uint256 loss, bool lossFirst) public {
        gain = bound(gain, 0, 60 * M);
        loss = bound(loss, 0, 8 * M);
        if (lossFirst) _loss(loss);
        if (gain != 0) _gain(gain);
        if (!lossFirst) _loss(loss);
        uint256 v = lock.value();
        uint256 x = lock.withdrawableExcess();
        assertEq(x, v > P ? v - P : 0);
        _unlockPeriod();
        // more than the excess is refused
        vm.prank(team);
        vm.expectRevert();
        lock.requestExcess(x + 1e12);
        uint256 got = _takeExcess(); // asserts value ≥ P after withdrawing
        assertLe(got, x + 1e6, "never more than the excess");
        if (v <= P) assertEq(got, 0, "nothing under water");
    }
}
