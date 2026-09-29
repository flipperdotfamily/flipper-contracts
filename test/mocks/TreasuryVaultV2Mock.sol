// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TreasuryVault} from "../../src/TreasuryVault.sol";

/// @notice A next version of the staking vault: same storage, one appended variable, one new function.
contract TreasuryVaultV2Mock is TreasuryVault {
    uint256 public appendedV2Var;

    function version() external pure returns (uint256) {
        return 2;
    }

    function setAppended(uint256 v) external onlyOwner {
        appendedV2Var = v;
    }
}
