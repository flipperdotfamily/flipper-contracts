// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FlipperBase} from "./utils/FlipperBase.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {TreasuryVault} from "../src/TreasuryVault.sol";
import {DutchAuctionConverter} from "../src/DutchAuctionConverter.sol";
import {PrincipalLock, IStakingVault} from "../src/PrincipalLock.sol";

/// @dev a contract wallet that can't take ETH back until told to
contract NoReceive {
    bool public open;

    function setOpen(bool o) external {
        open = o;
    }

    function flip(FlipperHouse h, address token, uint256 amount, uint256 value) external returns (uint256) {
        return h.flip{value: value}(token, amount, 0, block.timestamp);
    }

    function approve(address token, address spender) external {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        require(ok);
    }

    function claim(FlipperHouse h) external {
        h.claim(address(0));
    }

    receive() external payable {
        require(open, "no receive");
    }
}

/// @notice The liveness stress test's findings: M-1 (a staker's exit can't leave pending flips oversized), M-4 (the
///         auction clock stops through a lock; one take halves `lastPrice` at most), L-2 (cancel delays bounded),
///         L-3 (an unrefundable fee excess is credited, not a revert).
contract LivenessTest is FlipperBase {
    using stdStorage for StdStorage;

    StdStorage internal store;
    uint256 internal constant M = 1_000_000 ether;

    function setUp() public override {
        super.setUp();
        FlipperHouseBase.Params memory p = house.params();
        p.maxReservedBps = 3000; // 30%, as on Robinhood
        vm.prank(owner);
        house.setParams(p);
        vault.crystallize();
        flipperToken.mint(alice, 1_000 * M);
        vm.prank(alice);
        flipperToken.approve(address(vault), type(uint256).max);
    }

    /// @dev open max-size $FLIPPER flips from fresh players until `n` are pending
    function _pendingFlips(uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address p = address(uint160(0xf000 + i));
            uint256 cap = house.previewFlip(address(flipperToken), 1).maxLiability;
            uint256 amt = cap * BPS / WIN_COST - 1 ether;
            flipperToken.mint(p, amt);
            vm.deal(p, 1 ether);
            vm.prank(p);
            flipperToken.approve(address(house), type(uint256).max);
            ids[i] = _flip(p, address(flipperToken), amt);
        }
    }

    /// @dev open flips until the pending liabilities reach ~29% of the treasury (the cap is 30%)
    function _fillReserve() internal {
        for (uint256 i; i < 60 && house.reserved() * BPS < house.treasury() * 2900; ++i) {
            uint256 room = house.treasury() * 3000 / BPS - house.reserved();
            uint256 liab = Math.min(house.previewFlip(address(flipperToken), 1).maxLiability, room);
            if (liab < 2 ether) break;
            address p = address(uint160(0xe000 + i));
            uint256 amt = (liab - 1 ether) * BPS / WIN_COST;
            flipperToken.mint(p, amt);
            vm.deal(p, 1 ether);
            vm.prank(p);
            flipperToken.approve(address(house), type(uint256).max);
            _flip(p, address(flipperToken), amt);
        }
    }

    function _keep() internal view returns (uint256) {
        return Math.mulDiv(house.reserved(), BPS, 3000, Math.Rounding.Ceil);
    }

    // ── M-1 ──────────────────────────────────────────────────────────────────────────────────────────────

    function test_an_exit_cant_leave_pending_flips_oversized() public {
        // a whale is 80% of the bankroll; flips sized against it are pending
        vm.prank(alice);
        uint256 shares = vault.deposit(400 * M, 0);
        _pendingFlips(8);
        uint256 t = house.treasury();
        uint256 r = house.reserved();
        uint256 free = t - _keep();
        assertLt(free, t - r, "the reserve cap binds before the reserved amount does");
        assertEq(house.withdrawable(), free);
        assertEq(vault.freeBankroll(), free);

        vm.warp(vault.unlockAt(alice));
        vm.prank(alice);
        vault.requestWithdraw(shares);
        vm.warp(vm.getBlockTimestamp() + vault.withdrawCooldown());
        assertEq(vault.maxWithdrawable(alice), 0, "the whole exit doesn't fit");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.InsufficientFreeBankroll.selector, free));
        vault.withdraw(0);
        // the house refuses it directly too, to the wei
        vm.startPrank(address(vault));
        vm.expectRevert(FlipperHouseBase.ExceedsAvailable.selector);
        house.withdrawTreasury(alice, free + 1);
        house.withdrawTreasury(alice, free); // exactly the limit: allowed
        vm.stopPrank();
        assertLe(house.reserved() * BPS, house.treasury() * 3000, "what stays keeps the flips within the cap");
    }

    function test_principal_lock_excess_respects_the_free_bankroll() public {
        PrincipalLock lock = new PrincipalLock(IStakingVault(address(vault)), bob, address(this));
        flipperToken.mint(address(this), 400 * M);
        flipperToken.approve(address(lock), 400 * M);
        lock.stake(400 * M);
        flipperToken.mint(address(this), 300 * M);
        house.depositTreasury(300 * M); // a big gain: the lock's excess is large
        _fillReserve();
        uint256 free = vault.freeBankroll();
        assertLt(free, lock.value() - lock.principal(), "more excess than can leave now");
        assertEq(lock.withdrawableExcess(), free, "reported at the true limit");
    }

    // ── M-4 ──────────────────────────────────────────────────────────────────────────────────────────────

    function test_auction_clock_stops_while_locked() public {
        vm.prank(owner);
        converter.seedPrice(address(0), 1_000_000 ether);
        vm.deal(address(router), 1 ether);
        router.process();
        uint256 id = converter.lotsLength() - 1;
        vm.warp(vm.getBlockTimestamp() + 45 minutes);
        uint256 p = converter.priceOf(id);
        // a two-day lock
        store.target(address(house)).sig("treasury()").checked_write(house.treasury() / 3);
        house.checkDrawdown();
        assertTrue(house.locked());
        vm.warp(vm.getBlockTimestamp() + 2 days);
        assertEq(converter.priceOf(id), p, "frozen while locked");
        assertEq(house.lockedTime(), 2 days);
        house.unlock(true);
        assertEq(converter.priceOf(id), p, "resumes where it stopped");
        vm.warp(vm.getBlockTimestamp() + 15 minutes);
        assertLt(converter.priceOf(id), p);
        assertEq(house.lockedTime(), 2 days, "a finished lock stays counted");
    }

    function test_one_take_halves_last_price_at_most() public {
        vm.prank(owner);
        converter.seedPrice(address(0), 1_000_000 ether);
        vm.deal(address(router), 1 ether);
        router.process();
        uint256 id = converter.lotsLength() - 1;
        vm.warp(vm.getBlockTimestamp() + 20 days); // the floor has decayed away: a near-free sale
        uint256 p = converter.priceOf(id);
        assertLt(p, 1_000 ether);
        vm.startPrank(bob);
        flipperToken.approve(address(converter), type(uint256).max);
        converter.take(id, 1 ether, p);
        vm.stopPrank();
        assertEq(converter.lastPrice(address(0)), 500_000 ether, "halved, not collapsed");
    }

    // ── L-2 ──────────────────────────────────────────────────────────────────────────────────────────────

    function test_cancel_delays_are_bounded() public {
        FlipperHouseBase.Params memory p = house.params();
        vm.startPrank(owner);
        p.guardianCancelDelay = 30 days + 1;
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setParams(p);
        p.guardianCancelDelay = 30 days;
        p.playerCancelDelay = 30 days + 1;
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setParams(p);
        p.playerCancelDelay = 30 days;
        house.setParams(p);
        vm.stopPrank();
    }

    // ── L-3 ──────────────────────────────────────────────────────────────────────────────────────────────

    function test_unrefundable_fee_excess_is_credited_not_reverted() public {
        NoReceive w = new NoReceive();
        flipperToken.mint(address(w), 1_000 ether);
        w.approve(address(flipperToken), address(house));
        uint256 fee = house.randomnessFeeFor(address(flipperToken));
        vm.deal(address(w), fee * 3);
        uint256 id = w.flip(house, address(flipperToken), 1_000 ether, fee * 3); // 2 fees too many, no receive()
        assertGt(id, 0, "the flip went through");
        assertEq(house.claimable(address(w), address(0)), fee * 2);
        assertEq(lens.surplus(house, address(0)), 0, "ETH held = ETH owed");
        vm.expectRevert(); // still can't take ETH
        w.claim(house);
        w.setOpen(true);
        w.claim(house);
        assertEq(address(w).balance, fee * 2);
        assertEq(house.claimable(address(w), address(0)), 0);
    }
}
