// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FlipperHouse} from "../../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../../src/house/FlipperHouseBase.sol";
import {PrincipalLock} from "../../src/PrincipalLock.sol";
import {SimDriver} from "./SimDriver.sol";

/// @notice The handler: every call forwards to the test contract, which holds the simulated system.
contract LockHandler is Test {
    SimInvariantTest internal immutable t;

    constructor(SimInvariantTest _t) {
        t = _t;
    }

    function flip(uint256 who, uint256 size, uint8 kind, uint8 flags) external {
        t.hFlip(who, size, kind, flags);
    }

    function flipInFlight(uint256 who, uint256 size) external {
        t.hFlipInFlight(who, size);
    }

    function deliver(uint256 idx, bool late) external {
        t.hDeliver(idx, late);
    }

    function streak(bool playerWins, uint8 n) external {
        t.hStreak(playerWins, n);
    }

    function upkeep() external {
        t.hUpkeep();
    }

    function sweep(uint256 who, uint8 which) external {
        t.hSweep(who, which);
    }

    function request(uint256 fracBps, uint256 who) external {
        t.hRequest(fracBps, who);
    }

    function withdraw(uint256 who) external {
        t.hWithdraw(who);
    }

    function cancel(uint256 who) external {
        t.hCancel(who);
    }

    function warp(uint256 secs) external {
        t.hWarp(secs);
    }

    function stake(uint256 who, uint256 amount) external {
        t.hStake(who, amount);
    }

    function unstake(uint256 who, uint8 step) external {
        t.hUnstake(who, step);
    }

    function holder(uint256 who, uint256 amount, uint8 op) external {
        t.hHolder(who, amount, op);
    }

    function partnerClaim(uint256 id) external {
        t.hPartnerClaim(id);
    }

    function crystallize() external {
        t.hCrystallize();
    }

    function unlock(bool resetAth) external {
        t.hUnlock(resetAth);
    }
}

