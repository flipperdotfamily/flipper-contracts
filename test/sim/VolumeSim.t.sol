// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {SimDriver} from "./SimDriver.sol";

/// @notice Cumulative-volume simulation: from launch to ~$10k, $100k, $1M and $10M of flip volume (USD at the pool's
///         spot price when each flip is made, ETH at the fork's $2,686.81), one seed per test. At every level: the
///         7-day stream accrues fully, every holder's and staker's rewards are checked against the shadow, the
///         PrincipalLock is swept (anyone) and its excess taken (devAddress), and the state is logged as CSV.
///   Run (one at a time, it is long):
///     nice -n 10 forge test --match-path test/sim/VolumeSim.t.sol --match-test test_volume_seed1 -vv \
///       --gas-limit 9223372036854775807
contract VolumeSimTest is SimDriver {
    uint256 internal constant MAX_FLIPS = 60_000;

    function _levels() internal pure returns (uint256[4] memory l, string[4] memory n) {
        l = [uint256(10_000e18), 100_000e18, 1_000_000e18, 10_000_000e18];
        n = ["10k", "100k", "1M", "10M"];
    }

    function _volume(uint256 _seed) internal {
        _start(_seed);
        _logHeader();
        console2.log(GAS_HEADER);
        _logState("launch", simStart, 0);
        (uint256[4] memory l, string[4] memory n) = _levels();
        uint256 cap = vm.envOr("SIM_MAX_FLIPS", MAX_FLIPS);
        uint256 top = vm.envOr("SIM_LEVELS", uint256(4));
        for (uint256 i; i < top; ++i) {
            _driveTo(l[i], cap, 2 days);
            if (st.volUsd < l[i]) {
                console2.log("flip cap reached before level", n[i]);
                _checkpoint(string.concat("cap-before-", n[i]));
                break;
            }
            _checkpoint(n[i]);
        }
        _logTrips();
        _finish();
        console2.log("breaker trips (each recorded, then unlocked with an ATH reset)", st.breakerTrips);
    }

    function test_volume_seed1() public {
        _volume(1);
    }

    function test_volume_seed2() public {
        _volume(2);
    }

    function test_volume_seed3() public {
        _volume(3);
    }

    /// SIM_SEED picks any seed (e.g. more seeds in a loop from the shell)
    function test_volume_env_seed() public {
        _volume(vm.envOr("SIM_SEED", uint256(4)));
    }
}
