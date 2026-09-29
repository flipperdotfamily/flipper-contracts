// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {FlipperHouseBase, IAuctionConverter, IPartnerRegistry} from "./FlipperHouseBase.sol";
import {IRandomnessAdapter} from "../interfaces/IRandomness.sol";
import {IRouteAdapter} from "../interfaces/IRouteAdapter.sol";

/// @title HouseModule
/// @notice The house's cold paths — initialisation, cancellation, listing, permissionless upkeep, admin and partner
///         claims — run by `FlipperHouse` through `delegatecall` (its one-line stubs keep the house's ABI whole). It
///         shares the house's storage layout (`FlipperHouseBase`) and immutables, and holds no funds or state of
///         its own: every external function reverts unless reached by delegatecall, and nothing here selfdestructs
///         or delegatecalls out.
contract HouseModule is FlipperHouseBase {
    using SafeERC20 for IERC20;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address private immutable self;

    modifier onlyDelegateCall() {
        if (address(this) == self) revert Unauthorized();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(IPoolManager _poolManager, IERC20 _flipper, IRandomnessAdapter _randomness)
        FlipperHouseBase(_poolManager, _flipper, _randomness)
    {
        self = address(this);
    }

    function initialize(address _owner, Params calldata p) external initializer onlyDelegateCall {
        __Ownable_init(_owner);
        _setParams(p);
        guardian = _owner;
        unlocker = _owner;
        nextFlipId = 1;
        maxOpenPerPlayer = DEFAULT_MAX_OPEN_PER_PLAYER;
    }

    /// @notice Owner: re-base the edge schedule's ratchet (recovery, or carrying progress over to a new house), within
    ///         [0, toEth]. A high below `netBuybackEth` lasts only until the next booking raises it back to the net.
    function setBuybackHigh(int128 high) external onlyOwner onlyDelegateCall {
        if (high < 0 || uint256(int256(high)) > edgeSchedule.toEth) revert InvalidParams();
        buybackHigh = high;
        emit BuybackHighSet(high);
    }

    /// @notice Owner: the drawdown-scaled Kelly multiplier — `maxBps` (written to `Params.kellyBps`) until a drawdown of
    ///         `ddStartBps`, sliding to `minBps` at `ddEndBps` (at most the breaker's 50%). 0 < min ≤ max ≤ 100%.
    function setKellySchedule(uint16 maxBps, uint16 minBps, uint16 ddStartBps, uint16 ddEndBps)
        external
        onlyOwner
        onlyDelegateCall
    {
        if (minBps == 0 || minBps > maxBps || maxBps > BPS || ddStartBps >= ddEndBps || ddEndBps > DRAWDOWN_LOCK_BPS) {
            revert InvalidParams();
        }
        _params.kellyBps = maxBps;
        (kellyMinBps, kellyDdStartBps, kellyDdEndBps) = (minBps, ddStartBps, ddEndBps);
        emit KellyScheduleSet(maxBps, minBps, ddStartBps, ddEndBps);
    }

    /// @notice Owner or guardian: at most `maxOpen` flips per player waiting for randomness (1–255), and the smallest
    ///         liability a flip may carry, in $FLIPPER (0 = no floor). The randomness adapter caps open requests globally;
    ///         these keep one actor from holding that capacity with dust. The guardian may set them too, so the floor
    ///         can follow $FLIPPER's price without the owner's key (it can pause flips outright anyway).
    function setFlipLimits(uint16 maxOpen, uint128 minLiab) external onlyGuardian onlyDelegateCall {
        if (maxOpen == 0 || maxOpen > 255) revert InvalidParams();
        maxOpenPerPlayer = maxOpen;
        minLiability = minLiab;
        emit FlipLimitsSet(maxOpen, minLiab);
    }

    /// @notice Cancel a flip whose randomness never arrived. Players may cancel after `playerCancelDelay`, guardians
    ///         after `guardianCancelDelay`, both only while the randomness request is provably unrevealed (so a
    ///         revealed outcome can never be voided); only after `GUARDIAN_EMERGENCY_CANCEL_DELAY` (30 days) may the
    ///         guardian cancel regardless. A delivery recorded during a drawdown lock is settled, never cancelled.
    ///         The stake is returned; the randomness fee is not.
    function cancelFlip(uint256 flipId) external nonReentrant onlyDelegateCall {
        _whenUnlocked();
        Flip storage f = flips[flipId];
        if (f.status != Status.Pending || _deferredRoll[flipId] != 0) revert BadStatus();
        Params memory p = _params;
        uint256 age = block.timestamp - f.createdAt;
        if (msg.sender == guardian || msg.sender == owner()) {
            if (age < p.guardianCancelDelay) revert TooEarly();
            if (age < GUARDIAN_EMERGENCY_CANCEL_DELAY && !randomness.isPending(f.requestId)) {
                revert RandomnessRevealed();
            }
        } else if (msg.sender == f.player) {
            if (age < p.playerCancelDelay) revert TooEarly();
            if (!randomness.isPending(f.requestId)) revert RandomnessRevealed();
        } else {
            revert Unauthorized();
        }

        f.status = Status.Refunded;
        _closeOpen(f.player);
        reserved -= f.liability;
        escrowed[f.token] -= f.amount;
        if (gasleft() < PAY_GAS + 50_000) revert InsufficientGas(); // push the refund, don't defer it for lack of gas
        _pay(f.token, f.player, f.amount);
        emit FlipCancelled(flipId, msg.sender);
    }

    /// @notice Permissionlessly list a token through an approved route adapter (e.g. the v4 adapter).
    ///         The adapter vouches for the token and its canonical pools; the house additionally requires a
    ///         probe-sized round trip to cost no more than the route-cost allowance.
    function listToken(address token, IRouteAdapter adapter) external nonReentrant onlyDelegateCall {
        _whenUnlocked();
        if (paused) revert FlipRejected(REJECT_PAUSED);
        if (!isRouteAdapter[address(adapter)]) revert Unauthorized();
        TokenConfig storage tc = _tokens[token];
        if (tc.blocked) revert TokenBlocked();
        // never let a permissionless call overwrite a route set by the owner or another adapter
        if (tc.route.length != 0 && tc.adapter != address(adapter)) revert AlreadyListed();
        PoolKey[] memory route = adapter.routeFor(token, address(flipper));
        _writeRoute(token, route, address(adapter));

        uint256 cost = _probeRouteCost(route, token);
        if (cost > _params.listingMaxRouteCostBps) revert ListingProbeFailed(cost);
    }

    /// @notice Round-trip cost (bps) of buying then selling a probe-sized position through `route`.
    function _probeRouteCost(PoolKey[] memory route, address token) internal returns (uint256) {
        Params memory p = _params;
        uint256 probe = Math.max(maxLiability() * p.listingProbeBps / BPS, p.minListingProbe);
        (bool okB,, uint256 bought) = _tryQuote(
            _request(EXACT_IN, _reversePath(route), _c(address(flipper)), _c(token), probe, 0), p.swapGasLimit
        );
        if (!okB || bought == 0) return type(uint256).max;
        (bool okS,, uint256 back) =
            _tryQuote(_request(EXACT_IN, route, _c(token), _c(address(flipper)), bought, 0), p.swapGasLimit);
        if (!okS || back == 0) return type(uint256).max;
        return probe > back ? Math.mulDiv(probe - back, BPS, probe + back, Math.Rounding.Ceil) : 0;
    }

    /// @notice Owner listing with an explicit route (any v4 token). The owner vouches for the token contract.
    function setTokenRoute(address token, PoolKey[] calldata route) external onlyOwner onlyDelegateCall {
        _tokens[token].blocked = false;
        _writeRoute(token, route, address(0));
    }

    /// @notice Owner may enable or disable; the guardian may only disable. Disabling blocks permissionless
    ///         re-listing. Pending flips always settle through the stored route.
    function setTokenEnabled(address token, bool enabled) external onlyDelegateCall {
        if (enabled ? msg.sender != owner() : (msg.sender != owner() && msg.sender != guardian)) {
            revert Unauthorized();
        }
        TokenConfig storage tc = _tokens[token];
        if (enabled && tc.route.length == 0) revert InvalidParams();
        tc.enabled = enabled;
        tc.blocked = !enabled;
        emit TokenEnabled(token, enabled);
    }

    function _writeRoute(address token, PoolKey[] memory route, address adapter) internal {
        if (token == address(0) || token == address(flipper) || token.code.length == 0) revert InvalidAddress();
        if (!(_pathEnd(route, _c(token)) == _c(address(flipper)))) revert InvalidPath();
        TokenConfig storage tc = _tokens[token];
        bool isNew = tc.route.length == 0;
        delete tc.route;
        for (uint256 i; i < route.length; ++i) {
            tc.route.push(route[i]);
        }
        tc.enabled = true;
        tc.adapter = adapter;
        if (isNew) listedTokens.push(token);
        emit TokenListed(token, adapter, route);
    }

    /// @notice Pay a pending win (anyone may call). The house buys the stake's worth of the token for at most the
    ///         reserved liability (→ Won); if that can't execute, then once `pendingTimeout` has passed since the flip
    ///         the reserved liability — the flip-time buy quote × 1.05 — is paid in $FLIPPER (→ WonFallback).
    ///         Whoever picks the moment can at most push the payout to that liability, which the flip priced and
    ///         reserved as its worst case; no market-derived valuation is used, so nothing here can be inflated.
    function resolvePendingWin(uint256 flipId) external nonReentrant onlyDelegateCall {
        _whenUnlocked();
        Flip storage f = flips[flipId];
        if (f.status != Status.WinPending) revert BadStatus();
        address token = f.token;
        uint256 liability = f.liability;
        // the buy attempt is swallowed on failure (then the $FLIPPER fallback may apply): give it its full budget
        if (gasleft() < uint256(_params.swapGasLimit) + SETTLE_OVERHEAD_GAS + 50_000) revert InsufficientGas();
        (bool ok, uint256 spent, uint256 received) = _buyWinnings(token, f.amount, liability, _tokens[token].route);
        uint256 flipperPaid = liability;
        if (ok) {
            flipperPaid = spent;
            f.status = Status.Won;
            _pay(token, f.player, received);
        } else {
            if (block.timestamp < f.createdAt + _params.pendingTimeout) revert TooEarly();
            received = 0;
            f.status = Status.WonFallback;
            _pay(address(flipper), f.player, liability);
        }
        reserved -= liability;
        treasury -= flipperPaid;
        emit PendingWinResolved(flipId, received, flipperPaid);
        _checkDrawdown();
    }

    /// @notice Move `amount` of a token's inventory (losses whose sale failed) to the Dutch-auction converter, which
    ///         sells it for $FLIPPER into the bankroll (anyone may call). A token that can't be transferred is left in
    ///         place and flagged for the guardian (`writeOffInventory`).
    function sweepInventory(address token, uint256 amount) external nonReentrant onlyDelegateCall {
        _whenUnlocked();
        address c = converter;
        uint256 inv = inventory[token];
        if (c == address(0) || amount == 0 || amount > inv) revert ExceedsAvailable();
        if (gasleft() < PAY_GAS + 150_000) revert InsufficientGas(); // a starved transfer would read as "stuck"
        if (!_tryTransfer(token, c, amount)) {
            emit InventoryStuck(token, amount);
            return;
        }
        uint256 value = Math.mulDiv(inventoryValue[token], amount, inv);
        inventory[token] = inv - amount;
        inventoryValue[token] -= value;
        IAuctionConverter(c).kick(token, amount, value);
        _checkDrawdown();
    }

    /// @notice Guardian: stop accounting for inventory that can't be moved (the tokens stay here as dust).
    function writeOffInventory(address token) external onlyGuardian onlyDelegateCall {
        emit InventoryWrittenOff(token, inventory[token]);
        inventory[token] = 0;
        inventoryValue[token] = 0;
    }

    function setParams(Params calldata p) external onlyOwner onlyDelegateCall {
        _setParams(p);
    }

    function _setParams(Params memory p) internal {
        // odds: the guaranteed profit floor must hold at zero route cost on both kinds of flip
        if (p.baseWinChanceBps < 3000 || p.baseWinChanceBps > 4900) revert InvalidParams();
        if (p.minWinChanceBps < 2500 || p.minWinChanceBps > p.baseWinChanceBps) revert InvalidParams();
        if (p.flipperPayoutBps < 2 * BPS || p.flipperPayoutBps > 21_500) revert InvalidParams();
        if (p.minHouseEdgeBps < 100 || p.minHouseEdgeBps > 2000) revert InvalidParams();
        if (2 * uint256(p.baseWinChanceBps) + p.minHouseEdgeBps > BPS) revert InvalidParams();
        if (uint256(p.baseWinChanceBps) * p.flipperPayoutBps > (BPS - uint256(p.minHouseEdgeBps)) * BPS) {
            revert InvalidParams();
        }
        if (p.maxRouteCostBps == 0 || p.maxRouteCostBps > 2000) revert InvalidParams();
        if (p.listingMaxRouteCostBps == 0 || p.listingMaxRouteCostBps > p.maxRouteCostBps) revert InvalidParams();
        if (p.lossSlippageBps < 50 || p.lossSlippageBps > 5000) revert InvalidParams();
        if (p.maxBetBps == 0 || p.maxBetBps > 1000) revert InvalidParams();
        if (p.rewardsShareBps > BPS) revert InvalidParams();
        if (p.listingProbeBps == 0 || p.listingProbeBps > BPS) revert InvalidParams();
        if (p.swapGasLimit < 150_000) revert InvalidParams();
        // every settlement attempt keeps SETTLE_OVERHEAD_GAS back (see _attemptGas), so the budget only has to fit
        // one full attempt; a win's fallback quote runs on whatever is left
        if (p.callbackGasLimit > 30_000_000 || p.callbackGasLimit < uint256(p.swapGasLimit) + SETTLE_OVERHEAD_GAS) {
            revert InvalidParams();
        }
        if (p.flipperCallbackGasLimit < 250_000 || p.flipperCallbackGasLimit > p.callbackGasLimit) revert InvalidParams();
        if (p.guardianCancelDelay < 1 hours || p.playerCancelDelay < 1 days) revert InvalidParams();
        // bounded above too: an unbounded delay would also block the 30-day emergency cancel
        if (p.guardianCancelDelay > GUARDIAN_EMERGENCY_CANCEL_DELAY || p.playerCancelDelay > 30 days) {
            revert InvalidParams();
        }
        if (p.pendingTimeout < 1 hours || p.pendingTimeout > 30 days) revert InvalidParams();
        if (p.maxReservedBps > BPS) revert InvalidParams();
        if (p.kellyBps == 0 || p.kellyBps > BPS) revert InvalidParams();
        if (p.kellyBps < kellyMinBps) revert InvalidParams();
        _params = p;
        emit ParamsUpdated(p);
    }

    function setGuardian(address g) external onlyOwner onlyDelegateCall {
        guardian = g;
        emit GuardianUpdated(g);
    }

    function setConverter(address c) external onlyOwner onlyDelegateCall {
        converter = c;
        emit ConverterSet(c);
    }

    function setRouteAdapter(address adapter, bool allowed) external onlyOwner onlyDelegateCall {
        isRouteAdapter[adapter] = allowed;
        emit RouteAdapterUpdated(adapter, allowed);
    }

    function setRevenueRouter(address router) external onlyOwner onlyDelegateCall {
        if (router != address(0) && router.code.length == 0) revert InvalidAddress();
        revenueRouter = router;
        emit RevenueRouterUpdated(router);
    }

    /// @notice One-time: make `v` (the TreasuryVault) the only account that can withdraw bankroll.
    function setVault(address v) external onlyOwner onlyDelegateCall {
        if (vault != address(0)) revert VaultAlreadySet();
        if (v.code.length == 0) revert InvalidAddress();
        vault = v;
        emit VaultSet(v);
    }

    function setPaused(bool p) external onlyGuardian onlyDelegateCall {
        if (!p && msg.sender != owner()) revert Unauthorized(); // only the owner unpauses
        paused = p;
        emit PausedSet(p);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Partners
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Pay a partner's accrued $FLIPPER to its current payout address (anyone may call).
    function claimPartner(uint256 partnerId) external nonReentrant onlyDelegateCall returns (uint256 amount) {
        _whenUnlocked();
        amount = partnerAccrued[partnerId];
        if (amount == 0) return 0;
        address to = IPartnerRegistry(partnerRegistry).payoutOf(partnerId);
        if (to == address(0)) revert InvalidAddress();
        partnerAccrued[partnerId] = 0;
        partnerAccruedTotal -= amount;
        flipper.safeTransfer(to, amount);
        emit PartnerClaimed(partnerId, to, amount);
    }

    function setPartnerRegistry(address r) external onlyOwner onlyDelegateCall {
        if (r != address(0) && r.code.length == 0) revert InvalidAddress();
        partnerRegistry = r;
        emit PartnerRegistrySet(r);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Drawdown circuit breaker
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Settle, market-free, a flip whose randomness arrived while the protocol was locked (anyone may call,
    ///         once unlocked). Safe mode: losses become inventory, wins return the stake and reserve the winnings
    ///         (`resolvePendingWin`) — the outcome is public, so nobody may pick a market moment for it.
    function settleDeferred(uint256 flipId) external nonReentrant onlyDelegateCall {
        _whenUnlocked();
        uint256 r = _deferredRoll[flipId];
        Flip storage f = flips[flipId];
        if (r == 0 || f.status != Status.Pending) revert BadStatus();
        delete _deferredRoll[flipId];
        uint16 roll = uint16(r - 1);
        f.roll = roll;
        _settleSafe(flipId, f, roll >= BPS - f.winChanceBps, roll);
        _checkDrawdown();
    }

    /// @notice Track the NAV's all-time high and lock the protocol if the NAV per unit is below half of it (anyone).
    function checkDrawdown() external onlyDelegateCall {
        _checkDrawdown();
    }

    /// @notice Lift the drawdown lock (the unlocker only). `resetAth` re-bases the all-time high to today's NAV per
    ///         unit (otherwise the next check re-locks unless the NAV has recovered above half of the old high).
    function unlock(bool resetAth) external onlyDelegateCall {
        if (msg.sender != unlocker) revert Unauthorized();
        if (!locked) revert BadStatus();
        locked = false;
        uint256 at = _lockedAt;
        if (at != 0) _lockedSeconds += uint64(block.timestamp - at); // (a lock from before the clock existed: 0)
        _lockedAt = 0;
        uint256 nav = _nav();
        if (resetAth) navAth = uint128(nav);
        emit Unlocked(nav, navAth, resetAth);
    }

    /// @notice Start handing the unlocker role to `next` (two-step: `next` accepts).
    function transferUnlocker(address next) external onlyDelegateCall {
        if (msg.sender != unlocker) revert Unauthorized();
        pendingUnlocker = next;
        emit UnlockerTransferStarted(next);
    }

    function acceptUnlocker() external onlyDelegateCall {
        if (msg.sender != pendingUnlocker || msg.sender == address(0)) revert Unauthorized();
        unlocker = msg.sender;
        pendingUnlocker = address(0);
        emit UnlockerTransferred(msg.sender);
    }

    /// @notice Owner: name the unlocker directly, at any time, and drop any pending hand-over. The unlocker is an
    ///         operator key; the owner can always replace a lost or compromised one, so the breaker can't be orphaned.
    function setUnlocker(address u) external onlyOwner onlyDelegateCall {
        if (u == address(0)) revert Unauthorized();
        unlocker = u;
        pendingUnlocker = address(0);
        emit UnlockerTransferred(u);
    }

    /// @notice Owner: below this treasury ($FLIPPER) the drawdown check doesn't run (dust guard).
    function setLockMinTreasury(uint128 amount) external onlyOwner onlyDelegateCall {
        lockMinTreasury = amount;
        emit LockMinTreasurySet(amount);
    }

    /// @notice Lower the drawdown breaker's reference (the all-time-high NAV per unit) to `newAth`, anywhere from today's
    ///         NAV up to the current high (0 = today's NAV); the lock threshold becomes half of it. For a genuine cold
    ///         streak with no sign of exploitation, before it trips the lock. The unlocker only, while unlocked (a locked
    ///         house re-bases through `unlock(true)`). Lower only: raising the reference could only force a lock.
    function resetNavAth(uint256 newAth) external onlyDelegateCall {
        if (msg.sender != unlocker) revert Unauthorized();
        _whenUnlocked();
        uint256 nav = _nav();
        uint256 old = navAth;
        if (newAth == 0) newAth = nav;
        if (newAth < nav || newAth > old) revert AthOutOfBounds(nav, old, newAth);
        navAth = uint128(newAth);
        emit NavAthReset(old, newAth, nav, msg.sender);
    }
}
