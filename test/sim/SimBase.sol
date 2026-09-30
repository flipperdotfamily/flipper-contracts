// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {FlipperHouse} from "../../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../../src/house/FlipperHouseBase.sol";
import {TreasuryVault} from "../../src/TreasuryVault.sol";
import {FlipperRewardToken} from "../../src/FlipperRewardToken.sol";
import {RevenueRouter} from "../../src/RevenueRouter.sol";
import {DutchAuctionConverter} from "../../src/DutchAuctionConverter.sol";
import {PartnerRegistry} from "../../src/PartnerRegistry.sol";
import {PrincipalLock} from "../../src/PrincipalLock.sol";
import {DiceEntropyAdapter} from "../../src/randomness/DiceEntropyAdapter.sol";
import {IDiceEntropy} from "../../src/interfaces/IDiceEntropy.sol";
import {V4RouteAdapter} from "../../src/adapters/V4RouteAdapter.sol";
import {FlipperLens} from "../../src/lens/FlipperLens.sol";
import {DevSwapRouter} from "../../src/mocks/DevSwapRouter.sol";
import {LiquidityKeeper} from "../../src/LiquidityKeeper.sol";
import {LocalPositionManager} from "../utils/LocalPositionManager.sol";
import {RobinhoodAddresses as RH} from "../../script/lib/RobinhoodAddresses.sol";
import {SimTypes, ISimDeployer} from "./SimTypes.sol";
// in the dependency graph so it is rebuilt with the protocol and its artifact is visible to deployCode
import {SimDeployer} from "./SimDeployer.sol";

