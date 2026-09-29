// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {ListingPolicy} from "../src/ListingPolicy.sol";
import {V4RouteAdapter} from "../src/adapters/V4RouteAdapter.sol";
import {FlipperDeploy} from "./lib/FlipperDeploy.sol";

/// @notice Give WETH a 1:1 route to native ETH on an existing deployment: deploy the WethWrapperHook (mined address,
///         CREATE2 deployer), create its pool, pin the hook and whitelist the pool in the ListingPolicy, then list
///         WETH through the v4 adapter (anyone could do this last step). Upgrade the v4 adapter first
///         (script/Upgrade.s.sol TARGET=v4Adapter). Prints the manifest key `contracts.wethWrapperHook`.
///
///   Env: PRIVATE_KEY (owner of the ListingPolicy), DEPLOYMENT_FILE (default deployments/local.json)
///   On the dev fork: `cast rpc anvil_setAutomine true` first and `false` after (see dev.sh).
contract DeployWethWrapper is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        string memory json = vm.readFile(vm.envOr("DEPLOYMENT_FILE", string("deployments/local.json")));
        FlipperDeploy.System memory s;
        s.house = FlipperHouse(payable(vm.parseJsonAddress(json, ".contracts.house")));
        s.v4 = V4RouteAdapter(vm.parseJsonAddress(json, ".contracts.v4Adapter"));
        s.policy = ListingPolicy(vm.parseJsonAddress(json, ".contracts.listingPolicy"));
        address weth = vm.parseJsonAddress(json, ".contracts.weth");
        FlipperDeploy.Config memory c;
        c.poolManager = IPoolManager(vm.parseJsonAddress(json, ".contracts.poolManager"));

        vm.startBroadcast(pk);
        PoolKey memory key = FlipperDeploy.deployWethWrapper(c, s, weth, FlipperDeploy.CREATE2_DEPLOYER);
        s.v4.registerAndList(weth, key);
        vm.stopBroadcast();

        FlipperHouseBase.Preview memory pv = s.house.previewFlip(weth, 0.01 ether);
        console2.log("wethWrapperHook ", address(s.wethWrapper));
        console2.log("WETH route cost bps (0.01 WETH)", pv.routeCostBps);
        console2.log("WETH win chance bps", pv.winChanceBps);
    }
}
