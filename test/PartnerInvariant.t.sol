// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PartnerBase} from "./Partner.t.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {PartnerRegistry} from "../src/PartnerRegistry.sol";

/// @notice Random partner flips (codes, tiers, discounts, self-attribution), settlements, claims and mid-flight
///         registry changes. The house stays solvent, partner accounting adds up, no attributed flip is priced below
///         the house-edge floor, and no settlement gets stuck (shares never exceed a loss's proceeds).
contract PartnerHandler is Test {
    PartnerInvariantTest internal t;
    uint256[] public pending;
    uint256 public floorViolations;
    uint256 public stuck;

    constructor(PartnerInvariantTest _t) {
        t = _t;
    }

    function flip(uint256 who, uint256 amountSeed, uint256 codeSeed, bool useFlipper) external {
        (bool ok, uint256 id, bool broke) = t.doFlip(who, amountSeed, codeSeed, useFlipper);
        if (ok) pending.push(id);
        if (broke) floorViolations++;
    }

    function settle(uint256 idx, uint256 word) external {
        if (pending.length == 0) return;
        idx = bound(idx, 0, pending.length - 1);
        uint256 id = pending[idx];
        pending[idx] = pending[pending.length - 1];
        pending.pop();
        if (!t.doSettle(id, word)) stuck++;
    }

    function mutate(uint256 seed) external {
        t.doMutate(seed);
    }

    function claim(uint256 seed) external {
        t.doClaim(seed);
    }
}

contract PartnerInvariantTest is PartnerBase {
    PartnerHandler internal handler;
    uint256[] internal ids;
    string[5] internal codes = ["demo", "pa", "pb", "nobody", ""];

    function setUp() public override {
        super.setUp();
        vm.startPrank(partnerController);
        ids.push(demoId);
        ids.push(registry.register("pa", makeAddr("payA"), 0));
        ids.push(registry.register("pb", makeAddr("payB"), 10_000));
        vm.stopPrank();
        vm.startPrank(owner);
        registry.setTierCut(2, 3000); // only the default tier (1) has a cut out of the box
        registry.approve(ids[1], 2);
        registry.approve(ids[2], 3);
        registry.setTierCut(3, 5000);
        vm.stopPrank();
        handler = new PartnerHandler(this);
        targetContract(address(handler));
    }

    function doFlip(uint256 who, uint256 amountSeed, uint256 codeSeed, bool useFlipper)
        external
        returns (bool, uint256, bool)
    {
        address p = [alice, bob, mallory, partnerPayout][who % 4];
        if (p == partnerPayout && flipperToken.balanceOf(p) == 0) {
            flipperToken.mint(p, 50_000_000 ether);
            tokenT.mint(p, 500_000_000 ether);
            vm.deal(p, 100 ether);
            vm.startPrank(p);
            flipperToken.approve(address(house), type(uint256).max);
            tokenT.approve(address(house), type(uint256).max);
            vm.stopPrank();
        }
        address token = useFlipper ? address(flipperToken) : address(tokenT);
        uint256 amount = useFlipper ? bound(amountSeed, 1 ether, 4_000_000 ether) : bound(amountSeed, 1 ether, 40_000_000 ether);
        FlipperHouseBase.Preview memory pv = house.previewFlip(token, amount);
        if (pv.code != 0) return (false, 0, false);
        string memory code = codes[codeSeed % codes.length];
        uint256 id = _flipWith(p, token, amount, bytes(code).length == 0 ? bytes("") : _suffix(code));
        (, uint256 kept) = _edges(id);
        (uint256 pid,) = _tag(id);
        bool broke = pid != 0 && kept + 1 < defaultParams().minHouseEdgeBps;
        return (true, id, broke);
    }

    function doSettle(uint256 id, uint256 word) external returns (bool settled) {
        if (_status(id) != FlipperHouseBase.Status.Pending) return true;
        _reveal(id, word);
        return _status(id) != FlipperHouseBase.Status.Pending;
    }

    function doMutate(uint256 seed) external {
        uint256 id = ids[seed % ids.length];
        uint256 action = (seed >> 8) % 5;
        if (action == 0) {
            vm.prank(partnerController);
            registry.setDiscount(id, uint16((seed >> 16) % 10_001));
        } else if (action == 1) {
            vm.prank(owner);
            registry.setTierCut(uint8(1 + (seed >> 16) % 3), uint16((seed >> 24) % 5001));
        } else if (action == 2) {
            vm.prank(owner);
            registry.approve(id, uint8(1 + (seed >> 16) % 3));
        } else if (action == 3) {
            vm.prank(owner);
            registry.setSuspended(id, true);
        } else {
            vm.prank(owner);
            registry.setAllowSelf(id, seed % 2 == 0);
        }
    }

    function doClaim(uint256 seed) external {
        house.claimPartner(ids[seed % ids.length]);
    }

    function invariant_solvent() public view {
        _assertSolvent();
    }

    function invariant_partner_accounting_adds_up() public view {
        uint256 sum;
        for (uint256 i; i < ids.length; ++i) {
            sum += house.partnerAccrued(ids[i]);
        }
        assertEq(sum, house.partnerAccruedTotal());
    }

    function invariant_edge_after_cut_never_below_floor() public view {
        assertEq(handler.floorViolations(), 0);
    }

    function invariant_settlements_never_stuck() public view {
        assertEq(handler.stuck(), 0);
    }
}
