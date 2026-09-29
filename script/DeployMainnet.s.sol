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
import {HouseModule} from "../src/house/HouseModule.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {FlipperRewardToken} from "../src/FlipperRewardToken.sol";
import {FlipperLens} from "../src/lens/FlipperLens.sol";
import {TreasuryVault, IVaultHouse} from "../src/TreasuryVault.sol";
import {ListingPolicy} from "../src/ListingPolicy.sol";
import {DutchAuctionConverter} from "../src/DutchAuctionConverter.sol";
import {PartnerRegistry} from "../src/PartnerRegistry.sol";
import {PrincipalLock, IStakingVault} from "../src/PrincipalLock.sol";
import {LiquidityKeeper, IV4PositionManager, IUNCXV4Locker} from "../src/LiquidityKeeper.sol";
import {V4RouteAdapter} from "../src/adapters/V4RouteAdapter.sol";
import {V3RouteAdapter, IV4AdapterDepth} from "../src/adapters/V3RouteAdapter.sol";
import {V3BridgeHook} from "../src/adapters/V3BridgeHook.sol";
import {WethWrapperHook} from "../src/adapters/WethWrapperHook.sol";
import {IUniswapV3Factory} from "../src/interfaces/IUniswapV3.sol";
import {ILaunchpadVerifier} from "../src/interfaces/ILaunchpadVerifier.sol";
import {IRandomnessAdapter} from "../src/interfaces/IRandomness.sol";
import {IDiceEntropy} from "../src/interfaces/IDiceEntropy.sol";
import {DiceEntropyAdapter} from "../src/randomness/DiceEntropyAdapter.sol";
import {IPonsV2Factory} from "../src/interfaces/IPons.sol";
import {PonsVerifier} from "../src/verifiers/PonsVerifier.sol";
import {CodehashVerifier} from "../src/verifiers/CodehashVerifier.sol";
import {FlipperDeploy, IBindable} from "./lib/FlipperDeploy.sol";
import {DiceDeploy} from "./lib/DiceDeploy.sol";
import {RobinhoodAddresses as RH} from "./lib/RobinhoodAddresses.sol";

