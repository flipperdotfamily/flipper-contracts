// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {FlipperBase} from "./utils/FlipperBase.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";

/// @notice Stress-test F-1: the randomness adapter caps open requests globally, so one player may hold at most
///         `maxOpenPerPlayer` flips waiting for randomness, and every flip must carry at least `minLiability`.
contract FlipLimitsTest is FlipperBase {
    using stdStorage for StdStorage;

    StdStorage internal store;
    uint8 internal constant TOO_MANY_OPEN = 9;
    uint8 internal constant AMOUNT_CODE = 2;
    uint128 internal constant MIN_LIAB = 50_000 ether;

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        house.setFlipLimits(4, MIN_LIAB);
    }

    function _flipOk(address who, uint256 amount) internal returns (uint256) {
        return _flip(who, address(flipperToken), amount);
    }

    function _expectRejected(address who, address token, uint256 amount, uint8 code) internal {
        uint256 fee = house.randomnessFeeFor(token);
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(FlipperHouseBase.FlipRejected.selector, code));
        house.flip{value: fee}(token, amount, 0, block.timestamp);
    }

    function _preview(address who, address token, uint256 amount) internal returns (FlipperHouseBase.Preview memory pv) {
        vm.prank(who);
        pv = house.previewFlip(token, amount);
    }

    // ── per-player cap ───────────────────────────────────────────────────────────────────────────────────

    function test_a_player_holds_at_most_four_open_flips() public {
        uint256[] memory ids = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            ids[i] = _flipOk(alice, 100_000 ether);
        }
        assertEq(house.openFlips(alice), 4);
        assertEq(_preview(alice, address(flipperToken), 100_000 ether).code, TOO_MANY_OPEN, "the preview says so");
        _expectRejected(alice, address(flipperToken), 100_000 ether, TOO_MANY_OPEN);
        _expectRejected(alice, address(tokenT), 1_000_000 ether, TOO_MANY_OPEN);
        // others are unaffected
        _flipOk(bob, 100_000 ether);
        // a delivery frees a slot
        _reveal(ids[0], LOSS_WORD);
        assertEq(house.openFlips(alice), 3);
        _flipOk(alice, 100_000 ether);
    }

    function test_every_way_out_of_pending_frees_the_slot() public {
        uint256 a = _flipOk(alice, 100_000 ether);
        uint256 b = _flipOk(alice, 100_000 ether);
        uint256 c = _flipOk(alice, 100_000 ether);
        uint256 d = _flipOk(alice, 100_000 ether);
        _reveal(a, WIN_WORD); // settled (win)
        entropy.failFirstAttempt(provider, _seq(b), bytes32(LOSS_WORD)); // first delivery failed: still open
        assertEq(house.openFlips(alice), 3);
        vm.warp(vm.getBlockTimestamp() + 8 days);
        vm.prank(alice);
        house.cancelFlip(c); // cancelled (provably unrevealed)
        assertEq(house.openFlips(alice), 2);
        // delivered during a drawdown lock: deferred, but no longer waiting for randomness
        store.target(address(house)).sig("treasury()").checked_write(house.treasury() / 3);
        house.checkDrawdown();
        assertTrue(house.locked());
        _reveal(d, WIN_WORD);
        assertEq(house.openFlips(alice), 1);
        house.unlock(true); // this contract deployed the house: the unlocker
        house.settleDeferred(d);
        assertEq(house.openFlips(alice), 1, "settling the deferred flip doesn't count twice");
        _assertSolvent();
    }

    function test_the_global_pool_needs_many_funded_players() public {
        // 1-wei dust is refused outright; at the floor, one player holds only four requests
        _expectRejected(mallory, address(flipperToken), 1, AMOUNT_CODE);
        uint256 atFloor = uint256(MIN_LIAB) * BPS / WIN_COST + 1;
        for (uint256 i; i < 4; ++i) {
            _flipOk(mallory, atFloor);
        }
        _expectRejected(mallory, address(flipperToken), atFloor, TOO_MANY_OPEN);
    }

    // ── dust floor ───────────────────────────────────────────────────────────────────────────────────────

    function test_dust_floor_on_liability() public {
        // $FLIPPER flips: liability = 1.05 × stake
        uint256 edge = uint256(MIN_LIAB) * BPS / WIN_COST; // the stake whose liability is just under / at the floor
        uint256 below = edge - 1 ether;
        assertEq(_preview(alice, address(flipperToken), below).code, AMOUNT_CODE);
        _expectRejected(alice, address(flipperToken), below, AMOUNT_CODE);
        FlipperHouseBase.Preview memory pv = _preview(alice, address(flipperToken), edge + 1 ether);
        assertEq(pv.code, 0);
        assertGe(pv.liability, MIN_LIAB);
        _flipOk(alice, edge + 1 ether);
        // token flips: the liability (1.05 × the buy quote, in $FLIPPER) meets the same floor; 1 T ≈ 0.1 $FLIPPER
        assertEq(_preview(alice, address(tokenT), 400_000 ether).code, AMOUNT_CODE);
        assertEq(_preview(alice, address(tokenT), 600_000 ether).code, 0);
    }

    /// the guardian (the operator key) re-prices the floor as $FLIPPER's price moves, within the same bounds
    function test_the_guardian_sets_the_limits_too() public {
        address op = makeAddr("operator");
        vm.prank(owner);
        house.setGuardian(op);
        vm.startPrank(op);
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setFlipLimits(0, 0);
        house.setFlipLimits(4, 123 ether);
        vm.stopPrank();
        assertEq(house.minLiability(), 123 ether);
        vm.prank(alice);
        vm.expectRevert();
        house.setFlipLimits(4, 1);
    }

    function test_limits_are_the_owners_and_bounded() public {
        vm.prank(alice);
        vm.expectRevert();
        house.setFlipLimits(10, 0);
        vm.startPrank(owner);
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setFlipLimits(0, 0);
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setFlipLimits(256, 0);
        vm.expectEmit(address(house));
        emit FlipperHouseBase.FlipLimitsSet(1, 0);
        house.setFlipLimits(1, 0);
        vm.stopPrank();
        assertEq(house.maxOpenPerPlayer(), 1);
        assertEq(house.minLiability(), 0);
        _flipOk(alice, 1); // no floor: any amount
        _expectRejected(alice, address(flipperToken), 1, TOO_MANY_OPEN);
    }
}
