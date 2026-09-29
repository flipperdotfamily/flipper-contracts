// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {FlipperHouse} from "../src/FlipperHouse.sol";
import {HouseModule} from "../src/house/HouseModule.sol";
import {TreasuryVault} from "../src/TreasuryVault.sol";
import {PartnerRegistry} from "../src/PartnerRegistry.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {FlipperLens} from "../src/lens/FlipperLens.sol";
import {PythEntropyAdapter} from "../src/randomness/PythEntropyAdapter.sol";
import {HookitRouteAdapter} from "../src/adapters/HookitRouteAdapter.sol";
import {V4RouteAdapter} from "../src/adapters/V4RouteAdapter.sol";
import {V3RouteAdapter} from "../src/adapters/V3RouteAdapter.sol";

/// @notice Deploy a new implementation for one proxy and upgrade it (or print the ProxyAdmin calldata to
///         schedule through a timelock / multisig).
///
///   Always run `script/storage-layout.sh --check` first: storage must stay append-only.
///
///   Env
///     PRIVATE_KEY          broadcaster (must own the ProxyAdmin unless SCHEDULE_ONLY=1)
///     DEPLOYMENT_FILE      manifest with contract addresses (default deployments/local.json)
///     TARGET               house | router | randomness | hookitAdapter | v4Adapter | v3Adapter | lens | treasuryVault |
///                          partnerRegistry
///     SCHEDULE_ONLY        1 → only deploy the implementation and print (proxyAdmin, calldata)
///     UPGRADE_CALLDATA     optional initializer/migration call (hex), default empty
contract Upgrade is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        string memory file = vm.envOr("DEPLOYMENT_FILE", string("deployments/local.json"));
        string memory json = vm.readFile(file);
        string memory target = vm.envString("TARGET");
        bytes memory data = vm.envOr("UPGRADE_CALLDATA", bytes(""));
        bool scheduleOnly = vm.envOr("SCHEDULE_ONLY", uint256(0)) == 1;

        address proxy = vm.parseJsonAddress(json, string.concat(".contracts.", target));
        ProxyAdmin admin = ProxyAdmin(address(uint160(uint256(vm.load(proxy, ERC1967Utils.ADMIN_SLOT)))));
        address oldImpl = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));

        vm.startBroadcast(pk);
        address impl = _deployImpl(target, json, proxy);
        bytes memory call = abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(proxy), impl, data));
        if (!scheduleOnly) {
            admin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), impl, data);
        }
        vm.stopBroadcast();

        console2.log("proxy       ", proxy);
        console2.log("proxyAdmin  ", address(admin));
        console2.log("old impl    ", oldImpl);
        console2.log("new impl    ", impl);
        if (scheduleOnly) {
            console2.log("schedule this call on the ProxyAdmin owner (timelock / multisig):");
            console2.logBytes(call);
        }
    }

    function _deployImpl(string memory target, string memory json, address proxy) internal returns (address) {
        bytes32 t = keccak256(bytes(target));
        IPoolManager pm = IPoolManager(vm.parseJsonAddress(json, ".contracts.poolManager"));
        if (t == keccak256("house")) {
            FlipperHouse h = FlipperHouse(payable(proxy));
            // immutables must be carried over unchanged
            // the cold paths live in a HouseModule the house delegatecalls: deploy a fresh one with the new code
            address m = address(new HouseModule(pm, h.flipper(), h.randomness()));
            return address(new FlipperHouse(pm, h.flipper(), h.randomness(), m));
        }
        if (t == keccak256("router")) return address(new RevenueRouter(pm));
        if (t == keccak256("randomness")) return address(new PythEntropyAdapter());
        if (t == keccak256("hookitAdapter")) return address(new HookitRouteAdapter());
        if (t == keccak256("lens")) return address(new FlipperLens());
        if (t == keccak256("v4Adapter")) return address(new V4RouteAdapter());
        if (t == keccak256("v3Adapter")) return address(new V3RouteAdapter());
        if (t == keccak256("treasuryVault")) return address(new TreasuryVault());
        if (t == keccak256("partnerRegistry")) return address(new PartnerRegistry());
        revert("unknown TARGET");
    }
}
