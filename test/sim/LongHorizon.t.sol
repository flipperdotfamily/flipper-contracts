// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {SimDriver} from "./SimDriver.sol";

/// @notice Years of simulated time: a batch of flips spread over every week, the upkeep and the actors' rhythms,
///         the lock swept monthly and its excess taken quarterly. Checks: nothing overflows or gets stuck; the reward
///         accumulators match the shadow every quarter (no drift); the NAV all-time high, the vault's high-water mark
///         and POL only move up; the breaker never trips in fair play (every trip is reported); gas per flip and per
///         claim stays flat quarter after quarter (no growing loops).
///   Run: nice -n 10 forge test --match-path test/sim/LongHorizon.t.sol -vv --gas-limit 9223372036854775807
contract LongHorizonTest is SimDriver {
    uint256[8][] internal gasByQuarter;
    uint256 internal unlocksSeen;

    // each weekly step runs as an external self-call so a failure names its step
    function stepFlip() external {
        require(msg.sender == address(this));
        _randomFlip();
    }

    function stepUpkeep() external {
        require(msg.sender == address(this));
        _upkeep();
        _actors();
    }

    function stepQuarter(string calldata q) external {
        require(msg.sender == address(this));
        _checkShadow(true);
        _checkLpFees();
        _takeExcess();
        _claim(dev);
        _logState(q, simStart, lastDust);
        gasByQuarter.push(_gasSample(q));
    }

    function _named(bool ok, bytes memory err, string memory step) internal pure {
        if (ok) return;
        if (err.length == 0) revert(string.concat("empty revert in ", step));
        assembly ("memory-safe") {
            revert(add(err, 0x20), mload(err))
        }
    }

    function test_long_horizon() public {
        uint256 years_ = vm.envOr("SIM_YEARS", uint256(3));
        _start(31);
        // years of "hold" (nobody ever sells a reward) drain the pool: the realistic market sells (SIM_MARKET=hold to
        // override)
        sellRewards = keccak256(bytes(vm.envOr("SIM_MARKET", string("sell")))) == keccak256("sell");
        _logHeader();
        console2.log(GAS_HEADER);
        _logState("launch", simStart, 0);
        uint256 end = simStart + years_ * 365 days;
        uint256 week;
        uint256 lastAth;
        uint256 lastHwm;
        uint256 lastPol;
        uint256 mem = _fmp();
        while (vm.getBlockTimestamp() < end) {
            _resetFmp(mem);
            uint256 n = _randBetween(10, 60);
            uint256 step = 5 days / n;
            if (house.locked()) _unlockAfterTrip();
            for (uint256 i; i < n; ++i) {
                if (house.locked()) break;
                (bool ok, bytes memory err) = address(this).call(abi.encodeCall(this.stepFlip, ()));
                _named(ok, err, string.concat("flip, week ", vm.toString(week)));
                _advance(_randBetween(step / 2, step * 3 / 2));
            }
            {
                (bool ok, bytes memory err) = address(this).call(abi.encodeCall(this.stepUpkeep, ()));
                _named(ok, err, string.concat("upkeep/actors, week ", vm.toString(week)));
            }
            lastDust = _checkAll(principal0);
            _checkShadow(false);
            ++batches;
            ++week;
            // monotone marks (no manual resets in this run)
            if (unlocks == unlocksSeen) assertGe(uint256(house.navAth()), lastAth, "NAV ATH only rises between resets");
            unlocksSeen = unlocks;
            assertGe(vault.hwm(), lastHwm, "vault high-water mark only rises");
            assertGe(vault.protocolShares(), lastPol, "POL only grows");
            lastAth = house.navAth();
            lastHwm = vault.hwm();
            lastPol = vault.protocolShares();
            if (week % 4 == 0) _sweep(players[week % players.length]);
            if (week % 13 == 0) {
                string memory q = string.concat("Q", vm.toString(week / 13));
                (bool ok, bytes memory err) = address(this).call(abi.encodeCall(this.stepQuarter, (q)));
                _named(ok, err, q);
            }
            uint256 left = vm.getBlockTimestamp() < end ? end - vm.getBlockTimestamp() : 0;
            _advance(2 days < left ? 2 days : left); // the rest of the week
        }
        _logTrips();
        console2.log("breaker trips (each recorded, then unlocked with an ATH reset)", st.breakerTrips);
        // gas flat: flips and settlements within 15% of the first quarter's, claims and the sweep within 30% (their
        // branches depend on what is pending). Harvest isn't asserted: it swings with its branch (an ETH auction lot
        // kicked or not, a house share or not): its per-quarter samples are logged (CSV,gas) for inspection
        uint256[8] memory g0 = gasByQuarter[0];
        for (uint256 q = 1; q < gasByQuarter.length; ++q) {
            for (uint256 k; k < 7; ++k) {
                if (g0[k] == 0 || gasByQuarter[q][k] == 0) continue;
                assertLe(gasByQuarter[q][k], g0[k] * (k < 4 ? 115 : 130) / 100, "gas grows over time");
            }
        }
        _logState("end", simStart, lastDust);
        _finish();
        console2.log("weeks / flips / volume USD", week, st.flips, st.volUsd / 1e18);
    }
}
