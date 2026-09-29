// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

import {V4SwapEngine} from "./base/V4SwapEngine.sol";
import {FlipperToken} from "./FlipperToken.sol";
import {IRevenueRouter} from "./interfaces/IRevenueRouter.sol";
import {IHookitLaunchFactory} from "./interfaces/IHookit.sol";
import {IPonsV2Factory, IPonsV2Curve} from "./interfaces/IPons.sol";

interface IHouseTreasury {
    function depositTreasury(uint256 amount) external;
    function flushRewards() external;
}

/// @notice where holders' $FLIPPER goes: pulls `amount` from the caller and streams it to holders
interface IFlipperDistributor {
    function distribute(uint256 amount) external;
}

interface IEthAuction {
    function kick(address asset, uint256 amount, uint256 refValue) external payable returns (uint256 lotId);
}

/// @notice The LiquidityKeeper as the router uses it.
interface ILiquidityKeeperLaunch {
    function router() external view returns (address);
    function launch(PoolKey calldata key, uint160 sqrtPriceX96, int24 lower, int24 upper, uint128 liquidity)
        external
        payable
        returns (uint256);
}

/// @title RevenueRouter
/// @notice Launches $FLIPPER (the router is its permanent creator and receives the pool's LP fees) and turns protocol
///         revenue into $FLIPPER for (a) the house bankroll and (b) $FLIPPER holders. Upkeep is permissionless.
///
///   Launch paths (exactly one, once):
///     - launchpad factory:   `launchFlipper` — launch through a launchpad factory with this contract as creator;
///                            its creator fees accrue here (legacy path, not used by the default deployment).
///     - pons v2 (Robinhood): `launchFlipperPons` — launch, buy out the bonding curve and create the graduated v4
///                            pool in one transaction; creator fees (70% of the 1% hook fee) accrue here.
///     - self-launched v4:    `launchFlipperV4` — deploys a plain ERC20, opens a hookless v4 pool and seeds it with
///                            single-sided $FLIPPER liquidity held for good by the immutable, ownerless LiquidityKeeper
///                            (a PositionManager NFT: no upgrade of this contract can touch it); its LP fees are the
///                            protocol's creator revenue, collected here. Works on any chain.
///   Every path performs the deployer's opening buy in the launch transaction itself.
///
///   Revenue (all permissionless)
///     - `harvest()` pulls fees in: the house's skimmed profit share (`FlipperHouse.flushRewards`), each owner-set
///       harvest call (fixed target + calldata, e.g. the launchpad escrow's `claim(ETH)`), and the protocol-owned LP
///       position's fees. The caller earns `bountyBps` of the ETH and $FLIPPER it brought in, capped per call.
///     - `process()` (also run by `harvest`) splits the $FLIPPER held: the house share → 100% holders; creator
///       $FLIPPER → `treasuryShareBps` to the bankroll, the rest to holders. Holders' $FLIPPER goes to `rewards`
///       (`distribute`, e.g. the reward-bearing $FLIPPER itself), or waits in `rewardsFlipperPending` while unset.
///     - All ETH is sold for $FLIPPER by Dutch auction on the `converter` (no oracle, no `minOut`, nothing to
///       sandwich); the $FLIPPER it fetches comes back here and is split as creator revenue on the next `process`.
///   Revenue can only ever leave to the house bankroll, the rewards distributor, the converter (ETH, sold for
///   $FLIPPER that returns here) or, as the capped bounty, to whoever harvests.
///
///   Deployed behind a TransparentUpgradeableProxy; storage is append-only.
contract RevenueRouter is IRevenueRouter, V4SwapEngine, Ownable2StepUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    struct HarvestCall {
        address target;
        bytes data;
    }

    uint256 internal constant BPS = 10_000;
    /// bounty ceiling: 1%
    uint16 public constant MAX_BOUNTY_BPS = 100;
    uint256 public constant MAX_HARVEST_CALLS = 8;
    /// @dev gas a swallowed call (house flush, harvest calls, the rewards distributor) must be able to get: below it
    ///      the whole transaction reverts, so gas estimates always include it and nothing is skipped silently
    uint256 internal constant SWALLOWED_CALL_GAS = 300_000;

    IERC20 public flipper;
    /// @dev unused (legacy launchpad-token rewards)
    IERC20 public rewardToken;
    address public house;
    /// @notice holders' $FLIPPER distributor (`distribute(amount)`); address(0) → held in `rewardsFlipperPending`
    address public rewards;
    uint16 public treasuryShareBps;
    uint32 public swapGasLimit;
    /// @dev unused since upkeep went permissionless (slot kept)
    mapping(address => bool) public isKeeper;

    /// @notice $FLIPPER received from the house share that is earmarked 100% for rewards
    uint256 public houseRewardsPending;

    /// @dev unused (slot kept)
    mapping(address => bool) public isCollectTarget;

    /// @dev unused (legacy conversion routes; slots kept)
    PoolKey[] internal _ethToFlipper;
    PoolKey[] internal _ethToReward;
    PoolKey[] internal _flipperToReward;

    /// @dev unused (legacy earmarked ETH; zeroed by the next `process`)
    uint256 public rewardsEthPending;
    /// @dev unused (slot kept)
    mapping(address => bool) public isSwapTarget;

    /// @notice the protocol-owned $FLIPPER liquidity position's pool and range (self-launched v4 path); the position
    ///         itself is a PositionManager NFT held for good by `liquidityKeeper`
    PoolKey internal _lpKey;
    int24 public lpTickLower;
    int24 public lpTickUpper;

    /// @dev unused (slot kept)
    mapping(address => mapping(bytes4 => bool)) public isCollectSelector;

    /// @notice the Dutch-auction converter all ETH revenue is sold on
    address public converter;
    /// @notice holders' $FLIPPER waiting for `rewards` to be set
    uint256 public rewardsFlipperPending;
    /// @notice harvest bounty: share of the ETH / $FLIPPER a `harvest` brings in, capped per call in each asset
    uint16 public bountyBps;
    uint96 public bountyCapEth;
    uint96 public bountyCapFlipper;
    /// @notice ETH below this stays here until more arrives (no dust auction lots)
    uint128 public minLotEth;
    HarvestCall[] internal _harvestCalls;
    /// @notice the immutable, ownerless LiquidityKeeper holding the launch position (fees → `harvest`)
    address public liquidityKeeper;

    event HouseRewardsReceived(uint256 amount);
    event HarvestCallFailed(address indexed target);
    event Harvested(address indexed caller, uint256 ethIn, uint256 flipperIn, uint256 bountyEth, uint256 bountyFlipper);
    event Processed(uint256 flipperToTreasury, uint256 flipperToRewards, uint256 rewardsPending, uint256 ethToAuction);
    event HarvestCallsUpdated();
    event UpkeepParamsSet(address converter, uint16 bountyBps, uint96 bountyCapEth, uint96 bountyCapFlipper, uint128 minLotEth);
    event RewardsSet(address rewards);
    event FlipperLaunched(address indexed launchpad, address indexed token, bytes32 poolId, uint256 tokensOut);
    event Configured(address house, address rewards);

    error Unauthorized();
    error InvalidParams();
    error SwapFailed();
    error AlreadyConfigured();
    error EthRefundFailed();
    error InsufficientGas();
    error ProtocolLocked();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(IPoolManager _poolManager) V4SwapEngine(_poolManager) {
        _disableInitializers();
    }

    function initialize(address _owner) external initializer {
        __Ownable_init(_owner);
        treasuryShareBps = 5000;
        swapGasLimit = 2_500_000;
        bountyBps = 10;
    }

    receive() external payable {}

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Launch (one path, once)
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Launchpad-factory launch with this contract as creator, then buy `extraBuyEth` more in the same
    ///         transaction (legacy path, not used by the default deployment).
    ///         `msg.value` = launchFee + params.devBuyQuoteIn + extraBuyEth (excess refunded).
    function launchFlipper(
        IHookitLaunchFactory factory,
        IHookitLaunchFactory.LaunchParams calldata params,
        uint256 extraBuyEth,
        uint256 minExtraOut,
        address recipient
    ) external payable onlyOwner nonReentrant returns (address token, bytes32 poolId, uint256 tokensOut) {
        _launchable();
        if (params.quote != address(0) || params.customHook != address(0)) revert InvalidParams();
        uint256 ethBefore = address(this).balance - msg.value;

        uint256 launchId;
        (launchId, token, poolId) = factory.launch{value: msg.value - extraBuyEth}(params);
        flipper = IERC20(token);
        if (extraBuyEth != 0) _buy(factory.poolKeyOf(launchId), token, extraBuyEth, minExtraOut);
        tokensOut = _handOut(token, recipient, ethBefore);
        emit FlipperLaunched(address(factory), token, poolId, tokensOut);
    }

    /// @notice pons v2: launch with this contract as creator and fee recipient, buy `buyEth` of the bonding curve
    ///         (clamped to what is left; the whole curve is ≈4.2424 ETH) and, if that graduates it, create the v4
    ///         pool — all in one transaction. `msg.value` = launchFee + buyEth (excess refunded).
    function launchFlipperPons(IPonsV2Factory factory, IPonsV2Factory.TokenParams calldata params, uint256 buyEth, address recipient)
        external
        payable
        onlyOwner
        nonReentrant
        returns (address token, address curve, uint256 tokensOut)
    {
        _launchable();
        if (params.creatorFeeRecipient != address(0) && params.creatorFeeRecipient != address(this)) {
            revert InvalidParams(); // creator fees must accrue to the protocol
        }
        uint256 ethBefore = address(this).balance - msg.value;
        (token, curve) = factory.launchToken{value: factory.launchFee()}(params, 0, address(0));
        flipper = IERC20(token);
        // the launcher is exempt from the snipe tax; the curve refunds any unused ETH
        if (buyEth != 0) IPonsV2Curve(curve).buy{value: buyEth}(buyEth, 0, address(this));
        // a sold-out curve is swept inside the buy (phase 1); seeding the v4 pool is a separate, permissionless call
        if (factory.getLaunchedToken(token).phase == 1) factory.createGraduatedPool(token);
        tokensOut = _handOut(token, recipient, ethBefore);
        emit FlipperLaunched(address(factory), token, bytes32(0), tokensOut);
    }

    /// @notice Self-launch on a hookless Uniswap v4 pool (any chain). Deploys a fixed-supply plain ERC20, initialises
    ///         `(ETH, token, fee, tickSpacing, no hook)` at `sqrtPriceX96` (token per ETH), seeds `poolSupply` as
    ///         single-sided liquidity from that price down to the minimum tick (through `liquidityKeeper`, which holds
    ///         the position for good), then buys `openingBuyEth` for `recipient`, who also receives the rest of the
    ///         supply. `msg.value` above `openingBuyEth` pays the keeper's UNCX lock fee when it locks; the rest is
    ///         refunded.
    function launchFlipperV4(
        string calldata name,
        string calldata symbol,
        uint256 supply,
        uint256 poolSupply,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96,
        uint256 openingBuyEth,
        uint256 minOpeningOut,
        address recipient
    ) external payable onlyOwner nonReentrant returns (address token, uint256 tokensOut) {
        if (poolSupply > supply) revert InvalidParams();
        token = address(new FlipperToken(name, symbol, supply, address(this)));
        tokensOut = _launchV4(token, poolSupply, fee, tickSpacing, sqrtPriceX96, openingBuyEth, minOpeningOut, recipient);
    }

    /// @notice `launchFlipperV4` for a token deployed beforehand with its whole supply minted to this contract (the
    ///         reward-bearing $FLIPPER, whose code is too large to embed here).
    function launchFlipperV4Token(
        IERC20 token,
        uint256 poolSupply,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96,
        uint256 openingBuyEth,
        uint256 minOpeningOut,
        address recipient
    ) external payable onlyOwner nonReentrant returns (uint256 tokensOut) {
        if (poolSupply > token.balanceOf(address(this))) revert InvalidParams();
        tokensOut = _launchV4(
            address(token), poolSupply, fee, tickSpacing, sqrtPriceX96, openingBuyEth, minOpeningOut, recipient
        );
    }

    /// @notice One-time wiring once the house and rewards exist. `flipper` is set by a launch path or here (for a
    ///         $FLIPPER launched elsewhere).
    function configure(IERC20 _flipper, address _house, address _rewards) external onlyOwner {
        if (house != address(0)) revert AlreadyConfigured();
        if (address(flipper) == address(0)) flipper = _flipper;
        else if (address(_flipper) != address(flipper)) revert InvalidParams();
        house = _house;
        rewards = _rewards;
        emit Configured(_house, _rewards);
    }

    /// @inheritdoc IRevenueRouter
    function onHouseRewards(uint256 amount) external {
        if (msg.sender != house) revert Unauthorized();
        houseRewardsPending += amount;
        emit HouseRewardsReceived(amount);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Permissionless upkeep
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Pull all revenue in, pay the caller's bounty, then `process`. Anyone may call.
    ///   1. the house's skimmed profit share (`flushRewards`; no bounty on it)
    ///   2. every harvest call (owner-set target + calldata; a failing call is skipped)
    ///   3. the protocol-owned LP position's fees, through `liquidityKeeper.collect()` (self-launched v4 path)
    ///   The bounty is `bountyBps` of the ETH and of the $FLIPPER that steps 2–3 brought in, each capped
    ///   (`bountyCapEth` / `bountyCapFlipper`). Donating to a fee source to farm it loses 99.9%+ of the donation.
    /// @return bountyEth / bountyFlipper paid to the caller
    function harvest() external nonReentrant returns (uint256 bountyEth, uint256 bountyFlipper) {
        _whenUnlocked();
        _callNoReturn(house, abi.encodeCall(IHouseTreasury.flushRewards, ()));
        uint256 eth0 = address(this).balance;
        uint256 fl0 = flipper.balanceOf(address(this));
        uint256 n = _harvestCalls.length;
        for (uint256 i; i < n; ++i) {
            HarvestCall storage h = _harvestCalls[i];
            if (!_callNoReturn(h.target, h.data)) emit HarvestCallFailed(h.target);
        }
        address keeper = liquidityKeeper;
        if (keeper != address(0) && !_callNoReturn(keeper, abi.encodeWithSignature("collect()"))) {
            emit HarvestCallFailed(keeper);
        }
        uint256 eth1 = address(this).balance;
        uint256 fl1 = flipper.balanceOf(address(this));
        uint256 ethIn = eth1 > eth0 ? eth1 - eth0 : 0;
        uint256 flIn = fl1 > fl0 ? fl1 - fl0 : 0;
        bountyEth = _min(ethIn * bountyBps / BPS, bountyCapEth);
        bountyFlipper = _min(flIn * bountyBps / BPS, bountyCapFlipper);
        if (bountyFlipper != 0) flipper.safeTransfer(msg.sender, bountyFlipper);
        if (bountyEth != 0) {
            (bool sent,) = msg.sender.call{value: bountyEth}("");
            if (!sent) revert EthRefundFailed();
        }
        emit Harvested(msg.sender, ethIn, flIn, bountyEth, bountyFlipper);
        _process();
    }

    /// @notice Route what is held (anyone may call): the house share → holders; creator $FLIPPER →
    ///         `treasuryShareBps` to the bankroll, the rest to holders; all ETH (≥ `minLotEth`) → a converter lot.
    function process() external nonReentrant {
        _whenUnlocked();
        _process();
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Owner, before the launch: the LiquidityKeeper that will hold the launch position (its router must be this).
    function setLiquidityKeeper(address keeper) external onlyOwner {
        _launchable();
        if (ILiquidityKeeperLaunch(keeper).router() != address(this)) revert InvalidParams();
        liquidityKeeper = keeper;
    }

    function lpPosition() external view returns (PoolKey memory key, int24 tickLower, int24 tickUpper) {
        return (_lpKey, lpTickLower, lpTickUpper);
    }

    function harvestCalls() external view returns (HarvestCall[] memory) {
        return _harvestCalls;
    }

    function setTreasuryShareBps(uint16 bps) external onlyOwner {
        if (bps > BPS) revert InvalidParams();
        treasuryShareBps = bps;
    }

    function setSwapGasLimit(uint32 g) external onlyOwner {
        if (g < 200_000) revert InvalidParams();
        swapGasLimit = g;
    }

    /// @notice set the holders' $FLIPPER distributor (address(0): hold in `rewardsFlipperPending`)
    function setRewards(address r) external onlyOwner {
        rewards = r;
        emit RewardsSet(r);
    }

    function setUpkeepParams(address _converter, uint16 _bountyBps, uint96 capEth, uint96 capFlipper, uint128 _minLotEth)
        external
        onlyOwner
    {
        if (_bountyBps > MAX_BOUNTY_BPS) revert InvalidParams();
        converter = _converter;
        bountyBps = _bountyBps;
        bountyCapEth = capEth;
        bountyCapFlipper = capFlipper;
        minLotEth = _minLotEth;
        emit UpkeepParamsSet(_converter, _bountyBps, capEth, capFlipper, _minLotEth);
    }

    /// @notice Add a fee-claim call `harvest` makes (fixed calldata, e.g. a launchpad fee escrow's `claim()`).
    ///         Never a custodied token, the house, the distributor, the converter or the PoolManager.
    function addHarvestCall(address target, bytes calldata data) external onlyOwner {
        _notCustodial(target);
        if (_harvestCalls.length >= MAX_HARVEST_CALLS) revert InvalidParams();
        _harvestCalls.push(HarvestCall(target, data));
        emit HarvestCallsUpdated();
    }

    function removeHarvestCall(uint256 i) external onlyOwner {
        uint256 last = _harvestCalls.length - 1;
        if (i != last) _harvestCalls[i] = _harvestCalls[last];
        _harvestCalls.pop();
        emit HarvestCallsUpdated();
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function _launchV4(
        address token,
        uint256 poolSupply,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96,
        uint256 openingBuyEth,
        uint256 minOpeningOut,
        address recipient
    ) internal returns (uint256 tokensOut) {
        _launchable();
        if (poolSupply == 0 || tickSpacing <= 0 || msg.value < openingBuyEth) revert InvalidParams();
        uint256 ethBefore = address(this).balance - msg.value;
        flipper = IERC20(token);

        address keeper = liquidityKeeper;
        if (keeper == address(0)) revert InvalidParams();
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(token), fee, tickSpacing, IHooks(address(0)));
        // single-sided in currency1 ($FLIPPER): the whole range sits at or below the opening price
        int24 upper = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        upper = (upper / tickSpacing) * tickSpacing;
        if (upper > TickMath.getTickAtSqrtPrice(sqrtPriceX96)) upper -= tickSpacing;
        int24 lower = TickMath.minUsableTick(tickSpacing);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upper);
        // L = amount1 / (√Pb − √Pa)  (Q96)
        uint256 liquidity = FullMath.mulDiv(poolSupply, 1 << 96, sqrtUpper - sqrtLower);
        _lpKey = key;
        lpTickLower = lower;
        lpTickUpper = upper;
        // the keeper initialises the pool and holds the position for good (a PositionManager NFT; UNCX-locked when so
        // configured); `msg.value` above the opening buy pays a lock fee, the rest comes back
        IERC20(token).safeTransfer(keeper, poolSupply);
        ILiquidityKeeperLaunch(keeper).launch{value: msg.value - openingBuyEth}(
            key, sqrtPriceX96, lower, upper, uint128(liquidity)
        );

        if (openingBuyEth != 0) _buy(key, token, openingBuyEth, minOpeningOut);
        tokensOut = _handOut(token, recipient, ethBefore);
        emit FlipperLaunched(address(poolManager), token, keccak256(abi.encode(key)), tokensOut);
    }

    function _launchable() internal view {
        if (address(flipper) != address(0)) revert AlreadyConfigured();
    }

    function _buy(PoolKey memory key, address token, uint256 ethIn, uint256 minOut) internal {
        PoolKey[] memory path = new PoolKey[](1);
        path[0] = key;
        (bool ok,,) = _trySwap(_request(EXACT_IN, path, Currency.wrap(address(0)), _c(token), ethIn, minOut), swapGasLimit);
        if (!ok) revert SwapFailed();
    }

    /// @dev send every launched token held here to `recipient` and refund this call's unused ETH to the caller
    function _handOut(address token, address recipient, uint256 ethBefore) internal returns (uint256 tokensOut) {
        tokensOut = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(recipient, tokensOut);
        uint256 refund = address(this).balance - ethBefore;
        if (refund != 0) {
            (bool sent,) = msg.sender.call{value: refund}("");
            if (!sent) revert EthRefundFailed();
        }
    }

    function _notCustodial(address target) internal view {
        // never a token we custody or a contract that holds / receives revenue (would allow moving funds)
        if (
            target == address(0) || target == address(this) || target == address(flipper) || target == house
                || target == rewards || target == converter || target == address(poolManager)
        ) revert InvalidParams();
    }

    function _process() internal {
        IERC20 fl = flipper;
        uint256 bal = fl.balanceOf(address(this));
        uint256 held = rewardsFlipperPending;
        if (held > bal) held = bal;
        uint256 skim = houseRewardsPending;
        if (skim > bal - held) skim = bal - held;
        uint256 toTreasury = (bal - held - skim) * treasuryShareBps / BPS;
        uint256 toRewards = bal - toTreasury;
        houseRewardsPending = 0;
        rewardsFlipperPending = toRewards;
        if (toTreasury != 0) {
            fl.forceApprove(house, toTreasury);
            IHouseTreasury(house).depositTreasury(toTreasury);
        }
        address r = rewards;
        if (r != address(0) && toRewards != 0) {
            if (gasleft() < SWALLOWED_CALL_GAS) revert InsufficientGas();
            fl.forceApprove(r, toRewards);
            try IFlipperDistributor(r).distribute(toRewards) {
                rewardsFlipperPending = 0;
            } catch {}
            fl.forceApprove(r, 0);
        }
        uint256 eth = address(this).balance;
        address c = converter;
        if (c != address(0) && eth != 0 && eth >= minLotEth) IEthAuction(c).kick{value: eth}(address(0), eth, 0);
        else eth = 0;
        rewardsEthPending = 0;
        emit Processed(toTreasury, toRewards - rewardsFlipperPending, rewardsFlipperPending, eth);
    }

    /// @dev call without copying returndata (a fee source can't return-bomb the harvest)
    function _callNoReturn(address target, bytes memory data) internal returns (bool ok) {
        if (gasleft() < SWALLOWED_CALL_GAS) revert InsufficientGas();
        assembly ("memory-safe") {
            ok := call(gas(), target, 0, add(data, 0x20), mload(data), 0, 0)
        }
    }

    /// @dev the house's drawdown lock halts revenue upkeep too (a house without the breaker never locks)
    function _whenUnlocked() internal view {
        (bool ok, bytes memory r) = house.staticcall(abi.encodeWithSignature("locked()"));
        if (ok && r.length == 32 && abi.decode(r, (bool))) revert ProtocolLocked();
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _c(address a) internal pure returns (Currency) {
        return Currency.wrap(a);
    }
}
