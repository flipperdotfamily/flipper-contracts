// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {FlipperHouse} from "../src/FlipperHouse.sol";
import {V4RouteAdapter} from "../src/adapters/V4RouteAdapter.sol";
import {FlipperDeploy} from "./lib/FlipperDeploy.sol";
import {RobinhoodAddresses} from "./lib/RobinhoodAddresses.sol";
import {InkAddresses} from "./lib/InkAddresses.sol";

/// @notice Add Uniswap v3 routing (V3BridgeHook + V3RouteAdapter) to an existing deployment: deploys both, sets the
///         adapter's $FLIPPER pool and USD quote route from the V4RouteAdapter's, allows it on the house, and prints
///         the manifest keys (`contracts.v3Adapter`, `contracts.v3Bridge`). The house must run an implementation
///         whose V4SwapEngine pre-pays exact inputs (upgrade it first: script/Upgrade.s.sol TARGET=house).
///
///   Env: PRIVATE_KEY (owner of the house and deployer of the adapter), DEPLOYMENT_FILE (default
///        deployments/local.json), PROXY_ADMIN_OWNER (default: the broadcaster)
///   On the dev fork: `cast rpc anvil_setAutomine true` first and `false` after (see dev.sh).
contract DeployV3 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        string memory json = vm.readFile(vm.envOr("DEPLOYMENT_FILE", string("deployments/local.json")));
        FlipperHouse house = FlipperHouse(payable(vm.parseJsonAddress(json, ".contracts.house")));
        V4RouteAdapter v4 = V4RouteAdapter(vm.parseJsonAddress(json, ".contracts.v4Adapter"));
        bool robinhood = keccak256(bytes(vm.parseJsonString(json, ".chain"))) == keccak256("robinhood");
        address v3Factory = robinhood ? RobinhoodAddresses.V3_FACTORY : InkAddresses.V3_FACTORY;
        address weth = robinhood ? RobinhoodAddresses.WETH : InkAddresses.WETH;

        FlipperDeploy.Config memory c;
        c.poolManager = IPoolManager(vm.parseJsonAddress(json, ".contracts.poolManager"));
        c.deployer = deployer;
        c.owner = deployer;
        c.proxyAdminOwner = vm.envOr("PROXY_ADMIN_OWNER", deployer);
        FlipperDeploy.System memory s;
        s.house = house;
        s.v4 = v4;

        vm.startBroadcast(pk);
        FlipperDeploy.deployV3(c, s, v3Factory, weth, FlipperDeploy.CREATE2_DEPLOYER);
        s.v3.setFlipperPool(v4.flipperPool());
        address[] memory quotes = v4.quoteCurrencies();
        for (uint256 i; i < quotes.length; ++i) {
            s.v3.setQuote(quotes[i], v4.quotePool(quotes[i]));
        }
        vm.stopBroadcast();

        console2.log("v3 bridge hook ", address(s.v3Bridge));
        console2.log("v3 route adapter", address(s.v3));
        console2.log("manifest: contracts.v3Adapter / contracts.v3Bridge");
    }
}
