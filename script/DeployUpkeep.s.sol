// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {FlipperDeploy} from "./lib/FlipperDeploy.sol";
import {RobinhoodAddresses} from "./lib/RobinhoodAddresses.sol";
import {InkAddresses} from "./lib/InkAddresses.sol";

/// @notice Switch an existing deployment to keeperless upkeep, right after upgrading the house and the router
///         (script/Upgrade.s.sol TARGET=house, TARGET=router, TARGET=lens): deploy the Dutch-auction converter (house
///         and router may kick), point both at it with the default harvest bounty and minimum lot, set the house's
///         `pendingTimeout` (0 after the upgrade: set it in the same session), hold holders' $FLIPPER in the router
///         until a distributor exists, and register the launchpad's fee claim as a harvest call.
///         Prints the manifest key `contracts.auctionConverter`.
///
///   Env: PRIVATE_KEY (owner of the house and the router), DEPLOYMENT_FILE (default deployments/local.json)
///   On the dev fork: `cast rpc anvil_setAutomine true` first and `false` after (see dev.sh).
contract DeployUpkeep is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        string memory json = vm.readFile(vm.envOr("DEPLOYMENT_FILE", string("deployments/local.json")));
        bool robinhood = keccak256(bytes(vm.parseJsonString(json, ".chain"))) == keccak256("robinhood");
        FlipperDeploy.System memory s;
        s.house = FlipperHouse(payable(vm.parseJsonAddress(json, ".contracts.house")));
        s.router = RevenueRouter(payable(vm.parseJsonAddress(json, ".contracts.router")));
        address feeSource = vm.parseJsonAddress(json, ".contracts.feeSource");
        FlipperDeploy.Config memory c;
        c.deployer = vm.addr(pk);
        c.poolManager = IPoolManager(vm.parseJsonAddress(json, ".contracts.poolManager"));

        FlipperHouseBase.Params memory p = s.house.params();
        p.pendingTimeout = robinhood
            ? RobinhoodAddresses.defaultParams().pendingTimeout
            : InkAddresses.defaultParams().pendingTimeout;

        vm.startBroadcast(pk);
        s.house.setParams(p);
        FlipperDeploy.deployConverter(c, s, s.house.flipper());
        s.router.setRewards(address(0));
        if (feeSource != address(0) && s.router.harvestCalls().length == 0) {
            s.router.addHarvestCall(
                feeSource,
                robinhood
                    ? abi.encodeWithSignature("claim()")
                    : abi.encodeWithSignature("claim(address)", address(0))
            );
        }
        vm.stopBroadcast();

        console2.log("auctionConverter", address(s.converter));
        console2.log("pendingTimeout  ", p.pendingTimeout);
    }
}
