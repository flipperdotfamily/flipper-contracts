// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";

import {TreasuryVault} from "../../src/TreasuryVault.sol";
import {FlipperRewardToken} from "../../src/FlipperRewardToken.sol";
import {PrincipalLock} from "../../src/PrincipalLock.sol";
import {SimDriver} from "./SimDriver.sol";

/// @notice The lock's lifecycle edges the economic model checks against, on the simulated launch, and how the
///         permissionless `distribute(0)` re-spread changes the reward stream's timing.
///   Run: nice -n 10 forge test --match-path test/sim/LockLifecycle.t.sol -vv --gas-limit 9223372036854775807
contract LockLifecycleTest is SimDriver {
    function setUp() public {
        _start(41);
    }

    /// Before the vault's 7-day lock: a request reverts `Locked`. After it: request, a withdrawal before the 2-day
    /// cooldown reverts `CoolingDown`, after it pays. A second request restarts the cooldown for everything queued.
    function test_request_before_the_lock_then_cooldown() public {
        _driveTo(10_000e18, 40_000, 12 hours);
        uint256 until = vault.unlockAt(address(lock));
        assertLt(vm.getBlockTimestamp(), until, "still inside the 7-day lock");
        if (lock.withdrawableExcess() == 0) _streak(false, 30, BPS); // make sure there is an excess
        uint256 x = lock.withdrawableExcess();
        assertGt(x, 0, "an excess exists");
        vm.prank(dev);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.Locked.selector, until));
        lock.requestExcess(x / 2);

        _advance(until - vm.getBlockTimestamp());
        _upkeep();
        x = lock.withdrawableExcess();
        vm.prank(dev);
        lock.requestExcess(x / 2);
        (,, uint256 readyAt) = lock.pendingWithdrawal();
        assertEq(readyAt, vm.getBlockTimestamp() + vault.withdrawCooldown(), "2-day cooldown");
        _advance(1 days);
        vm.prank(dev);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.CoolingDown.selector, readyAt));
        lock.withdrawExcess();
        // queue more: the cooldown restarts for everything queued
        uint256 more = lock.withdrawableExcess() / 4;
        vm.prank(dev);
        lock.requestExcess(more);
        (,, uint256 readyAt2) = lock.pendingWithdrawal();
        assertEq(readyAt2, vm.getBlockTimestamp() + vault.withdrawCooldown(), "restarted");
        _advance(readyAt2 - vm.getBlockTimestamp());
        uint256 d0 = token.balanceOf(dev);
        (, uint256 qa,) = lock.pendingWithdrawal();
        vm.prank(dev);
        uint256 got = lock.withdrawExcess();
        assertApproxEqRel(got, qa, 1e12);
        assertGe(token.balanceOf(dev) - d0, got, "paid (with the swept rewards) to devAddress");
        assertGe(lock.value(), lock.principal());
    }

    /// `distribute(0)` (anyone, e.g. every hour) must not delay the stream: it only checkpoints. And a distribution
    /// never slows what is already streaming (the rate is max(current, everything unstreamed / 7 days)).
    function test_distribute_zero_does_not_delay_the_stream() public {
        _driveTo(3_000e18, 40_000, 12 hours);
        _upkeep();
        _advance(8 days); // drain the current stream
        for (uint256 i; i < 20; ++i) {
            _randomFlip(); // fresh revenue
            _advance(30);
        }
        _upkeep();
        uint256 pending0 = token.pendingStream();
        assertGt(pending0, 0, "a fresh stream");

        uint256 snap = vm.snapshotState();
        _advance(7 days);
        uint256 streamedNoCalls = pending0 - token.pendingStream();
        vm.revertToState(snap);

        for (uint256 h; h < 7 * 24; ++h) {
            _advance(1 hours);
            vm.prank(arb);
            token.distribute(0);
        }
        uint256 streamed7 = pending0 - token.pendingStream();
        for (uint256 h; h < 7 * 24; ++h) {
            _advance(1 hours);
            vm.prank(arb);
            token.distribute(0);
        }
        uint256 streamed14 = pending0 - token.pendingStream();
        console2.log("streamed after 7 days: no calls (bps) / hourly distribute(0) (bps)", streamedNoCalls * 10_000 / pending0, streamed7 * 10_000 / pending0);
        console2.log("streamed after 14 days with hourly distribute(0) (bps)", streamed14 * 10_000 / pending0);
        assertEq(streamedNoCalls, pending0, "without calls the stream completes in 7 days");
        assertEq(streamed7, pending0, "hourly distribute(0) doesn't delay it");
        _checkShadow(true); // accounting stays exact either way
    }
}