/// @notice Invariant suite over the whole simulated system, starting from a deployment that has already seen ~$10k
///         of volume and whose lock period has passed. Random flips (settled at once, in flight, late / safe mode,
///         forced streaks either way, partner-attributed), the permissionless upkeep, lock sweeps by anyone, excess
///         requests / withdrawals / cancels by devAddress and by others, time, stakers depositing and withdrawing,
///         holders trading and claiming, partner claims, crystallisations, the breaker and its unlock.
///   Invariants: the principal is never reduced; payouts only ever go to devAddress; the house is solvent; every
///   $FLIPPER is accounted for; the reward reserve covers every claim; the excess is exactly min(max(0, value − P), free bankroll); a
///   withdrawal never leaves the position under the principal; the breaker only trips below half the NAV high.
///   Run: nice -n 10 forge test --match-path test/sim/SimInvariant.t.sol -vv --gas-limit 9223372036854775807
contract SimInvariantTest is SimDriver {
    LockHandler internal handler;
    uint256[] internal inflight;
    uint256[] internal deferred;

    // ghosts
    string public breach; // first violation seen inside a handler call ("" = none)
    uint256 public lockOutToDev;
    uint256 public lockOutElsewhere;
    uint256 public calls;
    uint256 public withdrawals;
    uint256 public requests;
    uint256 public sweeps;
    uint256 public unauthorizedTried;

    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    function setUp() public {
        _start(uint256(keccak256("invariant")));
        _driveTo(10_000e18, 5_000, 1 days);
        _upkeep();
        uint256 until = vault.unlockAt(address(lock));
        if (vm.getBlockTimestamp() < until) _advance(until - vm.getBlockTimestamp());
        handler = new LockHandler(this);
        targetContract(address(handler));
        lockOutToDev = token.balanceOf(dev) - st.devWalletClaims; // paid before the handler took over
    }

    modifier action() {
        require(msg.sender == address(handler), "handler only");
        vm.recordLogs();
        ++calls;
        _;
        _scan(vm.getRecordedLogs());
    }

    function _flag(string memory why) internal {
        if (bytes(breach).length == 0) breach = why;
    }

    /// @dev every $FLIPPER that leaves the lock must go to devAddress (or, at the one-time stake, the vault)
    function _scan(Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(token) || l.topics.length != 3 || l.topics[0] != TRANSFER) continue;
            if (address(uint160(uint256(l.topics[1]))) != address(lock)) continue;
            address to = address(uint160(uint256(l.topics[2])));
            uint256 v = abi.decode(l.data, (uint256));
            if (to == dev) lockOutToDev += v;
            else lockOutElsewhere += v;
        }
    }

    /// @dev `_harvest` reads (and so clears) the recorded logs: scan what it read
    function _onLogs(Vm.Log[] memory logs) internal override {
        _scan(logs);
    }

    function _other(uint256 who) internal view returns (address) {
        uint256 k = who % 4;
        return k == 0 ? players[who % players.length] : (k == 1 ? holders[who % holders.length] : (k == 2 ? harvester : arb));
    }

    // ── flips ────────────────────────────────────────────────────────────────────────────────────────────

    function hFlip(uint256 who, uint256 size, uint8 kind, uint8 flags) external action {
        if (house.locked()) return;
        address p = players[who % players.length];
        bytes memory sfx = flags % 4 == 0 ? _suffix("p2") : (flags % 4 == 1 ? _suffix("demo") : bytes(""));
        bool late = flags % 16 == 15;
        uint256 frac = bound(size, 500, BPS);
        if (kind % 3 == 0) {
            uint256 cap = _flipperCap(p, sfx);
            uint256 amt = Math.max(cap * frac / BPS, _minFlipperStake());
            if (amt > cap) return;
            if (token.balanceOf(p) < amt) _buyExact(p, amt - token.balanceOf(p));
            amt = Math.min(amt, token.balanceOf(p));
            if (amt < _minFlipperStake()) return;
            _flipSettle(p, address(token), amt, sfx, Force.Random, late);
        } else {
            address tk = kind % 3 == 1 ? address(weth) : address(usdg);
            uint256 cap = _tokenCap(tk, tk == address(weth) ? 1000 ether : 1e18);
            uint256 amt = cap * frac / BPS;
            if (amt == 0) return;
            if (tk == address(weth)) {
                vm.prank(p);
                weth.deposit{value: amt}();
            } else {
                _fundUsdg(p, amt);
            }
            _flipSettle(p, tk, amt, sfx, Force.Random, late);
        }
    }

    function hFlipInFlight(uint256 who, uint256 size) external action {
        if (house.locked() || inflight.length >= 4) return;
        address p = players[who % players.length];
        uint256 cap = _flipperCap(p, "");
        uint256 amt = Math.max(cap * bound(size, 500, BPS) / BPS, _minFlipperStake());
        if (amt > cap) return;
        if (token.balanceOf(p) < amt) _buyExact(p, amt - token.balanceOf(p));
        amt = Math.min(amt, token.balanceOf(p));
        if (amt < _minFlipperStake()) return;
        uint256 id = _flipOnly(p, address(token), amt, "");
        if (id != 0) inflight.push(id);
    }

    function hDeliver(uint256 idx, bool late) external action {
        if (inflight.length == 0) return;
        idx = idx % inflight.length;
        uint256 id = inflight[idx];
        inflight[idx] = inflight[inflight.length - 1];
        inflight.pop();
        _deliver(id, Force.Random, late);
        if (_status(id) == FlipperHouseBase.Status.Pending) deferred.push(id); // arrived while locked
        else _book(id);
    }

    function hStreak(bool playerWins, uint8 n) external action {
        _streak(playerWins, bound(n, 1, 12), BPS);
    }

    // ── upkeep, time ─────────────────────────────────────────────────────────────────────────────────────

    function hUpkeep() external action {
        _upkeep();
    }

    function hWarp(uint256 secs) external action {
        _advance(bound(secs, 1 minutes, 20 days));
    }

    function hCrystallize() external action {
        if (house.locked()) return;
        vm.prank(harvester);
        vault.crystallize();
    }

    function hUnlock(bool resetAth) external action {
        if (!house.locked()) return;
        _exec(address(house), abi.encodeCall(FlipperHouse.unlock, (resetAth)));
        if (resetAth) shadowAth = uint256(house.navAth());
        _wasLocked = false;
        if (!resetAth) {
            // without a reset the next check re-locks unless the NAV recovered above half its high
            house.checkDrawdown();
            _afterAction("checkDrawdown");
            if (house.locked()) return;
        }
        for (uint256 i; i < deferred.length; ++i) {
            if (_status(deferred[i]) == FlipperHouseBase.Status.Pending) {
                house.settleDeferred(deferred[i]);
                _book(deferred[i]);
            }
        }
        delete deferred;
    }

    // ── the lock ─────────────────────────────────────────────────────────────────────────────────────────

    function hSweep(uint256 who, uint8 which) external action {
        address c = _other(who);
        uint256 d0 = token.balanceOf(dev);
        uint256 c0 = token.balanceOf(c);
        uint256 vr = lock.pendingVaultRewards();
        uint256 hr = lock.pendingHolderRewards();
        uint256 paid;
        vm.prank(c);
        if (which % 3 == 0) {
            try lock.sweepRewards() returns (uint256 a, uint256 b) {
                paid = a + b;
                if (a != vr || b != hr) _flag("sweep paid other than pending");
            } catch {
                if (!house.locked()) _flag("sweepRewards reverted while unlocked");
                return;
            }
        } else if (which % 3 == 1) {
            try lock.sweepVaultRewards() returns (uint256 a) {
                paid = a;
                if (a != vr) _flag("vault sweep paid other than pending");
            } catch {
                if (!house.locked()) _flag("sweepVaultRewards reverted while unlocked");
                return;
            }
        } else {
            try lock.sweepHolderRewards() returns (uint256 b) {
                paid = b;
                if (b != hr) _flag("holder sweep paid other than pending");
            } catch {
                if (!house.locked()) _flag("sweepHolderRewards reverted while unlocked");
                return;
            }
        }
        ++sweeps;
        if (token.balanceOf(dev) - d0 != paid) _flag("sweep: devAddress did not receive it all");
        if (token.balanceOf(c) != c0) _flag("sweep: the caller received something");
        st.devVaultRewards += which % 3 == 2 ? 0 : vr;
        st.devHolderRewards += which % 3 == 1 ? 0 : hr;
    }

    function hRequest(uint256 fracBps, uint256 who) external action {
        bool asDev = who % 3 != 0;
        address c = asDev ? dev : _other(who);
        uint256 x = lock.withdrawableExcess();
        (uint256 q,,) = lock.pendingWithdrawal();
        uint256 qv = vault.previewRedeem(q);
        uint256 amt = x * bound(fracBps, 0, 12_000) / BPS; // up to 120% of the excess
        vm.prank(c);
        try lock.requestExcess(amt) {
            if (!asDev) _flag("a non-dev request succeeded");
            ++requests;
            (uint256 q2,,) = lock.pendingWithdrawal();
            if (vault.previewRedeem(q2) > lock.withdrawableExcess()) _flag("queued more than the excess");
            if (amt + qv > x + 1e6 && q2 > q) _flag("request above the excess accepted");
        } catch {
            if (!asDev) ++unauthorizedTried;
        }
    }

    function hWithdraw(uint256 who) external action {
        bool asDev = who % 3 != 0;
        address c = asDev ? dev : _other(who);
        uint256 d0 = token.balanceOf(dev);
        uint256 vr = lock.pendingVaultRewards();
        uint256 hr = lock.pendingHolderRewards();
        vm.prank(c);
        try lock.withdrawExcess() returns (uint256 assets) {
            if (!asDev) _flag("a non-dev withdrawal succeeded");
            ++withdrawals;
            if (lock.value() < lock.principal()) _flag("a withdrawal left the value under the principal");
            if (token.balanceOf(dev) - d0 != assets + vr + hr) _flag("withdrawal not paid in full to devAddress");
            st.devExcess += assets;
            st.devVaultRewards += vr;
            st.devHolderRewards += hr;
        } catch {
            if (!asDev) ++unauthorizedTried;
        }
    }

    function hCancel(uint256 who) external action {
        bool asDev = who % 3 != 0;
        vm.prank(asDev ? dev : _other(who));
        try lock.cancelExcess() {
            if (!asDev) _flag("a non-dev cancel succeeded");
        } catch {}
    }

    // ── stakers, holders, partners ───────────────────────────────────────────────────────────────────────

    function hStake(uint256 who, uint256 amount) external action {
        if (house.locked()) return;
        address s = stakers[who % stakers.length];
        amount = bound(amount, 1_000_000 ether, 30_000_000 ether);
        if (token.balanceOf(s) < amount) _buyExact(s, amount - token.balanceOf(s));
        amount = Math.min(amount, token.balanceOf(s));
        if (amount == 0) return;
        vm.prank(s);
        try vault.deposit(amount, 0) {} catch {}
    }

    function hUnstake(uint256 who, uint8 step) external action {
        if (house.locked()) return;
        address s = stakers[who % stakers.length];
        uint256 sh = vault.balanceOf(s);
        if (step % 4 == 0) {
            (uint256 p,) = vault.pending(s);
            if (sh > p) {
                vm.prank(s);
                try vault.requestWithdraw(sh - p) {} catch {}
            }
        } else if (step % 4 == 1) {
            vm.prank(s);
            try vault.withdraw(0) {} catch {}
        } else if (step % 4 == 2) {
            vm.prank(s);
            try vault.cancelWithdraw() {} catch {}
        } else {
            uint256 due = vault.pendingRewards(s);
            vm.prank(s);
            try vault.claimRewards() returns (uint256 got) {
                if (got != due) _flag("staker claim != pending");
            } catch {}
        }
    }

    function hHolder(uint256 who, uint256 amount, uint8 op) external action {
        if (house.locked()) return;
        address h = holders[who % holders.length];
        if (op % 3 == 0) {
            _buyExact(h, bound(amount, 1 ether, 5_000_000 ether));
        } else if (op % 3 == 1) {
            uint256 b = token.balanceOf(h);
            if (b > 1 ether) _sell(h, bound(amount, 1, b / 2));
        } else {
            _claim(h);
        }
    }

    function hPartnerClaim(uint256 id) external action {
        if (house.locked()) return;
        id = 1 + id % 2;
        uint256 acc = house.partnerAccrued(id);
        address to = partners.payoutOf(id);
        uint256 b0 = token.balanceOf(to);
        vm.prank(arb);
        house.claimPartner(id);
        if (token.balanceOf(to) - b0 != acc) _flag("partner claim != accrued");
    }

    // ── invariants ───────────────────────────────────────────────────────────────────────────────────────

    function invariant_no_breach_inside_handlers() public view {
        assertEq(breach, "", breach);
    }

    function invariant_principal_never_reduced() public view {
        assertEq(lock.principal(), principal0, "principal");
    }

    function invariant_payouts_only_to_dev() public view {
        assertEq(lockOutElsewhere, 0, "the lock paid someone other than devAddress");
        assertEq(token.balanceOf(address(lock)), 0, "the lock holds nothing between transactions");
    }

    function invariant_solvency() public view {
        _checkSolvency();
    }

    function invariant_conservation() public view {
        _checkConservation();
    }

    function invariant_reward_reserve() public view {
        _checkRewardReserve();
    }

    function invariant_excess_formula() public view {
        uint256 v = lock.value();
        uint256 x = v > principal0 ? v - principal0 : 0;
        uint256 free = vault.freeBankroll();
        assertEq(lock.withdrawableExcess(), x < free ? x : free, "excess = min(max(0, value - P), free bankroll)");
    }

    function invariant_dev_receipts_add_up() public view {
        // devAddress holds exactly what the lock paid it plus what it claimed on its own wallet
        assertEq(token.balanceOf(dev), lockOutToDev + st.devWalletClaims, "dev receipts");
    }

    function afterInvariant() external view {
        // (reporting only)
        calls;
    }
}
