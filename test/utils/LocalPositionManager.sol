// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

/// @notice A local Uniswap v4 PositionManager for unit tests: the canonical Permit2 bytecode etched at its address, then
///         v4-periphery's PositionManager (no descriptor, no WETH) on `pm`, from its artifact (test/utils/PosmArtifacts.sol).
library LocalPositionManager {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function deploy(IPoolManager pm) internal returns (address) {
        if (PERMIT2.code.length == 0) new DeployPermit2().deployPermit2();
        return vm.deployCode(
            "out/PositionManager.sol/PositionManager.json", abi.encode(pm, PERMIT2, uint256(0), address(0), address(0))
        );
    }
}