interface IChainlinkFeedM {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IOwnableM {
    function owner() external view returns (address);
}

/// @notice The mainnet deployment of flipper.family on Robinhood Chain, split into phases that one wallet (the owner:
///         a Ledger) signs. Driven by `script/mainnet.sh`, which simulates each phase against the live chain, asks for
///         confirmation, then broadcasts it (`--ledger --slow`).
///
///   Every phase is idempotent: before each action it reads the chain (and the state file) and skips what is already
///   done, so a phase that failed part-way (a rejected signature, a dropped RPC, a reverted transaction) is simply run
///   again. Addresses are persisted in STATE_FILE after every phase; one recorded without code on chain (its
///   transaction never landed) is deployed again.
///
///   Phases, in order: preflight (read-only) → fund → launch → core → seal → bankroll → routes → listings → roles →
///   manifest (writes the app manifest) → [the API accepts the unlocker role with the operator key] → check (read-only).
///
///   Roles at the end (`check` asserts every one):
///     owner (OWNER_ADDRESS, the Ledger): owner of every contract and of every ProxyAdmin; PrincipalLock owner
///     operator (OPERATOR_ADDRESS): the house guardian (pause, disable a token, emergency cancels, the minimum flip,
///                                  resuming Dice) and the drawdown breaker's unlocker (two-step: `roles` offers it,
///                                  the operator accepts). Its key is generated and held by the API (managed keys).
///     dev claim wallet (CLAIM_WALLET): PrincipalLock.devAddress: requests and receives the team's excess and rewards;
///                                      the owner can point it elsewhere at any time (`setDevAddress`)
///     upkeep (UPKEEP_ADDRESS): the API's maintenance key (managed by the API); no onchain role
///
///   Env: OWNER_ADDRESS, OPERATOR_ADDRESS, CLAIM_WALLET, UPKEEP_ADDRESS (required); STATE_FILE
///   (deployments/robinhood.state.json), MANIFEST_FILE (deployments/robinhood.json), V4_START_MCAP_USD (5000),
///   OPENING_BUY_SUPPLY_BPS (1250), MAX_OPENING_BUY_ETH (0.5 ether: the launch refuses to spend more), UNCX_LOCK (0),
///   REHEARSAL (0; 1 = an anvil fork of Robinhood Chain: chain id 31337 allowed, ArbSys off).
contract DeployMainnet is Script {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint24 internal constant POOL_FEE = 10_000;
    int24 internal constant TICK_SPACING = 200;

    struct Cfg {
        address owner;
        address operator;
        address claim;
        address upkeep;
        uint256 startMcapUsd;
        uint256 buyBps;
        uint256 maxBuyEth;
        bool uncx;
        bool rehearsal;
        string stateFile;
        string manifestFile;
    }

    /// @dev everything the phases hand each other (persisted as JSON)
    struct St {
        uint256 deployBlock;
        address router;
        address keeper;
        address flipper;
        uint256 bought;
        address randomness;
        address house;
        address lens;
        address v4;
        address vault;
        address policy;
        address converter;
        address partners;
        address principalLock;
        address v3Bridge;
        address v3;
        address wethWrapper;
        address ponsVerifier;
        address stockVerifier;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Phases
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Read-only: the environment, the chain, the owner's balance and what the launch will cost.
    function preflight() external view {
        Cfg memory c = _cfg();
        _requireChain(c);
        (uint256 px, uint160 sqrtP, uint256 want, uint256 buyEth, uint256 lockFee) = _launchTerms(c);
        console2.log("chain id              ", block.chainid);
        console2.log("owner (Ledger)        ", c.owner);
        console2.log("operator              ", c.operator);
        console2.log("dev claim wallet      ", c.claim);
        console2.log("upkeep (API key)      ", c.upkeep);
        console2.log("ETH/USD (8 dec)       ", px);
        console2.log("start sqrtPriceX96    ", uint256(sqrtP));
        console2.log("opening buy FLIPPER   ", want);
        console2.log("opening buy ETH (wei) ", buyEth);
        console2.log("UNCX lock fee (wei)   ", lockFee);
        console2.log("owner balance (wei)   ", c.owner.balance);
        console2.log("owner nonce           ", uint256(vm.getNonce(c.owner)));
        console2.log("base fee (wei)        ", block.basefee);
        require(buyEth + lockFee <= c.maxBuyEth, "opening buy above MAX_OPENING_BUY_ETH");
        uint256 funding = _fundingNeeded(c);
        console2.log("wallet funding (wei)  ", funding);
        // the launch value, the backend wallets' top-ups (the fund step runs first) and a generous gas budget (the
        // whole deploy is ~60M gas; 0.01 ETH covers it up to ~0.15 gwei)
        require(c.owner.balance >= buyEth + lockFee + funding + 0.01 ether, "owner balance: opening buy + funding + 0.01 ETH gas");
        require(block.basefee <= 1 gwei, "base fee above 1 gwei: wait");
        require(RH.DICE_ENTROPY.code.length != 0 && RH.POSITION_MANAGER.code.length != 0, "Robinhood contracts missing");
        require(FlipperDeploy.CREATE2_DEPLOYER.code.length != 0, "CREATE2 deployer missing");
        if (c.uncx) require(RH.UNCX_V4_LOCKER.code.length != 0, "UNCX locker missing");
        St memory st = _load(c);
        if (st.router != address(0)) console2.log("state file: resuming (router)", st.router);
        else require(vm.getNonce(c.owner) < 1_000_000, "nonce");
    }

    /// @notice Top up the backend-held wallets from the owner: the operator (guardian + unlocker; the API signs its
    ///         actions) to OPERATOR_FUND_WEI (0.005 ETH), the upkeep key to UPKEEP_FUND_WEI (0.025 ETH) and the dev
    ///         claim wallet (the API's claim key: it pays for the sweeps) to CLAIM_FUND_WEI (0.01 ETH). Only what's
    ///         missing is sent.
    function fund() external {
        Cfg memory c = _cfg();
        _requireChain(c);
        (address[3] memory who, uint256[3] memory target) = _fundTargets(c);
        require(_fundingNeeded(c) <= 1 ether, "funding above 1 ETH: check the *_FUND_WEI values");
        vm.startBroadcast(c.owner);
        for (uint256 i; i < 3; ++i) {
            if (who[i].balance >= target[i]) continue;
            uint256 amount = target[i] - who[i].balance;
            (bool ok,) = payable(who[i]).call{value: amount}("");
            require(ok, "funding transfer failed");
            console2.log("funded", who[i], amount);
        }
        vm.stopBroadcast();
    }

    /// @notice Router → LiquidityKeeper → $FLIPPER → launch: the whole supply single-sided in its v4 pool at the start
    ///         market cap, the position minted to the keeper for good, and the owner's opening buy (exactly
    ///         OPENING_BUY_SUPPLY_BPS of the supply), in one transaction.
    function launch() external {
        Cfg memory c = _cfg();
        _requireChain(c);
        St memory st = _load(c);
        FlipperDeploy.Config memory fc = _fc(c);
        vm.startBroadcast(c.owner);
        if (st.deployBlock == 0) st.deployBlock = block.number;

        if (!_has(st.router)) st.router = address(FlipperDeploy.deployRouter(fc));
        RevenueRouter router = RevenueRouter(payable(st.router));
        require(router.owner() == c.owner, "router owner");

        address locker = c.uncx ? RH.UNCX_V4_LOCKER : address(0);
        if (router.liquidityKeeper() == address(0)) {
            if (!_has(st.keeper)) {
                st.keeper = address(
                    new LiquidityKeeper(
                        IPoolManager(RH.POOL_MANAGER),
                        IV4PositionManager(RH.POSITION_MANAGER),
                        st.router,
                        IUNCXV4Locker(locker),
                        RH.UNCX_MAX_FLAT_FEE,
                        RH.UNCX_MAX_LP_FEE_BPS,
                        RH.UNCX_MAX_COLLECT_FEE_BPS
                    )
                );
            }
            router.setLiquidityKeeper(st.keeper);
        } else {
            st.keeper = router.liquidityKeeper();
        }

        if (address(router.flipper()) == address(0)) {
            // a token from an earlier attempt is reused only while the router still holds its whole supply
            if (!_has(st.flipper) || IERC20(st.flipper).balanceOf(st.router) != SUPPLY) {
                st.flipper = address(FlipperDeploy.deployRewardToken(fc, router, "Flipper", "FLIPPER", SUPPLY));
            }
            (, uint160 sqrtP, uint256 want, uint256 buyEth, uint256 lockFee) = _launchTerms(c);
            require(buyEth + lockFee <= c.maxBuyEth, "opening buy above MAX_OPENING_BUY_ETH");
            uint256 before = IERC20(st.flipper).balanceOf(c.owner);
            router.launchFlipperV4Token{value: buyEth + lockFee}(
                IERC20(st.flipper), SUPPLY, POOL_FEE, TICK_SPACING, sqrtP, buyEth, want, c.owner
            );
            st.bought = IERC20(st.flipper).balanceOf(c.owner) - before;
            console2.log("opening buy ETH     ", buyEth);
            console2.log("opening buy FLIPPER ", st.bought);
        } else {
            require(address(router.flipper()) == st.flipper || st.flipper == address(0), "router launched another token");
            st.flipper = address(router.flipper());
        }
        vm.stopBroadcast();
        _save(c, st);
    }

    /// @notice Randomness (Dice), the house and everything around it, wired exactly as FlipperDeploy.deployCoreWith.
    function core() external {
        Cfg memory c = _cfg();
        _requireChain(c);
        St memory st = _load(c);
        require(_launched(st), "run launch first");
        FlipperDeploy.Config memory fc = _fc(c);
        IERC20 flipper = IERC20(st.flipper);
        RevenueRouter router = RevenueRouter(payable(st.router));
        vm.startBroadcast(c.owner);

        if (!_has(st.randomness)) {
            DiceEntropyAdapter.Config memory dcfg = RH.diceAdapterConfig();
            // L2 block numbers come from ArbSys on the live chain; an anvil fork has no ArbSys precompile
            st.randomness = address(DiceDeploy.deployAdapter(fc, IDiceEntropy(RH.DICE_ENTROPY), address(0), !c.rehearsal, dcfg));
        }
        if (!_has(st.house)) {
            IRandomnessAdapter rnd = IRandomnessAdapter(st.randomness);
            address module = address(new HouseModule(IPoolManager(RH.POOL_MANAGER), flipper, rnd));
            st.house = FlipperDeploy.proxy(
                address(new FlipperHouse(IPoolManager(RH.POOL_MANAGER), flipper, rnd, module)),
                c.owner,
                abi.encodeCall(FlipperHouse.initialize, (c.owner, RH.defaultParams()))
            );
        }
        FlipperHouse house = FlipperHouse(payable(st.house));
        require(address(house.randomness()) == st.randomness, "house uses another randomness adapter");
        address consumer = DiceEntropyAdapter(st.randomness).consumer();
        if (consumer == address(0)) IBindable(st.randomness).bind(st.house);
        else require(consumer == st.house, "adapter bound to another house: clear `randomness` and `house` in the state file");

        if (!_has(st.lens)) st.lens = FlipperDeploy.proxy(address(new FlipperLens()), c.owner, "");
        if (!_has(st.v4)) {
            st.v4 = FlipperDeploy.proxy(
                address(new V4RouteAdapter()),
                c.owner,
                abi.encodeCall(V4RouteAdapter.initialize, (IPoolManager(RH.POOL_MANAGER), st.house, c.owner))
            );
        }
        V4RouteAdapter v4 = V4RouteAdapter(st.v4);
        require(v4.house() == st.house, "v4 adapter bound to another house");
        if (!_has(st.vault)) {
            st.vault = FlipperDeploy.proxy(
                address(new TreasuryVault()),
                c.owner,
                abi.encodeCall(
                    TreasuryVault.initialize,
                    (
                        IVaultHouse(st.house),
                        flipper,
                        c.owner,
                        FlipperDeploy.VAULT_FEE_BPS,
                        FlipperDeploy.VAULT_LOCK,
                        FlipperDeploy.VAULT_COOLDOWN
                    )
                )
            );
        }
        if (house.vault() == address(0)) house.setVault(st.vault);
        else require(house.vault() == st.vault, "house has another vault");
        if (house.revenueRouter() != st.router) house.setRevenueRouter(st.router);
        if (!house.isRouteAdapter(st.v4)) house.setRouteAdapter(st.v4, true);
        if (!_has(st.policy)) st.policy = address(new ListingPolicy(c.owner));
        if (address(v4.listingPolicy()) != st.policy) v4.setListingPolicy(ListingPolicy(st.policy));
        if (router.house() == address(0)) router.configure(flipper, st.house, address(0));
        else require(router.house() == st.house, "router configured for another house");

        if (!_has(st.converter)) {
            st.converter = address(
                new DutchAuctionConverter(
                    flipper,
                    st.house,
                    c.owner,
                    FlipperDeploy.AUCTION_HALF_LIFE,
                    FlipperDeploy.AUCTION_START_MULTIPLE,
                    FlipperDeploy.AUCTION_DEFAULT_START
                )
            );
        }
        DutchAuctionConverter conv = DutchAuctionConverter(payable(st.converter));
        if (!conv.isKicker(st.house)) conv.setKicker(st.house, true);
        if (!conv.isKicker(st.router)) conv.setKicker(st.router, true);
        if (house.converter() != st.converter) house.setConverter(st.converter);
        if (router.converter() != st.converter) {
            router.setUpkeepParams(
                st.converter,
                FlipperDeploy.HARVEST_BOUNTY_BPS,
                FlipperDeploy.HARVEST_BOUNTY_CAP_ETH,
                uint96(SUPPLY / FlipperDeploy.HARVEST_BOUNTY_CAP_SUPPLY_DIV),
                FlipperDeploy.MIN_LOT_ETH
            );
        }

        if (!_has(st.partners)) {
            st.partners = FlipperDeploy.proxy(
                address(new PartnerRegistry()), c.owner, abi.encodeCall(PartnerRegistry.initialize, (c.owner))
            );
        }
        PartnerRegistry partners = PartnerRegistry(st.partners);
        if (partners.tierCutBps(1) != FlipperDeploy.PARTNER_TIER1_CUT_BPS) partners.setTierCut(1, FlipperDeploy.PARTNER_TIER1_CUT_BPS);
        if (partners.tierCutBps(2) != FlipperDeploy.PARTNER_TIER2_CUT_BPS) partners.setTierCut(2, FlipperDeploy.PARTNER_TIER2_CUT_BPS);
        if (partners.tierCutBps(3) != FlipperDeploy.PARTNER_TIER3_CUT_BPS) partners.setTierCut(3, FlipperDeploy.PARTNER_TIER3_CUT_BPS);
        if (house.partnerRegistry() != st.partners) house.setPartnerRegistry(st.partners);
        vm.stopBroadcast();
        _save(c, st);
    }

    /// @notice Fix the reward token's exemptions for good (house, router, converter, keeper, vault) and stream the
    ///         router's holders' share through it.
    function seal() external {
        Cfg memory c = _cfg();
        _requireChain(c);
        St memory st = _load(c);
        require(_has(st.house) && _has(st.converter) && _has(st.vault), "run core first");
        FlipperRewardToken token = FlipperRewardToken(st.flipper);
        RevenueRouter router = RevenueRouter(payable(st.router));
        vm.startBroadcast(c.owner);
        if (token.sealer() != address(0)) {
            require(token.sealer() == c.owner, "token sealer is not the owner");
            FlipperDeploy.sealRewardToken(_sys(st), token); // also router.setRewards(token)
        } else if (router.rewards() != st.flipper) {
            router.setRewards(st.flipper);
        }
        if (router.treasuryShareBps() != 0) router.setTreasuryShareBps(0);
        vm.stopBroadcast();
        _save(c, st);
    }

    /// @notice The vault's production parameters, the team's opening buy staked for good through the PrincipalLock
    ///         (dev claim wallet = CLAIM_WALLET, owner = the Ledger), then the house's risk settings.
    function bankroll() external {
        Cfg memory c = _cfg();
        _requireChain(c);
        St memory st = _load(c);
        require(IERC20(st.flipper).balanceOf(st.router) == 0 && _has(st.vault), "run launch, core and seal first");
        require(FlipperRewardToken(st.flipper).sealer() == address(0), "run seal first");
        FlipperHouse house = FlipperHouse(payable(st.house));
        TreasuryVault vault = TreasuryVault(st.vault);
        vm.startBroadcast(c.owner);

        if (
            vault.performanceFeeBps() != FlipperDeploy.VAULT_FEE_BPS || vault.lockDuration() != FlipperDeploy.VAULT_LOCK
                || vault.withdrawCooldown() != FlipperDeploy.VAULT_COOLDOWN
        ) {
            vault.setParams{gas: FlipperDeploy.VAULT_CALL_GAS}(
                FlipperDeploy.VAULT_FEE_BPS, FlipperDeploy.VAULT_LOCK, FlipperDeploy.VAULT_COOLDOWN
            );
        }

        if (!_has(st.principalLock)) {
            st.principalLock = address(new PrincipalLock(IStakingVault(st.vault), c.claim, c.owner));
        }
        PrincipalLock lock = PrincipalLock(st.principalLock);
        if (lock.principal() == 0) {
            vault.crystallize{gas: FlipperDeploy.VAULT_CALL_GAS}();
            uint256 held = IERC20(st.flipper).balanceOf(c.owner);
            uint256 amount = st.bought != 0 ? Math.min(st.bought, held) : held;
            require(amount != 0, "no opening-buy FLIPPER to stake");
            IERC20(st.flipper).approve(st.principalLock, amount);
            lock.stake{gas: FlipperDeploy.VAULT_CALL_GAS}(amount);
            console2.log("staked (principal)  ", amount);
        }

        if (house.lockMinTreasury() == 0) {
            // the drawdown check runs once the treasury holds at least a tenth of the stake
            require(house.treasury() != 0, "empty treasury");
            house.setLockMinTreasury(uint128(house.treasury() / 10));
        }
        FlipperHouseBase.EdgeSchedule memory es = RH.edgeSchedule();
        (uint96 f, uint96 to, uint16 ws, uint16 we, uint16 ps, uint16 pe) = house.edgeSchedule();
        if (f != es.fromEth || to != es.toEth || ws != es.winStartBps || we != es.winEndBps || ps != es.payoutStartBps || pe != es.payoutEndBps) {
            house.setEdgeSchedule(es);
        }
        if (
            house.params().kellyBps != RH.KELLY_BPS || house.kellyMinBps() != RH.KELLY_MIN_BPS
                || house.kellyDdStartBps() != RH.KELLY_DD_START_BPS || house.kellyDdEndBps() != RH.KELLY_DD_END_BPS
        ) {
            house.setKellySchedule(RH.KELLY_BPS, RH.KELLY_MIN_BPS, RH.KELLY_DD_START_BPS, RH.KELLY_DD_END_BPS);
        }
        if (house.maxOpenPerPlayer() != RH.MAX_OPEN_PER_PLAYER || house.minLiability() != RH.MIN_LIABILITY) {
            house.setFlipLimits(RH.MAX_OPEN_PER_PLAYER, RH.MIN_LIABILITY);
        }
        // the revenue auction's first ETH lot: a reference (and so a floor) from the pool's price
        DutchAuctionConverter conv = DutchAuctionConverter(payable(st.converter));
        if (conv.lastPrice(address(0)) == 0) conv.seedPrice(address(0), _flipperPerEth(st));
        vm.stopBroadcast();
        _save(c, st);
    }

    /// @notice Swap routes: the $FLIPPER pool and USDG quote on the v4 adapter (plus pons' meme hook), and the v3 bridge
    ///         hook + V3RouteAdapter for Uniswap v3 pools.
    function routes() external {
        Cfg memory c = _cfg();
        _requireChain(c);
        St memory st = _load(c);
        require(_has(st.policy), "run core first");
        FlipperHouse house = FlipperHouse(payable(st.house));
        V4RouteAdapter v4 = V4RouteAdapter(st.v4);
        PoolKey memory fk = _flipperKey(st);
        PoolKey memory usdg = _usdgPool();
        vm.startBroadcast(c.owner);

        if (_id(v4.flipperPool()) != _id(fk)) v4.setFlipperPool(fk);
        if (!v4.isHookAllowed(RH.PONS_V2_MEME_HOOK)) v4.setHookAllowed(RH.PONS_V2_MEME_HOOK, true);
        if (_id(v4.quotePool(RH.USDG)) != _id(usdg)) v4.setQuote(RH.USDG, usdg);

        if (!_has(st.v3Bridge)) {
            bytes memory args = abi.encode(IPoolManager(RH.POOL_MANAGER), IUniswapV3Factory(RH.V3_FACTORY), RH.WETH);
            bytes32 initHash = keccak256(abi.encodePacked(type(V3BridgeHook).creationCode, args));
            bytes32 salt = FlipperDeploy.mineHookSalt(FlipperDeploy.CREATE2_DEPLOYER, initHash, FlipperDeploy.V3_BRIDGE_FLAGS);
            st.v3Bridge = address(
                new V3BridgeHook{salt: salt}(IPoolManager(RH.POOL_MANAGER), IUniswapV3Factory(RH.V3_FACTORY), RH.WETH)
            );
        }
        if (!_has(st.v3)) {
            st.v3 = FlipperDeploy.proxy(
                address(new V3RouteAdapter()),
                c.owner,
                abi.encodeCall(V3RouteAdapter.initialize, (V3BridgeHook(payable(st.v3Bridge)), st.house, c.owner))
            );
        }
        V3RouteAdapter v3 = V3RouteAdapter(st.v3);
        if (address(v3.v4Adapter()) != st.v4) v3.setV4Adapter(IV4AdapterDepth(st.v4));
        if (address(v3.listingPolicy()) != st.policy) v3.setListingPolicy(ListingPolicy(st.policy));
        if (!house.isRouteAdapter(st.v3)) house.setRouteAdapter(st.v3, true);
        if (_id(v3.flipperPool()) != _id(fk)) v3.setFlipperPool(fk);
        if (_id(v3.quotePool(RH.USDG)) != _id(usdg)) v3.setQuote(RH.USDG, usdg);
        vm.stopBroadcast();
        _save(c, st);
    }

    /// @notice The listing policy (the stock-token verifier attached, the pons verifier deployed but not attached,
    ///         the majors allowlisted), WETH through its 1:1 wrapper pool, the curated launch whitelist, the launch
    ///         stock tokens (RH.launchStocks) and memecoins (RH.launchMemes).
    function listings() external {
        Cfg memory c = _cfg();
        _requireChain(c);
        St memory st = _load(c);
        require(_has(st.v3), "run routes first");
        ListingPolicy policy = ListingPolicy(st.policy);
        vm.startBroadcast(c.owner);

        if (!_has(st.ponsVerifier)) {
            st.ponsVerifier = address(
                new PonsVerifier(
                    IPonsV2Factory(RH.PONS_V2_FACTORY),
                    RH.PONS_V2_MEME_HOOK,
                    RH.PONS_V2_MEME_HOOK.codehash,
                    RH.PONS_TOKEN_TEMPLATE,
                    RH.PONS_TOKEN_SIZE,
                    RH.PONS_TOKEN_IMMUTABLES
                )
            );
        }
        if (!_has(st.stockVerifier)) {
            st.stockVerifier = address(new CodehashVerifier(RH.STOCK_TOKEN_CODEHASH, "robinhood-stock", st.v3Bridge));
        }
        if (!_attached(policy, st.stockVerifier)) policy.attach(ILaunchpadVerifier(st.stockVerifier));
        address[] memory trusted = RH.trustedTokens();
        for (uint256 i; i < trusted.length; ++i) {
            if (!policy.isTokenAllowlisted(trusted[i])) policy.setTokenAllowlisted(trusted[i], true);
        }

        // WETH ↔ native ETH through a 1:1 wrapper-hook pool, then WETH listed
        if (!_has(st.wethWrapper)) {
            bytes memory args = abi.encode(IPoolManager(RH.POOL_MANAGER), RH.WETH);
            bytes32 initHash = keccak256(abi.encodePacked(type(WethWrapperHook).creationCode, args));
            bytes32 salt = FlipperDeploy.mineHookSalt(FlipperDeploy.CREATE2_DEPLOYER, initHash, FlipperDeploy.V3_BRIDGE_FLAGS);
            st.wethWrapper = address(new WethWrapperHook{salt: salt}(IPoolManager(RH.POOL_MANAGER), RH.WETH));
        }
        WethWrapperHook ww = WethWrapperHook(payable(st.wethWrapper));
        PoolKey memory wk = ww.poolKey();
        (uint160 wsp,,,) = StateLibrary.getSlot0(IPoolManager(RH.POOL_MANAGER), PoolIdLibrary.toId(wk));
        if (wsp == 0) ww.initialize();
        if (!policy.isHookPinned(st.wethWrapper)) policy.pinHook(st.wethWrapper, true);
        if (!policy.isPoolWhitelisted(_id(wk))) policy.setPoolWhitelisted(wk, true);
        if (!_listed(st, RH.WETH)) V4RouteAdapter(st.v4).registerAndList(RH.WETH, wk);

        // the curated launch whitelist: each pool whitelisted, then listed if its route-cost probe passes (simulated
        // off the broadcast first; a failing probe leaves the pool whitelisted for anyone to list later)
        RH.Listing[] memory w = RH.launchWhitelist();
        for (uint256 i; i < w.length; ++i) {
            bool isV3 = w[i].v3Pool != address(0);
            if (isV3 && !policy.isV3PoolWhitelisted(w[i].v3Pool)) policy.setV3PoolWhitelisted(w[i].v3Pool, true);
            if (!isV3 && !policy.isPoolWhitelisted(_id(w[i].key))) policy.setPoolWhitelisted(w[i].key, true);
            if (_listed(st, w[i].token)) continue;
            vm.stopBroadcast();
            uint256 snap = vm.snapshotState();
            bool ok = _tryList(st, w[i]);
            vm.revertToState(snap);
            vm.startBroadcast(c.owner);
            if (!ok) {
                console2.log("launch whitelist: probe failed, left whitelisted but unlisted", w[i].token);
                continue;
            }
            if (isV3) V3RouteAdapter(st.v3).registerAndList(w[i].token, w[i].v3Pool);
            else V4RouteAdapter(st.v4).registerAndList(w[i].token, w[i].key);
        }

        // stock tokens: vetted by the stock-token verifier (no whitelisting); listed only when the probe passes
        RH.Listing[] memory stocks = RH.launchStocks();
        for (uint256 i; i < stocks.length; ++i) {
            if (_listed(st, stocks[i].token)) continue;
            vm.stopBroadcast();
            uint256 snap = vm.snapshotState();
            bool ok = _tryList(st, stocks[i]);
            vm.revertToState(snap);
            vm.startBroadcast(c.owner);
            if (!ok) {
                console2.log("launch stocks: probe failed, not listed", stocks[i].token);
                continue;
            }
            V4RouteAdapter(st.v4).registerAndList(stocks[i].token, stocks[i].key);
        }

        // memecoins: the pool is whitelisted only together with a listing whose probe passes (else nothing is done)
        RH.Listing[] memory memes = RH.launchMemes();
        for (uint256 i; i < memes.length; ++i) {
            if (_listed(st, memes[i].token)) continue;
            vm.stopBroadcast();
            uint256 snap = vm.snapshotState();
            if (!policy.isPoolWhitelisted(_id(memes[i].key))) {
                vm.prank(c.owner);
                policy.setPoolWhitelisted(memes[i].key, true);
            }
            bool ok = _tryList(st, memes[i]);
            vm.revertToState(snap);
            vm.startBroadcast(c.owner);
            if (!ok) {
                console2.log("launch memes: doesn't qualify (probe failed), left out", memes[i].token);
                continue;
            }
            if (!policy.isPoolWhitelisted(_id(memes[i].key))) policy.setPoolWhitelisted(memes[i].key, true);
            V4RouteAdapter(st.v4).registerAndList(memes[i].token, memes[i].key);
        }
        vm.stopBroadcast();
        _save(c, st);
    }

    /// @notice The operator becomes the house guardian and is offered the breaker's unlocker role (it accepts in
    ///         `acceptUnlocker`); the PrincipalLock's claim wallet follows CLAIM_WALLET.
    function roles() external {
        Cfg memory c = _cfg();
        _requireChain(c);
        St memory st = _load(c);
        require(_has(st.principalLock), "run bankroll first");
        FlipperHouse house = FlipperHouse(payable(st.house));
        vm.startBroadcast(c.owner);
        if (house.guardian() != c.operator) house.setGuardian(c.operator);
        if (house.unlocker() != c.operator && house.pendingUnlocker() != c.operator) house.transferUnlocker(c.operator);
        PrincipalLock lock = PrincipalLock(st.principalLock);
        if (lock.devAddress() != c.claim) lock.setDevAddress(c.claim);
        vm.stopBroadcast();
        _save(c, st);
    }

    /// @notice Signed by the OPERATOR: accept the drawdown breaker's unlocker role.
    function acceptUnlocker() external {
        Cfg memory c = _cfg();
        _requireChain(c);
        St memory st = _load(c);
        FlipperHouse house = FlipperHouse(payable(st.house));
        if (house.unlocker() == c.operator) return;
        require(house.pendingUnlocker() == c.operator, "run roles first (unlocker not offered to the operator)");
        vm.startBroadcast(c.operator);
        house.acceptUnlocker();
        vm.stopBroadcast();
    }

    /// @notice Read-only: assert the finished deployment (roles, ownership, settings, the pool, the lock). Every line
    ///         prints; any failure reverts with its reason.
    function check() external view {
        Cfg memory c = _cfg();
        St memory st = _load(c);
        FlipperHouse house = FlipperHouse(payable(st.house));
        RevenueRouter router = RevenueRouter(payable(st.router));
        FlipperRewardToken token = FlipperRewardToken(st.flipper);
        PrincipalLock lock = PrincipalLock(st.principalLock);
        LiquidityKeeper keeper = LiquidityKeeper(payable(st.keeper));

        // every contract exists
        address[17] memory all = [
            st.router, st.keeper, st.flipper, st.randomness, st.house, st.lens, st.v4, st.vault, st.policy,
            st.converter, st.partners, st.principalLock, st.v3Bridge, st.v3, st.wethWrapper, st.ponsVerifier,
            st.stockVerifier
        ];
        for (uint256 i; i < all.length; ++i) {
            require(all[i].code.length != 0, "a recorded contract has no code");
        }

        // owners: the Ledger everywhere (Ownable2Step pending transfers would show as a different owner)
        address[10] memory owned = [
            st.router, st.randomness, st.house, st.v4, st.vault, st.policy, st.converter, st.partners, st.v3, st.principalLock
        ];
        for (uint256 i; i < owned.length; ++i) {
            require(IOwnableM(owned[i]).owner() == c.owner, "an Ownable contract isn't owned by OWNER_ADDRESS");
        }
        // upgrade keys: every proxy's ProxyAdmin is owned by the Ledger
        address[8] memory proxies = [st.router, st.randomness, st.house, st.lens, st.v4, st.vault, st.partners, st.v3];
        for (uint256 i; i < proxies.length; ++i) {
            address admin = address(uint160(uint256(vm.load(proxies[i], _ADMIN_SLOT))));
            require(admin.code.length != 0 && IOwnableM(admin).owner() == c.owner, "a ProxyAdmin isn't owned by OWNER_ADDRESS");
        }
        console2.log("owners + ProxyAdmins: OWNER_ADDRESS", c.owner);

        // operator roles
        require(house.guardian() == c.operator, "guardian != OPERATOR_ADDRESS");
        bool unlockerDone = house.unlocker() == c.operator;
        require(unlockerDone || house.pendingUnlocker() == c.operator, "unlocker neither the operator nor offered to it");
        if (!unlockerDone) console2.log("WARNING unlocker still the owner: run acceptUnlocker from the operator");
        console2.log("guardian / unlocker: operator", c.operator);

        // the token: fixed supply, sealed, exemptions, nothing owned
        require(token.totalSupply() == SUPPLY, "supply");
        require(token.sealer() == address(0), "token not sealed");
        require(address(token.vault()) == st.vault, "token vault");
        require(token.rewardExempt(st.house) && token.rewardExempt(st.router) && token.rewardExempt(st.converter), "exempt");
        require(token.rewardExempt(st.keeper) && token.rewardExempt(st.vault), "exempt keeper/vault");
        require(router.rewards() == st.flipper && router.treasuryShareBps() == 0, "router rewards");

        // the pool position: in the keeper, for good; the router never held it
        require(keeper.launched() && router.liquidityKeeper() == st.keeper, "keeper");
        uint256 tokenId = keeper.tokenId();
        address posOwner = IV4PositionManager(RH.POSITION_MANAGER).ownerOf(tokenId);
        require(posOwner == (c.uncx ? RH.UNCX_V4_LOCKER : st.keeper), "position NFT owner");
        (, uint256 inPool) = keeper.positionAmounts();
        console2.log("pool position FLIPPER", inPool);

        // the team stake
        require(lock.principal() == st.bought && lock.principal() != 0, "principal != opening buy");
        require(lock.devAddress() == c.claim, "claim wallet");
        require(lock.value() + 1 >= lock.principal(), "lock value below principal");
        require(token.balanceOf(c.owner) == 0, "owner still holds FLIPPER (unstaked opening buy?)");
        console2.log("principal (staked)   ", lock.principal());

        // the house
        require(house.vault() == st.vault && house.revenueRouter() == st.router, "house wiring");
        require(house.converter() == st.converter && house.partnerRegistry() == st.partners, "house wiring 2");
        require(house.isRouteAdapter(st.v4) && house.isRouteAdapter(st.v3), "route adapters");
        require(DiceEntropyAdapter(st.randomness).consumer() == st.house, "randomness bound");
        require(DiceEntropyAdapter(st.randomness).arbitrum() == !c.rehearsal, "ArbSys flag");
        require(!house.paused() && !house.locked(), "house paused or locked");
        require(house.treasury() >= lock.principal() - 1, "treasury below the stake");
        require(house.lockMinTreasury() != 0, "lockMinTreasury");
        FlipperHouseBase.EdgeSchedule memory es = RH.edgeSchedule();
        (uint96 f, uint96 to,,,,) = house.edgeSchedule();
        require(f == es.fromEth && to == es.toEth, "edge schedule");
        require(house.params().kellyBps == RH.KELLY_BPS && house.kellyMinBps() == RH.KELLY_MIN_BPS, "kelly");
        require(house.maxOpenPerPlayer() == RH.MAX_OPEN_PER_PLAYER && house.minLiability() == RH.MIN_LIABILITY, "limits");
        TreasuryVault vault = TreasuryVault(st.vault);
        require(
            vault.performanceFeeBps() == FlipperDeploy.VAULT_FEE_BPS && vault.lockDuration() == FlipperDeploy.VAULT_LOCK
                && vault.withdrawCooldown() == FlipperDeploy.VAULT_COOLDOWN,
            "vault params"
        );
        require(DutchAuctionConverter(payable(st.converter)).lastPrice(address(0)) != 0, "converter seed price");
        require(_listed(st, RH.WETH), "WETH not listed");
        RH.Listing[] memory w = RH.launchWhitelist();
        for (uint256 i; i < w.length; ++i) {
            if (!_listed(st, w[i].token)) console2.log("NOTE whitelist token not listed (probe failed)", w[i].token);
        }
        w = RH.launchStocks();
        for (uint256 i; i < w.length; ++i) {
            if (!_listed(st, w[i].token)) console2.log("NOTE stock token not listed (probe failed)", w[i].token);
        }
        w = RH.launchMemes();
        for (uint256 i; i < w.length; ++i) {
            if (!_listed(st, w[i].token)) console2.log("NOTE memecoin not listed (didn't qualify)", w[i].token);
        }
        console2.log("listed tokens        ", house.listedTokensLength());
        console2.log("treasury             ", house.treasury());
        console2.log("check: OK");
    }

    /// @notice Write the manifest the web app and the API read (the dev manifest's shape).
    function manifest() external {
        Cfg memory c = _cfg();
        St memory st = _load(c);
        require(_launched(st) && _has(st.principalLock), "incomplete deployment");
        string memory o = "contracts";
        vm.serializeAddress(o, "listingPolicy", st.policy);
        vm.serializeAddress(o, "hookitVerifier", address(0));
        vm.serializeAddress(o, "ponsVerifier", st.ponsVerifier);
        vm.serializeAddress(o, "stockVerifier", st.stockVerifier);
        vm.serializeAddress(o, "house", st.house);
        vm.serializeAddress(o, "lens", st.lens);
        vm.serializeAddress(o, "holderRewards", st.flipper);
        vm.serializeAddress(o, "router", st.router);
        vm.serializeAddress(o, "auctionConverter", st.converter);
        vm.serializeAddress(o, "partnerRegistry", st.partners);
        vm.serializeAddress(o, "principalLock", st.principalLock);
        vm.serializeAddress(o, "liquidityKeeper", st.keeper);
        vm.serializeAddress(o, "positionManager", RH.POSITION_MANAGER);
        vm.serializeAddress(o, "uncxLocker", c.uncx ? RH.UNCX_V4_LOCKER : address(0));
        vm.serializeAddress(o, "houseModule", FlipperHouse(payable(st.house)).module());
        vm.serializeAddress(o, "randomness", st.randomness);
        vm.serializeAddress(o, "hookitAdapter", address(0));
        vm.serializeAddress(o, "v4Adapter", st.v4);
        vm.serializeAddress(o, "v3Adapter", st.v3);
        vm.serializeAddress(o, "v3Bridge", st.v3Bridge);
        vm.serializeAddress(o, "wethWrapperHook", st.wethWrapper);
        vm.serializeAddress(o, "treasuryVault", st.vault);
        vm.serializeAddress(o, "flipper", st.flipper);
        vm.serializeAddress(o, "rewardToken", RH.PONS);
        vm.serializeAddress(o, "poolManager", RH.POOL_MANAGER);
        vm.serializeAddress(o, "v4Quoter", RH.V4_QUOTER);
        vm.serializeAddress(o, "ethUsdFeed", RH.CHAINLINK_ETH_USD);
        vm.serializeAddress(o, "entropy", RH.DICE_ENTROPY);
        vm.serializeAddress(o, "vrfWrapper", address(0));
        vm.serializeAddress(o, "entropyProvider", DiceEntropyAdapter(st.randomness).provider());
        vm.serializeAddress(o, "launchpad", RH.POOL_MANAGER);
        vm.serializeAddress(o, "feeSource", address(0));
        vm.serializeAddress(o, "ponsCurve", address(0));
        vm.serializeAddress(o, "devSwapRouter", address(0));
        vm.serializeAddress(o, "v3SwapRouter", RH.V3_SWAP_ROUTER02);
        vm.serializeAddress(o, "v3QuoterV2", RH.V3_QUOTER_V2);
        vm.serializeAddress(o, "weth", RH.WETH);
        vm.serializeAddress(o, "hookitFactory", address(0));
        vm.serializeAddress(o, "hookitFeeEscrow", address(0));
        string memory contracts = vm.serializeAddress(o, "multicall3", 0xcA11bde05977b3631167028862bE2a173976CA11);

        string memory pk = "flipperKey";
        PoolKey memory k = _flipperKey(st);
        vm.serializeAddress(pk, "currency0", Currency.unwrap(k.currency0));
        vm.serializeAddress(pk, "currency1", Currency.unwrap(k.currency1));
        vm.serializeUint(pk, "fee", k.fee);
        vm.serializeInt(pk, "tickSpacing", k.tickSpacing);
        string memory fkJson = vm.serializeAddress(pk, "hooks", address(k.hooks));
        vm.serializeString("pools", "flipper", fkJson);
        string memory pools = vm.serializeUint("pools", "rewardV3Fee", 10_000);

        string memory a = "accounts";
        vm.serializeAddress(a, "deployer", c.owner);
        vm.serializeAddress(a, "owner", c.owner);
        vm.serializeAddress(a, "operator", c.operator);
        vm.serializeAddress(a, "claimWallet", c.claim);
        vm.serializeAddress(a, "upkeep", c.upkeep);
        string memory accounts = vm.serializeAddress(a, "keeper", c.upkeep);

        uint256 n = FlipperHouse(payable(st.house)).listedTokensLength();
        address[] memory listed = new address[](n);
        for (uint256 i; i < n; ++i) {
            listed[i] = FlipperHouse(payable(st.house)).listedTokens(i);
        }

        string memory r = "root";
        vm.serializeUint(r, "chainId", block.chainid);
        vm.serializeUint(r, "liveChainId", RH.CHAIN_ID);
        vm.serializeString(r, "chain", "robinhood");
        vm.serializeString(r, "chainName", "Robinhood Chain");
        vm.serializeString(r, "explorer", "https://robinhoodchain.blockscout.com");
        vm.serializeString(r, "launchpadKind", "v4");
        vm.serializeUint(r, "deployBlock", st.deployBlock);
        vm.serializeUint(r, "poolManagerStartBlock", 9_505);
        vm.serializeString(r, "entropyMode", "dice");
        vm.serializeString(r, "randomnessMode", "dice");
        vm.serializeAddress(r, "listedTokens", listed);
        vm.serializeString(r, "contracts", contracts);
        vm.serializeString(r, "pools", pools);
        string memory json = vm.serializeString(r, "accounts", accounts);
        vm.writeJson(json, c.manifestFile);
        console2.log("manifest written", c.manifestFile);
    }

    function _fundTargets(Cfg memory c) internal view returns (address[3] memory who, uint256[3] memory target) {
        who = [c.operator, c.upkeep, c.claim];
        target = [
            vm.envOr("OPERATOR_FUND_WEI", uint256(0.005 ether)),
            vm.envOr("UPKEEP_FUND_WEI", uint256(0.025 ether)),
            vm.envOr("CLAIM_FUND_WEI", uint256(0.01 ether))
        ];
    }

    /// @dev what the fund step still has to send
    function _fundingNeeded(Cfg memory c) internal view returns (uint256 total) {
        (address[3] memory who, uint256[3] memory target) = _fundTargets(c);
        for (uint256 i; i < 3; ++i) {
            if (who[i].balance < target[i]) total += target[i] - who[i].balance;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Launch maths
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @return px ETH/USD (8 decimals), sqrtP the start price, want the opening buy in $FLIPPER, buyEth its cost with
    ///         the pool fee, lockFee UNCX's flat fee when locking there without a free-lock whitelist
    function _launchTerms(Cfg memory c)
        internal
        view
        returns (uint256 px, uint160 sqrtP, uint256 want, uint256 buyEth, uint256 lockFee)
    {
        (, int256 p,, uint256 updatedAt,) = IChainlinkFeedM(RH.CHAINLINK_ETH_USD).latestRoundData();
        require(p > 0 && updatedAt != 0, "ETH/USD feed");
        if (!c.rehearsal) require(block.timestamp - updatedAt < 6 hours, "ETH/USD feed stale");
        px = uint256(p);
        require(px >= 500e8 && px <= 50_000e8, "ETH/USD out of sanity bounds");
        uint256 fdvWei = c.startMcapUsd * 1e8 * 1e18 / px;
        sqrtP = uint160(Math.sqrt(FullMath.mulDiv(SUPPLY, 1 << 96, fdvWei) << 96));
        want = SUPPLY * c.buyBps / 10_000;
        uint256 lpFeeBps;
        if (c.uncx) {
            // a keeper deployed by now may be whitelisted for free locks; before that, assume the paid terms
            address k = _peekKeeper(c);
            bool free = k != address(0) && IUNCXV4Locker(RH.UNCX_V4_LOCKER).whitelistedForFreeLock(k);
            if (!free) {
                lockFee = IUNCXV4Locker(RH.UNCX_V4_LOCKER).flatFee();
                lpFeeBps = IUNCXV4Locker(RH.UNCX_V4_LOCKER).lpFee();
            }
        }
        buyEth = lpFeeBps == 0
            ? FlipperDeploy.openingBuyEth(SUPPLY, sqrtP, TICK_SPACING, POOL_FEE, want)
            : _openingBuyEthAfterLpFee(sqrtP, want, lpFeeBps);
    }

    /// @dev Deploy._openingBuyEth: after UNCX removed `lpFeeBps` of the position's liquidity at lock time (it keeps
    ///      L − floor(L·fee / 10,000); one wei less here, so the buy never comes up short of `want`)
    function _openingBuyEthAfterLpFee(uint160 sqrtP, uint256 want, uint256 lpFeeBps) internal pure returns (uint256) {
        int24 t0 = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 upper = (t0 / TICK_SPACING) * TICK_SPACING;
        if (upper > t0) upper -= TICK_SPACING;
        uint160 su = TickMath.getSqrtPriceAtTick(upper);
        uint160 sl = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(TICK_SPACING));
        uint256 liq = FullMath.mulDiv(SUPPLY, 1 << 96, su - sl);
        liq -= liq * lpFeeBps / 10_000 + 1;
        (, uint256 amountIn,, uint256 feeAmount) = SwapMath.computeSwapStep(su, sl, uint128(liq), int256(want), POOL_FEE);
        return amountIn + feeAmount;
    }

    function _peekKeeper(Cfg memory c) internal view returns (address) {
        St memory st = _load(c);
        if (!_has(st.router)) return address(0);
        return RevenueRouter(payable(st.router)).liquidityKeeper();
    }

    function _flipperPerEth(St memory st) internal view returns (uint256) {
        (uint160 sp,,,) = StateLibrary.getSlot0(IPoolManager(RH.POOL_MANAGER), PoolIdLibrary.toId(_flipperKey(st)));
        require(sp != 0, "pool not initialized");
        return FullMath.mulDiv(FullMath.mulDiv(1e18, sp, 1 << 96), sp, 1 << 96);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    bytes32 internal constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function _cfg() internal view returns (Cfg memory c) {
        c.owner = vm.envAddress("OWNER_ADDRESS");
        c.operator = vm.envAddress("OPERATOR_ADDRESS");
        c.claim = vm.envAddress("CLAIM_WALLET");
        c.upkeep = vm.envAddress("UPKEEP_ADDRESS");
        c.startMcapUsd = vm.envOr("V4_START_MCAP_USD", uint256(5000));
        c.buyBps = vm.envOr("OPENING_BUY_SUPPLY_BPS", uint256(1250));
        c.maxBuyEth = vm.envOr("MAX_OPENING_BUY_ETH", uint256(0.5 ether));
        c.uncx = vm.envOr("UNCX_LOCK", uint256(0)) == 1;
        c.rehearsal = vm.envOr("REHEARSAL", uint256(0)) == 1;
        c.stateFile = vm.envOr("STATE_FILE", string("deployments/robinhood.state.json"));
        c.manifestFile = vm.envOr("MANIFEST_FILE", string("deployments/robinhood.json"));
        require(c.owner != address(0) && c.operator != address(0) && c.claim != address(0) && c.upkeep != address(0), "an address is zero");
        require(c.owner != c.operator && c.owner != c.upkeep && c.operator != c.upkeep, "owner, operator and upkeep must differ");
        require(c.buyBps != 0 && c.buyBps <= 5000, "OPENING_BUY_SUPPLY_BPS");
        require(c.startMcapUsd >= 1000 && c.startMcapUsd <= 1_000_000, "V4_START_MCAP_USD");
    }

    function _requireChain(Cfg memory c) internal view {
        if (c.rehearsal) {
            require(block.chainid == 31337 || block.chainid == RH.CHAIN_ID, "rehearsal: an anvil fork of Robinhood Chain");
        } else {
            require(block.chainid == RH.CHAIN_ID, "not Robinhood Chain (4663)");
        }
        require(RH.POOL_MANAGER.code.length != 0, "no Uniswap v4 here");
    }

    function _fc(Cfg memory c) internal pure returns (FlipperDeploy.Config memory fc) {
        fc.poolManager = IPoolManager(RH.POOL_MANAGER);
        fc.deployer = c.owner;
        fc.owner = c.owner;
        fc.proxyAdminOwner = c.owner;
        fc.params = RH.defaultParams();
    }

    function _sys(St memory st) internal pure returns (FlipperDeploy.System memory s) {
        s.router = RevenueRouter(payable(st.router));
        s.house = FlipperHouse(payable(st.house));
        s.converter = DutchAuctionConverter(payable(st.converter));
        s.vault = TreasuryVault(st.vault);
    }

    function _has(address a) internal view returns (bool) {
        return a != address(0) && a.code.length != 0;
    }

    function _launched(St memory st) internal view returns (bool) {
        return _has(st.router) && address(RevenueRouter(payable(st.router)).flipper()) == st.flipper && _has(st.flipper);
    }

    function _flipperKey(St memory st) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(st.flipper), POOL_FEE, TICK_SPACING, IHooks(address(0)));
    }

    function _usdgPool() internal pure returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(address(0)), Currency.wrap(RH.USDG), RH.USDG_POOL_FEE, RH.USDG_POOL_TICK_SPACING, IHooks(address(0))
        );
    }

