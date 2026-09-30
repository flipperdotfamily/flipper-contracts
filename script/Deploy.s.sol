// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapMath} from "v4-core/libraries/SwapMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {FlipperRewardToken} from "../src/FlipperRewardToken.sol";
import {MockEntropyV2} from "../src/mocks/MockEntropyV2.sol";
import {MockVRFWrapper} from "../src/mocks/MockVRFWrapper.sol";
import {DevSwapRouter} from "../src/mocks/DevSwapRouter.sol";
import {IRandomnessAdapter} from "../src/interfaces/IRandomness.sol";
import {IVRFV2PlusWrapper} from "../src/interfaces/IVRFV2PlusWrapper.sol";
import {IEntropyV2} from "../src/interfaces/IEntropyV2.sol";
import {IHookitLaunchFactory} from "../src/interfaces/IHookit.sol";
import {IPonsV2Factory} from "../src/interfaces/IPons.sol";
import {ILaunchpadVerifier} from "../src/interfaces/ILaunchpadVerifier.sol";
import {FlipperDeploy} from "./lib/FlipperDeploy.sol";
import {DiceDeploy} from "./lib/DiceDeploy.sol";
import {IDiceEntropy} from "../src/interfaces/IDiceEntropy.sol";
import {DiceEntropyAdapter} from "../src/randomness/DiceEntropyAdapter.sol";
import {InkAddresses} from "./lib/InkAddresses.sol";
import {RobinhoodAddresses} from "./lib/RobinhoodAddresses.sol";
import {IUNCXV4Locker} from "../src/LiquidityKeeper.sol";

interface IChainlinkFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IFactoryMcap {
    function launchMcapQuoteWei() external view returns (uint256);
}

