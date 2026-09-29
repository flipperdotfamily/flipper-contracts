// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {PartnerBase} from "./Partner.t.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";

/// @notice Hot-path gas of the house (flip request and settlement), logged for before/after comparisons.
///         `forge test --match-contract HouseGasTest -vv`
contract HouseGasTest is PartnerBase {
    uint256 internal constant T_AMOUNT = 1_000_000 ether;
    uint256 internal constant F_AMOUNT = 1_000_000 ether;

    function _flipGas(address token, uint256 amount, bytes memory suffix) internal returns (uint256 id, uint256 gasUsed) {
        uint256 fee = house.randomnessFeeFor(token);
        bytes memory data = bytes.concat(
            abi.encodeCall(FlipperHouse.flip, (token, amount, 0, block.timestamp)), suffix
        );
        vm.prank(alice);
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = address(house).call{value: fee}(data);
        gasUsed = g - gasleft();
        require(ok, "flip failed");
        id = abi.decode(ret, (uint256));
    }

    function _previewGas(address token, uint256 amount, bytes memory suffix) internal returns (uint256 gasUsed) {
        bytes memory data = bytes.concat(abi.encodeCall(FlipperHouse.previewFlip, (token, amount)), suffix);
        vm.prank(alice);
        uint256 g = gasleft();
        (bool ok,) = address(house).call(data);
        gasUsed = g - gasleft();
        require(ok, "preview failed");
    }

    function _settleGas(uint256 id, uint256 word) internal returns (uint256 gasUsed) {
        uint256 g = gasleft();
        _reveal(id, word);
        gasUsed = g - gasleft();
    }

    function _run(string memory label, bytes memory suffix) internal {
        // warm-up flip so every run measures the same storage temperature
        (uint256 w,) = _flipGas(address(tokenT), T_AMOUNT, suffix);
        _reveal(w, LOSS_WORD);

        console2.log(string.concat(label, " preview token"), _previewGas(address(tokenT), T_AMOUNT, suffix));
        console2.log(string.concat(label, " preview FLIPPER"), _previewGas(address(flipperToken), F_AMOUNT, suffix));
        (uint256 id, uint256 g) = _flipGas(address(tokenT), T_AMOUNT, suffix);
        console2.log(string.concat(label, " flip token"), g);
        console2.log(string.concat(label, " settle token win"), _settleGas(id, WIN_WORD));
        (id,) = _flipGas(address(tokenT), T_AMOUNT, suffix);
        console2.log(string.concat(label, " settle token loss"), _settleGas(id, LOSS_WORD));
        (id, g) = _flipGas(address(flipperToken), F_AMOUNT, suffix);
        console2.log(string.concat(label, " flip FLIPPER"), g);
        console2.log(string.concat(label, " settle FLIPPER win"), _settleGas(id, WIN_WORD));
        (id,) = _flipGas(address(flipperToken), F_AMOUNT, suffix);
        console2.log(string.concat(label, " settle FLIPPER loss"), _settleGas(id, LOSS_WORD));
    }

    function test_gas_hot_path() public {
        _run("[no partner]", "");
    }

    function test_gas_hot_path_edge_schedule() public {
        vm.startPrank(owner);
        house.setEdgeSchedule(FlipperHouseBase.EdgeSchedule(10 ether, 350 ether, 4500, 4750, 20_500, 20_000));
        vm.stopPrank();
        _run("[edge schedule]", "");
    }

    function test_gas_hot_path_partner() public {
        _run("[partner demo]", _suffix("demo"));
    }
}
