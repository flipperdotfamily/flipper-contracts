// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PartnerBase} from "./Partner.t.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";

/// @notice The edge-scaled Kelly cap: a flip's liability ≤ min(maxBetBps, kellyBps × f*) of the unreserved bankroll,
///         f* the bankroll's exact Kelly fraction under the flip's own terms (odds after fees and partner discount,
///         route quotes, partner and holder shares).
contract KellyTest is PartnerBase {
    uint256 internal constant WAD = 1e18;

    // tokens whose only route is one deep, fee-tiered pool straight to $FLIPPER: route cost ≈ the pool fee
    MockERC20 internal t0; // fee 0: route cost ~0
    MockERC20 internal t5; // fee 5%: route cost ~5.1%
    MockERC20 internal t10; // fee 9.4%: route cost ~9.8%

    function setUp() public override {
        super.setUp();
        t0 = _direct("T0", 0);
        t5 = _direct("T5", 50_000);
        t10 = _direct("T10", 94_000);
    }

    function _direct(string memory sym, uint24 fee) internal returns (MockERC20 t) {
        t = new MockERC20(sym, sym, 18);
        (address a, address b) = address(t) < address(flipperToken)
            ? (address(t), address(flipperToken))
            : (address(flipperToken), address(t));
        PoolKey memory key = PoolKey(Currency.wrap(a), Currency.wrap(b), fee, TS, IHooks(address(0)));
        manager.initialize(key, uint160(1 << 96)); // 1 token = 1 $FLIPPER
        t.mint(address(this), 1e40);
        flipperToken.mint(address(this), 1e40);
        t.approve(address(lp), type(uint256).max);
        flipperToken.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(TS), TickMath.maxUsableTick(TS), int256(uint256(1e33)), 0
            ),
            ""
        );
        vm.prank(owner);
        house.setTokenRoute(address(t), _single(key));
        for (uint256 i; i < 3; ++i) {
            address u = [alice, bob, mallory][i];
            t.mint(u, 1e30);
            vm.prank(u);
            t.approve(address(house), type(uint256).max);
        }
    }

    // ── the reference: exact Kelly, computed independently ──────────────────────────────────────────────

    /// @dev f* (WAD) = q − p·W/G per unit of the loss on a player win: W = the buy b (token flip) or payout − stake
    ///      ($FLIPPER flip); G = sale proceeds s less the partner's and the holders' shares (as `_creditLoss` books them)
    function _exactKelly(address token, uint256 p, uint256 s, uint256 b, uint256 share) internal view returns (uint256) {
        FlipperHouseBase.Params memory pr = house.params();
        bool isF = token == address(flipperToken);
        uint256 e;
        if (isF) {
            e = BPS - Math.mulDiv(p, pr.flipperPayoutBps, BPS, Math.Rounding.Ceil);
        } else {
            uint256 h = b > s ? Math.mulDiv(b - s, BPS, b + s, Math.Rounding.Ceil) : 0;
            e = BPS > h + 2 * p ? BPS - h - 2 * p : 0;
        }
        uint256 q = BPS - p;
        uint256 sh = share < e ? share : e;
        uint256 cut = Math.mulDiv(WAD, sh * BPS + (e - sh) * pr.rewardsShareBps, BPS * q); // shares per unit proceeds
        if (cut >= WAD) return 0;
        uint256 g = WAD - cut; // G / s
        uint256 w = isF ? (uint256(pr.flipperPayoutBps) - BPS) * WAD / BPS : Math.mulDiv(b, WAD, s); // W / s
        uint256 loss = p * Math.mulDiv(w, WAD, g); // p·W/G, WAD × bps
        uint256 gain = q * WAD;
        return gain > loss ? (gain - loss) / BPS : 0;
    }

    function _unreserved() internal view returns (uint256) {
        return house.treasury() - house.reserved();
    }

    /// @dev previewFlip as `player` with an optional ERC-8021 suffix
    function _preview(address player, address token, uint256 amount, bytes memory suffix)
        internal
        returns (FlipperHouseBase.Preview memory pv)
    {
        vm.prank(player);
        (bool ok, bytes memory ret) =
            address(house).call(bytes.concat(abi.encodeCall(FlipperHouse.previewFlip, (token, amount)), suffix));
        assertTrue(ok, "preview");
        pv = abi.decode(ret, (FlipperHouseBase.Preview));
    }

    function _share(address player, address token, uint256 amount, bytes memory suffix) internal returns (uint256) {
        if (suffix.length == 0) return 0;
        // the share is fixed by a real flip; take it from one (and undo it)
        uint256 snap = vm.snapshotState();
        uint256 id = _flipWith(player, token, amount, suffix);
        (, uint256 share) = _tag(id);
        vm.revertToState(snap);
        return share;
    }

    /// @dev the preview's cap against the reference: ≤ kelly × exact f* × unreserved (× 1.05 slack for token flips'
    ///      fallback-inclusive liability), and within 0.2% below it (or at the ceiling)
    function _checkCap(FlipperHouseBase.Preview memory pv, address token, uint256 share) internal view {
        uint256 k = house.params().kellyBps;
        uint256 f = _exactKelly(token, pv.winChanceBps, pv.sellQuote, pv.buyQuote, share);
        uint256 ref = Math.mulDiv(_unreserved(), f * k, WAD * BPS);
        uint256 ceiling = house.maxLiability();
        assertLe(pv.maxLiability, ref * 105 / 100 + 1, "never above kelly x exact f* x 1.05");
        // (the reference carries f* to 18 digits; the contract is exact)
        assertLe(pv.maxLiability, ref + ref / 1e12 + 1, "in fact never above kelly x exact f*");
        if (ref < ceiling) assertGe(pv.maxLiability, ref * 998 / 1000, "within 0.2% of it");
        else assertEq(pv.maxLiability, ceiling, "the ceiling binds");
    }

    function _capBps(FlipperHouseBase.Preview memory pv) internal view returns (uint256) {
        return pv.maxLiability * 1e6 / _unreserved(); // 1e6 = 100%
    }

    // ── scaling ──────────────────────────────────────────────────────────────────────────────────────────

    function test_cap_scales_with_route_cost() public {
        uint256 amt = 10_000 ether;
        FlipperHouseBase.Preview memory a = house.previewFlip(address(t0), amt);
        FlipperHouseBase.Preview memory b = house.previewFlip(address(t5), amt);
        FlipperHouseBase.Preview memory c = house.previewFlip(address(t10), amt);
        assertEq(a.code, 0);
        assertEq(b.code, 0);
        assertEq(c.code, 0);
        assertLt(a.routeCostBps, 10);
        assertApproxEqAbs(b.routeCostBps, 512, 5);
        assertApproxEqAbs(c.routeCostBps, 984, 5);
        _checkCap(a, address(t0), 0);
        _checkCap(b, address(t5), 0);
        _checkCap(c, address(t10), 0);
        // half Kelly of: 5.5% at a 10% gross edge, 2.83% at 5.1% route cost, 1.24% at 9.8% route cost (2% edge)
        emit log_named_uint("cap, 1e6 = 100% of unreserved: route cost ~0", _capBps(a));
        emit log_named_uint("cap: route cost ~5%", _capBps(b));
        emit log_named_uint("cap: route cost ~10%", _capBps(c));
        assertApproxEqAbs(_capBps(a), 27_500, 150);
        assertApproxEqAbs(_capBps(b), 14_144, 100);
        assertApproxEqAbs(_capBps(c), 6_204, 100);
        assertGt(_capBps(a), _capBps(b));
        assertGt(_capBps(b), _capBps(c));
    }

    function test_flipper_flip_cap() public {
        FlipperHouseBase.Preview memory pv = house.previewFlip(address(flipperToken), 1 ether);
        _checkCap(pv, address(flipperToken), 0);
        // exact Kelly 4.169% at 45% × 2.05x with half of the 7.75% edge to holders; half of it
        assertApproxEqAbs(_capBps(pv), 20_843, 5);
    }

    function test_cap_shrinks_with_partner_discount_and_share() public {
        bytes memory sfx = _suffix("demo");
        uint256 amt = 10_000 ether;
        address[2] memory tokens = [address(t0), address(flipperToken)];
        for (uint256 i; i < 2; ++i) {
            FlipperHouseBase.Preview memory plain = _preview(alice, tokens[i], amt, "");
            FlipperHouseBase.Preview memory viaP = _preview(alice, tokens[i], amt, sfx);
            assertGt(viaP.winChanceBps, plain.winChanceBps, "discount: better odds");
            uint256 share = _share(alice, tokens[i], amt, sfx);
            assertGt(share, 0);
            _checkCap(viaP, tokens[i], share);
            assertLt(viaP.maxLiability, plain.maxLiability, "a partner flip gets a smaller cap");
        }
        // a bigger cut (tier 3: 30% of the edge) shrinks it further
        FlipperHouseBase.Preview memory t1 = _preview(alice, address(t0), amt, sfx);
        vm.prank(owner);
        registry.approve(demoId, 3);
        FlipperHouseBase.Preview memory t3 = _preview(alice, address(t0), amt, sfx);
        _checkCap(t3, address(t0), _share(alice, address(t0), amt, sfx));
        assertLt(t3.maxLiability, t1.maxLiability);
    }

    function test_ceiling_binds_when_kelly_exceeds_it() public {
        FlipperHouseBase.Params memory p = house.params();
        p.kellyBps = 10_000; // full Kelly: 5.5% on a cheap token route
        p.maxBetBps = 450; // 4.5% ceiling
        vm.prank(owner);
        house.setParams(p);
        FlipperHouseBase.Preview memory tok = house.previewFlip(address(t0), 10_000 ether);
        assertEq(tok.maxLiability, house.maxLiability(), "ceiling");
        _checkCap(tok, address(t0), 0);
        // $FLIPPER (4.17% full Kelly) stays under the 4.5% ceiling
        FlipperHouseBase.Preview memory fl = house.previewFlip(address(flipperToken), 1 ether);
        assertLt(fl.maxLiability, house.maxLiability());
        _checkCap(fl, address(flipperToken), 0);
    }

    function test_kelly_bounds() public {
        FlipperHouseBase.Params memory p = house.params();
        vm.startPrank(owner);
        p.kellyBps = 0;
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setParams(p);
        p.kellyBps = 10_001;
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setParams(p);
        p.kellyBps = 1;
        house.setParams(p);
        p.kellyBps = 10_000;
        house.setParams(p);
        vm.stopPrank();
        assertEq(house.params().kellyBps, 10_000);
    }

    function test_unprofitable_terms_get_no_cap() public {
        // a partner whose share eats the edge left after the discount: f* ≤ 0 → rejected as over the cap
        FlipperHouseBase.Params memory p = house.params();
        p.rewardsShareBps = 10_000; // every bit of edge to holders: the bankroll keeps nothing
        vm.prank(owner);
        house.setParams(p);
        FlipperHouseBase.Preview memory pv = house.previewFlip(address(flipperToken), 1 ether);
        assertEq(pv.maxLiability, 0);
        assertEq(pv.code, 7, "REJECT_BET_SIZE");
    }

    // ── views = acceptance ───────────────────────────────────────────────────────────────────────────────

    /// @dev largest amount the preview accepts (as `player`, with `suffix`), by bisection to the wei
    function _edge(address player, address token, bytes memory suffix) internal returns (uint256 lo) {
        uint256 hi = 1e27;
        lo = 1;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_preview(player, token, mid, suffix).code == 0) lo = mid;
            else hi = mid;
        }
    }

    function test_preview_max_is_exactly_what_flip_accepts() public {
        address[3] memory tokens = [address(flipperToken), address(t0), address(t10)];
        bytes[2] memory sfx = [bytes(""), _suffix("demo")];
        for (uint256 i; i < tokens.length; ++i) {
            for (uint256 j; j < 2; ++j) {
                uint256 snap = vm.snapshotState();
                uint256 max = _edge(alice, tokens[i], sfx[j]);
                FlipperHouseBase.Preview memory above = _preview(alice, tokens[i], max + 1, sfx[j]);
                assertEq(above.code, 7, "1 wei more: over the cap");
                uint256 fee = house.randomnessFeeFor(tokens[i]);
                vm.prank(alice);
                (bool ok, bytes memory ret) = address(house).call{value: fee}(
                    bytes.concat(abi.encodeCall(FlipperHouse.flip, (tokens[i], max + 1, 0, block.timestamp)), sfx[j])
                );
                assertFalse(ok);
                assertEq(bytes4(ret), FlipperHouseBase.FlipRejected.selector);
                assertEq(abi.decode(_tail(ret), (uint8)), 7);
                _flipWith(alice, tokens[i], max, sfx[j]);
                vm.revertToState(snap);
            }
        }
    }

    function _tail(bytes memory r) internal pure returns (bytes memory t) {
        t = new bytes(r.length - 4);
        for (uint256 i; i < t.length; ++i) {
            t[i] = r[i + 4];
        }
    }

    // ── fuzz ─────────────────────────────────────────────────────────────────────────────────────────────

    /// the cap never exceeds kelly × exact Kelly (× 1.05) of the unreserved bankroll, whatever the kelly multiplier,
    /// token, size, partner or pending liabilities
    function testFuzz_cap_never_exceeds_exact_kelly(uint256 amount, uint16 k, uint8 which, bool viaPartner, uint256 pending)
        public
    {
        k = uint16(bound(k, 1, BPS));
        FlipperHouseBase.Params memory p = house.params();
        p.kellyBps = k;
        vm.prank(owner);
        house.setParams(p);
        address token = [address(flipperToken), address(t0), address(t5), address(t10)][which % 4];
        // some liabilities already pending
        pending = bound(pending, 0, 3);
        for (uint256 i; i < pending; ++i) {
            FlipperHouseBase.Preview memory q = house.previewFlip(address(flipperToken), 1 ether);
            _flip(bob, address(flipperToken), q.maxLiability * BPS / WIN_COST / 2);
        }
        amount = bound(amount, 1e12, 5_000_000 ether);
        bytes memory sfx = viaPartner ? _suffix("demo") : bytes("");
        FlipperHouseBase.Preview memory pv = _preview(alice, token, amount, sfx);
        if (pv.code != 0 && pv.code != 7) return; // priced out before the cap (route cost)
        uint256 share = pv.code == 0 ? _share(alice, token, amount, sfx) : 0;
        if (pv.code == 7 && viaPartner) return; // no flip to read the share from; covered by the accepted cases
        _checkCap(pv, token, share);
    }
}
