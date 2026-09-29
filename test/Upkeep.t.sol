// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FlipperBase} from "./utils/FlipperBase.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {FlipperLens} from "../src/lens/FlipperLens.sol";
import {DutchAuctionConverter} from "../src/DutchAuctionConverter.sol";

/// @notice Keeperless upkeep: permissionless pending-win resolution, inventory sweeps into the Dutch auction,
///         guardian write-offs of untransferable inventory, and the converter's pricing.
contract UpkeepTest is FlipperBase {
    uint256 internal constant AMOUNT = 1_000_000 ether; // 0.1 ETH of T

    function _pendingWin() internal returns (uint256 id) {
        id = _flip(alice, address(tokenT), AMOUNT);
        toggle.set(true, true, false, false);
        _reveal(id, WIN_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.WinPending));
        toggle.set(false, false, false, false);
    }

    function _lostInventory() internal returns (uint256 id) {
        id = _flip(alice, address(tokenT), AMOUNT);
        toggle.set(true, true, false, false);
        _reveal(id, LOSS_WORD);
        toggle.set(false, false, false, false);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.LostInventory));
    }

    // ── resolvePendingWin ────────────────────────────────────────────────────────────────────────────────

    /// Whoever picks the moment can push the in-kind buy's cost up to the reserved liability, never beyond: a pump
    /// past the cap makes the buy fail (TooEarly before the timeout); a pump under it costs at most the liability.
    function test_resolve_cost_is_capped_by_liability_whatever_the_price() public {
        uint256 id = _pendingWin();
        (,,,,,,, uint128 liability,,,,) = house.flips(id);

        uint256 snap = vm.snapshotState();
        _buyWithEth(tPool, 60 ether); // T up ~2.3x: buying AMOUNT costs more than the liability
        vm.prank(mallory);
        vm.expectRevert(FlipperHouseBase.TooEarly.selector);
        house.resolvePendingWin(id);
        vm.revertToState(snap);

        _buyWithEth(tPool, 2 ether); // a small pump: still under the cap
        uint256 t0 = house.treasury();
        uint256 a0 = tokenT.balanceOf(alice);
        vm.prank(mallory);
        house.resolvePendingWin(id);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Won));
        assertEq(tokenT.balanceOf(alice) - a0, AMOUNT, "winnings in kind");
        assertLe(t0 - house.treasury(), liability, "cost bounded by the reserved liability");
        assertEq(house.reserved(), 0);
        _assertSolvent();
    }

    /// After the timeout the $FLIPPER fallback is only a fallback: if the buy executes, the win is paid in kind.
    function test_resolve_after_timeout_still_prefers_in_kind() public {
        uint256 id = _pendingWin();
        vm.warp(vm.getBlockTimestamp() + 2 days);
        uint256 a0 = tokenT.balanceOf(alice);
        house.resolvePendingWin(id);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Won));
        assertEq(tokenT.balanceOf(alice) - a0, AMOUNT);
    }

    function test_resolve_rejects_other_statuses() public {
        uint256 id = _flip(alice, address(tokenT), AMOUNT);
        vm.expectRevert(FlipperHouseBase.BadStatus.selector);
        house.resolvePendingWin(id);
        _reveal(id, LOSS_WORD);
        vm.expectRevert(FlipperHouseBase.BadStatus.selector);
        house.resolvePendingWin(id);
    }

    function test_pending_timeout_bounds() public {
        FlipperHouseBase.Params memory p = defaultParams();
        vm.startPrank(owner);
        p.pendingTimeout = 1 hours - 1;
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setParams(p);
        p.pendingTimeout = 30 days + 1;
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setParams(p);
        p.pendingTimeout = 1 hours;
        house.setParams(p);
        vm.stopPrank();
    }

    function test_lens_lists_pending_wins() public {
        uint256 a = _pendingWin();
        uint256 b = _flip(bob, address(tokenT), AMOUNT); // still pending randomness
        uint256 c = _pendingWin();
        FlipperLens.FlipView[] memory all = lens.pendingWins(house, address(0), 0, type(uint256).max);
        assertEq(all.length, 2);
        assertEq(all[0].id, a);
        assertEq(all[1].id, c);
        assertEq(all[0].player, alice);
        assertEq(lens.pendingWins(house, bob, 0, 100).length, 0);
        assertEq(lens.pendingWins(house, alice, c, c + 1).length, 1);
        b;
    }

    // ── inventory → Dutch auction ────────────────────────────────────────────────────────────────────────

    function test_partial_sweeps_carry_proportional_reference() public {
        uint256 id = _lostInventory();
        (,,,,,,,, uint128 sellQuote,,,) = house.flips(id);
        assertEq(house.inventoryValue(address(tokenT)), sellQuote);

        house.sweepInventory(address(tokenT), AMOUNT / 4);
        assertEq(house.inventory(address(tokenT)), AMOUNT * 3 / 4);
        assertEq(house.inventoryValue(address(tokenT)), sellQuote - uint256(sellQuote) / 4);
        DutchAuctionConverter.Lot memory l = converter.lot(0);
        assertEq(l.kicker, address(house));
        assertEq(l.remaining, AMOUNT / 4);
        assertEq(l.startPrice, (uint256(sellQuote) / 4) * 1e18 / (AMOUNT / 4) * 4);

        vm.expectRevert(FlipperHouseBase.ExceedsAvailable.selector);
        house.sweepInventory(address(tokenT), AMOUNT);
        vm.expectRevert(FlipperHouseBase.ExceedsAvailable.selector);
        house.sweepInventory(address(tokenT), 0);
        _assertSolvent();
    }

    function test_untransferable_inventory_is_skipped_then_written_off() public {
        _lostInventory();
        vm.mockCallRevert(
            address(tokenT), abi.encodeCall(IERC20.transfer, (address(converter), AMOUNT)), "blocked"
        );
        vm.expectEmit(address(house));
        emit FlipperHouseBase.InventoryStuck(address(tokenT), AMOUNT);
        house.sweepInventory(address(tokenT), AMOUNT);
        vm.clearMockedCalls();
        assertEq(house.inventory(address(tokenT)), AMOUNT, "left in place");
        assertEq(converter.lotsLength(), 0);

        vm.prank(mallory);
        vm.expectRevert(FlipperHouseBase.Unauthorized.selector);
        house.writeOffInventory(address(tokenT));
        vm.prank(owner);
        house.writeOffInventory(address(tokenT));
        assertEq(house.inventory(address(tokenT)), 0);
        assertEq(house.inventoryValue(address(tokenT)), 0);
        _assertSolvent();
    }

    function test_sweep_needs_a_converter() public {
        _lostInventory();
        vm.prank(owner);
        house.setConverter(address(0));
        vm.expectRevert(FlipperHouseBase.ExceedsAvailable.selector);
        house.sweepInventory(address(tokenT), AMOUNT);
    }

    // ── converter ────────────────────────────────────────────────────────────────────────────────────────

    function test_converter_price_halves_per_half_life_linear_within() public {
        _lostInventory();
        house.sweepInventory(address(tokenT), AMOUNT);
        uint256 p0 = converter.priceOf(0);
        uint256 h = converter.halfLife();
        vm.warp(vm.getBlockTimestamp() + h / 2);
        assertEq(converter.priceOf(0), p0 - (p0 >> 1) / 2, "linear within the half-life");
        vm.warp(vm.getBlockTimestamp() + h / 2);
        assertEq(converter.priceOf(0), p0 >> 1);
        // the floor: half the reference (p0 / 4), halving every day
        uint256 floor = converter.lot(0).floorPrice;
        assertEq(floor, p0 / 8);
        vm.warp(vm.getBlockTimestamp() + 2 * h);
        assertEq(converter.priceOf(0), floor, "held at the floor, not below");
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(converter.priceOf(0), floor >> 1, "the floor decays daily");
        vm.warp(vm.getBlockTimestamp() + 255 days);
        assertEq(converter.priceOf(0), 0, "eventually free: every lot clears");
    }

    /// Stress-test F-3: a router ETH lot has no reference of its own; one seeded price (launch) gives the first lot a
    /// start and a floor, and after that the last clearing price does.
    function test_eth_lots_get_a_seeded_reference_and_floor() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        converter.seedPrice(address(0), 1_000_000 ether);
        vm.prank(owner);
        converter.seedPrice(address(0), 1_000_000 ether); // 1 ETH = 1M $FLIPPER
        vm.prank(owner);
        vm.expectRevert(DutchAuctionConverter.AlreadyPriced.selector);
        converter.seedPrice(address(0), 1 ether);

        vm.deal(address(router), 1 ether);
        router.process();
        uint256 id = converter.lotsLength() - 1;
        DutchAuctionConverter.Lot memory l = converter.lot(id);
        assertEq(l.startPrice, 4_000_000 ether);
        assertEq(l.floorPrice, 500_000 ether);
        // a thin market nobody watches: hours later it is still at half the reference, not near zero
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        assertEq(converter.priceOf(id), 500_000 ether);
    }

    function test_converter_take_rules() public {
        _lostInventory();
        house.sweepInventory(address(tokenT), AMOUNT);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        uint256 p = converter.priceOf(0);
        vm.startPrank(bob);
        flipperToken.approve(address(converter), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(DutchAuctionConverter.PriceAboveMax.selector, p, p - 1));
        converter.take(0, AMOUNT, p - 1);
        vm.expectRevert(DutchAuctionConverter.BadLot.selector);
        converter.take(0, AMOUNT + 1, p);
        uint256 t0 = house.treasury();
        uint256 paid = converter.take(0, AMOUNT / 2, p); // partial
        assertEq(paid, (AMOUNT / 2 * p + 1e18 - 1) / 1e18, "rounded up against the taker");
        assertEq(house.treasury(), t0 + paid);
        assertEq(converter.lot(0).remaining, AMOUNT / 2);
        converter.take(0, AMOUNT / 2, p);
        vm.expectRevert(DutchAuctionConverter.BadLot.selector);
        converter.take(0, 1, p);
        vm.stopPrank();
        assertEq(converter.lastPrice(address(tokenT)), p);
    }

    function test_only_kickers_kick() public {
        vm.prank(mallory);
        vm.expectRevert(DutchAuctionConverter.Unauthorized.selector);
        converter.kick(address(0), 1 ether, 0);
        vm.prank(mallory);
        vm.expectRevert();
        converter.setKicker(mallory, true);
        assertTrue(converter.isKicker(address(house)));
        assertTrue(converter.isKicker(address(router)));
    }
}
