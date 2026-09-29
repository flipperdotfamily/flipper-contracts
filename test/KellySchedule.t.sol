// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FlipperBase} from "./utils/FlipperBase.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";

/// @notice The drawdown-scaled Kelly: the multiplier slides from half Kelly at no drawdown to quarter Kelly at the
///         breaker's 50% (drawdown = 1 − NAV per unit / its ATH), re-evaluated on every flip.
contract KellyScheduleTest is FlipperBase {
    using stdStorage for StdStorage;

    StdStorage internal store;
    uint256 internal constant M = 1_000_000 ether;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant REF = 100 * M; // FlipperBase's bankroll

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        house.setKellySchedule(5000, 2500, 0, 5000);
    }

    function _setTreasury(uint256 t) internal {
        store.target(address(house)).sig("treasury()").checked_write(t);
    }

    function test_kelly_backs_off_to_quarter_at_the_breaker() public {
        uint256[6] memory ddBps = [uint256(0), 1000, 2500, 4000, 4900, 5000];
        uint256[6] memory k = [uint256(5000), 4500, 3750, 3000, 2550, 2500];
        uint256 prevFrac = type(uint256).max;
        for (uint256 i; i < 6; ++i) {
            _setTreasury(REF * (BPS - ddBps[i]) / BPS);
            assertEq(house.currentKellyBps(), k[i], "kelly");
            // the model's form: 5000 × NAV/ATH, floored at 2500
            assertEq(house.currentKellyBps(), Math.max(2500, 5000 * (BPS - ddBps[i]) / BPS));
            FlipperHouseBase.Preview memory pv = house.previewFlip(address(flipperToken), 1 ether);
            uint256 frac = pv.maxLiability * 1e18 / (house.treasury() - house.reserved());
            assertLt(frac, prevFrac, "the cap shrinks with the drawdown");
            prevFrac = frac;
        }
        house.checkDrawdown();
        assertFalse(house.locked(), "exactly half: still open");
    }

    function test_every_flip_is_sized_at_the_current_drawdown() public {
        uint256 cap0 = house.previewFlip(address(flipperToken), 1 ether).maxLiability;
        // real losses (house wins pay out): the NAV falls and the next flip's cap shrinks more than the bankroll did
        for (uint256 i; i < 6; ++i) {
            uint256 cap = house.previewFlip(address(flipperToken), 1 ether).maxLiability;
            _reveal(_flip(alice, address(flipperToken), cap * BPS / WIN_COST - 1 ether), WIN_WORD);
        }
        uint256 t = house.treasury();
        uint256 cap1 = house.previewFlip(address(flipperToken), 1 ether).maxLiability;
        assertLt(house.currentKellyBps(), 5000);
        assertLt(cap1 * REF, cap0 * t, "backed off beyond the bankroll's own shrinkage");
        _assertSolvent();
    }

    function test_kelly_is_max_before_the_check_is_live() public {
        vm.prank(owner);
        house.setLockMinTreasury(uint128(200 * M)); // the drawdown check isn't live below this
        _setTreasury(60 * M); // a 40% drawdown, but under the dust guard
        assertEq(house.currentKellyBps(), 5000);
    }

    function test_off_is_flat() public {
        // a house whose schedule was never set (fresh storage, or storage upgraded from before it): flat kellyBps
        vm.prank(owner);
        house.setKellySchedule(5000, 2500, 0, 5000);
        uint256 slot = _slotOf(address(house), "kellyDdEndBps()");
        vm.store(address(house), bytes32(slot), bytes32(0)); // (the three uint16s and their slot-mates, zeroed)
        _setTreasury(60 * M);
        assertEq(house.kellyDdEndBps(), 0);
        assertEq(house.currentKellyBps(), 5000);
    }

    /// @dev the slot a view reads (found by recording its storage accesses)
    function _slotOf(address target, string memory sig) internal returns (uint256) {
        vm.record();
        (bool ok,) = target.staticcall(abi.encodeWithSignature(sig));
        require(ok);
        (bytes32[] memory reads,) = vm.accesses(target);
        return uint256(reads[reads.length - 1]);
    }

    function test_kelly_schedule_bounds() public {
        vm.startPrank(owner);
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setKellySchedule(5000, 0, 0, 5000); // min 0
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setKellySchedule(5000, 5001, 0, 5000); // min > max
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setKellySchedule(10_001, 2500, 0, 5000);
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setKellySchedule(5000, 2500, 5000, 5000); // start ≥ end
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setKellySchedule(5000, 2500, 0, 5001); // past the breaker
        vm.expectEmit(address(house));
        emit FlipperHouseBase.KellyScheduleSet(8000, 2000, 1000, 4000);
        house.setKellySchedule(8000, 2000, 1000, 4000);
        // setParams can't put the max under the min
        FlipperHouseBase.Params memory p = house.params();
        p.kellyBps = 1999;
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setParams(p);
        vm.stopPrank();
        assertEq(house.params().kellyBps, 8000);
        assertEq(house.kellyMinBps(), 2000);
        assertEq(house.kellyDdStartBps(), 1000);
        assertEq(house.kellyDdEndBps(), 4000);
    }

    /// @dev exact Kelly f* (WAD) of a $FLIPPER flip at win chance `w` and payout `pay`, half the edge to holders
    function _fStar(uint256 w, uint256 pay) internal pure returns (uint256) {
        uint256 e = BPS - Math.mulDiv(w, pay, BPS, Math.Rounding.Ceil);
        uint256 q = BPS - w;
        uint256 g = WAD - Math.mulDiv(WAD, e * 5000, BPS * q);
        uint256 loss = w * Math.mulDiv((pay - BPS) * WAD / BPS, WAD, g);
        return q * WAD > loss ? (q * WAD - loss) / BPS : 0;
    }

    /// the cap never exceeds max Kelly × f* of the unreserved bankroll, whatever the drawdown
    function testFuzz_cap_never_above_max_kelly(uint256 dd, uint256 growth) public {
        dd = bound(dd, 0, 4999);
        growth = bound(growth, 0, 80_000);
        uint256 t = REF * (BPS + growth) / BPS;
        _setTreasury(t);
        house.checkDrawdown(); // the ATH follows
        _setTreasury(t * (BPS - dd) / BPS);
        FlipperHouseBase.Params memory p = house.params();
        FlipperHouseBase.Preview memory pv = house.previewFlip(address(flipperToken), 1 ether);
        uint256 unres = house.treasury() - house.reserved();
        uint256 ref = Math.mulDiv(unres, _fStar(p.baseWinChanceBps, p.flipperPayoutBps) * 5000, WAD * BPS);
        assertLe(pv.maxLiability, ref + ref / 1e12 + 1, "never above max Kelly x f*");
        uint256 k = house.currentKellyBps();
        assertLe(k, 5000);
        assertGe(k, 2500);
        // and at the scaled multiplier (to rounding)
        uint256 scaled = Math.mulDiv(unres, _fStar(p.baseWinChanceBps, p.flipperPayoutBps) * k, WAD * BPS);
        assertApproxEqRel(pv.maxLiability, scaled, 1e14);
    }
}