/// Uniswap SwapRouter02 (IV3SwapRouter: no deadline field)
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Deploys flipper.family and writes a deployment manifest. Defaults: Robinhood Chain, our own reward-bearing
///         $FLIPPER on a hookless Uniswap v4 pool, Dice randomness.
///
///   CHAIN      robinhood (default) | ink (legacy)
///   LAUNCHPAD  how $FLIPPER is launched — always from the RevenueRouter (the protocol is the permanent creator; the
///              LP position is held for good by the LiquidityKeeper) with the opening buy inside the launch transaction:
///                v4    (default)  our own ERC20 + hookless ETH-quoted v4 pool seeded single-sided through the keeper
///                                 (V4_START_MCAP_USD, default $5k; V4_POOL_BPS, default all of the supply; V4_FEE,
///                                 V4_TICK_SPACING), then the opening buy: exactly OPENING_BUY_SUPPLY_BPS of the supply
///                                 (default 1500 = 15%; 0 = an OPENING_BUY_USD buy instead).
///                                 The token is the reward-bearing $FLIPPER (`FlipperRewardToken`: holder rewards
///                                 streamed in $FLIPPER to every holder; REWARD_BEARING=0 for a plain ERC20)
///                pons  (legacy)   pons v2 bonding curve bought out in the launch transaction (PONS_BUY_ETH)
///
///   Env
///     DEPLOYER_PRIVATE_KEY   broadcaster (also the first funded dev account)
///     KEEPER_ADDRESS         dev randomness provider / fulfiller (and house guardian when DEV=1); house and router
///                            upkeep is permissionless (no keeper role)
///     OWNER / PROXY_ADMIN_OWNER   default: deployer (production: multisig / TimelockController)
///     REWARD_TOKEN           starter token seeded to dev accounts (default PONS; manifest `rewardToken`, kept for
///                            tooling). Holder rewards are paid in $FLIPPER by the token itself (manifest
///                            `holderRewards` = the $FLIPPER token)
///     ENTROPY_MODE           randomness source:
///                            dice         Dice Protocol (DiceEntropy, a Pyth Entropy v2 fork) with its default
///                                         provider (default on the live chain)
///                            dice-mirror  dev on a Robinhood fork: the live DiceEntropy, provider re-keyed by the keeper
///                                         (DEV=1 default)
///                            dice-mock    dev: a local DiceEntropy copy, the keeper as admin and provider
///                            DICE_ENTROPY / DICE_PROVIDER / DICE_ARBSYS / DICE_PROMPT_WINDOW / DICE_STALL_TIMEOUT /
///                            DICE_MAX_OPEN / DICE_MAX_FEE_WEI / DICE_REVEALER override the Dice defaults
///                            chainlink    Chainlink VRF v2.5 (VRF_WRAPPER, or a local dev wrapper)
///     UNCX_LOCK              0 (default): the launch position (a v4 PositionManager NFT) is held by the immutable,
///                            ownerless LiquidityKeeper (manifest `liquidityKeeper`); 1: the keeper also locks it forever
///                            in UNCX's v4 locker (Robinhood only; manifest `uncxLocker`; UNCX's 0.1 ETH flat fee is added
///                            to the launch value, and the keeper refuses UNCX fees above RobinhoodAddresses' caps)
///     PRINCIPAL_LOCK         1 (default): the opening buy is staked in the TreasuryVault for good through an immutable
///                            PrincipalLock (manifest `principalLock`): its principal can never be withdrawn, its
///                            earnings go only to DEV_PAYOUT_ADDRESS (default: the deployer). 0: no lock
///     TREASURY_SEED_BPS      share of the deployer's other $FLIPPER (all of it with PRINCIPAL_LOCK=0; the supply kept
///                            out of the pool otherwise) deposited into the bankroll (default 9000); it stays
///                            protocol-owned (the TreasuryVault bootstraps it as POL)
///     VAULT_FEE_BPS          TreasuryVault performance fee: share of stakers' gains above the high-water mark that
///                            becomes protocol-owned (default 8000)
///     VAULT_LOCK_DAYS        lock after each stake (default 7; DEV=1: 1)
///     VAULT_COOLDOWN_HOURS   withdrawal cooldown (default 48; DEV=1: 10 minutes)
///     SEED_ACCOUNT_KEYS      comma-separated keys that each buy SEED_BUY_ETH of $FLIPPER and of the reward token
///     DEV                    "1" for local development
///     DEPLOYMENT_FILE        default deployments/local.json
contract Deploy is Script {
    uint256 internal constant INK_CHAIN_ID = 57073;

    struct Env {
        uint256 pk;
        address deployer;
        address keeper;
        address owner;
        address proxyAdminOwner;
        bool robinhood;
        string launchpad;
        bool rewardBearing; // v4 launch of the reward-bearing $FLIPPER
        string entropyMode;
        address rewardToken;
        uint256 openingBuyUsd;
        uint256 openingBuySupplyBps;
        uint256 treasurySeedBps;
        bool principalLock;
        address devPayout;
        bool dev;
    }

    struct ChainCfg {
        string name;
        string explorer;
        address poolManager;
        address v4Quoter;
        address ethUsd;
        address usdQuote;
        PoolKey usdQuotePool;
        address[] hooks;
        uint256 poolManagerStartBlock;
        address v3Factory; // Uniswap v3 (0 = no v3 route adapter)
        address weth; // the WETH v3 pools pair against (shown as native ETH by the v3 bridge)
        FlipperHouseBase.Params params;
    }

    struct Launch {
        address flipper;
        uint256 bought; // $FLIPPER the opening buy acquired (self-launched v4 only)
        PoolKey key;
        address launchpad; // factory (hookit / pons) or the PoolManager (v4)
        address feeSource; // creator-fee escrow router.harvest() claims from (0 for v4: LP fees collected by harvest)
        address curve; // pons bonding curve (reward-exempt)
        address keeper; // LiquidityKeeper holding the launch position (self-launched v4)
        address positionManager;
        address locker; // UNCX v4 locker when UNCX_LOCK=1
    }

    struct Reward {
        bool v4; // has a v4 ETH pool (listed on the house); else v3-only
        PoolKey key;
        uint24 v3Fee; // v3 WETH pool fee used for dev seeding / keeper conversion when !v4
    }

    /// @dev what the manifest needs besides the system (a struct keeps `run` within the stack)
    struct Out {
        address source;
        address provider;
        uint256 deployBlock;
        address devSwap;
        ILaunchpadVerifier[] verifiers;
        address[] launchListed;
        address principalLock;
    }

    function run() external {
        Env memory e = _env();
        Out memory o;
        ChainCfg memory ch = e.robinhood ? _robinhood() : _ink();

        vm.startBroadcast(e.pk);
        o.deployBlock = block.number;

        FlipperDeploy.Config memory c = FlipperDeploy.Config({
            poolManager: IPoolManager(ch.poolManager),
            entropy: IEntropyV2(address(0)),
            entropyProvider: address(0),
            deployer: e.deployer,
            owner: e.owner,
            proxyAdminOwner: e.proxyAdminOwner,
            params: ch.params
        });

        // 1. router, then $FLIPPER launch + opening buy in one transaction (router = creator / LP owner)
        RevenueRouter router = FlipperDeploy.deployRouter(c);
        Launch memory l = _launch(e, ch, router);

        // 2. randomness, then everything else
        IRandomnessAdapter rnd;
        (rnd, o.source, o.provider) = _randomness(e, c);
        FlipperDeploy.System memory s =
            FlipperDeploy.deployCoreWith(c, router, IERC20(l.flipper), rnd, !e.robinhood);
        if (!e.robinhood) {
            FlipperDeploy.addHookitRail(s, InkAddresses.HOOKIT_FACTORY_V1);
            FlipperDeploy.addHookitRail(s, InkAddresses.HOOKIT_FACTORY_V2);
        }

        // reward-bearing $FLIPPER: exemptions fixed for good, the vault's virtual balance, the router's holders'
        // share (house profit share and LP fees, both legs) streamed through `distribute`
        if (e.rewardBearing) {
            FlipperDeploy.sealRewardToken(s, FlipperRewardToken(l.flipper));
            router.setTreasuryShareBps(0);
        }

        // a sample partner for the showcase / web: code "demo", tier 1, half its cut returned to players as odds
        // (payout: the deployer, so the deployer's own flips don't attribute to it)
        s.partners.register("demo", e.deployer, 5000); // active at once, in the default tier

        // 3. bankroll: any protocol-owned seed first (bootstrapped 1:1 as POL, so no later depositor pays a fee on
        //    it), the vault's parameters, then the team's opening buy staked for good through the PrincipalLock
        _seedBankroll(e, s, l);
        _configureVault(e, s);
        if (e.principalLock && l.bought != 0) {
            o.principalLock = address(FlipperDeploy.deployPrincipalLock(s, IERC20(l.flipper), e.devPayout, e.owner, l.bought));
        }
        // the drawdown check runs once the treasury holds at least a tenth of the seed
        s.house.setLockMinTreasury(uint128(s.house.treasury() / 10));
        // the edge steps down from 7.75% to 5% as the house's own net buybacks grow from 25 to 250 ETH, and Kelly backs
        // off from half to quarter as the drawdown nears the breaker
        if (e.robinhood) s.house.setEdgeSchedule(RobinhoodAddresses.edgeSchedule());
        s.house.setKellySchedule(
            RobinhoodAddresses.KELLY_BPS,
            RobinhoodAddresses.KELLY_MIN_BPS,
            RobinhoodAddresses.KELLY_DD_START_BPS,
            RobinhoodAddresses.KELLY_DD_END_BPS
        );
        // a player holds at most a few of the randomness adapter's open requests, and each needs a real liability
        s.house.setFlipLimits(
            RobinhoodAddresses.MAX_OPEN_PER_PLAYER, e.robinhood ? RobinhoodAddresses.MIN_LIABILITY : 0
        );
        // the revenue auction's first ETH lot: a reference (and so a floor) from the pool's price right after launch
        s.converter.seedPrice(address(0), _flipperPerEth(ch.poolManager, l.key));

        // 4. listings, routes, roles
        Reward memory rw = _reward(e, s);
        if (rw.v4) s.house.setTokenRoute(e.rewardToken, _two(rw.key, l.key));
        _addHarvestCalls(router, l);

        // any-v4 listings: route via the $FLIPPER pool; hookless pools + the launchpad's hooks; a USD quote
        s.v4.setFlipperPool(l.key);
        if (address(s.hookit) != address(0)) s.hookit.setFlipperPool(l.key);
        for (uint256 i; i < ch.hooks.length; ++i) {
            s.v4.setHookAllowed(ch.hooks[i], true);
        }
        s.v4.setQuote(ch.usdQuote, ch.usdQuotePool);
        // Uniswap v3 pools, bridged into v4 (same $FLIPPER pool and USD quote route)
        if (ch.v3Factory != address(0)) {
            FlipperDeploy.deployV3(c, s, ch.v3Factory, ch.weth, FlipperDeploy.CREATE2_DEPLOYER);
            s.v3.setFlipperPool(l.key);
            s.v3.setQuote(ch.usdQuote, ch.usdQuotePool);
        }
        // listing policy: only vetted tokens list permissionlessly. Robinhood: the majors allowlisted, the stock-token
        // verifier attached (other launchpad verifiers are deployed but none is attached at launch), and the curated
        // launch whitelist listed by exact pool
        o.verifiers = _vetting(e, s);
        // WETH ↔ native ETH through a 1:1 wrapper-hook pool (no AMM pool needed), then list WETH (permissionless
        // once the pool is whitelisted; done here so it is flippable from the start)
        PoolKey memory wethKey = FlipperDeploy.deployWethWrapper(c, s, ch.weth, FlipperDeploy.CREATE2_DEPLOYER);
        s.v4.registerAndList(ch.weth, wethKey);
        o.launchListed = e.robinhood ? _listLaunchWhitelist(s, e.pk) : new address[](0);
        if (e.dev) s.house.setGuardian(e.keeper);
        FlipperDeploy.handOver(s, c);
        o.devSwap = e.dev ? address(new DevSwapRouter(IPoolManager(ch.poolManager))) : address(0);
        vm.stopBroadcast();

        // 5. dev accounts buy some $FLIPPER and reward token through the real pools
        if (o.devSwap != address(0)) _seedAccounts(e, l, rw, o.devSwap);

        _writeManifest(e, ch, s, l, rw, o);
        console2.log("chain          ", ch.name);
        console2.log("launchpad      ", e.launchpad);
        console2.log("FLIPPER        ", l.flipper);
        console2.log("house          ", address(s.house));
        console2.log("treasury       ", s.house.treasury());
        console2.log("treasury vault ", address(s.vault));
    }

    // ── chains ───────────────────────────────────────────────────────────────────────────────────────────

    function _ink() internal pure returns (ChainCfg memory ch) {
        ch.name = "Ink";
        ch.explorer = "https://explorer.inkonchain.com";
        ch.poolManager = InkAddresses.POOL_MANAGER;
        ch.v4Quoter = InkAddresses.V4_QUOTER;
        ch.ethUsd = InkAddresses.CHAINLINK_ETH_USD;
        ch.usdQuote = InkAddresses.USDC;
        ch.usdQuotePool =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(InkAddresses.USDC), 3000, 60, IHooks(address(0)));
        ch.hooks = new address[](3);
        ch.hooks[0] = InkAddresses.HOOKIT_HOOK_V1;
        ch.hooks[1] = InkAddresses.HOOKIT_HOOK_V2;
        ch.hooks[2] = InkAddresses.HOOKIT_GRADUATED_HOOK;
        ch.poolManagerStartBlock = 6_391_727; // first Initialize
        ch.v3Factory = InkAddresses.V3_FACTORY;
        ch.weth = InkAddresses.WETH;
        ch.params = InkAddresses.defaultParams();
    }

    function _robinhood() internal pure returns (ChainCfg memory ch) {
        ch.name = "Robinhood Chain";
        ch.explorer = "https://robinhoodchain.blockscout.com";
        ch.poolManager = RobinhoodAddresses.POOL_MANAGER;
        ch.v4Quoter = RobinhoodAddresses.V4_QUOTER;
        ch.ethUsd = RobinhoodAddresses.CHAINLINK_ETH_USD;
        ch.usdQuote = RobinhoodAddresses.USDG;
        ch.usdQuotePool = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(RobinhoodAddresses.USDG),
            RobinhoodAddresses.USDG_POOL_FEE,
            RobinhoodAddresses.USDG_POOL_TICK_SPACING,
            IHooks(address(0))
        );
        ch.hooks = new address[](1);
        ch.hooks[0] = RobinhoodAddresses.PONS_V2_MEME_HOOK;
        ch.poolManagerStartBlock = 9_505; // first Initialize
        ch.v3Factory = RobinhoodAddresses.V3_FACTORY;
        ch.weth = RobinhoodAddresses.WETH;
        ch.params = RobinhoodAddresses.defaultParams();
    }

    // ── launch ───────────────────────────────────────────────────────────────────────────────────────────

    function _launch(Env memory e, ChainCfg memory ch, RevenueRouter router) internal returns (Launch memory l) {
        bytes32 lp = keccak256(bytes(e.launchpad));
        if (lp == keccak256("hookit")) {
            require(!e.robinhood, "hookit is Ink-only");
            address factory = vm.envOr("HOOKIT_FACTORY", InkAddresses.HOOKIT_FACTORY_V2);
            (uint256 value, uint256 devBuy, uint256 extra) = _hookitOpeningBuy(factory, ch.ethUsd, e.openingBuyUsd);
            (l.flipper,,) = router.launchFlipper{value: value}(
                IHookitLaunchFactory(factory), InkAddresses.flipperLaunchParams(devBuy), extra, 1, e.deployer
            );
            IHookitLaunchFactory f = IHookitLaunchFactory(factory);
            l.key = f.poolKeyOf(f.tokenLaunchId(l.flipper));
            l.launchpad = factory;
            l.feeSource = InkAddresses.HOOKIT_FEE_ESCROW;
        } else if (lp == keccak256("pons")) {
            require(e.robinhood, "pons is Robinhood-only");
            IPonsV2Factory f = IPonsV2Factory(RobinhoodAddresses.PONS_V2_FACTORY);
            uint256 buyEth = vm.envOr("PONS_BUY_ETH", RobinhoodAddresses.PONS_CURVE_BUYOUT_ETH);
            bytes32 salt = keccak256(abi.encode("flipper.family", block.number));
            (l.flipper, l.curve,) = router.launchFlipperPons{value: f.launchFee() + buyEth}(
                f, RobinhoodAddresses.flipperPonsParams(salt), buyEth, e.deployer
            );
            require(f.getLaunchedToken(l.flipper).phase == 2, "pons curve not bought out: raise PONS_BUY_ETH");
            l.key = PoolKey(
                Currency.wrap(address(0)), Currency.wrap(l.flipper), 0, 200, IHooks(RobinhoodAddresses.PONS_V2_MEME_HOOK)
            );
            l.launchpad = address(f);
            l.feeSource = RobinhoodAddresses.PONS_V2_FEE_ESCROW;
            console2.log("pons buy-out ETH", buyEth);
        } else if (lp == keccak256("v4")) {
            l = _launchV4(e, ch, router);
        } else {
            revert("LAUNCHPAD must be hookit|pons|v4");
        }
    }

    /// @dev Self-launch on a hookless v4 pool: the router seeds `V4_POOL_BPS` of the supply single-sided at the start
    ///      FDV and makes the opening buy in the same transaction: exactly `OPENING_BUY_SUPPLY_BPS` of the supply
    ///      (ETH from the pool maths, enforced as the buy's minimum out), or `OPENING_BUY_USD` of ETH when that is 0.
    function _launchV4(Env memory e, ChainCfg memory ch, RevenueRouter router) internal returns (Launch memory l) {
        uint256 px = _ethUsd(ch.ethUsd);
        uint256 supply = vm.envOr("V4_SUPPLY", uint256(1_000_000_000 ether));
        uint256 poolSupply = supply * vm.envOr("V4_POOL_BPS", uint256(10_000)) / 10_000;
        // opening FDV in ETH → price (token wei per ETH wei) → sqrtPriceX96 = sqrt(supply/fdv)·2^96
        uint256 fdvWei = vm.envOr("V4_START_MCAP_USD", uint256(5000)) * 1e8 * 1e18 / px;
        uint160 sqrtP = uint160(Math.sqrt(FullMath.mulDiv(supply, 1 << 96, fdvWei) << 96));
        uint24 fee = uint24(vm.envOr("V4_FEE", uint256(10_000)));
        int24 ts = int24(int256(vm.envOr("V4_TICK_SPACING", uint256(200))));
        uint256 want = supply * e.openingBuySupplyBps / 10_000;
        require(want <= poolSupply, "OPENING_BUY_SUPPLY_BPS above V4_POOL_BPS");
        uint256 out;
        // the launch position goes to an immutable, ownerless keeper (a PositionManager NFT), optionally UNCX-locked
        bool uncx = _envUintOr("UNCX_LOCK", 0) == 1;
        require(!uncx || e.robinhood, "UNCX_LOCK: Robinhood only");
        address locker = uncx ? RobinhoodAddresses.UNCX_V4_LOCKER : address(0);
        l.positionManager = e.robinhood ? RobinhoodAddresses.POSITION_MANAGER : InkAddresses.POSITION_MANAGER;
        l.keeper = address(
            FlipperDeploy.deployLiquidityKeeper(
                IPoolManager(ch.poolManager),
                router,
                l.positionManager,
                locker,
                RobinhoodAddresses.UNCX_MAX_FLAT_FEE,
                RobinhoodAddresses.UNCX_MAX_LP_FEE_BPS,
                RobinhoodAddresses.UNCX_MAX_COLLECT_FEE_BPS
            )
        );
        l.locker = locker;
        // UNCX's flat fee rides along with the opening buy and its LP fee comes out of the position's liquidity before
        // the buy (neither applies when UNCX whitelisted the keeper for free locks)
        bool paidLock = uncx && !IUNCXV4Locker(locker).whitelistedForFreeLock(l.keeper);
        uint256 lockFee = paidLock ? IUNCXV4Locker(locker).flatFee() : 0;
        uint256 buyEth = want != 0
            ? _openingBuyEth(poolSupply, sqrtP, ts, fee, want, paidLock ? IUNCXV4Locker(locker).lpFee() : 0)
            : e.openingBuyUsd * 1e8 * 1e18 / px;
        uint256 minOut = want != 0 ? want : 1;
        if (e.rewardBearing) {
            FlipperDeploy.Config memory c;
            c.poolManager = IPoolManager(ch.poolManager);
            l.flipper = address(FlipperDeploy.deployRewardToken(c, router, "Flipper", "FLIPPER", supply));
            out = router.launchFlipperV4Token{value: buyEth + lockFee}(
                IERC20(l.flipper), poolSupply, fee, ts, sqrtP, buyEth, minOut, e.deployer
            );
        } else {
            (l.flipper, out) = router.launchFlipperV4{value: buyEth + lockFee}(
                "Flipper", "FLIPPER", supply, poolSupply, fee, ts, sqrtP, buyEth, minOut, e.deployer
            );
        }
        l.bought = out - (supply - poolSupply); // the rest of the hand-out is the supply kept out of the pool
        (l.key,,) = router.lpPosition();
        l.launchpad = ch.poolManager;
        console2.log("opening buy ETH", buyEth);
        console2.log("opening buy FLIPPER", l.bought);
    }

    /// @dev FlipperDeploy.openingBuyEth after UNCX removed `lpFeeBps` of the position's liquidity at lock time (it
    ///      keeps L − floor(L·fee / 10,000); one wei less here, so the buy never comes up short of `want`)
    function _openingBuyEth(uint256 poolSupply, uint160 sqrtP, int24 ts, uint24 fee, uint256 want, uint256 lpFeeBps)
        internal
        pure
        returns (uint256)
    {
        if (lpFeeBps == 0) return FlipperDeploy.openingBuyEth(poolSupply, sqrtP, ts, fee, want);
        int24 t0 = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 upper = (t0 / ts) * ts;
        if (upper > t0) upper -= ts;
        uint160 su = TickMath.getSqrtPriceAtTick(upper);
        uint160 sl = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(ts));
        uint256 liq = FullMath.mulDiv(poolSupply, 1 << 96, su - sl);
        liq -= liq * lpFeeBps / 10_000 + 1;
        (, uint256 amountIn,, uint256 feeAmount) = SwapMath.computeSwapStep(su, sl, uint128(liq), int256(want), fee);
        return amountIn + feeAmount;
    }

    /// @dev the $FLIPPER pool's spot price: $FLIPPER wei per 1e18 wei of ETH (currency0 is native ETH)
    function _flipperPerEth(address pm, PoolKey memory key) internal view returns (uint256) {
        (uint160 sp,,,) = StateLibrary.getSlot0(IPoolManager(pm), PoolIdLibrary.toId(key));
        return FullMath.mulDiv(FullMath.mulDiv(1e18, sp, 1 << 96), sp, 1 << 96);
    }

    /// @dev fee claims `router.harvest()` makes (fixed calldata; anyone may trigger them). Self-launched v4: none
    ///      (the router collects its LP position's fees itself). pons' operator sweeps hook fees into the escrow.
    function _addHarvestCalls(RevenueRouter router, Launch memory l) internal {
        if (l.feeSource == address(0)) return;
        if (l.launchpad == RobinhoodAddresses.PONS_V2_FACTORY) {
            router.addHarvestCall(l.feeSource, abi.encodeWithSignature("claim()"));
        } else {
            router.addHarvestCall(l.feeSource, abi.encodeWithSignature("claim(address)", address(0))); // hookit ETH
        }
    }

    /// @dev the protocol-owned part of the bankroll: `treasurySeedBps` of the deployer's $FLIPPER, less the opening buy
    ///      when the PrincipalLock stakes that (all of it, with the whole supply in the pool)
    function _seedBankroll(Env memory e, FlipperDeploy.System memory s, Launch memory l) internal {
        uint256 bal = IERC20(l.flipper).balanceOf(e.deployer);
        uint256 locked = e.principalLock ? Math.min(l.bought, bal) : 0;
        uint256 bank = (bal - locked) * e.treasurySeedBps / 10_000;
        if (bank == 0) return;
        IERC20(l.flipper).approve(address(s.house), bank);
        s.house.depositTreasury(bank);
    }

    /// @dev the listing policy's verifiers and allowlist. Robinhood: [0] pons (deployed, not attached), [1] stock tokens
    ///      (attached)
    function _vetting(Env memory e, FlipperDeploy.System memory s) internal returns (ILaunchpadVerifier[] memory verifiers) {
        if (e.robinhood) {
            verifiers = FlipperDeploy.deployRobinhoodVerifiers(address(s.v3Bridge));
            ILaunchpadVerifier[] memory attach = new ILaunchpadVerifier[](1);
            attach[0] = verifiers[1];
            FlipperDeploy.applyVetting(s, attach, RobinhoodAddresses.trustedTokens());
        } else {
            verifiers = FlipperDeploy.deployInkVerifiers();
            FlipperDeploy.applyVetting(s, verifiers, InkAddresses.trustedTokens());
        }
    }

    /// @dev Robinhood's launch whitelist (RobinhoodAddresses.launchWhitelist): each pool whitelisted in the listing
    ///      policy, then the token registered and listed through its adapter. The listing (its route-cost probe) is
    ///      simulated first off the broadcast: one that would fail is logged and skipped (the pool stays whitelisted,
    ///      so anyone can list it later), and never reverts the deploy.
    function _listLaunchWhitelist(FlipperDeploy.System memory s, uint256 pk) internal returns (address[] memory tokens) {
        RobinhoodAddresses.Listing[] memory w = RobinhoodAddresses.launchWhitelist();
        address[] memory listed = new address[](w.length);
        uint256 n;
        for (uint256 i; i < w.length; ++i) {
            bool v3 = w[i].v3Pool != address(0);
            if (v3) s.policy.setV3PoolWhitelisted(w[i].v3Pool, true);
            else s.policy.setPoolWhitelisted(w[i].key, true);
            vm.stopBroadcast();
            uint256 snap = vm.snapshotState();
            bool ok = v3 ? _tryListV3(s, w[i]) : _tryListV4(s, w[i]);
            vm.revertToState(snap);
            vm.startBroadcast(pk);
            if (!ok) {
                console2.log("launch whitelist: listing skipped (probe failed), pool left whitelisted", w[i].token);
                continue;
            }
            if (v3) s.v3.registerAndList(w[i].token, w[i].v3Pool);
            else s.v4.registerAndList(w[i].token, w[i].key);
            listed[n++] = w[i].token;
        }
        tokens = new address[](n);
        for (uint256 i; i < n; ++i) {
            tokens[i] = listed[i];
        }
    }

    function _tryListV3(FlipperDeploy.System memory s, RobinhoodAddresses.Listing memory l) internal returns (bool) {
        try s.v3.registerAndList(l.token, l.v3Pool) {
            return true;
        } catch (bytes memory err) {
            console2.logBytes(err);
            return false;
        }
    }

    function _tryListV4(FlipperDeploy.System memory s, RobinhoodAddresses.Listing memory l) internal returns (bool) {
        try s.v4.registerAndList(l.token, l.key) {
            return true;
        } catch (bytes memory err) {
            console2.logBytes(err);
            return false;
        }
    }

    function _reward(Env memory e, FlipperDeploy.System memory s) internal view returns (Reward memory rw) {
        if (e.rewardToken == InkAddresses.HKT && !e.robinhood) {
            rw.v4 = true;
            rw.key = s.hookit.ethPoolOf(InkAddresses.HKT);
        } else if (e.rewardToken == RobinhoodAddresses.PONS && e.robinhood) {
            rw.v3Fee = 10_000; // WETH/PONS 1% (≈836 WETH deep)
        } else {
            // any other reward token: a v4 ETH pool must be given explicitly
            rw.v4 = true;
            rw.key = PoolKey(
                Currency.wrap(address(0)),
                Currency.wrap(e.rewardToken),
                uint24(vm.envUint("REWARD_POOL_FEE")),
                int24(int256(vm.envUint("REWARD_POOL_TICK_SPACING"))),
                IHooks(vm.envOr("REWARD_POOL_HOOKS", address(0)))
            );
        }
    }

    // ── randomness ───────────────────────────────────────────────────────────────────────────────────────

    /// @return rnd the adapter the house will use
    /// @return source Pyth Entropy contract or VRF wrapper behind it
    /// @return provider Entropy provider (Pyth modes) / keeper allowed to fulfil (local Chainlink wrapper)
    function _randomness(Env memory e, FlipperDeploy.Config memory c)
        internal
        returns (IRandomnessAdapter rnd, address source, address provider)
    {
        bytes32 m = keccak256(bytes(e.entropyMode));
        if (m == keccak256("dice") || m == keccak256("dice-mirror") || m == keccak256("dice-mock")) return _dice(e, c, m);
        if (m == keccak256("chainlink")) {
            address wrapper = vm.envOr("VRF_WRAPPER", address(0));
            if (wrapper == address(0)) {
                require(e.dev, "local VRF wrapper is dev-only (set VRF_WRAPPER for a real one)");
                MockVRFWrapper w = new MockVRFWrapper(_vrfConfig(e));
                w.setFulfiller(e.keeper, true);
                wrapper = address(w);
                provider = e.keeper;
            }
            source = wrapper;
            rnd = FlipperDeploy.deployChainlinkAdapter(
                c, IVRFV2PlusWrapper(wrapper), uint16(vm.envOr("VRF_CONFIRMATIONS", uint256(1)))
            );
            return (rnd, source, provider);
        }
        require(!e.robinhood, "Pyth Entropy is not deployed on Robinhood Chain: use ENTROPY_MODE=dice");
        if (m == keccak256("mock")) {
            require(e.dev, "mock entropy is dev-only");
            // Fortuna's live rate on Ink: 1e7 wei per callback gas, 500k-gas minimum (+1 wei protocol fee)
            c.entropy = IEntropyV2(address(new MockEntropyV2(e.keeper, 1, 1e7)));
            c.entropyProvider = e.keeper;
        } else if (m == keccak256("real")) {
            c.entropy = IEntropyV2(InkAddresses.ENTROPY);
            c.entropyProvider = vm.envAddress("ENTROPY_PROVIDER");
        } else if (m == keccak256("prod")) {
            c.entropy = IEntropyV2(InkAddresses.ENTROPY);
            c.entropyProvider = address(0); // Entropy's default provider (Fortuna)
        } else {
            revert("ENTROPY_MODE must be dice|dice-mirror|dice-mock|chainlink|mock|real|prod");
        }
        rnd = FlipperDeploy.deployPythAdapter(c);
        return (rnd, address(c.entropy), c.entropyProvider);
    }

    /// @dev Dice Protocol: `dice` (production), `dice-mirror` (dev, Robinhood fork), `dice-mock` (dev, local copy)
    function _dice(Env memory e, FlipperDeploy.Config memory c, bytes32 m)
        internal
        returns (IRandomnessAdapter rnd, address source, address provider)
    {
        bool mock = m == keccak256("dice-mock");
        require(e.dev || m == keccak256("dice"), "dice-mirror / dice-mock are dev-only");
        require(mock || e.robinhood, "Dice is deployed on Robinhood Chain only: use ENTROPY_MODE=dice-mock");
        IDiceEntropy dice = mock
            ? DiceDeploy.deployLocalDice(e.keeper, e.keeper, e.deployer)
            : IDiceEntropy(_isSet("DICE_ENTROPY") ? vm.envAddress("DICE_ENTROPY") : RobinhoodAddresses.DICE_ENTROPY);
        DiceEntropyAdapter.Config memory cfg = RobinhoodAddresses.diceAdapterConfig();
        cfg.promptWindow = uint32(_envUintOr("DICE_PROMPT_WINDOW", cfg.promptWindow));
        cfg.stallTimeout = uint32(_envUintOr("DICE_STALL_TIMEOUT", cfg.stallTimeout));
        cfg.maxOpen = uint32(_envUintOr("DICE_MAX_OPEN", cfg.maxOpen));
        cfg.maxFee = uint128(_envUintOr("DICE_MAX_FEE_WEI", cfg.maxFee));
        if (_isSet("DICE_REVEALER")) cfg.revealer = vm.envAddress("DICE_REVEALER");
        // L2 blocks from ArbSys on the live chain; anvil has no ArbSys precompile
        bool arbSys = _isSet("DICE_ARBSYS") ? vm.envBool("DICE_ARBSYS") : e.robinhood && !e.dev;
        address p = _isSet("DICE_PROVIDER") ? vm.envAddress("DICE_PROVIDER") : address(0); // 0: Dice's default
        rnd = DiceDeploy.deployAdapter(c, dice, p, arbSys, cfg);
        return (rnd, address(dice), DiceEntropyAdapter(address(rnd)).provider());
    }

    /// @dev the local wrapper prices like Chainlink's VRFV2PlusWrapper at the requester's gas price. Robinhood
    ///      (Arbitrum Nitro): Arbitrum One's live wrapper config incl. its 2.5M callback cap. Ink (OP stack): Base's
    ///      config (coordinator overhead 128.5k) without the cap — hookit's nested-swap gas exceeds 2.5M, which is
    ///      why production on Ink uses Pyth Entropy. VRF_L1_COST_WEI = L1 posting cost of a fulfillment tx.
    function _vrfConfig(Env memory e) internal view returns (MockVRFWrapper.Config memory) {
        uint256 l1 = vm.envOr("VRF_L1_COST_WEI", uint256(0));
        return e.robinhood
            ? MockVRFWrapper.Config(13_400, 104_500, 435, 60, 0, 2_500_000, l1)
            : MockVRFWrapper.Config(13_400, 128_500, 435, 60, 0, 0, l1);
    }

    // ── staking vault ────────────────────────────────────────────────────────────────────────────────────

    /// @dev env overrides of the vault defaults (short lock / cooldown in dev so exits are testable), then
    ///      crystallize so the seeded bankroll is recorded as protocol-owned at deployment
    function _configureVault(Env memory e, FlipperDeploy.System memory s) internal {
        uint256 fee = _envUintOr("VAULT_FEE_BPS", FlipperDeploy.VAULT_FEE_BPS);
        uint256 lock = _envUintOr("VAULT_LOCK_DAYS", type(uint256).max);
        lock = lock != type(uint256).max
            ? lock * 1 days
            : e.dev ? uint256(1 days) : uint256(FlipperDeploy.VAULT_LOCK);
        uint256 cooldown = _envUintOr("VAULT_COOLDOWN_HOURS", type(uint256).max);
        cooldown = cooldown != type(uint256).max
            ? cooldown * 1 hours
            : e.dev ? uint256(10 minutes) : uint256(FlipperDeploy.VAULT_COOLDOWN);
        require(fee <= type(uint16).max && lock <= type(uint32).max && cooldown <= type(uint32).max, "VAULT_*");
        // explicit gas: forge sizes a script's transactions from the gas its simulation used, which doesn't show a
        // call's gas floor (the vault reverts with less than 300k left for its reward-token sync, so that
        // eth_estimateGas can't starve it); FlipperDeploy.VAULT_CALL_GAS covers every vault call here
        s.vault.setParams{gas: FlipperDeploy.VAULT_CALL_GAS}(uint16(fee), uint32(lock), uint32(cooldown));
        s.vault.crystallize{gas: FlipperDeploy.VAULT_CALL_GAS}();
        console2.log("vault fee bps  ", fee);
        console2.log("vault lock s   ", lock);
        console2.log("vault cooldown ", cooldown);
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────────────────

    /// @dev set and non-empty (dev.sh exports .env.dev wholesale, and vm.envOr treats "" as a value)
    function _isSet(string memory name) internal view returns (bool) {
        return bytes(vm.envOr(name, string(""))).length != 0;
    }

    function _envUintOr(string memory name, uint256 dflt) internal view returns (uint256) {
        return _isSet(name) ? vm.envUint(name) : dflt;
    }

    function _env() internal view returns (Env memory e) {
        e.pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        e.deployer = vm.addr(e.pk);
        e.keeper = vm.envOr("KEEPER_ADDRESS", e.deployer);
        e.owner = vm.envOr("OWNER", e.deployer);
        e.proxyAdminOwner = vm.envOr("PROXY_ADMIN_OWNER", e.owner);
        // a local fork runs under its own chain id (so wallets can't mix it up with the live chain): CHAIN then
        // defaults to robinhood; on a live chain it defaults from the chain id
        string memory chain = block.chainid == INK_CHAIN_ID
            ? vm.envOr("CHAIN", string("ink"))
            : vm.envOr("CHAIN", string("robinhood"));
        e.robinhood = keccak256(bytes(chain)) == keccak256("robinhood");
        require(e.robinhood || keccak256(bytes(chain)) == keccak256("ink"), "CHAIN must be ink|robinhood");
        e.launchpad = vm.envOr("LAUNCHPAD", string("v4"));
        e.rewardBearing =
            keccak256(bytes(e.launchpad)) == keccak256("v4") && vm.envOr("REWARD_BEARING", uint256(1)) == 1;
        e.dev = vm.envOr("DEV", uint256(0)) == 1;
        e.entropyMode = vm.envOr("ENTROPY_MODE", string(e.robinhood ? (e.dev ? "dice-mirror" : "dice") : "chainlink"));
        e.rewardToken = vm.envOr("REWARD_TOKEN", e.robinhood ? RobinhoodAddresses.PONS : InkAddresses.HKT);
        e.openingBuyUsd = vm.envOr("OPENING_BUY_USD", uint256(1000));
        e.openingBuySupplyBps = _envUintOr("OPENING_BUY_SUPPLY_BPS", 1250);
        require(e.openingBuySupplyBps <= 10_000, "OPENING_BUY_SUPPLY_BPS");
        e.principalLock = _envUintOr("PRINCIPAL_LOCK", 1) == 1;
        e.devPayout = _isSet("DEV_PAYOUT_ADDRESS") ? vm.envAddress("DEV_PAYOUT_ADDRESS") : e.deployer;
        e.treasurySeedBps = vm.envOr("TREASURY_SEED_BPS", uint256(9000));
        require(e.treasurySeedBps <= 10_000, "TREASURY_SEED_BPS");
    }

    function _ethUsd(address feed) internal view returns (uint256) {
        (, int256 px,, uint256 updatedAt,) = IChainlinkFeed(feed).latestRoundData();
        require(px > 0 && updatedAt != 0, "ETH/USD feed");
        console2.log("ETH/USD (8 dec)", uint256(px));
        return uint256(px);
    }

    function _hookitOpeningBuy(address factory, address feed, uint256 usd)
        internal
        view
        returns (uint256 value, uint256 devBuy, uint256 extra)
    {
        uint256 totalEth = usd * 1e8 * 1e18 / _ethUsd(feed);
        uint256 maxDev = IFactoryMcap(factory).launchMcapQuoteWei() * 250 / 10_000 * 99 / 100;
        devBuy = totalEth < maxDev ? totalEth : maxDev;
        extra = totalEth - devBuy;
        value = IHookitLaunchFactory(factory).launchFee() + devBuy + extra;
        console2.log("opening buy ETH", totalEth);
    }

    function _seedAccounts(Env memory e, Launch memory l, Reward memory rw, address devSwap) internal {
        string memory raw = vm.envOr("SEED_ACCOUNT_KEYS", string(""));
        if (bytes(raw).length == 0) return;
        uint256 buyEth = vm.envOr("SEED_BUY_ETH", uint256(0.02 ether));
        string[] memory keys = vm.split(raw, ",");
        for (uint256 i; i < keys.length; ++i) {
            uint256 k = vm.parseUint(keys[i]);
            address who = vm.addr(k);
            vm.startBroadcast(k);
            DevSwapRouter(payable(devSwap)).swapExactIn{value: buyEth}(_one(l.key), address(0), l.flipper, buyEth, 1, who);
            _buyReward(e, rw, devSwap, buyEth, who);
            vm.stopBroadcast();
        }
    }

    function _buyReward(Env memory e, Reward memory rw, address devSwap, uint256 ethIn, address to) internal {
        if (rw.v4) {
            DevSwapRouter(payable(devSwap)).swapExactIn{value: ethIn}(_one(rw.key), address(0), e.rewardToken, ethIn, 1, to);
        } else {
            ISwapRouter02(RobinhoodAddresses.V3_SWAP_ROUTER02).exactInputSingle{value: ethIn}(
                ISwapRouter02.ExactInputSingleParams(RobinhoodAddresses.WETH, e.rewardToken, rw.v3Fee, to, ethIn, 1, 0)
            );
        }
    }

    function _writeManifest(
        Env memory e,
        ChainCfg memory ch,
        FlipperDeploy.System memory s,
        Launch memory l,
        Reward memory rw,
        Out memory out
    ) internal {
        address entropy = out.source;
        address provider = out.provider;
        address devSwap = out.devSwap;
        ILaunchpadVerifier[] memory verifiers = out.verifiers;
        address[] memory launchListed = out.launchListed;
        string memory o = "contracts";
        vm.serializeAddress(o, "listingPolicy", address(s.policy));
        vm.serializeAddress(o, "hookitVerifier", e.robinhood ? address(0) : address(verifiers[0]));
        vm.serializeAddress(o, "ponsVerifier", e.robinhood ? address(verifiers[0]) : address(0));
        vm.serializeAddress(o, "stockVerifier", e.robinhood ? address(verifiers[1]) : address(0));
        vm.serializeAddress(o, "house", address(s.house));
        vm.serializeAddress(o, "lens", address(s.lens));
        // the reward-bearing $FLIPPER is its own holder-rewards contract (claimable / claim / distribute)
        vm.serializeAddress(o, "holderRewards", e.rewardBearing ? l.flipper : address(0));
        vm.serializeAddress(o, "router", address(s.router));
        vm.serializeAddress(o, "auctionConverter", address(s.converter));
        vm.serializeAddress(o, "partnerRegistry", address(s.partners));
        vm.serializeAddress(o, "principalLock", out.principalLock);
        vm.serializeAddress(o, "liquidityKeeper", l.keeper);
        vm.serializeAddress(o, "positionManager", l.positionManager);
        vm.serializeAddress(o, "uncxLocker", l.locker);
        vm.serializeAddress(o, "houseModule", s.house.module());
        vm.serializeAddress(o, "randomness", address(s.randomness));
        vm.serializeAddress(o, "hookitAdapter", address(s.hookit));
        vm.serializeAddress(o, "v4Adapter", address(s.v4));
        vm.serializeAddress(o, "v3Adapter", address(s.v3));
        vm.serializeAddress(o, "v3Bridge", address(s.v3Bridge));
        vm.serializeAddress(o, "wethWrapperHook", address(s.wethWrapper));
        vm.serializeAddress(o, "treasuryVault", address(s.vault));
        vm.serializeAddress(o, "flipper", l.flipper);
        vm.serializeAddress(o, "rewardToken", e.rewardToken);
        vm.serializeAddress(o, "poolManager", ch.poolManager);
        vm.serializeAddress(o, "v4Quoter", ch.v4Quoter);
        vm.serializeAddress(o, "ethUsdFeed", ch.ethUsd);
        bool isChainlink = keccak256(bytes(e.entropyMode)) == keccak256("chainlink");
        vm.serializeAddress(o, "entropy", isChainlink ? address(0) : entropy);
        vm.serializeAddress(o, "vrfWrapper", isChainlink ? entropy : address(0));
        vm.serializeAddress(o, "entropyProvider", provider);
        vm.serializeAddress(o, "launchpad", l.launchpad);
        vm.serializeAddress(o, "feeSource", l.feeSource);
        vm.serializeAddress(o, "ponsCurve", l.curve);
        vm.serializeAddress(o, "devSwapRouter", devSwap);
        vm.serializeAddress(o, "v3SwapRouter", rw.v4 ? address(0) : RobinhoodAddresses.V3_SWAP_ROUTER02);
        vm.serializeAddress(o, "v3QuoterV2", rw.v4 ? address(0) : RobinhoodAddresses.V3_QUOTER_V2);
        vm.serializeAddress(o, "weth", e.robinhood ? RobinhoodAddresses.WETH : InkAddresses.WETH);
        vm.serializeAddress(o, "hookitFactory", e.robinhood ? address(0) : vm.envOr("HOOKIT_FACTORY", InkAddresses.HOOKIT_FACTORY_V2));
        vm.serializeAddress(o, "hookitFeeEscrow", e.robinhood ? address(0) : InkAddresses.HOOKIT_FEE_ESCROW);
        string memory contracts = vm.serializeAddress(o, "multicall3", 0xcA11bde05977b3631167028862bE2a173976CA11);

        string memory pools = "pools";
        vm.serializeString(pools, "flipper", _keyJson("flipperKey", l.key));
        string memory poolsJson = rw.v4
            ? vm.serializeString(pools, "rewardToken", _keyJson("rewardKey", rw.key))
            : vm.serializeUint(pools, "rewardV3Fee", rw.v3Fee);

        string memory acct = "accounts";
        vm.serializeAddress(acct, "deployer", e.deployer);
        string memory accounts = vm.serializeAddress(acct, "keeper", e.keeper);

        address[] memory listed = new address[]((rw.v4 ? 2 : 1) + launchListed.length);
        listed[0] = e.robinhood ? RobinhoodAddresses.WETH : InkAddresses.WETH;
        for (uint256 i; i < launchListed.length; ++i) {
            listed[(rw.v4 ? 2 : 1) + i] = launchListed[i];
        }
        if (rw.v4) listed[1] = e.rewardToken;

        string memory root = "root";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "liveChainId", e.robinhood ? RobinhoodAddresses.CHAIN_ID : INK_CHAIN_ID);
        vm.serializeString(root, "chain", e.robinhood ? "robinhood" : "ink");
        vm.serializeString(root, "chainName", ch.name);
        vm.serializeString(root, "explorer", ch.explorer);
        vm.serializeString(root, "launchpadKind", e.launchpad);
        vm.serializeUint(root, "deployBlock", out.deployBlock);
        vm.serializeUint(root, "poolManagerStartBlock", ch.poolManagerStartBlock);
        vm.serializeString(root, "entropyMode", e.entropyMode);
        vm.serializeString(root, "randomnessMode", e.entropyMode);
        vm.serializeAddress(root, "listedTokens", listed);
        vm.serializeString(root, "contracts", contracts);
        vm.serializeString(root, "pools", poolsJson);
        string memory json = vm.serializeString(root, "accounts", accounts);
        string memory file = vm.envOr("DEPLOYMENT_FILE", string("deployments/local.json"));
        vm.writeJson(json, file);
        console2.log("manifest       ", file);
    }

    function _keyJson(string memory id, PoolKey memory k) internal returns (string memory) {
        vm.serializeAddress(id, "currency0", Currency.unwrap(k.currency0));
        vm.serializeAddress(id, "currency1", Currency.unwrap(k.currency1));
        vm.serializeUint(id, "fee", k.fee);
        vm.serializeInt(id, "tickSpacing", k.tickSpacing);
        return vm.serializeAddress(id, "hooks", address(k.hooks));
    }

    function _one(PoolKey memory a) internal pure returns (PoolKey[] memory r) {
        r = new PoolKey[](1);
        r[0] = a;
    }

    function _two(PoolKey memory a, PoolKey memory b) internal pure returns (PoolKey[] memory r) {
        r = new PoolKey[](2);
        r[0] = a;
        r[1] = b;
    }
}
