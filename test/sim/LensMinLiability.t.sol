// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FlipperLens} from "../../src/lens/FlipperLens.sol";
import {FlipperHouse} from "../../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../../src/house/FlipperHouseBase.sol";

/// @dev A house whose previews accept stakes in [minOk, maxOk] only: code 2 (REJECT_AMOUNT, under `minLiability`)
///      below, code 7 (REJECT_BET_SIZE) above — the shape `previewFlip` has since `minLiability`.
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

/// @notice Repro (lens, UI helper): `FlipperLens.maxStake` bisects assuming "accepted" is a prefix of the stakes, but
///         since `minLiability` a stake can also be refused for being too small (code 2). The bisection treats that as
///         "too big" (`hi = mid`), so when the accepted window [min, max] is narrower than 2x and the halving midpoints
///         step over it, the lens reports 0 although valid stakes exist.
contract LensMinLiabilityTest is Test {
    function test_maxStake_misses_a_narrow_window() public {
        FlipperLens lens = new FlipperLens();
        // accepted: [0.6, 0.9] (x 1e18); searching from 1000: midpoints 500, 250, ..., 0.976 (too big), 0.488 (too
        // small, but treated as too big) → converges on 0
        WindowHouse h = new WindowHouse(0.6e18, 0.9e18);
        (uint256 amt,) = lens.maxStake(FlipperHouse(payable(address(h))), address(1), 1000e18, false);
        emit log_named_uint("maxStake reported (0 = none)", amt);
        // fixed (a too-small midpoint now raises the lower bound): the window's top is found
        assertApproxEqRel(amt, 0.9e18, 0.001e18, "the narrow window is found");
        assertEq(h.previewFlip(address(1), 0.8e18).code, 0, "0.8 is accepted");
    }

    function test_maxStake_finds_a_wide_window() public {
        FlipperLens lens = new FlipperLens();
        WindowHouse h = new WindowHouse(0.01e18, 0.9e18);
        (uint256 amt,) = lens.maxStake(FlipperHouse(payable(address(h))), address(1), 1000e18, false);
        assertApproxEqRel(amt, 0.9e18, 0.002e18, "a window wider than 2x is found");
    }
}