interface IChainlinkFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Long-horizon simulation harness for flipper.family, deployed exactly as Deploy.s.sol deploys it (see
///         SimDeployer) with the launch config: V4_START_MCAP_USD=5000, V4_POOL_BPS=10000, OPENING_BUY_SUPPLY_BPS=1250,
///         PRINCIPAL_LOCK=1, dice-mock randomness, production vault parameters (80% fee, 7-day lock, 2-day cooldown).
///
///   Local analogues of the Robinhood routes: WETH (a WETH9) through the real WethWrapperHook pool, and a 6-dp USD
///   token (USDG) with a deep hookless ETH pool (fee 460, tick spacing 9, as USDG's). Both route through the
///   protocol's own $FLIPPER pool, which is the binding hop on the fork too.
///
///   Randomness is real Dice: flips request through the DiceEntropyAdapter; the keeper (the dice-mock provider and
///   trusted revealer) reveals from a hash chain this harness holds, within the prompt window, so settlement goes
///   through markets. Outcomes are seeded: the target block's hash is keccak(seed, flip), or searched to force an
///   outcome (streak scenarios). A small share of deliveries is made late on purpose (safe mode).
///
///   The market is closed-loop: the whole supply starts in the pool, so every $FLIPPER a player, holder or staker
///   owns was bought there. Players keep a float for $FLIPPER flips (buy when short, sell when well above it); an
///   arbitrageur takes auction lots as soon as they clear below the pool price; a harvester runs the permissionless
///   upkeep. Every flow into or out of the pool is attributed (players, arbitrage, house settlements).
///
///   A shadow integrator follows the reward stream between timestamps (eligible supply, rate, stream end) and
///   accrues every tracked holder's and staker's expected rewards independently of the token's accumulator.
abstract contract SimBase is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ── launch config (Deploy.s.sol env) ─────────────────────────────────────────────────────────────────
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    /// Chainlink ETH/USD on Robinhood Chain at block 72,650,000 (8 dp), the fork the rest of the suite uses
    uint256 internal constant ETH_USD = 268_681_000_000;
    uint256 internal ethUsd = ETH_USD; // fork: read from the chain's Chainlink feed
    address internal diceAdmin; // registers the dice provider (dice-mock: the keeper; dice-mirror: Dice's admin)
    mapping(address => uint256) internal baseAccrued; // fork: rewards accrued before the simulation started
    mapping(address => uint256) internal baseVault;
    uint256 internal untrackedBase; // fork: $FLIPPER held by accounts that don't act in the simulation
    uint256 internal constant START_MCAP_USD = 5000;
    uint256 internal constant POOL_BPS = 10_000;
    uint256 internal constant OPENING_BUY_SUPPLY_BPS = 1250;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAG = 2 ** 96;
    uint256 internal constant CHAIN_LEN = 1024;
    bytes16 internal constant ERC8021 = 0x80218021802180218021802180218021;

    // ── system ───────────────────────────────────────────────────────────────────────────────────────────
    IPoolManager internal manager;
    PoolModifyLiquidityTest internal lpRouter;
    ISimDeployer internal deployer; // local: the SimDeployer contract
    address internal deployerAddr; // the deployer: owner, unlocker, "demo" partner payout (fork: Deploy's broadcaster)
    bool internal forked;
    SimTypes.Out internal d;
    FlipperHouse internal house;
    FlipperRewardToken internal token;
    TreasuryVault internal vault;
    RevenueRouter internal router;
    DutchAuctionConverter internal converter;
    PartnerRegistry internal partners;
    PrincipalLock internal lock;
    DiceEntropyAdapter internal adapter;
    IDiceEntropy internal dice;
    V4RouteAdapter internal v4;
    FlipperLens internal lens;
    DevSwapRouter internal dex;
    WETH internal weth;
    MockERC20 internal usdg;
    PoolKey internal fKey;
    PoolKey internal usdgKey;
    int24 internal lpLower;
    int24 internal lpUpper;

    // ── actors ───────────────────────────────────────────────────────────────────────────────────────────
    address internal keeper = makeAddr("keeper");
    address internal dev = makeAddr("devPayout");
    address internal harvester = makeAddr("harvester");
    address internal arb = makeAddr("arb");
    address internal partnerCtl = makeAddr("partnerCtl");
    address internal partnerPayout = makeAddr("partnerPayout");
    address[] internal players;
    address[] internal holders; // passive wallets: [0] claims every batch, [1] rarely, [2] at checkpoints, [3] trades
    address[] internal stakers;
    address[] internal tracked; // every account whose rewards the shadow follows
    uint256 internal demoId = 1;
    uint256 internal p2Id;

    // ── seeded randomness ────────────────────────────────────────────────────────────────────────────────
    uint256 internal seed;
    uint256 internal nonce;

    // ── Dice hash chain ──────────────────────────────────────────────────────────────────────────────────
    bytes32[] internal chain; // chain[i] = keccak^i(secret); chain[CHAIN_LEN] is the registered commitment
    uint256 internal chainBase; // provider sequence the commitment was registered at
    uint256 internal rekeys;

    // ── shadow reward integrator ─────────────────────────────────────────────────────────────────────────
    mapping(address => uint256) internal expectedMag; // expected lifetime token rewards × 2^96
    mapping(address => uint256) internal expectedVaultMag; // expected vault pass-through × 2^96 (stakers)
    uint256 internal shadowRpt; // Σ Δt·rate/eligibleSupply (magnified)
    // counterfactuals for the lock's holder rewards (same stream, same balances, only the eligible supply differs):
    //   B: the lock's part of the vault's virtual balance excluded from holder rewards
    //   C: the lock's eligible share capped at `lockCapBps` of the eligible supply
    mapping(address => uint256) internal expectedMagB;
    mapping(address => uint256) internal expectedMagC;
    uint256 internal lockMagC; // the lock's rewards under C (× 2^96)
    uint256 internal lockCapBps = 2500;
    uint256 internal lockShareBpsTime; // Σ lock share of the eligible supply (bps) × seconds
    uint256 internal streamSeconds;

    // ── flows and counters (cumulative) ──────────────────────────────────────────────────────────────────
    struct Stats {
        uint256 flips;
        uint256 flipsFlipper;
        uint256 flipsToken;
        uint256 flipsPartner;
        uint256 wins;
        uint256 rejected;
        uint256 safeDeliveries;
        uint256 volEth; // flip stakes at flip-time value, ETH wei
        uint256 volUsd; // … in USD (1e18)
        uint256 volFlipper; // $FLIPPER staked on $FLIPPER flips
        uint256 volTokenEth; // ETH value staked on token flips
        uint256 winPending;
        uint256 wonFallback;
        uint256 lostInventory;
        uint256 playerEthIn; // ETH players paid into the $FLIPPER pool
        uint256 playerEthOut; // ETH players took out of it
        uint256 arbEthIn; // ETH the arbitrageur paid into the pool (to take lots)
        uint256 houseEthIn; // ETH into the pool from house settlements (losses sold for $FLIPPER)
        uint256 houseEthOut; // ETH out of the pool from house settlements
        uint256 lpFeesEth; // LP fees harvested, ETH leg
        uint256 lpFeesFlipper; // … $FLIPPER leg
        uint256 bountyEth;
        uint256 bountyFlipper;
        uint256 harvests;
        uint256 lotsTaken;
        uint256 auctionEth; // ETH sold at auction
        uint256 auctionFlipper; // $FLIPPER it fetched
        uint256 inventoryLotsTaken;
        uint256 devExcess; // excess the lock paid out
        uint256 devVaultRewards; // vault rewards the lock paid out
        uint256 devHolderRewards; // token rewards on the lock's own wallet it paid out
        uint256 devWalletClaims; // holder rewards the dev address claimed on its own wallet
        uint256 partnerClaimed;
        uint256 breakerTrips;
        uint256 belowMinLiability; // flips sized up to the house's minLiability (or skipped: cap below it)
        uint256 minLiabilityChanges; // the owner re-pricing minLiability as the $FLIPPER price moves
    }

    mapping(uint8 code => uint256) internal rejectedByCode; // previews that refused a drawn size, by reject code

    Stats internal st;
    uint256[] internal pendingWins;
    uint256 internal tokenCapWeth;
    uint256 internal tokenCapUsdg;
    uint256 internal tokenCapAt; // flip count of the last cap refresh
    uint256 internal startSqrtP; // pool price after the setup buys (baseline for price changes)
    uint256 internal lateDeliveryBps = 300; // share of deliveries made after the prompt window
    uint256 internal partnerBps = 3000; // share of flips carrying a partner code
    uint256 internal flipperShareBps = 6000; // share of $FLIPPER flips (rest: WETH / USDG)
    uint256 internal maxSizeBps = BPS; // stakes drawn in [10%, maxSizeBps] of the cap
    // ── market mode (SIM_MARKET): "hold" (default) keeps every reward; "sell" has every reward recipient (holders,
    //    stakers, partners, the harvester, the dev address) claim every batch and sell what it receives into the pool
    bool internal sellRewards;
    uint256 internal bountyToSell;
    uint256 internal devEthRealized; // ETH the dev address got selling its earnings ("sell" mode)
    uint256 internal rewardEthRealized; // ETH everyone else got selling rewards / bounties / partner shares

    // ── trace (SIM_TRACE=1): one CSV row per flip, per market / upkeep / lock / staking action, per upkeep ──
    bool internal trace;
    uint256 internal lastMaxLiab; // the flip's own cap, from the preview that sized it
    uint256 internal lastVolEth;
    bool internal lastLate;
    mapping(address => string) internal label;

    struct Settle {
        uint256 t0;
        uint256 r0;
        uint256 p0;
        uint256 e0;
        uint256 t1;
        uint256 r1;
        uint256 p1;
        uint256 e1;
    }

    Settle internal ls;

    // breaker trips: flip count, NAV/unit, ATH at the trip, cause
    struct Trip {
        uint256 flips;
        uint256 nav;
        uint256 ath;
        string cause;
    }

    Trip[] internal trips;
    uint256 internal shadowAth; // max NAV/unit seen after any action (treasury ≥ lockMinTreasury)

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Deployment
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function _deploy(uint256 _seed) internal {
        seed = _seed;
        trace = vm.envOr("SIM_TRACE", false);
        sellRewards = keccak256(bytes(vm.envOr("SIM_MARKET", string("hold")))) == keccak256("sell");
        lockCapBps = vm.envOr("SIM_LOCK_CAP_BPS", uint256(2500));
        vm.warp(1_790_352_033); // the fork block's timestamp
        vm.roll(1_000);
        vm.deal(address(this), 1e30);
        manager = IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        lpRouter = new PoolModifyLiquidityTest(manager);
        weth = new WETH();
        usdg = new MockERC20("USDG", "USDG", 6);
        usdgKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usdg)), 460, 9, IHooks(address(0)));
        _seedUsdPool(20_000 ether);

        deployer = ISimDeployer(deployCode("SimDeployer.sol:SimDeployer"));
        SimTypes.Cfg memory c = SimTypes.Cfg({
            poolManager: manager,
            ethUsd: ETH_USD,
            supply: SUPPLY,
            startMcapUsd: START_MCAP_USD,
            poolBps: POOL_BPS,
            fee: 10_000,
            tickSpacing: 200,
            openingBuySupplyBps: OPENING_BUY_SUPPLY_BPS,
            principalLock: true,
            devPayout: dev,
            treasurySeedBps: 9000,
            vaultFeeBps: 8000,
            vaultLock: 7 days,
            vaultCooldown: 2 days,
            keeper: keeper,
            dev: true,
            weth: address(weth),
            usdQuote: address(usdg),
            usdQuotePool: usdgKey,
            positionManager: LocalPositionManager.deploy(manager)
        });
        d = deployer.deploy{value: 10 ether}(c);
        deployerAddr = address(deployer);
        _wire();
        _postDeploy();
    }

    /// @dev typed handles on the deployed system (`d`)
    function _wire() internal {
        house = FlipperHouse(payable(d.house));
        token = FlipperRewardToken(d.flipper);
        vault = TreasuryVault(d.vault);
        router = RevenueRouter(payable(d.router));
        converter = DutchAuctionConverter(payable(d.converter));
        partners = PartnerRegistry(d.partners);
        lock = PrincipalLock(d.principalLock);
        adapter = DiceEntropyAdapter(d.randomness);
        dice = IDiceEntropy(d.dice);
        v4 = V4RouteAdapter(d.v4);
        lens = FlipperLens(d.lens);
        dex = DevSwapRouter(payable(d.devSwap));
        fKey = d.flipperKey;
        (, lpLower, lpUpper) = router.lpPosition();
    }

    /// @dev what the dev keeper and the first users do after Deploy: register the dice-mock provider, list USDG
    ///      (permissionless), a second partner, the actors' opening positions
    function _postDeploy() internal {
        // the dev keeper registers as the dice-mock provider (Deploy leaves that to `register-provider`)
        _rekey();
        vm.prank(keeper);
        dice.setDefaultGasLimit(200_000); // the live provider's default
        vm.roll(block.number + 1);

        // USDG lists permissionlessly (a trusted token on its own ETH pool)
        try v4.registerAndList(address(usdg), usdgKey) {} catch {} // (already listed on a deployed stack)

        // a second partner: registered permissionlessly (the default tier), no discount
        vm.prank(partnerCtl);
        p2Id = partners.register("p2", partnerPayout, 0);

        _makeActors();
        startSqrtP = _sqrtP();
    }

    /// @dev act as the deployer (owner of every contract, unlocker)
    function _exec(address target, bytes memory data) internal returns (bytes memory r) {
        if (!forked) return deployer.exec(target, data);
        vm.prank(deployerAddr);
        bool ok;
        (ok, r) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 0x20), mload(r))
            }
        }
    }

    /// @dev give `p` `amt` USDG: minted locally, bought through the real USDG/ETH pool on the fork
    function _fundUsdg(address p, uint256 amt) internal {
        if (!forked) {
            usdg.mint(p, amt);
            return;
        }
        uint256 ethIn = FullMath.mulDiv(amt, 1e18, _usdPerEth()) * 102 / 100 + 1e9;
        vm.prank(p);
        dex.swapExactIn{value: ethIn}(_one(usdgKey), address(0), address(usdg), ethIn, amt, p);
    }

    /// @dev attach to a stack Deploy.s.sol deployed on a Robinhood fork (the manifest it wrote)
    function _attachFork(uint256 _seed, string memory manifest) internal {
        seed = _seed;
        trace = vm.envOr("SIM_TRACE", false);
        sellRewards = keccak256(bytes(vm.envOr("SIM_MARKET", string("hold")))) == keccak256("sell");
        forked = true;
        string memory j = vm.readFile(manifest);
        manager = IPoolManager(RH.POOL_MANAGER);
        weth = WETH(payable(RH.WETH));
        usdg = MockERC20(RH.USDG);
        usdgKey = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(RH.USDG), RH.USDG_POOL_FEE, RH.USDG_POOL_TICK_SPACING, IHooks(address(0))
        );
        d.router = vm.parseJsonAddress(j, ".contracts.router");
        d.flipper = vm.parseJsonAddress(j, ".contracts.flipper");
        d.house = vm.parseJsonAddress(j, ".contracts.house");
        d.module = vm.parseJsonAddress(j, ".contracts.houseModule");
        d.randomness = vm.parseJsonAddress(j, ".contracts.randomness");
        d.dice = vm.parseJsonAddress(j, ".contracts.entropy");
        d.lens = vm.parseJsonAddress(j, ".contracts.lens");
        d.v4 = vm.parseJsonAddress(j, ".contracts.v4Adapter");
        d.vault = vm.parseJsonAddress(j, ".contracts.treasuryVault");
        d.policy = vm.parseJsonAddress(j, ".contracts.listingPolicy");
        d.converter = vm.parseJsonAddress(j, ".contracts.auctionConverter");
        d.partners = vm.parseJsonAddress(j, ".contracts.partnerRegistry");
        d.wethWrapper = vm.parseJsonAddress(j, ".contracts.wethWrapperHook");
        d.principalLock = vm.parseJsonAddress(j, ".contracts.principalLock");
        d.devSwap = vm.parseJsonAddress(j, ".contracts.devSwapRouter");
        d.liquidityKeeper = vm.parseJsonAddress(j, ".contracts.liquidityKeeper");
        deployerAddr = vm.parseJsonAddress(j, ".accounts.deployer");
        (d.flipperKey,,) = RevenueRouter(payable(d.router)).lpPosition();
        vm.deal(address(this), 1e30);
        _wire();
        // the deployment's own roles: the dice provider (dice-mirror: Dice's live default provider, re-keyed here by
        // Dice's admin, as the dev keeper does), the lock's dev address, the chain's ETH/USD
        keeper = adapter.provider();
        diceAdmin = RH.DICE_ADMIN;
        dev = lock.devAddress();
        (, int256 px,,,) = IChainlinkFeed(RH.CHAINLINK_ETH_USD).latestRoundData();
        ethUsd = uint256(px);
        _postDeploy();
        // baselines: what accrued before the simulation, and $FLIPPER held by accounts that don't act here
        for (uint256 i; i < tracked.length; ++i) {
            address a = tracked[i];
            baseAccrued[a] = token.accrued(a);
            baseVault[a] = vault.rewardsClaimed(a) + vault.pendingRewards(a);
        }
        uint256 known = token.balanceOf(address(manager)) + token.balanceOf(address(house))
            + token.balanceOf(address(vault)) + token.balanceOf(address(token)) + token.balanceOf(address(router))
            + token.balanceOf(address(converter)) + token.balanceOf(address(dex)) + token.balanceOf(address(this))
            + token.balanceOf(d.liquidityKeeper);
        for (uint256 i; i < tracked.length; ++i) {
            known += token.balanceOf(tracked[i]);
        }
        untrackedBase = token.totalSupply() - known;
    }

    function _seedUsdPool(uint256 ethDepth) internal {
        uint256 usdPerEth = ETH_USD * 1e6 / 1e8; // USDG raw per 1e18 wei
        uint160 sqrtP = uint160(Math.sqrt(FullMath.mulDiv(usdPerEth, 1 << 192, 1e18)));
        manager.initialize(usdgKey, sqrtP);
        uint256 liq = FullMath.mulDiv(ethDepth, sqrtP, 1 << 96);
        usdg.mint(address(this), type(uint128).max);
        usdg.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity{value: ethDepth * 102 / 100}(
            usdgKey,
            IPoolManager.ModifyLiquidityParams(TickMath.minUsableTick(9), TickMath.maxUsableTick(9), int256(liq), 0),
            ""
        );
    }

    /// @dev players, passive holders and stakers: funded with ETH; holders and stakers buy their $FLIPPER now
    function _makeActors() internal {
        for (uint256 i; i < 6; ++i) {
            address p = makeAddr(string.concat("player", vm.toString(i)));
            players.push(p);
            label[p] = string.concat("p", vm.toString(i));
            vm.deal(p, 1e27);
            vm.startPrank(p);
            token.approve(address(house), type(uint256).max);
            token.approve(address(dex), type(uint256).max);
            weth.approve(address(house), type(uint256).max);
            usdg.approve(address(house), type(uint256).max);
            vm.stopPrank();
            tracked.push(p);
        }
        for (uint256 i; i < 4; ++i) {
            address h = makeAddr(string.concat("holder", vm.toString(i)));
            holders.push(h);
            label[h] = string.concat("h", vm.toString(i));
            vm.deal(h, 1e24);
            vm.prank(h);
            token.approve(address(dex), type(uint256).max);
            tracked.push(h);
        }
        for (uint256 i; i < 2; ++i) {
            address s = makeAddr(string.concat("staker", vm.toString(i)));
            stakers.push(s);
            label[s] = string.concat("s", vm.toString(i));
            vm.deal(s, 1e24);
            vm.startPrank(s);
            token.approve(address(vault), type(uint256).max);
            token.approve(address(dex), type(uint256).max);
            vm.stopPrank();
            tracked.push(s);
        }
        label[dev] = "dev";
        label[partnerPayout] = "partnerPayout";
        label[harvester] = "harvester";
        label[arb] = "arb";
        label[deployerAddr] = "deployer";
        tracked.push(dev);
        tracked.push(partnerPayout);
        tracked.push(harvester);
        tracked.push(arb);
        tracked.push(address(lock));
        if (deployerAddr != dev) tracked.push(deployerAddr); // the "demo" partner's payout (fork: often the dev address)
        vm.deal(arb, 1e27);
        vm.prank(arb);
        token.approve(address(converter), type(uint256).max);
        // "sell" mode: every other recipient sells through the dev router
        address[4] memory sellers = [dev, partnerPayout, harvester, arb];
        for (uint256 i; i < 4; ++i) {
            vm.prank(sellers[i]);
            token.approve(address(dex), type(uint256).max);
        }

        // passive holders buy at launch: 20M, 5M, 50M, 10M (≈ 8.5% of the supply between them)
        uint256[4] memory want = [uint256(20_000_000 ether), 5_000_000 ether, 50_000_000 ether, 10_000_000 ether];
        for (uint256 i; i < 4; ++i) {
            _buyExact(holders[i], want[i]);
        }
        // players start with a float of 3M each
        for (uint256 i; i < players.length; ++i) {
            _buyExact(players[i], 3_000_000 ether);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Dice
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev register (or re-register) the keeper as provider with a fresh hash chain
    function _rekey() internal {
        bytes32 v = keccak256(abi.encode("dice secret", seed, rekeys++));
        if (chain.length == 0) {
            for (uint256 i; i <= CHAIN_LEN; ++i) {
                chain.push(v);
                v = keccak256(abi.encodePacked(v));
            }
        } else {
            for (uint256 i; i <= CHAIN_LEN; ++i) {
                chain[i] = v;
                v = keccak256(abi.encodePacked(v));
            }
        }
        chainBase = dice.getProviderInfoV2(keeper).sequenceNumber;
        vm.prank(diceAdmin == address(0) ? keeper : diceAdmin);
        dice.registerFor(keeper, 0, chain[CHAIN_LEN], "", uint64(CHAIN_LEN), "");
    }

    function _chainValue(uint256 seq) internal view returns (bytes32) {
        return chain[CHAIN_LEN - (seq - chainBase)];
    }

    /// @dev re-key before the chain runs out (every request is revealed at once, so none is in flight)
    function _ensureChain() internal {
        uint256 next = dice.getProviderInfoV2(keeper).sequenceNumber;
        if (next + 2 >= chainBase + CHAIN_LEN) _rekey();
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Randomness helpers
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev Memory: a test function is one EVM frame, and Solidity never frees memory, so a long simulation's every
    ///      string, array and encoding accumulates until forge's memory limit (shared by all frames) stops a callee
    ///      with an out-of-gas. Long loops restore the free-memory pointer after each step (nothing allocated in a
    ///      step is referenced after it).
    function _fmp() internal pure returns (uint256 p) {
        assembly ("memory-safe") {
            p := mload(0x40)
        }
    }

    function _resetFmp(uint256 p) internal pure {
        assembly ("memory-safe") {
            mstore(0x40, p)
        }
    }

    function _rand() internal returns (uint256) {
        return uint256(keccak256(abi.encode(seed, "rng", nonce++)));
    }

    function _randBetween(uint256 lo, uint256 hi) internal returns (uint256) {
        return hi <= lo ? lo : lo + _rand() % (hi - lo + 1);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Time (every clock move goes through the shadow integrator and the arbitrageur)
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev advance the clock by `dt`; the arbitrageur takes any auction lot the moment it clears below the pool
    function _advance(uint256 dt) internal {
        uint256 t = vm.getBlockTimestamp();
        uint256 end = t + dt;
        while (!house.locked()) {
            (uint256 when, uint256 lotId) = _nextLotCrossing(end);
            if (when == 0) break;
            _integrate(when - vm.getBlockTimestamp());
            vm.warp(when);
            _takeLot(lotId);
        }
        _integrate(end - vm.getBlockTimestamp());
        vm.warp(end);
    }

    /// @dev accrue the shadow over the next `dt` seconds at the current rate / eligible supply
    function _integrate(uint256 dt) internal {
        if (dt == 0) return;
        uint256 t0 = vm.getBlockTimestamp();
        uint256 pf = token.periodFinish();
        uint256 end = t0 + dt < pf ? t0 + dt : pf;
        if (end <= t0) return;
        uint256 es = token.eligibleSupply();
        if (es < 1e18) return; // streamed into `carry` instead
        uint256 streamed = (end - t0) * token.rewardRate();
        uint256 dRpt = streamed / es;
        shadowRpt += dRpt;
        uint256 vb = token.eligibleBalanceOf(address(vault));
        uint256 ds = vault.totalSupply();
        // the lock's part of the eligible supply, and the eligible supply under B and C
        uint256 lockElig = ds == 0 ? 0 : FullMath.mulDiv(vb, vault.balanceOf(address(lock)), ds);
        uint256 others = es - lockElig;
        uint256 lockC = Math.min(lockElig, others * lockCapBps / (BPS - lockCapBps));
        uint256 dRptB = others >= 1e18 ? streamed / others : 0;
        uint256 dRptC = others + lockC >= 1e18 ? streamed / (others + lockC) : 0;
        lockMagC += lockC * dRptC;
        lockShareBpsTime += lockElig * BPS / es * (end - t0);
        streamSeconds += end - t0;
        for (uint256 i; i < tracked.length; ++i) {
            address a = tracked[i];
            uint256 bal = token.eligibleBalanceOf(a);
            expectedMag[a] += bal * dRpt;
            expectedMagB[a] += bal * dRptB;
            expectedMagC[a] += bal * dRptC;
            if (ds != 0) {
                uint256 sh = vault.balanceOf(a);
                if (sh != 0) {
                    expectedVaultMag[a] += FullMath.mulDiv(vb * dRpt, sh, ds);
                    if (a != address(lock)) {
                        expectedMagB[a] += FullMath.mulDiv(vb * dRptB, sh, ds);
                        expectedMagC[a] += FullMath.mulDiv(vb * dRptC, sh, ds);
                    }
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Pool / prices
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function _sqrtP() internal view returns (uint160 sp) {
        (sp,,,) = manager.getSlot0(fKey.toId());
    }

    /// @dev $FLIPPER wei per 1e18 ETH wei at the pool's spot price
    function _flipperPerEth() internal view returns (uint256) {
        uint256 sp = _sqrtP();
        return FullMath.mulDiv(FullMath.mulDiv(1e18, sp, 1 << 96), sp, 1 << 96);
    }

    /// @dev ETH wei that `amount` $FLIPPER is worth at spot
    function _flipperToEth(uint256 amount) internal view returns (uint256) {
        uint256 sp = _sqrtP();
        return FullMath.mulDiv(FullMath.mulDiv(amount, 1 << 96, sp), 1 << 96, sp);
    }

    function _ethToUsd(uint256 w) internal view returns (uint256) {
        return w * ethUsd / 1e8; // USD × 1e18
    }

    /// @dev ETH held by the protocol-owned position (the pool's only liquidity), per its LiquidityKeeper
    function _poolEth() internal view returns (uint256 e) {
        (e,) = LiquidityKeeper(payable(d.liquidityKeeper)).positionAmounts();
    }

    function _poolFlipper() internal view returns (uint256 f) {
        (, f) = LiquidityKeeper(payable(d.liquidityKeeper)).positionAmounts();
    }

    function _usdPerEth() internal view returns (uint256) {
        (uint160 sp,,,) = manager.getSlot0(usdgKey.toId());
        return FullMath.mulDiv(FullMath.mulDiv(1e18, sp, 1 << 96), sp, 1 << 96);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Market (players, holders, the arbitrageur)
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function _one(PoolKey memory k) internal pure returns (PoolKey[] memory p) {
        p = new PoolKey[](1);
        p[0] = k;
    }

    /// @dev ETH that buys `amount` $FLIPPER out of the pool now (its one position is always in range): the exact
    ///      curve input grossed up by the 1% fee, plus a hair
    function _ethForFlipperOut(uint256 amount) internal view returns (uint256) {
        uint160 sp = _sqrtP();
        uint128 liq = manager.getLiquidity(fKey.toId());
        uint160 next = SqrtPriceMath.getNextSqrtPriceFromOutput(sp, liq, amount, true);
        uint256 x = SqrtPriceMath.getAmount0Delta(next, sp, liq, true);
        return x * 1_000_000 / (1_000_000 - uint256(fKey.fee)) * 10_001 / 10_000 + 1000;
    }

    /// @dev the most one buy may take out of the pool: half of what is left in it (the market can't supply more; in
    ///      the "hold" market the pool's $FLIPPER runs low as the house absorbs it)
    function _buyable() internal view returns (uint256) {
        return _poolFlipper() / 2;
    }

    uint256 internal buysCapped; // buys cut down because the pool ran low

    /// @dev buy at least `amount` $FLIPPER for `who` (at most `_buyable()`: callers use what arrived)
    function _swapIn(address who, uint256 amount) internal returns (uint256 ethIn) {
        uint256 cap = _buyable();
        if (amount > cap) {
            amount = cap;
            ++buysCapped;
        }
        if (amount == 0) return 0;
        ethIn = _ethForFlipperOut(amount);
        if (ethIn > who.balance / 2) {
            // the pool is nearly out of $FLIPPER (the price is beyond any buyer's means): no buy
            ++buysCapped;
            return 0;
        }
        uint256 bal0 = token.balanceOf(who);
        vm.prank(who);
        dex.swapExactIn{value: ethIn}(_one(fKey), address(0), address(token), ethIn, 1, who);
        uint256 got = token.balanceOf(who) - bal0;
        require(got >= amount, "buy short");
        _act("buy", who, ethIn, got, 0, 0, 0, 0);
    }

    /// @dev a player / holder / staker buys `amount` $FLIPPER (pool ETH attributed to players)
    function _buyExact(address who, uint256 amount) internal {
        st.playerEthIn += _swapIn(who, amount);
    }

    /// @dev "sell" mode: `who` sells `amount` of what it just received
    function _dump(address who, uint256 amount) internal {
        if (!sellRewards || amount == 0 || house.locked()) return;
        uint256 e0 = who.balance;
        _sell(who, amount);
        if (who == dev) devEthRealized += who.balance - e0;
        else rewardEthRealized += who.balance - e0;
    }

    uint256 internal sellsCapped; // sales cut down to what the pool can absorb above its launch price

    /// @dev $FLIPPER the pool can take before the price reaches the top of its one range (the launch price): beyond
    ///      it a sale would only partly fill, which the swap engine refuses
    function _sellable() internal view returns (uint256) {
        uint160 sp = _sqrtP();
        uint160 hi = TickMath.getSqrtPriceAtTick(lpUpper);
        if (sp >= hi) return 0;
        uint256 curve = SqrtPriceMath.getAmount1Delta(sp, hi, manager.getLiquidity(fKey.toId()), false);
        return curve * 95 / 100; // (the 1% fee comes off the input first: stay well inside)
    }

    function _sell(address who, uint256 amount) internal {
        uint256 cap = _sellable();
        if (amount > cap) {
            amount = cap;
            ++sellsCapped;
        }
        if (amount == 0 || _flipperToEth(amount) < 1e9) return; // dust: worth less than a gwei
        uint256 e0 = who.balance;
        vm.prank(who);
        try dex.swapExactIn(_one(fKey), address(token), address(0), amount, 1, who) {}
        catch {
            ++sellsCapped; // (a sale the pool can't fill: kept)
            return;
        }
        st.playerEthOut += who.balance - e0;
        _act("sell", who, amount, who.balance - e0, 0, 0, 0, 0);
    }

    mapping(uint256 lotId => uint256) internal lotRetryAt; // the arbitrageur couldn't fund it: try again after

    /// @dev the next auction lot to cross the arbitrageur's threshold before `end` (0 = none)
    function _nextLotCrossing(uint256 end) internal view returns (uint256 when, uint256 lotId) {
        uint256 n = converter.lotsLength();
        uint256 now_ = vm.getBlockTimestamp();
        for (uint256 i = _lotScanFrom; i < n; ++i) {
            DutchAuctionConverter.Lot memory l = converter.lot(i);
            if (l.remaining == 0) continue;
            uint256 thr = _lotThreshold(l);
            if (thr == 0) continue;
            uint256 t = _crossTime(l, thr);
            if (t < lotRetryAt[i]) t = lotRetryAt[i];
            if (t < now_) t = now_;
            if (t <= end && (when == 0 || t < when)) (when, lotId) = (t, i);
        }
    }

    uint256 internal _lotScanFrom;

    /// @dev the price ($FLIPPER per 1e18 units) at which the arbitrageur takes a lot: 3% under the pool for ETH;
    ///      under the flip-time value (the lot's reference) for inventory
    function _lotThreshold(DutchAuctionConverter.Lot memory l) internal view returns (uint256) {
        uint256 fpe = _flipperPerEth();
        if (l.asset == address(0)) return fpe * 97 / 100;
        // inventory: 3% under its market value in $FLIPPER (WETH 1:1 with ETH; USDG through its ETH pool)
        uint256 mkt = l.asset == address(weth) ? fpe : FullMath.mulDiv(fpe, 1e18, _usdPerEth());
        return mkt * 97 / 100;
    }

    /// @dev first timestamp at which the lot's price — the halving price, but never under its floor (half the
    ///      reference, itself halving daily) — is at or below `thr` (time spent locked is ignored: lots aren't taken then)
    function _crossTime(DutchAuctionConverter.Lot memory l, uint256 thr) internal view returns (uint256) {
        uint256 t = _crossTimeHalving(l, thr);
        uint256 fl = l.floorPrice;
        if (fl > thr) {
            uint256 f;
            while (f < 255 && (fl >> f) > thr) ++f;
            uint256 tf = l.startedAt + f * converter.FLOOR_HALF_LIFE();
            if (tf > t) t = tf;
        }
        return t;
    }

    function _crossTimeHalving(DutchAuctionConverter.Lot memory l, uint256 thr) internal view returns (uint256) {
        uint256 H = converter.halfLife();
        uint256 hi = l.startPrice;
        if (hi <= thr) return l.startedAt;
        uint256 k;
        while (k < 255 && (hi >> (k + 1)) > thr) ++k;
        // within half-life k: price = hk − (hk/2)·r/H, r ∈ [0, H)
        uint256 hk = hi >> k;
        uint256 half = hk >> 1;
        if (half == 0) return l.startedAt + (k + 1) * H;
        uint256 r = Math.mulDiv(hk - thr, H, half, Math.Rounding.Ceil);
        if (r >= H) return l.startedAt + (k + 1) * H;
        return l.startedAt + k * H + r;
    }

    /// @dev the arbitrageur buys the $FLIPPER it needs from the pool and takes the whole lot
    function _takeLot(uint256 lotId) internal {
        DutchAuctionConverter.Lot memory l = converter.lot(lotId);
        uint256 p = converter.priceOf(lotId);
        if (house.locked()) return;
        if (p > _lotThreshold(l)) {
            // not yet (a breaker pause shifted the lot's clock): look again later
            lotRetryAt[lotId] = vm.getBlockTimestamp() + 10 minutes;
            return;
        }
        uint256 need = Math.mulDiv(l.remaining, p, 1e18, Math.Rounding.Ceil);
        uint256 have = token.balanceOf(arb);
        if (have < need) st.arbEthIn += _swapIn(arb, need - have);
        uint256 amt = l.remaining;
        have = token.balanceOf(arb);
        if (have < need) {
            // the pool couldn't supply it all: take what it paid for, retry the rest later
            amt = p == 0 ? amt : Math.min(amt, have * 1e18 / p);
            lotRetryAt[lotId] = vm.getBlockTimestamp() + 1 hours;
            if (amt == 0) return;
        }
        vm.prank(arb);
        uint256 paid = converter.take(lotId, amt, p);
        l.remaining = uint128(amt);
        _act("take", arb, _tokenIdx(l.asset), l.remaining, paid, p, lotId, l.kicker == address(house) ? 1 : 0);
        if (l.asset == address(0)) {
            st.auctionEth += l.remaining;
            st.auctionFlipper += paid;
            ++st.lotsTaken;
        } else {
            ++st.inventoryLotsTaken;
        }
        _afterAction("take");
    }


    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Flips
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    enum Force {
        Random,
        PlayerWins,
        PlayerLoses
    }

    function _suffix(string memory codes) internal pure returns (bytes memory) {
        return abi.encodePacked(codes, uint8(bytes(codes).length), uint8(0), ERC8021);
    }

    function _preview(address player, address t, uint256 amount, bytes memory sfx)
        internal
        returns (FlipperHouseBase.Preview memory pv)
    {
        vm.prank(player, player);
        (bool ok, bytes memory r) =
            address(house).call(abi.encodePacked(abi.encodeCall(FlipperHouse.previewFlip, (t, amount)), sfx));
        require(ok, "preview reverted");
        pv = abi.decode(r, (FlipperHouseBase.Preview));
    }

    /// @dev make a flip and deliver its randomness through Dice; returns 0 if the house refused it
    function _flipSettle(address player, address t, uint256 amount, bytes memory sfx, Force force, bool late)
        internal
        returns (uint256 id)
    {
        id = _flipOnly(player, t, amount, sfx);
        if (id == 0) return 0;
        _deliver(id, force, late);
        _book(id);
    }

    /// @dev make a flip (randomness requested, not delivered); returns 0 if the house refused it
    function _flipOnly(address player, address t, uint256 amount, bytes memory sfx) internal returns (uint256 id) {
        _ensureChain();
        uint256 fee = house.randomnessFeeFor(t);
        uint256 volEth = t == address(token)
            ? _flipperToEth(amount)
            : (t == address(weth) ? amount : FullMath.mulDiv(amount, 1e18, _usdPerEth()));
        vm.prank(player, player);
        (bool ok, bytes memory r) = address(house).call{value: fee}(
            abi.encodePacked(abi.encodeCall(FlipperHouse.flip, (t, amount, 0, vm.getBlockTimestamp())), sfx)
        );
        if (!ok) {
            ++st.rejected;
            return 0;
        }
        id = abi.decode(r, (uint256));
        ++st.flips;
        if (t == address(token)) {
            ++st.flipsFlipper;
            st.volFlipper += amount;
        } else {
            ++st.flipsToken;
            st.volTokenEth += volEth;
        }
        if (sfx.length != 0) ++st.flipsPartner;
        st.volEth += volEth;
        st.volUsd += _ethToUsd(volEth);
        lastVolEth = volEth;
    }

    /// @dev bookkeeping once a flip's randomness was delivered
    function _book(uint256 id) internal {
        FlipperHouseBase.Status s = _status(id);
        if (s == FlipperHouseBase.Status.Won || s == FlipperHouseBase.Status.WonFallback) ++st.wins;
        if (s == FlipperHouseBase.Status.WinPending) {
            ++st.winPending;
            ++st.wins;
            pendingWins.push(id);
        }
        if (s == FlipperHouseBase.Status.WonFallback) ++st.wonFallback;
        if (s == FlipperHouseBase.Status.LostInventory) ++st.lostInventory;
        if (trace) _traceFlip(id);
        _afterAction("settle");
    }

    function _tokenIdx(address t) internal view returns (uint256) {
        return t == address(token) ? 0 : (t == address(weth) ? 1 : (t == address(usdg) ? 2 : 9));
    }

    string internal constant FLIP_HEADER =
        "CSV,flip,seed,i,flipId,t,player,token,amount,volEth,winChanceBps,roll,won,status,sellQuote,buyQuote,routeCostBps,liability,maxLiability,payoutBps,partnerId,partnerShareBps,late,flipperPaid,flipperReceived,toHolders,toPartner,treasuryAfter,reservedAfter,rewardsAccruedAfter,poolEthIn,poolEthOut,sqrtPriceX96After";

    function _traceFlip(uint256 id) internal {
        (address pl,, uint16 wc, uint16 roll, FlipperHouseBase.Status s, address t, uint128 amt, uint128 liab, uint128 sq, uint128 bq,, uint16 pay) =
            house.flips(id);
        (uint32 pid, uint16 share) = house.flipPartner(id);
        string memory r = _cs(_c(_c(_c(_c("CSV,flip", seed), st.flips), id), vm.getBlockTimestamp()), label[pl]);
        r = _c(_c(_c(r, _tokenIdx(t)), amt), lastVolEth);
        bool won = roll >= BPS - wc;
        r = _c(_c(_c(_c(r, wc), roll), won ? 1 : 0), uint256(s));
        uint256 rc = bq > sq ? Math.mulDiv(bq - sq, BPS, uint256(bq) + sq, Math.Rounding.Ceil) : 0;
        r = _c(_c(_c(_c(_c(_c(r, sq), bq), rc), liab), lastMaxLiab), pay);
        r = _c(_c(_c(r, pid), share), lastLate ? 1 : 0);
        uint256 paid = ls.t1 < ls.t0 ? ls.t0 - ls.t1 : 0;
        uint256 dT = ls.t1 > ls.t0 ? ls.t1 - ls.t0 : 0;
        uint256 dR = ls.r1 - ls.r0;
        uint256 dP = ls.p1 - ls.p0;
        uint256 recv = won ? 0 : dT + dR + dP;
        r = _c(_c(_c(_c(r, paid), recv), dR), dP);
        r = _c(_c(_c(r, house.treasury()), house.reserved()), house.rewardsAccrued());
        r = _c(_c(_c(r, ls.e1 > ls.e0 ? ls.e1 - ls.e0 : 0), ls.e0 > ls.e1 ? ls.e0 - ls.e1 : 0), uint256(_sqrtP()));
        console2.log(r);
    }

    string internal constant ACT_HEADER = "CSV,act,seed,i,t,kind,actor,a,b,c,d,e,f,treasury,sqrtPriceX96";

    /// @dev one traced action (see the README for what a..f mean per kind)
    function _act(string memory kind, address who, uint256 a, uint256 b, uint256 c_, uint256 d_, uint256 e, uint256 f)
        internal
    {
        if (!trace) return;
        string memory r = _cs(_cs(_c(_c(_c("CSV,act", seed), st.flips), vm.getBlockTimestamp()), kind), label[who]);
        r = _c(_c(_c(_c(_c(_c(r, a), b), c_), d_), e), f);
        console2.log(_c(_c(r, house.treasury()), uint256(_sqrtP())));
    }

    string internal constant CKPT_HEADER =
        "CSV,ckpt,seed,i,t,treasury,reserved,rewardsAccrued,navUnits,navAth,locked,lpFeesEth,lpFeesFlipper,bountyEth,bountyFlipper,totalDistributed,totalClaimed,eligibleSupply,vaultBalance,rewardRate,periodFinish,vaultTotalSupply,protocolShares,hwm,previewPricePerShare,depositorAssets,lockValue,lockExcess,lockPendingVault,lockPendingHolder,devBalance,sqrtPriceX96,poolEth,partnerAccruedTotal,volEth,netBuybackEth,buybackHigh,edgeWinBps,edgePayoutBps,kellyBps,ethUsd8,maxLiability";

    /// @dev the state after each upkeep
    function _ckpt() internal {
        if (!trace) return;
        string memory r = _c(_c(_c(_c("CSV,ckpt", seed), st.flips), vm.getBlockTimestamp()), house.treasury());
        r = _c(_c(_c(_c(_c(r, house.reserved()), house.rewardsAccrued()), house.navUnits()), house.navAth()), house.locked() ? 1 : 0);
        r = _c(_c(_c(_c(r, st.lpFeesEth), st.lpFeesFlipper), st.bountyEth), st.bountyFlipper);
        r = _c(_c(_c(_c(r, token.totalDistributed()), token.totalClaimed()), token.eligibleSupply()), token.vaultBalance());
        r = _c(_c(r, token.rewardRate()), token.periodFinish());
        r = _c(_c(_c(_c(_c(r, vault.totalSupply()), vault.protocolShares()), vault.hwm()), vault.previewPricePerShare()), vault.depositorAssets());
        r = _c(_c(_c(_c(r, lock.value()), lock.withdrawableExcess()), lock.pendingVaultRewards()), lock.pendingHolderRewards());
        r = _c(_c(_c(_c(_c(r, token.balanceOf(dev)), uint256(_sqrtP())), _poolEth()), house.partnerAccruedTotal()), st.volEth);
        r = _c(_edgeCols(r), house.maxLiability());
        console2.log(r);
    }

    function _deliver(uint256 id, Force force, bool late) internal {
        (,, uint16 wc,,,,,,,, uint256 req,) = house.flips(id);
        DiceEntropyAdapter.RequestView memory v = adapter.requestInfo(req);
        uint64 target = v.targetBlock;
        vm.roll(block.number + 1);
        lastLate = late;
        if (late) {
            _advance(31 + _rand() % 60);
            ++st.safeDeliveries;
        } else {
            _advance(1 + _rand() % 3);
        }
        bytes32 u = adapter.userRandom(target);
        bytes32 x = _chainValue(req);
        bytes32 h = force == Force.Random
            ? keccak256(abi.encode(seed, "blockhash", id))
            : _hashFor(u, x, wc, force == Force.PlayerWins, id);
        vm.setBlockhash(target, h);
        uint256 e0 = _poolEth();
        ls.t0 = house.treasury();
        ls.r0 = house.rewardsAccrued();
        ls.p0 = house.partnerAccruedTotal();
        vm.prank(keeper, keeper);
        dice.revealWithCallback{gas: 8_000_000}(keeper, uint64(req), u, x);
        uint256 e1 = _poolEth();
        ls.t1 = house.treasury();
        ls.r1 = house.rewardsAccrued();
        ls.p1 = house.partnerAccruedTotal();
        ls.e0 = e0;
        ls.e1 = e1;
        if (e1 > e0) st.houseEthIn += e1 - e0;
        else st.houseEthOut += e0 - e1;
    }

    /// @dev a target-block hash under which the flip (user randomness `u`, provider value `x`) wins / loses
    function _hashFor(bytes32 u, bytes32 x, uint256 wc, bool win, uint256 id) internal view returns (bytes32 h) {
        bytes32 dn = keccak256(abi.encodePacked(u, x, bytes32(0))); // Dice's combineRandomValues(u, x, 0)
        for (uint256 i;; ++i) {
            h = keccak256(abi.encode(seed, "forced", id, i));
            uint256 w = uint256(keccak256(abi.encode(dn, h)));
            if ((w % BPS >= BPS - wc) == win) return h;
        }
    }

    function _status(uint256 id) internal view returns (FlipperHouseBase.Status s) {
        (,,,, s,,,,,,,) = house.flips(id);
    }

    /// @dev largest $FLIPPER stake the house accepts for `player` with `sfx` (its Kelly term: size-independent)
    function _flipperCap(address player, bytes memory sfx) internal returns (uint256) {
        // probe at the smallest stake the house accepts (its Kelly cap doesn't depend on the size)
        FlipperHouseBase.Preview memory pv = _preview(player, address(token), _minFlipperStake(), sfx);
        if (pv.code != 0 && pv.code != 7) return 0;
        lastMaxLiab = pv.maxLiability;
        uint256 payout = house.currentFlipperPayoutBps(); // the edge schedule's, now
        return pv.maxLiability * BPS / (payout - BPS);
    }

    /// @dev the smallest $FLIPPER stake whose liability (1.05× the stake) meets the house's minLiability
    function _minFlipperStake() internal view returns (uint256) {
        uint256 payout = house.currentFlipperPayoutBps(); // the edge schedule's, now
        return Math.mulDiv(house.minLiability(), BPS, payout - BPS, Math.Rounding.Ceil) + 1;
    }

    /// @dev the owner's `setFlipLimits` policy (RobinhoodAddresses: "the owner lowers it as the price rises"): keep
    ///      the minimum liability worth about $0.34 (its launch value), re-priced when it drifts more than 3x either way
    function _ownerRepriceMinLiability() internal {
        uint256 target = FullMath.mulDiv(_flipperPerEth(), 0.34e8, ethUsd); // $0.34 in $FLIPPER wei
        uint256 cur = house.minLiability();
        if (cur == 0 || target == 0) return;
        if (cur > target * 3 || cur * 3 < target) {
            _exec(address(house), abi.encodeCall(FlipperHouse.setFlipLimits, (house.maxOpenPerPlayer(), uint128(target))));
            ++st.minLiabilityChanges;
            _act("setFlipLimits", deployerAddr, house.maxOpenPerPlayer(), target, cur, 0, 0, 0);
        }
    }

    function _refreshTokenCaps() internal {
        tokenCapWeth = _tokenCap(address(weth), 1000 ether);
        tokenCapUsdg = _tokenCap(address(usdg), 1e12 * 1e6);
        tokenCapAt = st.flips;
    }

    function _tokenCap(address t, uint256 hi) internal returns (uint256 amt) {
        (amt,) = lens.maxStake(house, t, hi, false);
    }

    /// @dev one random flip: $FLIPPER (with float management), WETH or USDG, maybe partner-attributed
    function _randomFlip() internal returns (uint256 id) {
        address p = players[_rand() % players.length];
        uint256 rp = _rand() % BPS;
        bytes memory sfx = rp < partnerBps * 2 / 3 ? _suffix("p2") : (rp < partnerBps ? _suffix("demo") : bytes(""));
        uint256 frac = _randBetween(1000, maxSizeBps);
        bool late = _rand() % BPS < lateDeliveryBps;
        uint256 kind = _rand() % BPS;
        if (kind < flipperShareBps) {
            uint256 cap = _flipperCap(p, sfx);
            if (cap == 0) return 0;
            uint256 amt = cap * frac / BPS;
            uint256 minAmt = _minFlipperStake();
            if (amt < minAmt) {
                ++st.belowMinLiability;
                if (cap < minAmt) return 0; // the house's cap is under its own minimum: no $FLIPPER flip fits
                amt = minAmt;
            }
            uint256 bal = token.balanceOf(p);
            if (bal < amt) _buyExact(p, amt - bal);
            amt = Math.min(amt, token.balanceOf(p));
            if (amt < minAmt) return 0;
            id = _flipSettle(p, address(token), amt, sfx, Force.Random, late);
            _manageFloat(p, cap);
        } else {
            if (st.flips >= tokenCapAt + 40 || tokenCapAt == 0) _refreshTokenCaps();
            bool isWeth = kind < flipperShareBps + (BPS - flipperShareBps) * 6 / 10;
            address t = isWeth ? address(weth) : address(usdg);
            uint256 cap = isWeth ? tokenCapWeth : tokenCapUsdg;
            if (cap == 0) return 0;
            uint256 amt = cap * frac / BPS;
            for (uint256 i; i < 4 && amt != 0; ++i) {
                FlipperHouseBase.Preview memory pv = _preview(p, t, amt, sfx);
                lastMaxLiab = pv.maxLiability;
                if (pv.code == 0) break;
                ++rejectedByCode[pv.code];
                if (pv.code == 2 && pv.liability != 0 && pv.liability < house.minLiability()) {
                    // below the house's minimum liability: size up (at most to the cap)
                    ++st.belowMinLiability;
                    uint256 up = FullMath.mulDiv(amt, uint256(house.minLiability()) * 105 / 100, pv.liability);
                    if (up > cap) {
                        amt = 0;
                        break;
                    }
                    amt = up;
                    continue;
                }
                amt /= 2;
            }
            if (amt == 0) return 0;
            if (isWeth) {
                if (weth.balanceOf(p) < amt) {
                    vm.prank(p);
                    weth.deposit{value: amt}();
                }
            } else if (usdg.balanceOf(p) < amt) {
                _fundUsdg(p, amt - usdg.balanceOf(p));
            }
            id = _flipSettle(p, t, amt, sfx, Force.Random, late);
        }
    }

    /// @dev players keep between 1× and 4× the current max stake; beyond 4× they sell down to 2×
    function _manageFloat(address p, uint256 cap) internal {
        uint256 bal = token.balanceOf(p);
        if (cap != 0 && bal > cap * 4) _sell(p, bal - cap * 2);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Upkeep (permissionless)
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    bytes32 internal constant HARVESTED = keccak256("Harvested(address,uint256,uint256,uint256,uint256)");
    bytes32 internal constant LP_FEES = keccak256("Collected(uint256,uint256)"); // the LiquidityKeeper's

    /// @dev logs read by the harness (and so no longer recorded): the invariant suite scans them
    function _onLogs(Vm.Log[] memory logs) internal virtual {}

    function _harvest() internal {
        if (house.locked()) return;
        _onLogs(vm.getRecordedLogs()); // whatever was recorded before (recordLogs would reset it)
        uint256 share0 = house.rewardsAccrued();
        uint256 dist0 = token.totalDistributed();
        uint256 lots0 = converter.lotsLength();
        vm.recordLogs();
        vm.prank(harvester, harvester);
        router.harvest();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _onLogs(logs);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(router) && logs[i].topics[0] == HARVESTED) {
                (,, uint256 bE, uint256 bF) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                st.bountyEth += bE;
                st.bountyFlipper += bF;
                bountyToSell += bF;
            } else if (logs[i].emitter == d.liquidityKeeper && logs[i].topics[0] == LP_FEES) {
                (uint256 a0, uint256 a1) = abi.decode(logs[i].data, (uint256, uint256));
                st.lpFeesEth += a0;
                st.lpFeesFlipper += a1;
                if (trace) {
                    uint256 lotEth = converter.lotsLength() > lots0 ? converter.lot(lots0).remaining : 0;
                    _act("harvest", harvester, a0, a1, share0, token.totalDistributed() - dist0, lotEth, 0);
                }
            }
        }
        ++st.harvests;
        _afterAction("harvest");
        uint256 b = bountyToSell;
        bountyToSell = 0;
        _dump(harvester, b);
    }

    function _upkeep() internal {
        if (house.locked()) return;
        _harvest();
        // pending wins (anyone): buy the winnings now, or pay the reserved liability after the timeout
        for (uint256 i; i < pendingWins.length;) {
            uint256 id = pendingWins[i];
            if (_status(id) != FlipperHouseBase.Status.WinPending) {
                pendingWins[i] = pendingWins[pendingWins.length - 1];
                pendingWins.pop();
                continue;
            }
            uint256 t0_ = house.treasury();
            vm.prank(harvester);
            try house.resolvePendingWin(id) {
                _act("resolveWin", harvester, id, t0_ - house.treasury(), 0, 0, 0, 0);
                _afterAction("resolvePendingWin");
            } catch {}
            ++i;
        }
        // inventory (anyone): to the auction
        address[2] memory ts = [address(weth), address(usdg)];
        for (uint256 i; i < 2; ++i) {
            uint256 inv = house.inventory(ts[i]);
            if (inv != 0) {
                vm.prank(harvester);
                house.sweepInventory(ts[i], inv);
                _act("sweepInventory", harvester, i + 1, inv, 0, 0, 0, 0);
                _afterAction("sweepInventory");
            }
        }
        // claimables from safe-mode settlements
        for (uint256 i; i < players.length; ++i) {
            for (uint256 j; j < 3; ++j) {
                address t = j == 0 ? address(token) : (j == 1 ? address(weth) : address(usdg));
                uint256 due = house.claimable(players[i], t);
                if (due != 0) {
                    vm.prank(players[i]);
                    house.claim(t);
                    _act("houseClaim", players[i], j, due, 0, 0, 0, 0);
                }
            }
        }
        // take any lot already below the threshold
        (uint256 when, uint256 lotId) = _nextLotCrossing(vm.getBlockTimestamp());
        while (when != 0) {
            _takeLot(lotId);
            (when, lotId) = _nextLotCrossing(vm.getBlockTimestamp());
        }
        _advanceLotScan();
        _ckpt();
    }

    function _advanceLotScan() internal {
        uint256 n = converter.lotsLength();
        while (_lotScanFrom < n && converter.lot(_lotScanFrom).remaining == 0) ++_lotScanFrom;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Breaker / ATH tracking after every action
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    bool internal _wasLocked;

    function _nav() internal view returns (uint256) {
        uint256 u = house.navUnits();
        return u == 0 ? 0 : house.treasury() * 1e18 / u;
    }

    /// @dev the unlocker lifts the breaker, re-basing the ATH to today's NAV (`unlock(true)`); the shadow follows
    function _unlockReset() internal {
        _exec(address(house), abi.encodeCall(FlipperHouse.unlock, (true)));
        _wasLocked = false;
        shadowAth = uint256(house.navAth());
    }

    function _afterAction(string memory what) internal {
        bool l = house.locked();
        if (l && !_wasLocked) {
            ++st.breakerTrips;
            trips.push(Trip(st.flips, _nav(), house.navAth(), what));
            // the breaker only trips below half the all-time high
            assertLt(_nav() * 2, uint256(house.navAth()), "breaker tripped at or above half the ATH");
        }
        _wasLocked = l;
        if (!l && house.treasury() >= house.lockMinTreasury()) {
            uint256 n = _nav();
            if (n > shadowAth) shadowAth = n;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Principal lock operations
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev anyone sweeps: both reward sources arrive at devAddress only; returns what arrived
    function _sweep(address caller) internal returns (uint256 got) {
        if (house.locked()) return 0;
        uint256 vr = lock.pendingVaultRewards();
        uint256 hr = lock.pendingHolderRewards();
        uint256 d0 = token.balanceOf(dev);
        uint256 c0 = token.balanceOf(caller);
        vm.prank(caller);
        (uint256 a, uint256 b) = lock.sweepRewards();
        got = token.balanceOf(dev) - d0;
        assertEq(a, vr, "vault rewards swept = pending");
        assertEq(b, hr, "holder rewards swept = pending");
        assertEq(got, a + b, "everything swept went to devAddress");
        if (caller != dev) assertEq(token.balanceOf(caller), c0, "nothing to the caller");
        assertEq(token.balanceOf(address(lock)), 0, "the lock keeps nothing");
        st.devVaultRewards += a;
        st.devHolderRewards += b;
        _act("lockSweep", caller, a, b, 0, 0, 0, 0);
        _dump(dev, got);
    }

    /// @dev the dev address requests the whole excess, waits out the cooldown (clock through `_advance`) and
    ///      withdraws; returns the excess paid (rewards swept alongside are counted separately)
    function _takeExcess() internal returns (uint256 assets) {
        if (house.locked()) return 0;
        if (vm.getBlockTimestamp() < vault.unlockAt(address(lock))) return 0;
        uint256 x = lock.withdrawableExcess();
        (uint256 q,,) = lock.pendingWithdrawal();
        if (q == 0) {
            if (vault.previewDeposit(x) == 0) return 0;
            uint256 d0 = token.balanceOf(dev);
            uint256 vr = lock.pendingVaultRewards();
            vm.prank(dev);
            lock.requestExcess(type(uint256).max);
            {
                (uint256 qs_, uint256 qa_,) = lock.pendingWithdrawal();
                _act("lockRequest", dev, qs_, qa_, vr, x, 0, 0);
            }
            assertEq(token.balanceOf(dev) - d0, vr, "a request sweeps the vault rewards to devAddress");
            st.devVaultRewards += vr;
            _dump(dev, vr);
            assertGe(lock.value(), lock.principal(), "value >= principal after a request");
            _advance(vault.withdrawCooldown());
        }
        (, uint256 qa, uint256 readyAt) = lock.pendingWithdrawal();
        if (vm.getBlockTimestamp() < readyAt) _advance(readyAt - vm.getBlockTimestamp());
        uint256 p0 = lock.principal();
        uint256 dBal = token.balanceOf(dev);
        uint256 vr2 = lock.pendingVaultRewards();
        uint256 hr2 = lock.pendingHolderRewards();
        uint256 free = house.withdrawable(); // reserved and the maxReservedBps rule respected
        if (qa > lock.withdrawableExcess() || qa > free) {
            // the position fell during the cooldown (or reservations bind): cancel, request again later
            vm.prank(dev);
            lock.cancelExcess();
            _act("lockCancel", dev, qa, lock.withdrawableExcess(), 0, 0, 0, 0);
            return 0;
        }
        vm.prank(dev);
        assets = lock.withdrawExcess();
        assertEq(token.balanceOf(dev) - dBal, assets + vr2 + hr2, "withdrawal + both reward sources to devAddress");
        assertEq(lock.principal(), p0, "principal unchanged");
        assertGe(lock.value(), lock.principal(), "value >= principal after a withdrawal");
        assertEq(token.balanceOf(address(lock)), 0, "the lock keeps nothing");
        st.devExcess += assets;
        st.devVaultRewards += vr2;
        st.devHolderRewards += hr2;
        _act("lockWithdraw", dev, assets, vr2, hr2, lock.value(), 0, 0);
        _dump(dev, assets + vr2 + hr2);
        _afterAction("withdrawExcess");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Holders / stakers
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    mapping(address => uint256) internal claimedBy;

    function _claim(address who) internal returns (uint256 got) {
        if (house.locked()) return 0;
        vm.prank(who);
        got = token.claim();
        claimedBy[who] += got;
        if (who == dev) st.devWalletClaims += got;
        if (got != 0) _act("claim", who, got, 0, 0, 0, 0, 0);
        if (who != deployerAddr) _dump(who, got);
    }

    function _claimVault(address who) internal returns (uint256 got) {
        if (house.locked()) return 0;
        uint256 due = vault.pendingRewards(who);
        vm.prank(who);
        got = vault.claimRewards();
        assertEq(got, due, "vault claim = pending");
        if (got != 0) _act("vaultClaim", who, got, 0, 0, 0, 0, 0);
        _dump(who, got);
    }

    function _claimPartners() internal virtual {
        if (house.locked()) return;
        for (uint256 id = 1; id <= 2; ++id) {
            uint256 acc = house.partnerAccrued(id);
            address to = partners.payoutOf(id);
            uint256 b0 = token.balanceOf(to);
            vm.prank(harvester);
            uint256 got = house.claimPartner(id);
            assertEq(got, acc, "partner claim = accrued");
            assertEq(token.balanceOf(to) - b0, acc, "paid to the payout address");
            st.partnerClaimed += got;
            if (got != 0) _act("partnerClaim", harvester, id, got, 0, 0, 0, 0);
            if (to != deployerAddr) _dump(to, got);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Invariants
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev house solvency: every $FLIPPER it owes is in its balance (exact without donations), and the same for
    ///      every flipped token
    function _checkSolvency() internal view {
        uint256 fBal = token.balanceOf(address(house));
        uint256 owed = house.treasury() + house.rewardsAccrued() + house.escrowed(address(token))
            + house.claimableTotal(address(token)) + house.partnerAccruedTotal();
        assertEq(fBal, owed, "house $FLIPPER balance == accounted");
        address[2] memory ts = [address(weth), address(usdg)];
        for (uint256 i; i < 2; ++i) {
            uint256 b = IERC20(ts[i]).balanceOf(address(house));
            assertGe(b, house.escrowed(ts[i]) + house.inventory(ts[i]) + house.claimableTotal(ts[i]), "token solvency");
        }
        assertLe(house.reserved(), house.treasury(), "reserved <= treasury");
        assertEq(vault.totalAssets(), house.treasury(), "vault assets = treasury");
    }

    /// @dev conservation: the whole supply is accounted for between the known holders
    function _checkConservation() internal view {
        address[9] memory proto = [
            address(manager), address(house), address(vault), address(token), address(router), address(converter),
            address(dex), address(this), d.liquidityKeeper
        ];
        uint256 sum = untrackedBase; // fork: holders that don't act in the simulation
        for (uint256 i; i < 9; ++i) {
            sum += token.balanceOf(proto[i]);
        }
        for (uint256 i; i < tracked.length; ++i) {
            sum += token.balanceOf(tracked[i]);
        }
        if (sum != token.totalSupply()) {
            // name every balance, and look for the missing $FLIPPER among the other deployed contracts
            console2.log("CONSERVATION MISS: sum / supply", sum, token.totalSupply());
            for (uint256 i; i < 9; ++i) {
                console2.log("  protocol", proto[i], token.balanceOf(proto[i]));
            }
            for (uint256 i; i < tracked.length; ++i) {
                console2.log("  tracked", tracked[i], token.balanceOf(tracked[i]));
            }
            address[10] memory other = [
                address(lens), address(v4), d.policy, address(partners), address(adapter), address(dice), d.wethWrapper,
                address(weth), address(usdg), address(lpRouter)
            ];
            for (uint256 i; i < 10; ++i) {
                console2.log("  other", other[i], token.balanceOf(other[i]));
            }
            console2.log("  DEAD", token.balanceOf(token.DEAD()));
        }
        assertEq(sum, token.totalSupply(), "conservation: every $FLIPPER accounted for");
        assertEq(token.totalSupply(), SUPPLY, "fixed supply");
    }

    /// @dev the reward reserve covers every claim, the unstreamed rest and the carry; returns the dust left over
    function _checkRewardReserve() internal view returns (uint256 dust) {
        uint256 reserve = token.balanceOf(address(token));
        assertEq(reserve, token.totalDistributed() - token.totalClaimed(), "reserve = distributed - claimed");
        uint256 owed = token.pendingStream() + token.carry() + token.claimable(address(vault));
        for (uint256 i; i < tracked.length; ++i) {
            owed += token.claimable(tracked[i]);
        }
        owed += token.claimable(address(dex)) + token.claimable(address(this));
        assertLe(owed, reserve, "reward reserve covers every claim");
        dust = reserve - owed;
        // the vault pays stakers from what it pulled
        uint256 vOwed;
        for (uint256 i; i < stakers.length; ++i) {
            vOwed += vault.pendingRewards(stakers[i]);
        }
        vOwed += vault.pendingRewards(address(lock));
        assertLe(vOwed, token.balanceOf(address(vault)) + token.claimable(address(vault)), "vault covers stakers");
    }

    function _checkLock(uint256 principal0) internal view {
        assertEq(lock.principal(), principal0, "principal never changes");
        assertEq(token.balanceOf(address(lock)), 0, "lock holds nothing between transactions");
        assertEq(token.allowance(address(lock), address(vault)), 0, "no standing allowance");
        uint256 v = lock.value();
        uint256 x = v > principal0 ? v - principal0 : 0;
        uint256 free = vault.freeBankroll();
        assertEq(lock.withdrawableExcess(), x < free ? x : free, "excess = min(max(0, value - P), free bankroll)");
    }

    function _checkAth() internal view {
        if (house.locked()) return;
        assertGe(uint256(house.navAth()) + 1e6, shadowAth, "ATH tracks the highest NAV/unit");
    }

    function _checkAll(uint256 principal0) internal view returns (uint256 dust) {
        _checkSolvency();
        _checkConservation();
        dust = _checkRewardReserve();
        _checkLock(principal0);
        _checkAth();
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Reporting (CSV rows on the console: "CSV,<table>,…"; tools/ turns them into files)
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function _c(string memory s, uint256 v) internal pure returns (string memory) {
        return string.concat(s, ",", vm.toString(v));
    }

    function _cs(string memory s, string memory v) internal pure returns (string memory) {
        return string.concat(s, ",", v);
    }

    string internal constant STATE_HEADER =
        "CSV,state,seed,label,flips,flipsFlipper,flipsToken,flipsPartner,wins,rejected,safeDeliveries,simDays,volEth,volUsd,volFlipper,volTokenEth,treasury,reserved,navUnits,navPerUnit,navAth,locked,breakerTrips,vaultDepositorShares,vaultPolShares,vaultPps,vaultHwm,polAssets,depositorAssets,lockPrincipal,lockValue,lockExcess,lockPendingVaultRewards,lockPendingHolderRewards,devExcessCum,devVaultRewardsCum,devHolderRewardsCum,devWalletClaimsCum,devBalance,rewardsAccrued,partnerAccruedTotal,partnerClaimedCum,totalDistributed,totalClaimed,pendingStream,carry,eligibleSupply,vaultEligible,sampleHolderBal,sampleHolderEarned,sampleEarnedPer1M,lpFeesEthCum,lpFeesFlipperCum,bountyEthCum,bountyFlipperCum,harvests,lotsTaken,auctionEthCum,auctionFlipperCum,poolSqrtPriceX96,flipperPerEth,fdvEth,fdvUsd,poolEth,poolFlipper,playerEthIn,playerEthOut,arbEthIn,houseEthIn,houseEthOut,maxLiability,maxFlipperStake,maxWethStake,treasuryPctSupplyBps,winPending,wonFallback,lostInventory,rewardDust,sampleHolderClaimable,sellRewards,devEthRealized,rewardEthRealized,lockVaultRewardsA,lockRewardsC,lockCapBps,sampleEarnedPer1M_B,sampleEarnedPer1M_C,lockEligibleShareBps,lockEligibleShareBpsTimeAvg,othersRewardsA,othersRewardsB,othersRewardsC,minLiability,belowMinLiability,minLiabilityChanges,rejAmount2,rejQuote4,rejRouteCost5,rejWinChance6,rejBetSize7,rejLocked8,rejTooManyOpen9,buysCapped,netBuybackEth,buybackHigh,edgeWinBps,edgePayoutBps,kellyBps,ethUsd8,sellsCapped";

    function _logHeader() internal pure {
        console2.log(STATE_HEADER);
    }

    function _logState(string memory label, uint256 simStart, uint256 dust) internal {
        string memory s = _cs(_c("CSV,state", seed), label);
        s = _c(_c(_c(_c(_c(s, st.flips), st.flipsFlipper), st.flipsToken), st.flipsPartner), st.wins);
        s = _c(_c(_c(s, st.rejected), st.safeDeliveries), (vm.getBlockTimestamp() - simStart) / 1 days);
        s = _c(_c(_c(_c(s, st.volEth), st.volUsd), st.volFlipper), st.volTokenEth);
        s = _c(_c(_c(s, house.treasury()), house.reserved()), house.navUnits());
        s = _c(_c(_c(_c(s, _nav()), house.navAth()), house.locked() ? 1 : 0), st.breakerTrips);
        {
            (,, uint256 pol, uint256 pps, uint256 hwm, uint256 polA, uint256 depA) = vault.stats();
            s = _c(_c(_c(_c(_c(_c(s, vault.totalSupply()), pol), pps), hwm), polA), depA);
        }
        s = _c(_c(_c(s, lock.principal()), lock.value()), lock.withdrawableExcess());
        s = _c(_c(s, lock.pendingVaultRewards()), lock.pendingHolderRewards());
        s = _c(_c(_c(_c(_c(s, st.devExcess), st.devVaultRewards), st.devHolderRewards), st.devWalletClaims), token.balanceOf(dev));
        s = _c(_c(_c(s, house.rewardsAccrued()), house.partnerAccruedTotal()), st.partnerClaimed);
        s = _c(_c(_c(_c(s, token.totalDistributed()), token.totalClaimed()), token.pendingStream()), token.carry());
        s = _c(_c(s, token.eligibleSupply()), token.vaultBalance());
        {
            address h = holders[0];
            uint256 bal = token.balanceOf(h);
            uint256 earned = token.accrued(h);
            s = _c(_c(_c(s, bal), earned), bal == 0 ? 0 : earned * 1_000_000 ether / bal);
        }
        s = _c(_c(_c(_c(s, st.lpFeesEth), st.lpFeesFlipper), st.bountyEth), st.bountyFlipper);
        s = _c(_c(_c(_c(s, st.harvests), st.lotsTaken), st.auctionEth), st.auctionFlipper);
        {
            uint256 fpe = _flipperPerEth();
            uint256 fdvEth = SUPPLY * 1e18 / fpe;
            s = _c(_c(_c(_c(s, uint256(_sqrtP())), fpe), fdvEth), _ethToUsd(fdvEth));
        }
        s = _c(_c(s, _poolEth()), _poolFlipper());
        s = _c(_c(_c(_c(_c(s, st.playerEthIn), st.playerEthOut), st.arbEthIn), st.houseEthIn), st.houseEthOut);
        s = _c(s, house.maxLiability());
        s = _c(s, _flipperCap(players[0], ""));
        s = _c(s, _tokenCap(address(weth), 1000 ether));
        s = _c(s, house.treasury() * BPS / SUPPLY);
        s = _c(_c(_c(_c(s, st.winPending), st.wonFallback), st.lostInventory), dust);
        s = _c(_c(_c(_c(s, token.claimable(holders[0])), sellRewards ? 1 : 0), devEthRealized), rewardEthRealized);
        s = _logCounterfactuals(s);
        s = _c(_c(_c(s, house.minLiability()), st.belowMinLiability), st.minLiabilityChanges);
        s = _c(_c(_c(_c(s, rejectedByCode[2]), rejectedByCode[4]), rejectedByCode[5]), rejectedByCode[6]);
        s = _c(_c(_c(_c(s, rejectedByCode[7]), rejectedByCode[8]), rejectedByCode[9]), buysCapped);
        s = _c(_edgeCols(s), sellsCapped);
        console2.log(s);
    }

    /// @dev the edge schedule's state (net buybacks and their ratcheted high, ETH wei, signed), the base terms and
    ///      the drawdown-scaled Kelly now, and the ETH/USD used
    function _edgeCols(string memory s) internal view returns (string memory) {
        (int256 net, int256 high,,, uint256 w, uint256 pay) = house.edgeProgress();
        s = _cs(_cs(s, vm.toString(net)), vm.toString(high));
        return _c(_c(_c(_c(s, w), pay), house.currentKellyBps()), ethUsd);
    }

    /// @dev the lock's rewards and everyone else's under A (as deployed), B (lock excluded), C (lock capped)
    function _logCounterfactuals(string memory s) internal view returns (string memory) {
        address h = holders[0];
        uint256 bal = token.balanceOf(h);
        s = _c(_c(_c(s, expectedVaultMag[address(lock)] / MAG), lockMagC / MAG), lockCapBps);
        s = _c(s, bal == 0 ? 0 : expectedMagB[h] / MAG * 1_000_000 ether / bal);
        s = _c(s, bal == 0 ? 0 : expectedMagC[h] / MAG * 1_000_000 ether / bal);
        {
            uint256 es = token.eligibleSupply();
            uint256 ds = vault.totalSupply();
            uint256 le = ds == 0 ? 0 : FullMath.mulDiv(token.vaultBalance(), vault.balanceOf(address(lock)), ds);
            s = _c(_c(s, es == 0 ? 0 : le * BPS / es), streamSeconds == 0 ? 0 : lockShareBpsTime / streamSeconds);
        }
        uint256 oA;
        uint256 oB;
        uint256 oC;
        for (uint256 i; i < tracked.length; ++i) {
            address a = tracked[i];
            if (a == address(lock)) continue;
            oA += (expectedMag[a] + expectedVaultMag[a]) / MAG;
            oB += expectedMagB[a] / MAG;
            oC += expectedMagC[a] / MAG;
        }
        return _c(_c(_c(s, oA), oB), oC);
    }

    function _logTrips() internal view {
        for (uint256 i; i < trips.length; ++i) {
            console2.log(_cs(_c(_c(_c(_c("CSV,trip", seed), trips[i].flips), trips[i].nav), trips[i].ath), trips[i].cause));
        }
    }

    receive() external payable {}
}
