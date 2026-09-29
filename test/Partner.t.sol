// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {FlipperBase} from "./utils/FlipperBase.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {HouseModule} from "../src/house/HouseModule.sol";
import {PartnerRegistry} from "../src/PartnerRegistry.sol";
import {IRouteAdapter} from "../src/interfaces/IRouteAdapter.sol";

/// @notice registries that misbehave: the house must treat each as "no partner" and flip normally
contract RevertingRegistry {
    function resolve(address, bytes calldata) external pure returns (uint256, uint256, uint256) {
        revert("nope");
    }

    function payoutOf(uint256) external pure returns (address) {
        return address(0);
    }
}

contract GasBurningRegistry {
    function resolve(address, bytes calldata) external pure returns (uint256, uint256, uint256) {
        while (true) {}
        return (1, 5000, 10_000);
    }
}

contract ReturnBombRegistry {
    function resolve(address, bytes calldata) external pure returns (uint256, uint256, uint256) {
        assembly {
            revert(0, 1000000)
        }
    }
}

contract ShortReturnRegistry {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 0x20)
        }
    }
}

abstract contract PartnerBase is FlipperBase {
    bytes16 internal constant MARKER = 0x80218021802180218021802180218021;
    PartnerRegistry internal registry;
    address internal partnerPayout = makeAddr("partnerPayout");
    address internal partnerController = makeAddr("partnerController");
    uint256 internal demoId;

    function setUp() public virtual override {
        super.setUp();
        registry = sys.partners;
        vm.prank(partnerController);
        demoId = registry.register("demo", partnerPayout, 5000);
        vm.prank(owner);
        registry.approve(demoId, 1); // tier 1: 10% of expected profit
    }

    function _suffix(string memory codes) internal pure returns (bytes memory) {
        return abi.encodePacked(codes, uint8(bytes(codes).length), uint8(0), MARKER);
    }

    function _flipWith(address player, address token, uint256 amount, bytes memory suffix)
        internal
        returns (uint256 id)
    {
        uint256 fee = house.randomnessFeeFor(token);
        bytes memory data =
            bytes.concat(abi.encodeCall(FlipperHouse.flip, (token, amount, 0, block.timestamp)), suffix);
        vm.prank(player);
        (bool ok, bytes memory ret) = address(house).call{value: fee}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        id = abi.decode(ret, (uint256));
    }

    function _winChance(uint256 id) internal view returns (uint256 p) {
        (,, uint16 w,,,,,,,,,) = house.flips(id);
        p = w;
    }

    function _tag(uint256 id) internal view returns (uint256 pid, uint256 share) {
        (uint32 a, uint16 b) = house.flipPartner(id);
        return (a, b);
    }

    /// expected house profit (bps of value) of a flip under its stored terms, and what the house keeps after the
    /// partner's share
    function _edges(uint256 id) internal view returns (uint256 e, uint256 kept) {
        (,, uint16 w,,, address token,,, uint128 s, uint128 b,, uint16 payout) = house.flips(id);
        if (token == address(flipperToken)) {
            e = BPS - Math.mulDiv(w, payout, BPS, Math.Rounding.Ceil);
        } else {
            uint256 h = b > s ? Math.mulDiv(b - s, BPS, uint256(b) + s, Math.Rounding.Ceil) : 0;
            e = BPS > h + 2 * uint256(w) ? BPS - h - 2 * uint256(w) : 0;
        }
        (, uint256 share) = _tag(id);
        kept = e - share;
    }
}

