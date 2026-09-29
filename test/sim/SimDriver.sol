// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {PrincipalLock} from "../../src/PrincipalLock.sol";
import {FlipperHouse} from "../../src/FlipperHouse.sol";
import {TreasuryVault} from "../../src/TreasuryVault.sol";
import {SimBase} from "./SimBase.sol";
import {LiquidityKeeper} from "../../src/LiquidityKeeper.sol";

/// @notice The simulation loop on top of SimBase: batches of random flips with time between them, the permissionless
///         upkeep after each batch, holders / stakers / partners acting at their own rhythm, invariant checks after
///         every batch, and volume checkpoints (the 7-day stream accrues fully, fee claims are checked against the
///         shadow, then the lock is swept and its excess taken).
abstract contract SimDriver is SimBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal principal0;
    uint256 internal simStart;
    uint256 internal batches;
    uint256 internal lastDust;
    uint256 internal fg0Start; // the $FLIPPER pool's fee growth (ETH leg) at launch
    uint256 internal fg1Start;
    bool internal staker0In;
    bool internal staker1In;
    uint256 internal staker1Phase;

    // gas samples
    string internal constant GAS_HEADER =
        "CSV,gas,seed,label,flips,simDays,flipFlipper,settleFlipper,flipWeth,settleWeth,claimHolder,claimVault,sweepLock,harvest";

    function _start(uint256 _seed) internal {
        _deploy(_seed);
        principal0 = lock.principal();
        simStart = vm.getBlockTimestamp();
        // fee growth counts from the pool's creation (the opening buy and the setup buys paid fees too; every one of
        // them is harvested later): the baseline is 0
        (fg0Start, fg1Start) = (0, 0);
        _logMeta();
    }

    /// @dev fork: fee growth counts from the position's last collection before the simulation
    function _forkFeeBaseline() internal {
        LiquidityKeeper lk = LiquidityKeeper(payable(d.liquidityKeeper));
        (, fg0Start, fg1Start) = manager.getPositionInfo(
            fKey.toId(), address(lk.positionManager()), lpLower, lpUpper, bytes32(lk.tokenId())
        );
    }

    /// @dev pool geometry and launch terms: enough to rebuild the $FLIPPER pool's curve offline
    function _logMeta() internal view {
        if (trace) {
            console2.log(FLIP_HEADER);
            console2.log(ACT_HEADER);
            console2.log(CKPT_HEADER);
        }
        console2.log(
            "CSV,meta,seed,liquidity,sqrtLowerX96,sqrtUpperX96,sqrtLaunchX96,openingBuyEth,openingBuyFlipper,ethUsd8,supply,lockPrincipal,forked,lpTickLower,lpTickUpper,treasury,navUnits,lockMinTreasury,vaultTotalSupply,protocolShares,hwm,startTime"
        );
        uint128 liq = manager.getLiquidity(fKey.toId());
        string memory s = _c(_c("CSV,meta", seed), liq);
        s = _c(_c(s, uint256(TickMath.getSqrtPriceAtTick(lpLower))), uint256(TickMath.getSqrtPriceAtTick(lpUpper)));
        s = _c(_c(_c(s, uint256(d.sqrtPriceX96)), d.openingBuyEth), d.bought);
        s = _c(_c(_c(s, ethUsd), SUPPLY), lock.principal());
        s = _cs(_cs(_c(s, forked ? 1 : 0), vm.toString(lpLower)), vm.toString(lpUpper));
        s = _c(_c(_c(s, house.treasury()), house.navUnits()), house.lockMinTreasury());
        s = _c(_c(_c(_c(s, vault.totalSupply()), vault.protocolShares()), vault.hwm()), simStart);
        console2.log(s);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // The loop
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev flip until cumulative volume reaches `usdTarget` (USD × 1e18) or `maxFlips`
    function _driveTo(uint256 usdTarget, uint256 maxFlips, uint256 gapMax) internal {
        uint256 idle;
        uint256 mem = _fmp();
        while (st.volUsd < usdTarget && st.flips < maxFlips) {
            uint256 f0 = st.flips;
            _batch(usdTarget, gapMax);
            _resetFmp(mem);
            idle = st.flips == f0 ? idle + 1 : 0;
            require(idle < 20, house.locked() ? "stalled: breaker locked" : "stalled: every flip refused");
        }
    }

    /// @dev a breaker trip in fair play: recorded (`trips`), then the unlocker lifts it after a day, re-basing the ATH
    bool internal autoUnlock = true;
    uint256 internal unlocks;

    function _unlockAfterTrip() internal {
        _advance(1 days); // the unlocker's reaction time (lots don't clear while locked)
        _unlockReset();
        _wasLocked = false;
        ++unlocks;
        _act("unlock", deployerAddr, trips.length, _nav(), house.navAth(), 0, 0, 0);
    }

    function _batch(uint256 usdTarget, uint256 gapMax) internal {
        if (house.locked() && autoUnlock) _unlockAfterTrip();
        uint256 n = _randBetween(20, 80);
        for (uint256 i; i < n && st.volUsd < usdTarget; ++i) {
            if (house.locked()) break;
            _randomFlip();
            _advance(_randBetween(2, 40));
        }
        _upkeep();
        _actors();
        if (!house.locked()) _ownerRepriceMinLiability();
        lastDust = _checkAll(principal0);
        _checkShadow(false);
        ++batches;
        _advance(_randBetween(1 hours, gapMax));
    }

    /// @dev holders, stakers and partners, each at its own rhythm
    function _actors() internal {
        if (house.locked()) return;
        if (sellRewards) {
            // mercenary market: every reward recipient claims and sells every batch
            for (uint256 i; i < tracked.length; ++i) {
                address a = tracked[i];
                if (a != address(lock) && a != deployerAddr && token.claimable(a) != 0) _claim(a);
            }
            for (uint256 i; i < stakers.length; ++i) {
                if (vault.pendingRewards(stakers[i]) != 0) _claimVault(stakers[i]);
            }
            _claimPartners();
            _sweep(players[batches % players.length]);
        }
        _claim(holders[0]); // every batch
        if (batches % 20 == 7) _claim(holders[1]); // rarely
        if (batches % 10 == 3) {
            // holders[3] trades: sells a fifth, or buys back to 10M
            uint256 b = token.balanceOf(holders[3]);
            if (batches % 20 == 3 && b > 1e24) _sell(holders[3], b / 5);
            else if (b < 10_000_000 ether) _buyExact(holders[3], 10_000_000 ether - b);
            // (a buy may come up short when the pool runs low)
        }
        // staker 0 joins after 400 flips and stays; claims every 25 batches
        if (!staker0In && st.flips > 400) {
            _buyExact(stakers[0], 10_000_000 ether);
            uint256 a0 = token.balanceOf(stakers[0]);
            vm.prank(stakers[0]);
            _act("stake", stakers[0], a0, vault.deposit(a0, 0), 0, 0, 0, 0);
            staker0In = true;
        }
        if (staker0In && batches % 25 == 11) _claimVault(stakers[0]);
        // staker 1 cycles: deposit, request after its lock, withdraw after the cooldown, deposit again
        _staker1();
        if (batches % 15 == 5) _claimPartners();
        if (batches % 12 == 6) _sweep(players[batches % players.length]); // anyone sweeps the lock
        if (batches % 9 == 4) {
            vm.prank(harvester);
            vault.crystallize();
            _act("crystallize", harvester, vault.protocolShares(), vault.hwm(), 0, 0, 0, 0);
        }
    }

    function _staker1() internal {
        address s = stakers[1];
        if (st.flips < 1500) return;
        if (staker1Phase == 0) {
            uint256 b = token.balanceOf(s);
            if (b < 5_000_000 ether) _buyExact(s, 5_000_000 ether - b);
            uint256 a1 = Math.min(5_000_000 ether, token.balanceOf(s));
            if (a1 == 0) return;
            vm.prank(s);
            _act("stake", s, a1, vault.deposit(a1, 0), 0, 0, 0, 0);
            staker1Phase = 1;
            staker1In = true;
        } else if (staker1Phase == 1 && vm.getBlockTimestamp() >= vault.unlockAt(s)) {
            uint256 sh = vault.balanceOf(s);
            vm.prank(s);
            vault.requestWithdraw(sh);
            _act("unstakeRequest", s, sh, vault.previewRedeem(sh), 0, 0, 0, 0);
            staker1Phase = 2;
        } else if (staker1Phase == 2) {
            (uint256 sh, uint256 readyAt) = vault.pending(s);
            if (sh != 0 && vm.getBlockTimestamp() >= readyAt && vault.maxWithdrawable(s) != 0) {
                _claimVault(s);
                vm.prank(s);
                _act("unstake", s, vault.withdraw(0), sh, 0, 0, 0, 0);
                staker1Phase = 3;
                staker1In = false;
            }
        } else if (staker1Phase == 3 && batches % 40 == 0) {
            staker1Phase = 0;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Streaks (forced outcomes on $FLIPPER flips at `sizeBps` of the Kelly cap)
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @return made flips actually made (stops early if the breaker trips or `stop` returns true)
    function _streak(bool playerWins, uint256 n, uint256 sizeBps) internal returns (uint256 made) {
        uint256 mem = _fmp();
        for (uint256 i; i < n; ++i) {
            _resetFmp(mem);
            if (house.locked()) break;
            address p = players[i % players.length];
            uint256 cap = _flipperCap(p, "");
            uint256 amt = cap * sizeBps / BPS;
            if (amt == 0) break;
            uint256 bal = token.balanceOf(p);
            if (bal < amt) _buyExact(p, amt - bal);
            amt = Math.min(amt, token.balanceOf(p));
            if (_flipSettle(p, address(token), amt, "", playerWins ? Force.PlayerWins : Force.PlayerLoses, false) != 0) {
                ++made;
            }
            _advance(_randBetween(2, 20));
        }
    }

    /// @dev house losses until the lock's value falls below `bps` of its principal (or `maxFlips`)
    function _sinkLockTo(uint256 bps, uint256 maxFlips) internal returns (uint256 made) {
        while (lock.value() * BPS >= lock.principal() * bps && made < maxFlips && !house.locked()) {
            made += _streak(true, 1, BPS);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Checkpoints
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev a volume level: let the stream accrue fully, check every claim against the shadow, record, sweep the
    ///      lock (anyone), take its excess (devAddress), record again
    function _checkpoint(string memory label) internal {
        // the mix is alive: both kinds of flip happen (a sizing bug can silently starve one)
        assertGt(st.flipsFlipper, st.flips / 5, "$FLIPPER flips happen");
        assertGt(st.flipsToken, st.flips / 10, "token flips happen");
        _upkeep();
        _advance(7 days);
        _upkeep();
        _checkShadow(true);
        _checkLpFees();
        lastDust = _checkAll(principal0);
        _logState(string.concat(label, ":pre"), simStart, lastDust);
        _gasSample(label);

        // only devAddress requests or withdraws
        vm.prank(players[0]);
        vm.expectRevert(PrincipalLock.Unauthorized.selector);
        lock.requestExcess(1);
        vm.prank(holders[0]);
        vm.expectRevert(PrincipalLock.Unauthorized.selector);
        lock.withdrawExcess();

        _sweep(holders[1]);
        _takeExcess();
        _claim(dev);
        _checkAll(principal0);
        _logState(string.concat(label, ":post"), simStart, lastDust);
    }

    /// @dev every tracked account's lifetime holder rewards equal its balance-time share; every staker's (and the
    ///      lock's) vault rewards its share-time share of what the vault's virtual balance earned
    function _checkShadow(bool strict) internal {
        for (uint256 i; i < tracked.length; ++i) {
            address a = tracked[i];
            uint256 exp = expectedMag[a] / MAG;
            uint256 act = token.accrued(a) - baseAccrued[a];
            if (strict || exp > 1e18) {
                assertApproxEqAbs(act, exp, 1e12 + exp / 1e9, "holder rewards = balance-time share");
            }
        }
        // vault pass-through (the lock and the stakers)
        for (uint256 i; i < 3; ++i) {
            address a = i < 2 ? stakers[i] : address(lock);
            uint256 exp = expectedVaultMag[a] / MAG;
            uint256 act = vault.rewardsClaimed(a) + vault.pendingRewards(a) - baseVault[a];
            assertApproxEqAbs(act, exp, 1e12 + exp / 1e9, "vault rewards = share-time share");
        }
    }

    /// @dev the protocol-owned position is the pool's only liquidity: every harvest collected exactly the fees it
    ///      had earned (its fee growth as of the last collection; trades after it earn fees the next harvest takes)
    function _checkLpFees() internal view {
        // the launch position: a PositionManager NFT (owner = the PositionManager, salt = the token id)
        LiquidityKeeper lk = LiquidityKeeper(payable(d.liquidityKeeper));
        (uint128 liq, uint256 fgi0, uint256 fgi1) = manager.getPositionInfo(
            fKey.toId(), address(lk.positionManager()), lpLower, lpUpper, bytes32(lk.tokenId())
        );
        uint256 e0 = FullMath.mulDiv(fgi0 - fg0Start, liq, 1 << 128);
        uint256 e1 = FullMath.mulDiv(fgi1 - fg1Start, liq, 1 << 128);
        assertApproxEqAbs(st.lpFeesEth, e0, st.harvests + 2, "LP fees harvested (ETH) = fee growth at the last collection");
        assertApproxEqAbs(st.lpFeesFlipper, e1, st.harvests + 2, "LP fees harvested ($FLIPPER) = fee growth at the last collection");
        // and nothing is left behind for good: what is owed now is only what accrued since
        (uint256 g0, uint256 g1) = manager.getFeeGrowthGlobals(fKey.toId());
        assertGe(g0, fgi0);
        assertGe(g1, fgi1);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Gas (sampled at checkpoints, state restored afterwards; every touched contract cooled first)
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function _cool() internal {
        vm.cool(address(house));
        vm.cool(d.module);
        vm.cool(address(token));
        vm.cool(address(vault));
        vm.cool(address(router));
        vm.cool(address(adapter));
        vm.cool(address(dice));
        vm.cool(address(manager));
        vm.cool(address(lock));
        vm.cool(address(converter));
        vm.cool(address(partners));
        vm.cool(address(weth));
        vm.cool(d.wethWrapper);
    }

    function _gasSample(string memory label) internal returns (uint256[8] memory g) {
        if (house.locked()) return g;
        uint256 snap = vm.snapshotState();
        address p = players[1];
        // a sample the house would refuse (e.g. half the cap under its minimum liability, late in a long run) is skipped:
        // a 0 sample isn't compared
        uint256 amtF = _flipperCap(p, "") / 2;
        (g[0], g[1]) = _gasFlip(p, address(token), amtF < _minFlipperStake() ? 0 : amtF);
        uint256 capW = _tokenCap(address(weth), 1000 ether) / 2;
        if (capW != 0 && _preview(p, address(weth), capW, "").code != 0) capW = 0;
        if (capW != 0) {
            vm.prank(p);
            weth.deposit{value: capW}();
            (g[2], g[3]) = _gasFlip(p, address(weth), capW);
        }
        _cool();
        vm.prank(holders[1]);
        uint256 g0 = gasleft();
        token.claim();
        g[4] = g0 - gasleft();
        if (staker0In) {
            _cool();
            vm.prank(stakers[0]);
            g0 = gasleft();
            vault.claimRewards();
            g[5] = g0 - gasleft();
        }
        _cool();
        vm.prank(players[2]);
        g0 = gasleft();
        lock.sweepRewards();
        g[6] = g0 - gasleft();
        _cool();
        vm.prank(harvester, harvester);
        g0 = gasleft();
        router.harvest();
        g[7] = g0 - gasleft();
        vm.revertToState(snap);
        string memory s = _cs(_c("CSV,gas", seed), label);
        s = _c(_c(s, st.flips), (vm.getBlockTimestamp() - simStart) / 1 days);
        for (uint256 i; i < 8; ++i) {
            s = _c(s, g[i]);
        }
        console2.log(s);
    }

    function _gasFlip(address p, address t, uint256 amt) internal returns (uint256 gFlip, uint256 gSettle) {
        if (amt == 0) return (0, 0);
        if (t == address(token)) {
            if (token.balanceOf(p) < amt) _buyExact(p, amt - token.balanceOf(p));
            amt = Math.min(amt, token.balanceOf(p));
            if (amt < _minFlipperStake()) return (0, 0);
        }
        _ensureChain();
        uint256 fee = house.randomnessFeeFor(t);
        _cool();
        vm.prank(p, p);
        uint256 g0 = gasleft();
        uint256 id = house.flip{value: fee}(t, amt, 0, vm.getBlockTimestamp());
        gFlip = g0 - gasleft();
        (,, uint16 wc,,,,,,,, uint256 req,) = house.flips(id);
        uint64 target = adapter.requestInfo(req).targetBlock;
        vm.roll(block.number + 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        bytes32 u = adapter.userRandom(target);
        bytes32 x = _chainValue(req);
        vm.setBlockhash(target, _hashFor(u, x, wc, false, id)); // always a loss: the same settlement path
        _cool();
        vm.prank(keeper, keeper);
        g0 = gasleft();
        dice.revealWithCallback{gas: 8_000_000}(keeper, uint64(req), u, x);
        gSettle = g0 - gasleft();
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // The end: everyone claims everything; what is left over is dust
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    string internal constant END_HEADER =
        "CSV,end,seed,flips,simDays,rewardReserve,pendingStream,carry,unclaimedDust,vaultBalance,vaultOwed,vaultDust,routerFlipper,routerPending,houseClaimableFlipper,partnerAccruedTotal,openLots,openLotEth";

    function _finish() internal {
        if (house.locked()) return;
        _upkeep();
        _advance(8 days); // everything distributed streams out
        _upkeep();
        _advance(8 days);
        _checkShadow(true);
        for (uint256 i; i < tracked.length; ++i) {
            if (tracked[i] != address(lock) && tracked[i] != deployerAddr) _claim(tracked[i]);
        }
        _sweep(harvester);
        for (uint256 i; i < stakers.length; ++i) {
            if (vault.balanceOf(stakers[i]) != 0 || vault.rewardsClaimed(stakers[i]) != 0) _claimVault(stakers[i]);
        }
        _claimPartners();
        _exec(address(token), abi.encodeWithSignature("claim()"));
        uint256 dust = _checkAll(principal0);
        uint256 vaultOwed = vault.pendingRewards(address(lock));
        for (uint256 i; i < stakers.length; ++i) {
            vaultOwed += vault.pendingRewards(stakers[i]);
        }
        uint256 openLots;
        uint256 openEth;
        for (uint256 i; i < converter.lotsLength(); ++i) {
            uint256 r = converter.lot(i).remaining;
            if (r != 0) {
                ++openLots;
                if (converter.lot(i).asset == address(0)) openEth += r;
            }
        }
        string memory s = _c(_c(_c("CSV,end", seed), st.flips), (vm.getBlockTimestamp() - simStart) / 1 days);
        s = _c(_c(_c(_c(s, token.balanceOf(address(token))), token.pendingStream()), token.carry()), dust);
        s = _c(_c(_c(s, token.balanceOf(address(vault))), vaultOwed), token.balanceOf(address(vault)) - vaultOwed);
        s = _c(_c(s, token.balanceOf(address(router))), router.rewardsFlipperPending());
        s = _c(_c(s, house.claimableTotal(address(token))), house.partnerAccruedTotal());
        s = _c(_c(s, openLots), openEth);
        console2.log(END_HEADER);
        console2.log(s);
        // nothing stuck: after everyone claimed, what is left is what still streams plus rounding dust
        // (fork: holders that don't act keep their claimables in the reserve)
        if (!forked) assertLt(dust, 1e12, "reward dust after every claim");
        assertLt(token.balanceOf(address(vault)) - vaultOwed, 1e12, "vault dust after every claim");
        assertEq(house.partnerAccruedTotal(), 0, "partners fully paid");
    }
}
