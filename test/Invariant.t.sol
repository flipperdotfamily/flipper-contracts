// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FlipperBase} from "./utils/FlipperBase.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";

/// @notice Drives random flips, random market moves, pool shutoffs, failed deliveries and random outcomes
///         through the house; the invariant suite checks it is always fully collateralised.
contract Handler is Test {
    FlipperHouseInvariantTest internal t;
    uint256[] public pending;

    constructor(FlipperHouseInvariantTest _t) {
        t = _t;
    }

    function flip(uint256 who, uint256 amountSeed, bool useFlipper) external {
        (bool ok, uint256 id) = t.doFlip(who, amountSeed, useFlipper);
        if (ok) pending.push(id);
    }

    function settle(uint256 idx, uint256 word, uint8 mode) external {
        if (pending.length == 0) return;
        idx = bound(idx, 0, pending.length - 1);
        uint256 id = pending[idx];
        pending[idx] = pending[pending.length - 1];
        pending.pop();
        t.doSettle(id, word, mode);
    }

    function market(uint256 amount, bool pump) external {
        t.doMarket(amount, pump);
    }

    function toggle(uint8 mask) external {
        t.doToggle(mask);
    }

    function keeperOps(uint256 seed) external {
        t.doKeeper(seed);
    }

    function pendingLength() external view returns (uint256) {
        return pending.length;
    }
}

contract FlipperHouseInvariantTest is FlipperBase {
    Handler internal handler;
    uint256[] internal pendingWins;

    function setUp() public override {
        super.setUp();
        handler = new Handler(this);
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](5);
        sels[0] = Handler.flip.selector;
        sels[1] = Handler.settle.selector;
        sels[2] = Handler.market.selector;
        sels[3] = Handler.toggle.selector;
        sels[4] = Handler.keeperOps.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function doFlip(uint256 who, uint256 amountSeed, bool useFlipper) external returns (bool, uint256) {
        address p = [alice, bob, mallory][who % 3];
        address token = useFlipper ? address(flipperToken) : address(tokenT);
        uint256 amount = useFlipper ? bound(amountSeed, 1 ether, 4_000_000 ether) : bound(amountSeed, 1 ether, 40_000_000 ether);
        FlipperHouseBase.Preview memory pv = house.previewFlip(token, amount);
        if (pv.code != 0) return (false, 0);
        return (true, _flip(p, token, amount));
    }

    function doSettle(uint256 id, uint256 word, uint8 mode) external {
        if (_status(id) != FlipperHouseBase.Status.Pending) return;
        if (mode % 5 == 0) {
            // failed first delivery, then recovery (safe mode)
            vm.mockCallRevert(address(house), abi.encodeWithSelector(FlipperHouse.onRandomness.selector), "x");
            _reveal(id, word);
            vm.clearMockedCalls();
            entropy.reveal(provider, _seq(id), bytes32(word));
        } else {
            _reveal(id, word);
        }
        if (_status(id) == FlipperHouseBase.Status.WinPending) pendingWins.push(id);
    }

    function doMarket(uint256 amount, bool pump) external {
        if (pump) _buyWithEth(tPool, bound(amount, 0.01 ether, 30 ether));
        else _sellForEth(tPool, bound(amount, 1e5 ether, 300_000_000 ether));
    }

    function doToggle(uint8 mask) external {
        toggle.set(mask & 1 != 0, mask & 2 != 0, mask & 4 != 0, mask & 8 != 0);
    }

    /// permissionless upkeep by an arbitrary caller: sweep inventory into the auction (sometimes taking the lot),
    /// resolve a pending win (sometimes after its timeout), flush the holders' share
    function doKeeper(uint256 seed) external {
        if (seed % 4 != 0) toggle.set(false, false, false, false);
        uint256 inv = house.inventory(address(tokenT));
        if (inv != 0) {
            uint256 amt = bound(seed, 1, inv);
            vm.prank(mallory);
            house.sweepInventory(address(tokenT), amt);
            if (seed % 2 == 0) {
                uint256 lotId = converter.lotsLength() - 1;
                vm.warp(vm.getBlockTimestamp() + 3 hours);
                uint256 p = converter.priceOf(lotId);
                vm.startPrank(bob);
                flipperToken.approve(address(converter), type(uint256).max);
                converter.take(lotId, amt, p);
                vm.stopPrank();
            }
        }
        if (pendingWins.length != 0) {
            uint256 id = pendingWins[pendingWins.length - 1];
            pendingWins.pop();
            if (_status(id) == FlipperHouseBase.Status.WinPending) {
                if (seed % 3 == 1) vm.warp(vm.getBlockTimestamp() + 1 days);
                vm.prank(mallory);
                try house.resolvePendingWin(id) {} catch {}
                if (_status(id) == FlipperHouseBase.Status.WinPending) pendingWins.push(id);
            }
        }
        if (seed % 3 == 0) house.flushRewards();
    }

    function invariant_solvent() public view {
        _assertSolvent();
    }

    function invariant_reserved_matches_open_liabilities() public view {
        assertLe(house.reserved(), house.treasury());
    }
}