    function _id(PoolKey memory k) internal pure returns (bytes32) {
        return keccak256(abi.encode(k));
    }

    function _attached(ListingPolicy p, address v) internal view returns (bool) {
        ILaunchpadVerifier[] memory vs = p.verifiers();
        for (uint256 i; i < vs.length; ++i) {
            if (address(vs[i]) == v) return true;
        }
        return false;
    }

    function _listed(St memory st, address token) internal view returns (bool enabled) {
        (enabled,,,) = FlipperHouse(payable(st.house)).tokenConfig(token);
    }

    function _tryList(St memory st, RH.Listing memory l) internal returns (bool) {
        if (l.v3Pool != address(0)) {
            try V3RouteAdapter(st.v3).registerAndList(l.token, l.v3Pool) {
                return true;
            } catch {
                return false;
            }
        }
        try V4RouteAdapter(st.v4).registerAndList(l.token, l.key) {
            return true;
        } catch {
            return false;
        }
    }

    // ── state file ────────────────────────────────────────────────────────────────────────────────────────

    function _load(Cfg memory c) internal view returns (St memory st) {
        if (!vm.exists(c.stateFile)) return st;
        string memory j = vm.readFile(c.stateFile);
        require(vm.parseJsonUint(j, ".chainId") == block.chainid, "state file is for another chain");
        require(vm.parseJsonAddress(j, ".owner") == c.owner, "state file is for another owner");
        st.deployBlock = vm.parseJsonUint(j, ".deployBlock");
        st.bought = vm.parseJsonUint(j, ".bought");
        st.router = _a(j, ".router");
        st.keeper = _a(j, ".keeper");
        st.flipper = _a(j, ".flipper");
        st.randomness = _a(j, ".randomness");
        st.house = _a(j, ".house");
        st.lens = _a(j, ".lens");
        st.v4 = _a(j, ".v4");
        st.vault = _a(j, ".vault");
        st.policy = _a(j, ".policy");
        st.converter = _a(j, ".converter");
        st.partners = _a(j, ".partners");
        st.principalLock = _a(j, ".principalLock");
        st.v3Bridge = _a(j, ".v3Bridge");
        st.v3 = _a(j, ".v3");
        st.wethWrapper = _a(j, ".wethWrapper");
        st.ponsVerifier = _a(j, ".ponsVerifier");
        st.stockVerifier = _a(j, ".stockVerifier");
    }