contract PartnerTest is PartnerBase {
    // ── registry ─────────────────────────────────────────────────────────────────────────────────────────

    function test_registration_rules() public {
        vm.expectRevert(PartnerRegistry.InvalidCode.selector);
        registry.register("Bad", partnerPayout, 0); // uppercase
        vm.expectRevert(PartnerRegistry.InvalidCode.selector);
        registry.register("a,b", partnerPayout, 0); // the ERC-8021 delimiter
        vm.expectRevert(PartnerRegistry.InvalidCode.selector);
        registry.register("", partnerPayout, 0);
        vm.expectRevert(PartnerRegistry.CodeTaken.selector);
        registry.register("demo", partnerPayout, 0);
        vm.expectRevert(PartnerRegistry.InvalidParams.selector);
        registry.register("x", partnerPayout, 10_001);
        uint256 id = registry.register("app-1_x", partnerPayout, 0);
        assertEq(uint8(registry.partner(id).status), uint8(PartnerRegistry.Status.Pending));
        vm.prank(mallory);
        vm.expectRevert();
        registry.approve(id, 3);
        vm.prank(mallory);
        vm.expectRevert(PartnerRegistry.NotController.selector);
        registry.setPayout(id, mallory);
        vm.prank(owner);
        vm.expectRevert(PartnerRegistry.InvalidParams.selector);
        registry.setTierCut(1, 5001);
    }

    function test_resolve_erc8021_vectors() public {
        (uint256 id, uint256 cut, uint256 disc) = registry.resolve(alice, _suffix("demo"));
        assertEq(id, demoId);
        assertEq(cut, 1000);
        assertEq(disc, 5000);
        // several codes: the first approved one wins
        (id,,) = registry.resolve(alice, _suffix("nobody,demo"));
        assertEq(id, demoId);
        // the helper builds the same suffix
        assertEq(registry.suffixOf("demo"), _suffix("demo"));
        // malformed tails resolve to nobody
        (id,,) = registry.resolve(alice, "");
        assertEq(id, 0);
        (id,,) = registry.resolve(alice, abi.encodePacked("demo", uint8(4), uint8(1), MARKER)); // schema 1
        assertEq(id, 0);
        (id,,) = registry.resolve(alice, abi.encodePacked("demo", uint8(4), uint8(0), bytes16(0))); // no marker
        assertEq(id, 0);
        (id,,) = registry.resolve(alice, abi.encodePacked("demo", uint8(200), uint8(0), MARKER)); // bad length
        assertEq(id, 0);
        (id,,) = registry.resolve(alice, _suffix("unknown"));
        assertEq(id, 0);
    }

    function test_resolve_status_and_self_attribution() public {
        (uint256 id,,) = registry.resolve(partnerPayout, _suffix("demo"));
        assertEq(id, 0, "payout can't attribute its own flips");
        (id,,) = registry.resolve(partnerController, _suffix("demo"));
        assertEq(id, 0, "nor the controller");
        vm.prank(owner);
        registry.setAllowSelf(demoId, true);
        (id,,) = registry.resolve(partnerPayout, _suffix("demo"));
        assertEq(id, demoId, "unless the owner allows it");

        vm.prank(owner);
        registry.setSuspended(demoId, true);
        (id,,) = registry.resolve(alice, _suffix("demo"));
        assertEq(id, 0, "suspended");
        vm.prank(partnerController);
        uint256 pending = registry.register("pend", partnerPayout, 0);
        (id,,) = registry.resolve(alice, _suffix("pend"));
        assertEq(id, 0, "pending");
        pending;
    }

    // ── pricing ──────────────────────────────────────────────────────────────────────────────────────────

    function test_partner_flip_gets_better_odds_and_emits() public {
        uint256 plain = _flip(alice, address(tokenT), 1_000_000 ether);
        uint256 base = _winChance(plain);
        // E = 10000 − h − 2·p; C = 10% E; D = 50% C; odds + D/2; the partner keeps C − D
        (,,,,,,,, uint128 s, uint128 b,,) = house.flips(plain);
        uint256 h = Math.mulDiv(b - s, BPS, uint256(b) + s, Math.Rounding.Ceil);
        uint256 e = BPS - h - 2 * base;
        uint256 c = e * 1000 / BPS;
        uint256 bonus = c * 5000 / BPS * BPS / (2 * BPS);
        assertGt(bonus, 0);
        uint256 expectedId = house.nextFlipId();
        vm.expectEmit(true, true, false, true, address(house));
        emit FlipperHouseBase.FlipPartner(expectedId, demoId, 1000, 5000, bonus, c - bonus * 2);
        uint256 id = _flipWith(alice, address(tokenT), 1_000_000 ether, _suffix("demo"));
        assertEq(id, expectedId);
        assertEq(_winChance(id), base + bonus, "odds + D/2");
        (uint256 pid, uint256 share) = _tag(id);
        assertEq(pid, demoId);
        assertEq(share, c - bonus * 2, "partner keeps C - D");
        (uint256 eAfter, uint256 kept) = _edges(id);
        assertEq(kept, e - c, "house keeps E - C");
        assertEq(eAfter, e - 2 * bonus);
    }

    function test_preview_with_suffix_shows_the_partner_odds() public {
        FlipperHouseBase.Preview memory plain = house.previewFlip(address(tokenT), 1_000_000 ether);
        bytes memory data =
            bytes.concat(abi.encodeCall(FlipperHouse.previewFlip, (address(tokenT), 1_000_000 ether)), _suffix("demo"));
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(house).call(data);
        assertTrue(ok);
        FlipperHouseBase.Preview memory withPartner = abi.decode(ret, (FlipperHouseBase.Preview));
        uint256 id = _flipWith(alice, address(tokenT), 1_000_000 ether, _suffix("demo"));
        assertGt(withPartner.winChanceBps, plain.winChanceBps);
        assertEq(withPartner.winChanceBps, _winChance(id), "preview matches the flip");
    }

    function test_edge_floor_holds_with_the_largest_cut() public {
        vm.startPrank(owner);
        registry.setTierCut(3, 5000);
        registry.approve(demoId, 3);
        vm.stopPrank();
        vm.prank(partnerController);
        registry.setDiscount(demoId, 10_000); // all of it back to players
        // token flip: E ≈ 8% at base odds; a 50% cut (4%) leaves the house above its 2% floor
        uint256 id = _flipWith(alice, address(tokenT), 1_000_000 ether, _suffix("demo"));
        (, uint256 kept) = _edges(id);
        assertGe(kept + 1, defaultParams().minHouseEdgeBps, "edge after the cut >= floor");
        // $FLIPPER flips: E = 10000 − 45%·2.05 = 7.75%: the cut is capped to 5.75% so the house keeps 2% (and at
        // that edge half Kelly allows ~0.5% of the bankroll: a 300k stake)
        uint256 f = _flipWith(alice, address(flipperToken), 300_000 ether, _suffix("demo"));
        (uint256 e, uint256 keptF) = _edges(f);
        assertGe(keptF + 1, defaultParams().minHouseEdgeBps);
        assertLe(e, 775);
    }

    function test_discount_captured_at_flip_time() public {
        uint256 id = _flipWith(alice, address(flipperToken), 1_000_000 ether, _suffix("demo"));
        (, uint256 share0) = _tag(id);
        uint256 p0 = _winChance(id);
        // everything changes before settlement
        vm.startPrank(owner);
        registry.setTierCut(1, 5000);
        registry.setSuspended(demoId, true);
        vm.stopPrank();
        vm.prank(partnerController);
        registry.setDiscount(demoId, 0);
        (, uint256 share1) = _tag(id);
        assertEq(share1, share0);
        assertEq(_winChance(id), p0);
        uint256 expected = Math.mulDiv(1_000_000 ether, share0 * BPS, BPS * (BPS - p0));
        _reveal(id, LOSS_WORD);
        assertEq(house.partnerAccrued(demoId), expected, "accrued on the flip-time share");
        _assertSolvent();
    }

    // ── accrual ──────────────────────────────────────────────────────────────────────────────────────────

    function test_accrues_on_losses_only_once_and_claims_to_payout() public {
        uint256 w = _flipWith(alice, address(flipperToken), 1_000_000 ether, _suffix("demo"));
        _reveal(w, WIN_WORD);
        assertEq(house.partnerAccrued(demoId), 0, "wins pay no partner share");

        uint256 l = _flipWith(alice, address(flipperToken), 1_000_000 ether, _suffix("demo"));
        uint256 r0 = house.rewardsAccrued();
        _reveal(l, LOSS_WORD);
        uint256 acc = house.partnerAccrued(demoId);
        assertGt(acc, 0);
        assertEq(house.partnerAccruedTotal(), acc);
        uint256 toHolders = house.rewardsAccrued() - r0;
        assertLe(acc + toHolders, 1_000_000 ether, "shares never exceed the proceeds");
        // a second delivery changes nothing
        uint64 seq = _seq(l);
        vm.expectRevert();
        entropy.reveal(provider, seq, bytes32(LOSS_WORD));
        assertEq(house.partnerAccrued(demoId), acc);
        _assertSolvent();

        vm.prank(mallory);
        assertEq(house.claimPartner(demoId), acc);
        assertEq(flipperToken.balanceOf(partnerPayout), acc);
        assertEq(house.partnerAccrued(demoId), 0);
        assertEq(house.partnerAccruedTotal(), 0);
        assertEq(house.claimPartner(demoId), 0);
        _assertSolvent();
    }

    function test_holder_share_is_proportionally_reduced() public {
        uint256 plain = _flip(alice, address(flipperToken), 1_000_000 ether);
        uint256 r0 = house.rewardsAccrued();
        _reveal(plain, LOSS_WORD);
        uint256 holdersPlain = house.rewardsAccrued() - r0;
        uint256 id = _flipWith(alice, address(flipperToken), 1_000_000 ether, _suffix("demo"));
        (uint256 e, uint256 kept) = _edges(id);
        r0 = house.rewardsAccrued();
        _reveal(id, LOSS_WORD);
        uint256 holdersPartner = house.rewardsAccrued() - r0;
        // holders get rewardsShare of (E' − A), bankroll the rest: the cut comes out of both halves
        uint256 pw = _winChance(id);
        assertApproxEqAbs(holdersPartner, Math.mulDiv(1_000_000 ether, kept * 5000, BPS * (BPS - pw)), 2);
        assertLt(holdersPartner, holdersPlain);
        e;
    }

    // ── hostile registries ───────────────────────────────────────────────────────────────────────────────

    function test_hostile_registry_means_no_partner() public {
        address[4] memory regs = [
            address(new RevertingRegistry()),
            address(new GasBurningRegistry()),
            address(new ReturnBombRegistry()),
            address(new ShortReturnRegistry())
        ];
        uint256 base = _winChance(_flip(alice, address(tokenT), 1_000_000 ether));
        for (uint256 i; i < regs.length; ++i) {
            vm.prank(owner);
            house.setPartnerRegistry(regs[i]);
            uint256 id = _flipWith(alice, address(tokenT), 1_000_000 ether, _suffix("demo"));
            (uint256 pid,) = _tag(id);
            assertEq(pid, 0);
            assertEq(_winChance(id), base);
        }
    }

    function test_no_registry_or_no_suffix_is_a_plain_flip() public {
        uint256 id = _flipWith(alice, address(tokenT), 1_000_000 ether, "");
        (uint256 pid,) = _tag(id);
        assertEq(pid, 0);
        id = _flipWith(alice, address(tokenT), 1_000_000 ether, hex"deadbeef");
        (pid,) = _tag(id);
        assertEq(pid, 0);
        vm.prank(owner);
        house.setPartnerRegistry(address(0));
        id = _flipWith(alice, address(tokenT), 1_000_000 ether, _suffix("demo"));
        (pid,) = _tag(id);
        assertEq(pid, 0);
    }

    function test_self_referral_needs_approval() public {
        vm.deal(partnerPayout, 10 ether);
        flipperToken.mint(partnerPayout, 10_000_000 ether);
        vm.prank(partnerPayout);
        flipperToken.approve(address(house), type(uint256).max);
        uint256 id = _flipWith(partnerPayout, address(flipperToken), 1_000_000 ether, _suffix("demo"));
        (uint256 pid,) = _tag(id);
        assertEq(pid, 0);
    }

    // ── module ───────────────────────────────────────────────────────────────────────────────────────────

    /// Every cold-path function reverts when called on the module directly (it only runs by delegatecall).
    function test_module_rejects_direct_calls() public {
        HouseModule m = HouseModule(payable(house.module()));
        PoolKey[] memory route = new PoolKey[](0);
        FlipperHouseBase.Params memory p = defaultParams();
        bytes[] memory calls = new bytes[](17);
        calls[0] = abi.encodeCall(HouseModule.initialize, (owner, p));
        calls[1] = abi.encodeCall(HouseModule.cancelFlip, (1));
        calls[2] = abi.encodeCall(HouseModule.listToken, (address(tokenT), IRouteAdapter(address(sys.v4))));
        calls[3] = abi.encodeCall(HouseModule.setTokenRoute, (address(tokenT), route));
        calls[4] = abi.encodeCall(HouseModule.setTokenEnabled, (address(tokenT), false));
        calls[5] = abi.encodeCall(HouseModule.resolvePendingWin, (1));
        calls[6] = abi.encodeCall(HouseModule.sweepInventory, (address(tokenT), 1));
        calls[7] = abi.encodeCall(HouseModule.writeOffInventory, (address(tokenT)));
        calls[8] = abi.encodeCall(HouseModule.setParams, (p));
        calls[9] = abi.encodeCall(HouseModule.setGuardian, (mallory));
        calls[10] = abi.encodeCall(HouseModule.setConverter, (mallory));
        calls[11] = abi.encodeCall(HouseModule.setRouteAdapter, (mallory, true));
        calls[12] = abi.encodeCall(HouseModule.setRevenueRouter, (address(0)));
        calls[13] = abi.encodeCall(HouseModule.setVault, (address(vault)));
        calls[14] = abi.encodeCall(HouseModule.setPaused, (true));
        calls[15] = abi.encodeCall(HouseModule.claimPartner, (1));
        calls[16] = abi.encodeCall(HouseModule.setPartnerRegistry, (address(0)));
        address[3] memory callers = [owner, mallory, address(house)];
        for (uint256 i; i < calls.length; ++i) {
            for (uint256 j; j < callers.length; ++j) {
                vm.prank(callers[j]);
                (bool ok,) = address(m).call(calls[i]);
                assertFalse(ok, "module callable directly");
            }
        }
        assertEq(address(m).balance, 0);
    }

    /// The house's ABI is whole: each moved function answers through the house, with the module's behaviour.
    function test_stubs_reach_the_module() public {
        vm.prank(owner);
        house.setGuardian(bob);
        assertEq(house.guardian(), bob);
        vm.prank(mallory);
        vm.expectRevert();
        house.setGuardian(mallory);
        vm.prank(mallory);
        vm.expectRevert(FlipperHouseBase.BadStatus.selector);
        house.resolvePendingWin(12345);
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        (bool ok,) = address(house).call{value: 1}(abi.encodeCall(FlipperHouse.setGuardian, (bob)));
        assertFalse(ok, "nonpayable stubs refuse value");
    }
}
