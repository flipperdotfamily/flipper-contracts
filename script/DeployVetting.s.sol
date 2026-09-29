// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {FlipperHouse} from "../src/FlipperHouse.sol";
import {ListingPolicy} from "../src/ListingPolicy.sol";
import {V4RouteAdapter} from "../src/adapters/V4RouteAdapter.sol";
import {V3RouteAdapter} from "../src/adapters/V3RouteAdapter.sol";
import {HookitRouteAdapter} from "../src/adapters/HookitRouteAdapter.sol";
import {ILaunchpadVerifier} from "../src/interfaces/ILaunchpadVerifier.sol";
import {FlipperDeploy} from "./lib/FlipperDeploy.sol";
import {RobinhoodAddresses} from "./lib/RobinhoodAddresses.sol";
import {InkAddresses} from "./lib/InkAddresses.sol";

/// @notice Turn on the listing policy on an existing deployment: deploy a ListingPolicy, point every route adapter at
///         it, attach the chain's default verifiers (Ink: hookit), allowlist the chain's majors, and whitelist the
///         first-hop pool of every token the house already lists (so re-listing them stays permissionless).
///         Upgrade the adapters first (script/Upgrade.s.sol TARGET=v4Adapter / v3Adapter / hookitAdapter).
///         Prints the manifest keys `contracts.listingPolicy` and `contracts.hookitVerifier`.
///
///   Env: PRIVATE_KEY (owner of the house and adapters), DEPLOYMENT_FILE (default deployments/local.json)
///   On the dev fork: `cast rpc anvil_setAutomine true` first and `false` after (see dev.sh).
contract DeployVetting is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        string memory json = vm.readFile(vm.envOr("DEPLOYMENT_FILE", string("deployments/local.json")));
        bool robinhood = keccak256(bytes(vm.parseJsonString(json, ".chain"))) == keccak256("robinhood");
        FlipperDeploy.System memory s;
        s.house = FlipperHouse(payable(vm.parseJsonAddress(json, ".contracts.house")));
        s.v4 = V4RouteAdapter(vm.parseJsonAddress(json, ".contracts.v4Adapter"));
        s.hookit = HookitRouteAdapter(vm.parseJsonAddress(json, ".contracts.hookitAdapter"));
        if (vm.keyExistsJson(json, ".contracts.v3Adapter")) {
            s.v3 = V3RouteAdapter(vm.parseJsonAddress(json, ".contracts.v3Adapter"));
        }

        vm.startBroadcast(pk);
        s.policy = new ListingPolicy(vm.addr(pk));
        s.v4.setListingPolicy(s.policy);
        s.hookit.setListingPolicy(s.policy, address(s.house));
        if (address(s.v3) != address(0)) s.v3.setListingPolicy(s.policy);
        ILaunchpadVerifier[] memory vs = robinhood ? new ILaunchpadVerifier[](0) : FlipperDeploy.deployInkVerifiers();
        FlipperDeploy.applyVetting(s, vs, robinhood ? RobinhoodAddresses.trustedTokens() : InkAddresses.trustedTokens());
        uint256 n = s.house.listedTokensLength();
        for (uint256 i; i < n; ++i) {
            address token = s.house.listedTokens(i);
            (,,, PoolKey[] memory route) = s.house.tokenConfig(token);
            if (route.length != 0) s.policy.setPoolWhitelisted(route[0], true);
        }
        vm.stopBroadcast();

        console2.log("listingPolicy ", address(s.policy));
        console2.log("hookitVerifier", vs.length != 0 ? address(vs[0]) : address(0));
        console2.log("pools whitelisted for listed tokens", n);
    }
}