    function _a(string memory j, string memory key) internal view returns (address) {
        return vm.keyExistsJson(j, key) ? vm.parseJsonAddress(j, key) : address(0);
    }

    function _save(Cfg memory c, St memory st) internal {
        string memory k = "state";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "owner", c.owner);
        vm.serializeUint(k, "deployBlock", st.deployBlock);
        vm.serializeUint(k, "bought", st.bought);
        vm.serializeAddress(k, "router", st.router);
        vm.serializeAddress(k, "keeper", st.keeper);
        vm.serializeAddress(k, "flipper", st.flipper);
        vm.serializeAddress(k, "randomness", st.randomness);
        vm.serializeAddress(k, "house", st.house);
        vm.serializeAddress(k, "lens", st.lens);
        vm.serializeAddress(k, "v4", st.v4);
        vm.serializeAddress(k, "vault", st.vault);
        vm.serializeAddress(k, "policy", st.policy);
        vm.serializeAddress(k, "converter", st.converter);
        vm.serializeAddress(k, "partners", st.partners);
        vm.serializeAddress(k, "principalLock", st.principalLock);
        vm.serializeAddress(k, "v3Bridge", st.v3Bridge);
        vm.serializeAddress(k, "v3", st.v3);
        vm.serializeAddress(k, "wethWrapper", st.wethWrapper);
        vm.serializeAddress(k, "ponsVerifier", st.ponsVerifier);
        string memory json = vm.serializeAddress(k, "stockVerifier", st.stockVerifier);
        vm.writeJson(json, c.stateFile);
    }
}
