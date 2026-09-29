// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {SimDriver} from "./SimDriver.sol";

/// @notice The volume simulation on a stack deployed by the real script/Deploy.s.sol on a Robinhood Chain fork (real
///         PoolManager, WETH through the WETH wrapper, the real USDG/ETH pool, the launch whitelist listed), with
///         the launch config. Skipped unless SIM_FORK_RPC and SIM_FORK_MANIFEST are set.
///   Deploy (own anvil, not the dev stack):
///     anvil --fork-url https://rpc.ordofi.network --fork-block-number 72650000 --chain-id 31340 --port 18989
///     DEPLOYER_PRIVATE_KEY=<anvil key 0> DEV=1 ENTROPY_MODE=dice-mock V4_START_MCAP_USD=5000 V4_POOL_BPS=10000 \
///       OPENING_BUY_SUPPLY_BPS=1500 PRINCIPAL_LOCK=1 VAULT_LOCK_DAYS=30 VAULT_COOLDOWN_HOURS=48 \
///       KEEPER_ADDRESS=<makeAddr("keeper")> DEV_PAYOUT_ADDRESS=<makeAddr("devPayout")> \
///       DEPLOYMENT_FILE=deployments/sim-fork.json forge script script/Deploy.s.sol:Deploy --rpc-url \
///       http://127.0.0.1:18989 --broadcast --slow
///   Run:
///     SIM_FORK_RPC=http://127.0.0.1:18989 SIM_FORK_MANIFEST=deployments/sim-fork.json nice -n 10 forge test \
///       --match-path test/sim/ForkSim.t.sol -vv --gas-limit 9223372036854775807
contract ForkSimTest is SimDriver {
    function test_fork_volume() public {
        string memory rpc = vm.envOr("SIM_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc); // own anvil forking the dev chain, block-pinned (never the live stack itself)
        uint256 s = vm.envOr("SIM_SEED", uint256(101));
        _attachFork(s, vm.envString("SIM_FORK_MANIFEST"));
        principal0 = lock.principal();
        simStart = vm.getBlockTimestamp();
        _forkFeeBaseline();
        _logMeta();
        _logHeader();
        console2.log(GAS_HEADER);
        _logState("launch", simStart, 0);
        uint256[4] memory l = [uint256(10_000e18), 100_000e18, 1_000_000e18, 10_000_000e18];
        string[4] memory n = ["10k", "100k", "1M", "10M"];
        uint256 top = vm.envOr("SIM_LEVELS", uint256(2));
        uint256 cap = vm.envOr("SIM_MAX_FLIPS", uint256(20_000));
        for (uint256 i; i < top; ++i) {
            _driveTo(l[i], cap, 2 days);
            if (st.volUsd < l[i]) {
                _checkpoint(string.concat("cap-before-", n[i]));
                break;
            }
            _checkpoint(n[i]);
        }
        _logTrips();
        _finish();
        console2.log("breaker trips", st.breakerTrips);
    }
}
