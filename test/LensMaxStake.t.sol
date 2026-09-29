// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FlipperLens} from "../src/lens/FlipperLens.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {FlipperBase} from "./utils/FlipperBase.sol";

/// @dev previews accept stakes in [minOk, maxOk] only: code 2 below (under `minLiability`), code 7 above
contract WindowHouse {
    uint256 public minOk;
    uint256 public maxOk;

    constructor(uint256 lo, uint256 hi) {
        minOk = lo;
        maxOk = hi;
    }

    function params() external pure returns (FlipperHouseBase.Params memory p) {
        p.baseWinChanceBps = 4500;
    }

    function currentBaseWinChanceBps() external pure returns (uint256) {
        return 4500;
    }

    function previewFlip(address, uint256 amount) external view returns (FlipperHouseBase.Preview memory pv) {
        pv.winChanceBps = 4500;
        pv.code = amount < minOk ? 2 : (amount > maxOk ? 7 : 0);
    }
}

/// @notice `FlipperLens.maxStake` with the dust floor: the accepted stakes are a window, not a prefix.
contract LensMaxStakeTest is Test {
    FlipperLens internal lens = new FlipperLens();

    function _max(uint256 minOk, uint256 maxOk, uint256 hi) internal returns (uint256 amt, uint8 code) {
        WindowHouse h = new WindowHouse(minOk, maxOk);
        FlipperHouseBase.Preview memory pv;
        (amt, pv) = lens.maxStake(FlipperHouse(payable(address(h))), address(1), hi, false);
        code = pv.code;
    }

    function test_narrow_window_is_found() public {
        (uint256 amt, uint8 code) = _max(0.6e18, 0.9e18, 1000e18);
        assertApproxEqRel(amt, 0.9e18, 0.001e18);
        assertLe(amt, 0.9e18);
        assertEq(code, 0);
    }

    function test_wide_window_and_a_hi_inside_it() public {
        (uint256 a,) = _max(0.01e18, 0.9e18, 1000e18);
        assertApproxEqRel(a, 0.9e18, 0.001e18);
        (uint256 b,) = _max(0.01e18, 0.9e18, 0.5e18);
        assertEq(b, 0.5e18, "hi itself accepted");
    }

    function test_no_window_reports_zero() public {
        (uint256 a,) = _max(2e18, 1e18, 1000e18); // empty
        assertEq(a, 0);
        (uint256 b,) = _max(2000e18, 3000e18, 1000e18); // all of (0, hi] too small
        assertEq(b, 0);
    }

    /// any window inside (0, hi]: the answer is accepted and within 0.1% of the top
    function testFuzz_window(uint256 minOk, uint256 width, uint256 hi) public {
        hi = bound(hi, 1e6, 1e30);
        minOk = bound(minOk, 1, hi);
        width = bound(width, 0, hi - minOk);
        uint256 maxOk = minOk + width;
        (uint256 amt, uint8 code) = _max(minOk, maxOk, hi);
        assertGe(amt, minOk, "found");
        assertLe(amt, maxOk);
        assertEq(code, 0);
        assertGe(amt, maxOk - maxOk / 1000 - 1, "within 0.1% of the top");
    }
}

/// @notice On the real house: with the dust floor set, the lens still finds the max stake.
contract LensMaxStakeHouseTest is FlipperBase {
    function test_real_house_with_the_floor() public {
        vm.prank(owner);
        house.setFlipLimits(4, 50_000 ether);
        (uint256 amt, FlipperHouseBase.Preview memory pv) = lens.maxStake(house, address(flipperToken), 1e30, false);
        assertEq(pv.code, 0);
        assertGt(amt, 0);
        assertEq(house.previewFlip(address(flipperToken), amt).code, 0);
        assertEq(house.previewFlip(address(flipperToken), amt + amt / 500).code, 7, "just above: too big");
    }
}
