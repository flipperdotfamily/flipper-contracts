// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PartnerBase} from "./Partner.t.sol";
import {GasSearch} from "./utils/GasSearch.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {MockEntropyV2} from "../src/mocks/MockEntropyV2.sol";

/// @notice Calls whose failure the house swallows must still run when a transaction is sent with exactly its
///         `eth_estimateGas` result: a gas floor in front of each makes the estimate include it.
contract GasFloorsTest is PartnerBase, GasSearch {
    function _flipData(address token, uint256 amount, bytes memory suffix) internal view returns (bytes memory) {
        return bytes.concat(abi.encodeCall(FlipperHouse.flip, (token, amount, 0, block.timestamp)), suffix);
    }

    /// a flip with a partner suffix, sent at its estimate, is attributed (the registry lookup isn't starved)
    function test_partner_lookup_runs_at_the_estimate() public {
        uint256 fee = house.randomnessFeeFor(address(tokenT));
        uint256 id = house.nextFlipId();
        _callAtEstimate(alice, address(house), _flipData(address(tokenT), 1_000_000 ether, _suffix("demo")), fee);
        (uint32 pid,) = house.flipPartner(id);
        assertEq(pid, demoId);
    }

    /// a delivery relayed at its estimate settles in kind (the swaps aren't starved into a degraded settlement)
    function test_settlement_runs_in_kind_at_the_estimate() public {
        uint256 w = _flip(alice, address(tokenT), 1_000_000 ether);
        _callAtEstimate(
            provider, address(entropy), abi.encodeCall(MockEntropyV2.reveal, (provider, _seq(w), bytes32(WIN_WORD))), 0
        );
        assertEq(uint8(_status(w)), uint8(FlipperHouseBase.Status.Won), "win bought in kind");
        uint256 l = _flip(alice, address(tokenT), 1_000_000 ether);
        _callAtEstimate(
            provider, address(entropy), abi.encodeCall(MockEntropyV2.reveal, (provider, _seq(l), bytes32(LOSS_WORD))), 0
        );
        assertEq(uint8(_status(l)), uint8(FlipperHouseBase.Status.Lost), "loss sold, not left as inventory");
    }

    /// resolving a pending win at its estimate still attempts the in-kind buy (not straight to the fallback)
    function test_resolve_buys_in_kind_at_the_estimate() public {
        uint256 id = _flip(alice, address(tokenT), 1_000_000 ether);
        toggle.set(true, true, false, false);
        _reveal(id, WIN_WORD);
        toggle.set(false, false, false, false);
        vm.warp(vm.getBlockTimestamp() + 2 days); // the $FLIPPER fallback is available too
        _callAtEstimate(mallory, address(house), abi.encodeCall(FlipperHouse.resolvePendingWin, (id)), 0);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Won));
    }

    /// sweeping at the estimate really moves the tokens (a starved transfer would read as "stuck")
    function test_sweep_moves_inventory_at_the_estimate() public {
        uint256 id = _flip(alice, address(tokenT), 1_000_000 ether);
        toggle.set(true, true, false, false);
        _reveal(id, LOSS_WORD);
        toggle.set(false, false, false, false);
        _callAtEstimate(mallory, address(house), abi.encodeCall(FlipperHouse.sweepInventory, (address(tokenT), 1_000_000 ether)), 0);
        assertEq(house.inventory(address(tokenT)), 0);
        assertEq(tokenT.balanceOf(address(converter)), 1_000_000 ether);
    }

    /// router: harvest at its estimate flushes the house share and runs every harvest call
    function test_harvest_flushes_at_the_estimate() public {
        uint256 l = _flip(alice, address(flipperToken), 1_000_000 ether);
        _reveal(l, LOSS_WORD);
        assertGt(house.rewardsAccrued(), 0);
        _callAtEstimate(mallory, address(router), abi.encodeWithSignature("harvest()"), 0);
        assertEq(house.rewardsAccrued(), 0, "flushed");
        assertGt(router.rewardsFlipperPending(), 0);
    }
}
