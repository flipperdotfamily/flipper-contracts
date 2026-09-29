// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {V4SwapEngine} from "../base/V4SwapEngine.sol";
import {TransientLock} from "../base/TransientLock.sol";
import {IRandomnessAdapter} from "../interfaces/IRandomness.sol";
import {IRouteAdapter} from "../interfaces/IRouteAdapter.sol";
import {IFlipRewards} from "../interfaces/IFlipRewards.sol";
import {IRevenueRouter} from "../interfaces/IRevenueRouter.sol";

/// @notice The partner registry as the house sees it (see PartnerRegistry).
interface IPartnerRegistry {
    /// @return partnerId 0 = none; cutBps the partner's tier cut of the flip's expected profit; discountBps the share
    ///         of that cut returned to the player as better odds
    function resolve(address player, bytes calldata tail)
        external
        view
        returns (uint256 partnerId, uint256 cutBps, uint256 discountBps);
    function payoutOf(uint256 partnerId) external view returns (address);
}

interface IAuctionConverter {
    function kick(address asset, uint256 amount, uint256 refValue) external payable returns (uint256 lotId);
}

/// @title FlipperHouseBase
/// @notice Shared state, types, events and helpers of the house. Two contracts inherit it and share its storage
///         exactly: `FlipperHouse` (the proxy's implementation: the hot path) and `HouseModule` (cold paths the house
///         delegatecalls: listing, upkeep, admin, partner claims). Storage is append-only.
abstract contract FlipperHouseBase is V4SwapEngine, Ownable2StepUpgradeable, TransientLock {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    enum Status {
        None,
        Pending, // waiting for randomness
        Won, // paid 2x in the flipped token (or 2.1x $FLIPPER for $FLIPPER flips)
        WonFallback, // stake returned + winnings paid in $FLIPPER because the buy could not execute
        WinPending, // stake returned; winnings owed, to be resolved by a keeper (pool unusable both ways)
        Lost, // stake sold into the bankroll
        LostInventory, // stake kept by the house as inventory (sale could not clear the floor)
        Refunded // cancelled before randomness arrived; stake returned
    }

    struct Flip {
        address player;
        uint40 createdAt;
        uint16 winChanceBps;
        uint16 roll;
        Status status;
        address token;
        uint128 amount;
        uint128 liability;
        uint128 sellQuote;
        uint128 buyQuote;
        uint256 requestId;
        uint16 payoutBps; // $FLIPPER payout, fixed at flip time
    }

    struct Params {
        uint16 baseWinChanceBps; // 4500 = 45%
        uint16 minWinChanceBps; // floor after the chance-based fee
        uint16 flipperPayoutBps; // 20500 = 2.05x on $FLIPPER flips
        uint16 minHouseEdgeBps; // guaranteed expected profit per flip after all route costs (2%)
        uint16 maxRouteCostBps; // hard reject above this route cost
        uint16 lossSlippageBps; // loss-side sale may clear at most this far below the flip-time quote
        uint16 maxBetBps; // hard ceiling on a flip's liability, as a share of the unreserved bankroll (5%)
        uint16 rewardsShareBps; // share of each flip's expected profit paid to $FLIPPER holders (50%)
        uint16 listingMaxRouteCostBps; // permissionless listing: a probe-sized round trip must cost ≤ this
        uint16 listingProbeBps; // permissionless listing probes a stake of this share of the max bet
        uint32 callbackGasLimit;
        uint32 swapGasLimit; // gas cap for each swap / quote attempt
        uint32 guardianCancelDelay;
        uint32 playerCancelDelay;
        uint128 minListingProbe; // lower bound on the listing probe, in $FLIPPER wei
        uint32 flipperCallbackGasLimit; // $FLIPPER flips never swap: a much smaller (cheaper) callback budget
        uint32 pendingTimeout; // after this a pending win may be paid its reserved liability in $FLIPPER
        uint16 maxReservedBps; // cap on all pending flips' liabilities as a share of the treasury (0 = off)
        // a flip's liability is also capped at this share of its own Kelly fraction of the unreserved bankroll
        // (5000 = half Kelly; 0, only in storage upgraded from before this field: the flat maxBetBps cap alone)
        uint16 kellyBps;
    }

    struct TokenConfig {
        bool enabled;
        bool blocked; // set when an admin disables a token; blocks permissionless re-listing
        address adapter; // adapter that listed it (0 = owner)
        PoolKey[] route; // token → $FLIPPER
        // reserved for per-token overrides (0 = the global parameter); not used yet
        uint128 maxLiability; // per-token max bet (e.g. a token's max-transaction cap)
        uint32 callbackGasLimit; // per-token callback gas class (Pyth charges per reserved callback gas)
    }

    /// @dev The edge schedule: the base win chance and the $FLIPPER payout step from their start to their end values
    ///      as the house's own net buybacks (`buybackHigh`, the ratcheted high of `netBuybackEth`) grow from `fromEth`
    ///      to `toEth`, linearly; they never step back. One slot.
    struct EdgeSchedule {
        uint96 fromEth; // ETH wei
        uint96 toEth; // ETH wei; 0 = off (Params' baseWinChanceBps / flipperPayoutBps apply)
        uint16 winStartBps;
        uint16 winEndBps;
        uint16 payoutStartBps;
        uint16 payoutEndBps;
    }

    /// @dev a flip's partner attribution, fixed at flip time
    struct PartnerTag {
        uint32 partnerId;
        uint16 shareBps; // the partner's share of the flip's expected profit, bps of its value
    }

    struct Preview {
        uint8 code; // 0 = ok, otherwise a REJECT_* code
        uint256 sellQuote;
        uint256 buyQuote;
        uint256 routeCostBps;
        uint256 winChanceBps;
        uint256 liability;
        uint256 maxLiability;
        uint256 randomnessFee;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    uint256 internal constant BPS = 10_000;
    uint256 internal constant PAY_GAS = 100_000;
    /// @dev Gas every settlement swap attempt leaves for the rest of the settlement: balance checks, payments or
    ///      claimable credits and events. Covers the worst case in which the flipped token burns
    ///      every capped call (test/SettlementGas.t.sol), so no attempt can make the callback run out of gas.
    uint256 internal constant SETTLE_OVERHEAD_GAS = 350_000;
    /// @dev gas cap and returndata bound of the partner registry lookup (a failing lookup means "no partner")
    uint256 internal constant PARTNER_GAS = 50_000;

    // Preview.code / FlipRejected(code): 0 ok, 1 paused, 2 amount, 3 token not listed, 4 quote failed,
    // 5 route too expensive, 6 win chance below floor, 7 exceeds max bet
    uint8 internal constant OK = 0;
    uint8 internal constant REJECT_PAUSED = 1;
    uint8 internal constant REJECT_AMOUNT = 2;
    uint8 internal constant REJECT_TOKEN = 3;
    uint8 internal constant REJECT_QUOTE = 4;
    uint8 internal constant REJECT_ROUTE_COST = 5;
    uint8 internal constant REJECT_WIN_CHANCE = 6;
    uint8 internal constant REJECT_BET_SIZE = 7;
    uint8 internal constant REJECT_LOCKED = 8;
    /// @dev the player already has `maxOpenPerPlayer` flips waiting for randomness
    uint8 internal constant REJECT_TOO_MANY_OPEN = 9;
    /// @dev `maxOpenPerPlayer` when unset (0): one player can't take more of the randomness adapter's open requests
    uint16 internal constant DEFAULT_MAX_OPEN_PER_PLAYER = 4;
    /// @dev the drawdown breaker locks when the NAV per unit falls below this share of its all-time high
    uint256 internal constant DRAWDOWN_LOCK_BPS = 5000;
    /// @dev a token win the buy can't deliver pays the stake back plus this much of the flip-time buy quote in
    ///      $FLIPPER (a 5% bonus for the delayed, different-token payout); it is also a token flip's liability
    uint256 internal constant TOKEN_FALLBACK_BPS = 10_500;
    uint256 internal constant NAV_ONE = 1e18;
    /// @dev before this, the guardian may cancel only a flip whose randomness is provably unrevealed
    uint256 internal constant GUARDIAN_EMERGENCY_CANCEL_DELAY = 30 days;

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IERC20 public immutable flipper;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IRandomnessAdapter public immutable randomness;

    Params internal _params;
    address public guardian;
    mapping(address => bool) internal isKeeper; // unused since upkeep went permissionless (slot kept)
    mapping(address => bool) public isRouteAdapter;
    /// @dev unused: the optional flipper-volume rewards hook was removed (slot kept)
    IFlipRewards internal rewards;
    address public revenueRouter;
    bool public paused;

    /// @notice $FLIPPER owned by the bankroll (includes `reserved`)
    uint256 public treasury;
    /// @notice $FLIPPER earmarked for pending flips' worst-case payouts; always <= treasury
    uint256 public reserved;
    /// @notice skimmed profit waiting to be converted to launchpad-token rewards
    uint256 public rewardsAccrued;
    mapping(address token => uint256) public escrowed;
    mapping(address token => uint256) public inventory;
    mapping(address token => uint256) public claimableTotal;
    mapping(address user => mapping(address token => uint256)) public claimable;

    mapping(address token => TokenConfig) internal _tokens;
    address[] public listedTokens;

    uint256 public nextFlipId;
    mapping(uint256 flipId => Flip) public flips;
    mapping(uint256 requestId => uint256 flipId) public flipIdByRequest;
    /// @notice staking vault (TreasuryVault); once set, the only account that can withdraw bankroll
    address public vault;
    /// @notice Dutch-auction converter that sells inventory for $FLIPPER back into the bankroll
    address public converter;
    /// @notice flip-time sell value ($FLIPPER) of each token's inventory: the auction's reference price
    mapping(address token => uint256) public inventoryValue;
    /// @notice the partner registry (codes, payouts, tiers); address(0) = no partner attribution
    address public partnerRegistry;
    /// @notice $FLIPPER accrued to each partner, claimable to its payout address (`claimPartner`)
    mapping(uint256 partnerId => uint256) public partnerAccrued;
    /// @notice sum of `partnerAccrued`: held by the house outside the bankroll
    uint256 public partnerAccruedTotal;
    /// @notice partner attribution of each attributed flip
    mapping(uint256 flipId => PartnerTag) public flipPartner;

    /// @notice Bankroll units: capital deposits (the vault's; the first seed) mint and capital withdrawals burn them
    ///         at the current NAV, so the NAV per unit — `treasury / navUnits` — moves only with the bankroll's
    ///         performance (flip PnL, income), never with stakers coming or going.
    uint128 public navUnits;
    /// @notice all-time-high NAV per unit (1e18 = one $FLIPPER per unit at the first seed); 0 until the treasury first
    ///         reaches `lockMinTreasury`
    uint128 public navAth;
    /// @notice below this treasury ($FLIPPER) the drawdown check doesn't run (dust guard)
    uint128 public lockMinTreasury;
    /// @notice the drawdown circuit breaker: set when the NAV per unit falls below 50% of its ATH; every user-facing
    ///         state change halts until the unlocker unlocks
    bool public locked;
    /// @notice the only account that can lift the lock (the deployer's key; not the owner or the guardian)
    address public unlocker;
    address public pendingUnlocker;
    /// @dev randomness delivered while locked: roll + 1, settled market-free by `settleDeferred` after unlock
    mapping(uint256 flipId => uint256) internal _deferredRoll;
    /// @notice each player's flips still waiting for randomness (at most `maxOpenPerPlayer`)
    mapping(address player => uint256) public openFlips;
    /// @notice the smallest liability a flip may carry, in $FLIPPER: a flip (and the randomness request it holds open)
    ///         must put real value at risk, not dust (0 = no floor)
    uint128 public minLiability;
    /// @notice most flips one player may have waiting for randomness at once (0 = DEFAULT_MAX_OPEN_PER_PLAYER)
    uint16 public maxOpenPerPlayer;
    /// @dev when the current drawdown lock began (0 while unlocked)
    uint64 internal _lockedAt;
    /// @dev total seconds of completed drawdown locks (see `lockedTime`)
    uint64 internal _lockedSeconds;
    /// @notice drawdown-scaled Kelly: the multiplier slides from `Params.kellyBps` (the max) at a drawdown of
    ///         `kellyDdStartBps` down to `kellyMinBps` at `kellyDdEndBps` (drawdown = 1 − NAV per unit / its ATH, as the
    ///         breaker measures it); `kellyDdEndBps` 0 = off (flat `kellyBps`)
    uint16 public kellyMinBps;
    uint16 public kellyDdStartBps;
    uint16 public kellyDdEndBps;
    /// @notice the edge schedule (see `EdgeSchedule`)
    EdgeSchedule public edgeSchedule;
    /// @notice the house's net buybacks: the real ETH its own settlement swaps moved through the $FLIPPER pool hop —
    ///         + a token-flip loss's sale (… → ETH → $FLIPPER), − a token-flip win's buy ($FLIPPER → ETH → …), also
    ///         when `resolvePendingWin` buys. $FLIPPER flips and $FLIPPER fallbacks don't swap and don't count.
    int128 public netBuybackEth;
    /// @notice the ratchet: the highest `netBuybackEth` so far (the owner may re-base it); the edge keys on it
    int128 public buybackHigh;

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Events / errors
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    event FlipRequested(
        uint256 indexed flipId,
        address indexed player,
        address indexed token,
        uint256 amount,
        uint256 winChanceBps,
        uint256 sellQuote,
        uint256 buyQuote,
        uint256 liability,
        uint256 requestId,
        uint256 randomnessFee
    );
    event FlipSettled(
        uint256 indexed flipId,
        address indexed player,
        address indexed token,
        bool won,
        uint256 roll,
        Status status,
        uint256 tokenPaid,
        uint256 flipperPaid,
        uint256 flipperReceived,
        bool safeMode
    );
    event FlipCancelled(uint256 indexed flipId, address indexed by);
    event PendingWinResolved(uint256 indexed flipId, uint256 tokenPaid, uint256 flipperPaid);
    /// a token that can't be transferred out: left for the guardian to write off
    event InventoryStuck(address indexed token, uint256 amount);
    event InventoryWrittenOff(address indexed token, uint256 amount);
    event PaymentDeferred(address indexed to, address indexed token, uint256 amount);
    event Claimed(address indexed to, address indexed token, uint256 amount);
    event TreasuryDeposit(address indexed from, uint256 amount);
    event TreasuryWithdrawal(address indexed to, uint256 amount);
    event ProfitShared(uint256 proceeds, uint256 toHolders);
    event RewardsFlushed(address indexed router, uint256 amount);
    event TokenListed(address indexed token, address indexed adapter, PoolKey[] route);
    event TokenEnabled(address indexed token, bool enabled);
    event ParamsUpdated(Params params);
    event GuardianUpdated(address guardian);
    event ConverterSet(address converter);
    event RouteAdapterUpdated(address adapter, bool allowed);
    event RevenueRouterUpdated(address router);
    event PausedSet(bool paused);
    event VaultSet(address vault);
    /// a flip attributed to a partner: its tier cut, the discount returned as odds, and the partner's share (bps)
    event FlipPartner(
        uint256 indexed flipId,
        uint256 indexed partnerId,
        uint256 cutBps,
        uint256 discountBps,
        uint256 winChanceBonusBps,
        uint256 partnerShareBps
    );
    event PartnerAccrued(uint256 indexed partnerId, uint256 indexed flipId, uint256 amount);
    event PartnerClaimed(uint256 indexed partnerId, address indexed to, uint256 amount);
    event PartnerRegistrySet(address registry);
    event DrawdownLocked(uint256 navPerUnit, uint256 athNavPerUnit);
    event Unlocked(uint256 navPerUnit, uint256 athNavPerUnit, bool athReset);
    event SettlementDeferred(uint256 indexed flipId);
    event UnlockerTransferStarted(address indexed pending);
    event UnlockerTransferred(address indexed unlocker);
    event LockMinTreasurySet(uint256 amount);
    event NavAthReset(uint256 oldAth, uint256 newAth, uint256 navPerUnit, address indexed caller);
    event FlipLimitsSet(uint256 maxOpenPerPlayer, uint256 minLiability);
    event EdgeScheduleSet(EdgeSchedule schedule);
    event BuybackHighSet(int256 buybackHigh);
    event KellyScheduleSet(uint256 maxBps, uint256 minBps, uint256 ddStartBps, uint256 ddEndBps);

    error FlipRejected(uint8 code);
    error Expired();
    error InvalidParams();
    error InvalidAddress();
    error Unauthorized();
    error FeeOnTransfer();
    error InsufficientFee(uint256 sent, uint256 required);
    error DuplicateRequest();
    error OnlyRandomness();
    error BadStatus();
    error TooEarly();
    error RandomnessRevealed();
    error ExceedsAvailable();
    error TokenBlocked();
    error AlreadyListed();
    error ListingProbeFailed(uint256 routeCostBps);
    error EthTransferFailed();
    error VaultAlreadySet();
    /// @dev a call whose failure would be swallowed didn't get enough gas: revert so gas estimates include it
    error InsufficientGas();
    error ProtocolLocked();
    /// @dev `resetNavAth` takes a reference between today's NAV per unit and the current all-time high
    error AthOutOfBounds(uint256 navPerUnit, uint256 athNavPerUnit, uint256 requested);

    modifier onlyGuardian() {
        if (msg.sender != guardian && msg.sender != owner()) revert Unauthorized();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(IPoolManager _poolManager, IERC20 _flipper, IRandomnessAdapter _randomness) V4SwapEngine(_poolManager) {
        if (address(_flipper) == address(0) || address(_randomness) == address(0)) revert InvalidAddress();
        flipper = _flipper;
        randomness = _randomness;
        _disableInitializers();
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Shared helpers
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev the base win chance and the $FLIPPER payout now: the edge schedule at the buyback high (win chance rounded
    ///      down, payout rounded up: in the house's favour), or Params' values when it is off
    function _baseTerms() internal view returns (uint256 win, uint256 payout) {
        EdgeSchedule memory s = edgeSchedule;
        if (s.toEth == 0) return (_params.baseWinChanceBps, _params.flipperPayoutBps);
        int256 h = buybackHigh;
        uint256 t; // progress, WAD
        if (h >= int256(uint256(s.toEth))) t = 1e18;
        else if (h > int256(uint256(s.fromEth))) t = (uint256(h) - s.fromEth) * 1e18 / (s.toEth - s.fromEth);
        return (_lerp(s.winStartBps, s.winEndBps, t), _lerp(s.payoutStartBps, s.payoutEndBps, t));
    }

    /// @dev a → b by `t` (WAD), rounded down either way: a lower win chance and a lower payout favour the house
    function _lerp(uint256 a, uint256 b, uint256 t) internal pure returns (uint256) {
        return a <= b ? a + (b - a) * t / 1e18 : a - Math.mulDiv(a - b, t, 1e18, Math.Rounding.Ceil);
    }

    /// @dev transient: the ETH the last swap moved through its $FLIPPER-end hop (the engine's `_onEthHop`). Quotes
    ///      revert, and their record with them; a successful `_trySwap` leaves exactly its own.
    bytes32 internal constant ETH_HOP_SLOT = keccak256("flipper.house.ethHop");

    function _tracksEthHop() internal pure override returns (bool) {
        return true;
    }

    function _onEthHop(uint256 eth) internal override {
        bytes32 slot = ETH_HOP_SLOT;
        assembly ("memory-safe") {
            tstore(slot, eth)
        }
    }

    /// @dev book the ETH the last swap moved through the $FLIPPER pool hop: + a sale into it, − a buy out of it
    function _bookBuyback(bool sale) internal {
        bytes32 slot = ETH_HOP_SLOT;
        uint256 eth;
        assembly ("memory-safe") {
            eth := tload(slot)
        }
        if (eth == 0) return;
        int128 net = int128(int256(netBuybackEth) + (sale ? int256(eth) : -int256(eth)));
        netBuybackEth = net;
        if (net > buybackHigh) buybackHigh = net;
    }

    /// @dev the Kelly multiplier now: `Params.kellyBps`, backed off linearly with the drawdown (see `kellyMinBps`);
    ///      the max until the drawdown check is live (an ATH, a treasury at or above `lockMinTreasury`)
    function _kelly() internal view returns (uint256 k) {
        k = _params.kellyBps;
        uint256 end = kellyDdEndBps;
        uint256 ath = navAth;
        if (end == 0 || ath == 0 || treasury < lockMinTreasury) return k;
        uint256 nav = _nav();
        if (nav >= ath) return k;
        uint256 dd = (ath - nav) * BPS / ath;
        uint256 start = kellyDdStartBps;
        if (dd <= start) return k;
        uint256 kmin = kellyMinBps;
        if (dd >= end) return kmin;
        return k - (k - kmin) * (dd - start) / (end - start);
    }

    function _maxOpenPerPlayer() internal view returns (uint256) {
        uint256 m = maxOpenPerPlayer;
        return m == 0 ? DEFAULT_MAX_OPEN_PER_PLAYER : m;
    }

    /// @dev a flip stops waiting for randomness (delivered, deferred or cancelled): free the player's slot
    function _closeOpen(address player) internal {
        uint256 n = openFlips[player];
        if (n != 0) openFlips[player] = n - 1; // (flips made before the counter existed never counted)
    }

    function _whenUnlocked() internal view {
        if (locked) revert ProtocolLocked();
    }

    /// @dev NAV per unit (1e18 = one $FLIPPER per unit); 0 before the first seed
    function _nav() internal view returns (uint256) {
        uint256 u = navUnits;
        return u == 0 ? 0 : treasury * NAV_ONE / u;
    }

    /// @dev Track the all-time-high NAV per unit and trip the breaker below half of it. Runs after everything that
    ///      can move the NAV (settlements, payouts, deposits) and via `checkDrawdown`. Reads nothing but the house's
    ///      own $FLIPPER accounting: no price, pool or oracle can move it.
    function _checkDrawdown() internal {
        if (locked || treasury < lockMinTreasury) return;
        uint256 nav = _nav();
        uint256 ath = navAth;
        if (nav > ath) {
            navAth = uint128(nav);
        } else if (nav * BPS < ath * DRAWDOWN_LOCK_BPS) {
            locked = true;
            _lockedAt = uint64(block.timestamp);
            emit DrawdownLocked(nav, ath);
        }
    }

    /// @dev Gas for one settlement swap attempt: at most `cap`, and never the `SETTLE_OVERHEAD_GAS` the rest of the
    ///      settlement needs (0 when that is all that is left: the attempt then fails and settlement degrades).
    function _attemptGas(uint256 cap) internal view returns (uint256) {
        uint256 left = gasleft();
        left = left > SETTLE_OVERHEAD_GAS ? left - SETTLE_OVERHEAD_GAS : 0;
        return cap < left ? cap : left;
    }

    /// @notice The hard ceiling on a single new flip's liability (`maxBetBps` of the unreserved bankroll). Each flip's
    ///         own cap is usually lower (its Kelly term): `previewFlip(...).maxLiability`.
    function maxLiability() public view returns (uint256) {
        uint256 t = treasury;
        uint256 r = reserved;
        return t > r ? (t - r) * _params.maxBetBps / BPS : 0;
    }

    /// @dev The largest liability a flip with these terms may take on: `min(maxBetBps, kellyBps × f*)` of the
    ///      unreserved bankroll. f* is the bankroll's exact Kelly fraction for the flip, per unit of what it loses when
    ///      the player wins (W: the buy, `b`, on a token flip; the payout less the stake on a $FLIPPER flip) against
    ///      what it keeps when the player loses (G: the sale proceeds `s` less the partner's and holders' shares, as
    ///      `_creditLoss` books them): f* = q − p·W/G. Per unit of proceeds, W = w / BPS and G = G' / (BPS·q) with
    ///      G' = BPS·q − (σ·BPS + (e − σ)·ρ), so f* = q·(G' − p·w) / (BPS·G'). A token flip's liability is 1.05·b
    ///      (it also reserves the fallback bonus), so capping the liability keeps the buy at risk 5% under Kelly.
    ///      f* ≤ 0 → 0.
    /// @param p the player's win chance (after the chance-based fee and any partner discount)
    /// @param s / b the flip-time sell and buy quotes ($FLIPPER; both the stake on a $FLIPPER flip)
    /// @param shareBps the partner's share of the flip's value
    function _betCap(bool isFlipper, uint256 p, uint256 s, uint256 b, uint256 shareBps) internal view returns (uint256) {
        Params storage pr = _params;
        uint256 t = treasury;
        uint256 r = reserved;
        if (t <= r) return 0;
        uint256 unres = t - r;
        uint256 cap = unres * pr.maxBetBps / BPS;
        uint256 k = _kelly();
        if (k == 0) return cap;
        (, uint256 payout) = _baseTerms();
        uint256 q = BPS - p;
        uint256 e = _edge(isFlipper, p, s, b, payout);
        uint256 sh = shareBps < e ? shareBps : e;
        // all three per unit of proceeds, ×BPS·q·BPS (the extra BPS keeps W's rounding under 0.01%)
        uint256 d = (sh * BPS + (e - sh) * pr.rewardsShareBps) * BPS;
        uint256 w = isFlipper ? (payout - BPS) * BPS : Math.mulDiv(b, BPS * BPS, s, Math.Rounding.Ceil);
        uint256 g = BPS * q * BPS;
        if (g <= d + p * w) return 0;
        g -= d;
        uint256 kelly = Math.mulDiv(unres, k * q * (g - p * w), BPS * BPS * g);
        return kelly < cap ? kelly : cap;
    }

    function _callbackGas(address token) internal view returns (uint32) {
        return token == address(flipper) ? _params.flipperCallbackGasLimit : _params.callbackGasLimit;
    }

    function _pullExact(address token, uint256 amount) internal {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) - before != amount) revert FeeOnTransfer();
    }

    /// @dev Gas-bounded push payment that can never revert; failures become claimable balances.
    function _pay(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!_tryTransfer(token, to, amount)) _credit(to, token, amount);
    }

    function _credit(address to, address token, uint256 amount) internal {
        if (amount == 0) return;
        claimable[to][token] += amount;
        claimableTotal[token] += amount;
        emit PaymentDeferred(to, token, amount);
    }

    /// @dev Buy exactly `amount` of `token` for at most `maxIn` $FLIPPER, as one gas-capped settlement attempt.
    ///      `received` is what actually arrived (a transfer-taxing token can't make us dip into other escrow); if the
    ///      token's balanceOf is unusable, the PoolManager's exact-output delivery is trusted.
    function _buyWinnings(address token, uint256 amount, uint256 maxIn, PoolKey[] memory route)
        internal
        returns (bool ok, uint256 spent, uint256 received)
    {
        (bool okB0, uint256 balBefore) = _balanceOf(token);
        (ok, spent,) = _trySwap(
            _request(EXACT_OUT, _reversePath(route), _c(address(flipper)), _c(token), amount, maxIn),
            _attemptGas(_params.swapGasLimit)
        );
        if (ok) {
            _bookBuyback(false);
            (bool okB1, uint256 balAfter) = _balanceOf(token);
            received = okB0 && okB1 ? (balAfter > balBefore ? balAfter - balBefore : 0) : amount;
            if (received > amount) received = amount;
        }
    }

    /// @dev Gas-bounded balanceOf that never reverts (untrusted token code runs inside settlement).
    function _balanceOf(address token) internal view returns (bool ok, uint256 bal) {
        bytes4 selector = IERC20.balanceOf.selector;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), address())
            // sequenced on purpose: Yul evaluates arguments right-to-left, so returndatasize() must be read
            // after the call, not alongside it
            ok := staticcall(50000, token, m, 0x24, 0x00, 0x20)
            ok := and(ok, gt(returndatasize(), 31))
            if ok { bal := mload(0x00) }
        }
    }

    function _tryTransfer(address token, address to, uint256 amount) internal returns (bool success) {
        bytes4 selector = IERC20.transfer.selector;
        uint256 g = PAY_GAS;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), to)
            mstore(add(m, 0x24), amount)
            // at most 32 bytes of returndata are copied (no returndata bombs)
            success := call(g, token, 0, m, 0x44, 0x00, 0x20)
            if success {
                switch returndatasize()
                case 0 { success := gt(extcodesize(token), 0) }
                default { success := and(gt(returndatasize(), 31), eq(mload(0x00), 1)) }
            }
        }
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    function _c(address a) internal pure returns (Currency) {
        return Currency.wrap(a);
    }

    /// @dev Market-free settlement for deliveries whose timing may have been chosen with the outcome known.
    ///      Makes no external calls: everything owed to the player becomes a claimable balance.
    function _settleSafe(uint256 flipId, Flip storage f, bool won, uint16 roll) internal {
        address token = f.token;
        address player = f.player;
        uint256 amount = f.amount;
        escrowed[token] -= amount;
        reserved -= f.liability;

        Status st;
        uint256 tokenPaid;
        uint256 flipperPaid;
        uint256 flipperReceived;
        if (token == address(flipper)) {
            if (won) {
                uint256 payout = amount * f.payoutBps / BPS;
                flipperPaid = payout - amount;
                treasury -= flipperPaid;
                _credit(player, token, payout);
                st = Status.Won;
            } else {
                flipperReceived = amount;
                _creditLoss(flipId, amount, amount, _edgeBps(f), f.winChanceBps);
                st = Status.Lost;
            }
        } else if (won) {
            tokenPaid = amount;
            _credit(player, token, amount);
            reserved += f.liability; // winnings resolved by a keeper at a fair price
            st = Status.WinPending;
        } else {
            inventory[token] += amount;
            inventoryValue[token] += f.sellQuote;
            st = Status.LostInventory;
        }
        f.status = st;
        emit FlipSettled(flipId, player, token, won, roll, st, tokenPaid, flipperPaid, flipperReceived, true);
    }

    /// @dev Books a lost stake's proceeds. The flip's *expected* profit is paid out of the loss, scaled by
    ///      1 / P(loss) so that across wins and losses the shares come out exactly: a partner's share (fixed at flip
    ///      time) first, then `rewardsShare` of the rest to holders; the bankroll keeps the remainder. `basis` (the
    ///      stake's flip-time mid value) is capped by the realized proceeds, so an inflated flip-time quote can't
    ///      inflate a share, and the shares together never exceed the proceeds.
    function _creditLoss(uint256 flipId, uint256 proceeds, uint256 basis, uint256 edgeBps, uint256 winChanceBps)
        internal
    {
        uint256 base = Math.min(basis, proceeds);
        uint256 denom = BPS * (BPS - winChanceBps);
        PartnerTag memory t = flipPartner[flipId];
        uint256 share = t.shareBps < edgeBps ? t.shareBps : edgeBps;
        uint256 toPartner;
        if (share != 0) {
            toPartner = Math.mulDiv(base, share * BPS, denom);
            partnerAccrued[t.partnerId] += toPartner;
            partnerAccruedTotal += toPartner;
            emit PartnerAccrued(t.partnerId, flipId, toPartner);
        }
        uint256 toHolders = Math.mulDiv(base, (edgeBps - share) * _params.rewardsShareBps, denom);
        if (toHolders + toPartner > proceeds) toHolders = proceeds - toPartner;
        rewardsAccrued += toHolders;
        treasury += proceeds - toHolders - toPartner;
        emit ProfitShared(proceeds, toHolders);
    }

    /// @dev Expected house profit of a flip (bps of the stake's mid value) under its own flip-time terms.
    function _edgeBps(Flip storage f) internal view returns (uint256) {
        return _edge(f.token == address(flipper), f.winChanceBps, f.sellQuote, f.buyQuote, f.payoutBps);
    }

    /// @dev Expected house profit (bps of the stake's mid value) at win chance `p`, quotes `s` / `b`, payout `payout`.
    function _edge(bool isFlipper, uint256 p, uint256 s, uint256 b, uint256 payout) internal pure returns (uint256) {
        if (isFlipper) return BPS - Math.mulDiv(p, payout, BPS, Math.Rounding.Ceil);
        uint256 h = b > s ? Math.mulDiv(b - s, BPS, b + s, Math.Rounding.Ceil) : 0;
        return BPS > h + 2 * p ? BPS - h - 2 * p : 0;
    }
}
