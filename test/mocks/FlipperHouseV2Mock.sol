// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {FlipperHouse} from "../../src/FlipperHouse.sol";
import {IRandomnessAdapter} from "../../src/interfaces/IRandomness.sol";

/// @notice A next version of the house: same storage, one appended variable, one new function.
contract FlipperHouseV2Mock is FlipperHouse {
    uint256 public appendedV2Var;

    constructor(IPoolManager pm, IERC20 f, IRandomnessAdapter r, address m) FlipperHouse(pm, f, r, m) {}

    function version() external pure returns (uint256) {
        return 2;
    }

    function setAppended(uint256 v) external onlyOwner {
        appendedV2Var = v;
    }
}
