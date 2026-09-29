// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SwapMath} from "v4-core/libraries/SwapMath.sol";
import {PrincipalLock, IStakingVault} from "../../src/PrincipalLock.sol";
import {LiquidityKeeper, IV4PositionManager, IUNCXV4Locker} from "../../src/LiquidityKeeper.sol";

import {FlipperHouse} from "../../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../../src/house/FlipperHouseBase.sol";
import {HouseModule} from "../../src/house/HouseModule.sol";
import {PartnerRegistry} from "../../src/PartnerRegistry.sol";
import {FlipperRewardToken, IRewardVault} from "../../src/FlipperRewardToken.sol";
import {RevenueRouter} from "../../src/RevenueRouter.sol";
import {FlipperLens} from "../../src/lens/FlipperLens.sol";
import {TreasuryVault, IVaultHouse} from "../../src/TreasuryVault.sol";
import {PythEntropyAdapter} from "../../src/randomness/PythEntropyAdapter.sol";
import {ChainlinkVRFAdapter} from "../../src/randomness/ChainlinkVRFAdapter.sol";
import {IRandomnessAdapter} from "../../src/interfaces/IRandomness.sol";
import {IVRFV2PlusWrapper} from "../../src/interfaces/IVRFV2PlusWrapper.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {HookitRouteAdapter} from "../../src/adapters/HookitRouteAdapter.sol";
import {V4RouteAdapter} from "../../src/adapters/V4RouteAdapter.sol";
import {V3BridgeHook} from "../../src/adapters/V3BridgeHook.sol";
import {WethWrapperHook} from "../../src/adapters/WethWrapperHook.sol";
import {V3RouteAdapter, IV4AdapterDepth} from "../../src/adapters/V3RouteAdapter.sol";
import {IUniswapV3Factory} from "../../src/interfaces/IUniswapV3.sol";
import {ILaunchpadVerifier} from "../../src/interfaces/ILaunchpadVerifier.sol";
import {ListingPolicy} from "../../src/ListingPolicy.sol";
import {DutchAuctionConverter} from "../../src/DutchAuctionConverter.sol";
import {IPonsV2Factory} from "../../src/interfaces/IPons.sol";
import {PonsVerifier} from "../../src/verifiers/PonsVerifier.sol";
import {CodehashVerifier} from "../../src/verifiers/CodehashVerifier.sol";
import {HookitVerifier} from "../../src/verifiers/HookitVerifier.sol";
import {RobinhoodAddresses} from "./RobinhoodAddresses.sol";
import {InkAddresses} from "./InkAddresses.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IEntropyV2} from "../../src/interfaces/IEntropyV2.sol";
import {IHookitLaunchFactory, IHookitMasterHook} from "../../src/interfaces/IHookit.sol";

/// @notice Deploys the protocol behind TransparentUpgradeableProxies. Shared by tests and scripts so the tested
///         topology is exactly the deployed one.
///
///   Order: RevenueRouter first (it must be the one to call hookit `launch()` so it becomes $FLIPPER's permanent
///   creator), then a randomness adapter (Pyth Entropy or Chainlink VRF), then the rest once $FLIPPER exists, the
///   TreasuryVault last (the house's one-time `setVault` makes it the only account that can withdraw bankroll).
///
///   Every proxy's ProxyAdmin is owned by `proxyAdminOwner` (a TimelockController or multisig in production).
///   Contracts are initialized with `deployer` as owner so the deployment can wire them; `handOver` then offers
///   ownership to `owner` (Ownable2Step: the new owner must `acceptOwnership`).
interface IBindable {
    function bind(address consumer) external;
}

library FlipperDeploy {
    // TreasuryVault defaults (Deploy.s.sol overrides them through `setParams` before the hand-over)
    uint16 internal constant VAULT_FEE_BPS = 8000; // 80% of depositors' gains above the high-water mark → POL
    uint32 internal constant VAULT_LOCK = 7 days;
    /// @dev gas for a script's vault calls: forge sizes script transactions from the simulation's gas used, which
    ///      doesn't show the vault's reward-sync gas floors (300k left at two points)
    uint256 internal constant VAULT_CALL_GAS = 1_500_000;
    uint32 internal constant VAULT_COOLDOWN = 2 days;
    /// Dutch-auction converter: price halves every 30 minutes from 4× the best reference (inventory lots: their
    /// flip-time sell quote; ETH lots: the last clearing price); with no reference it starts at 2^128 $FLIPPER-wei
    /// per 1e18 units and reaches any realistic price within ~2 days
    uint256 internal constant AUCTION_HALF_LIFE = 30 minutes;
    uint256 internal constant AUCTION_START_MULTIPLE = 4;
    uint256 internal constant AUCTION_DEFAULT_START = type(uint128).max;
    /// harvest bounty: 0.1% of what a harvest brings in, at most 0.005 ETH / 1e-6 of the $FLIPPER supply per call
    uint16 internal constant HARVEST_BOUNTY_BPS = 10;
    uint96 internal constant HARVEST_BOUNTY_CAP_ETH = 0.005 ether;
    uint256 internal constant HARVEST_BOUNTY_CAP_SUPPLY_DIV = 1_000_000;
    /// partner tiers: share of an attributed flip's expected house profit (capped so the house keeps its floor)
    uint16 internal constant PARTNER_TIER1_CUT_BPS = 1000;
    uint16 internal constant PARTNER_TIER2_CUT_BPS = 2000;
    uint16 internal constant PARTNER_TIER3_CUT_BPS = 3000;
    /// ETH revenue waits for at least this much before it is auctioned
    uint128 internal constant MIN_LOT_ETH = 0.001 ether;

    /// permission bits a V3BridgeHook address must carry (v4 reads hook permissions from the address)
    uint160 internal constant V3_BRIDGE_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
    /// deterministic-deployment proxy that forge scripts route `new X{salt: …}` through
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    struct Config {
        IPoolManager poolManager;
        IEntropyV2 entropy; // Pyth Entropy (used by deployPythAdapter)
        address entropyProvider; // 0 = Entropy's default provider
        address deployer; // msg.sender of the deployment (the broadcaster in scripts)
        address owner; // final owner of every contract
        address proxyAdminOwner; // owner of every ProxyAdmin
        FlipperHouseBase.Params params;
    }

    struct System {
        RevenueRouter router;
        FlipperHouse house;
        IRandomnessAdapter randomness; // PythEntropyAdapter or ChainlinkVRFAdapter
        FlipperLens lens;
        HookitRouteAdapter hookit;
        V4RouteAdapter v4; // any Uniswap v4 pool (hookless + allowlisted hooks)
        TreasuryVault vault; // bankroll staking (sFLIPPER); the seeded bankroll bootstraps as protocol-owned
        V3RouteAdapter v3; // Uniswap v3 pools through the bridge hook (0 where not deployed)
        V3BridgeHook v3Bridge;
        ListingPolicy policy; // which tokens list permissionlessly (shared by every route adapter)
        DutchAuctionConverter converter; // sells swept inventory and ETH revenue for $FLIPPER
        PartnerRegistry partners; // partner codes, payouts, tiers (ERC-8021 attribution)
        WethWrapperHook wethWrapper; // 1:1 WETH/ETH pool: WETH's route to native ETH (0 where not deployed)
    }

    function deployRouter(Config memory c) internal returns (RevenueRouter) {
        return RevenueRouter(
            payable(
                proxy(
                    address(new RevenueRouter(c.poolManager)),
                    c.proxyAdminOwner,
                    abi.encodeCall(RevenueRouter.initialize, (c.deployer))
                )
            )
        );
    }

    /// @notice Randomness from Pyth Entropy v2 (production on Ink).
    function deployPythAdapter(Config memory c) internal returns (IRandomnessAdapter) {
        return IRandomnessAdapter(
            proxy(
                address(new PythEntropyAdapter()),
                c.proxyAdminOwner,
                abi.encodeCall(PythEntropyAdapter.initialize, (c.entropy, c.entropyProvider, c.deployer))
            )
        );
    }

    /// @notice Randomness from Chainlink VRF v2.5 direct funding (the real VRFV2PlusWrapper, or the local
    ///         MockVRFWrapper in dev).
    function deployChainlinkAdapter(Config memory c, IVRFV2PlusWrapper wrapper, uint16 confirmations)
        internal
        returns (IRandomnessAdapter)
    {
        return IRandomnessAdapter(
            proxy(
                address(new ChainlinkVRFAdapter()),
                c.proxyAdminOwner,
                abi.encodeCall(ChainlinkVRFAdapter.initialize, (wrapper, confirmations, c.deployer))
            )
        );
    }

    /// @param flipper the $FLIPPER token (launched through `router.launchFlipper` in production)
    /// @param randomness adapter from `deployPythAdapter` / `deployChainlinkAdapter`, bound to the house here
    function deployCore(Config memory c, RevenueRouter router, IERC20 flipper, IRandomnessAdapter randomness)
        internal
        returns (System memory s)
    {
        return deployCoreWith(c, router, flipper, randomness, true);
    }

    /// @param withHookit deploy the hookit.fun route adapter (Ink only; Robinhood deploys none)
    function deployCoreWith(
        Config memory c,
        RevenueRouter router,
        IERC20 flipper,
        IRandomnessAdapter randomness,
        bool withHookit
    ) internal returns (System memory s) {
        s.router = router;
        s.randomness = randomness;
        s.house = FlipperHouse(
            payable(
                proxy(
                    address(
                        new FlipperHouse(
                            c.poolManager,
                            flipper,
                            s.randomness,
                            address(new HouseModule(c.poolManager, flipper, s.randomness))
                        )
                    ),
                    c.proxyAdminOwner,
                    abi.encodeCall(FlipperHouse.initialize, (c.deployer, c.params))
                )
            )
        );
        IBindable(address(randomness)).bind(address(s.house));

        s.lens = FlipperLens(proxy(address(new FlipperLens()), c.proxyAdminOwner, ""));
        if (withHookit) {
            s.hookit = HookitRouteAdapter(
                proxy(
                    address(new HookitRouteAdapter()),
                    c.proxyAdminOwner,
                    abi.encodeCall(HookitRouteAdapter.initialize, (c.deployer))
                )
            );
        }

        s.v4 = V4RouteAdapter(
            proxy(
                address(new V4RouteAdapter()),
                c.proxyAdminOwner,
                abi.encodeCall(V4RouteAdapter.initialize, (c.poolManager, address(s.house), c.deployer))
            )
        );

        s.vault = TreasuryVault(
            proxy(
                address(new TreasuryVault()),
                c.proxyAdminOwner,
                abi.encodeCall(
                    TreasuryVault.initialize,
                    (IVaultHouse(address(s.house)), flipper, c.deployer, VAULT_FEE_BPS, VAULT_LOCK, VAULT_COOLDOWN)
                )
            )
        );
        s.house.setVault(address(s.vault));

        s.house.setRevenueRouter(address(router));
        if (withHookit) s.house.setRouteAdapter(address(s.hookit), true);
        s.house.setRouteAdapter(address(s.v4), true);
        s.policy = new ListingPolicy(c.deployer);
        s.v4.setListingPolicy(s.policy);
        if (withHookit) s.hookit.setListingPolicy(s.policy, address(s.house));
        // holders' $FLIPPER waits in the router (`rewardsFlipperPending`) until a distributor is set
        router.configure(flipper, address(s.house), address(0));
        deployConverter(c, s, flipper);
        deployPartners(c, s);

    }

    /// @notice The reward-bearing $FLIPPER, its whole supply minted to the router, which then launches it
    ///         (`launchFlipperV4Token`). The deployer is its one-time sealer.
    function deployRewardToken(Config memory c, RevenueRouter router, string memory name, string memory symbol, uint256 supply)
        internal
        returns (FlipperRewardToken)
    {
        return new FlipperRewardToken(name, symbol, supply, address(router), address(c.poolManager));
    }

    /// @notice Fix the reward token's exemptions for good (the house, router, converter and LP keeper; the PoolManager,
    ///         the token itself and the dead address are exempt from construction), name the staking vault (virtual
    ///         balance), and wire the router's holders' share to `distribute`. Must run before any distribution.
    function sealRewardToken(System memory s, FlipperRewardToken token) internal {
        address lpKeeper = s.router.liquidityKeeper(); // only ever passes fees through, but never a holder
        address[] memory ex = new address[](lpKeeper != address(0) ? 4 : 3);
        ex[0] = address(s.house);
        ex[1] = address(s.router);
        ex[2] = address(s.converter);
        if (lpKeeper != address(0)) ex[3] = lpKeeper;
        token.seal(ex, IRewardVault(address(s.vault)), address(s.house));
        s.router.setRewards(address(token));
    }

    /// @notice Partner revenue share: the registry (approval-gated codes) with the default tier cuts, wired to the
    ///         house. Tier cuts are shares of each attributed flip's expected house profit.
    function deployPartners(Config memory c, System memory s) internal {
        s.partners = PartnerRegistry(
            proxy(address(new PartnerRegistry()), c.proxyAdminOwner, abi.encodeCall(PartnerRegistry.initialize, (c.deployer)))
        );
        s.partners.setTierCut(1, PARTNER_TIER1_CUT_BPS);
        s.partners.setTierCut(2, PARTNER_TIER2_CUT_BPS);
        s.partners.setTierCut(3, PARTNER_TIER3_CUT_BPS);
        s.house.setPartnerRegistry(address(s.partners));
    }

    /// @notice Deploy the Dutch-auction converter, let the house (inventory sweeps) and the router (ETH revenue) kick
    ///         lots, and point both at it with the default harvest bounty and minimum lot.
    function deployConverter(Config memory c, System memory s, IERC20 flipper) internal {
        s.converter = new DutchAuctionConverter(
            flipper, address(s.house), c.deployer, AUCTION_HALF_LIFE, AUCTION_START_MULTIPLE, AUCTION_DEFAULT_START
        );
        s.converter.setKicker(address(s.house), true);
        s.converter.setKicker(address(s.router), true);
        s.house.setConverter(address(s.converter));
        s.router.setUpkeepParams(
            address(s.converter),
            HARVEST_BOUNTY_BPS,
            HARVEST_BOUNTY_CAP_ETH,
            uint96(flipper.totalSupply() / HARVEST_BOUNTY_CAP_SUPPLY_DIV),
            MIN_LOT_ETH
        );
    }

    /// @notice Deploy the v3 bridge hook (at an address carrying its permission bits) and the V3RouteAdapter, and
    ///         allow the adapter on the house. The caller still sets the adapter's $FLIPPER pool and quotes.
    /// @param create2Deployer the account `new X{salt: …}` deploys from: CREATE2_DEPLOYER in broadcast scripts, the
    ///        calling contract in tests
    function deployV3(Config memory c, System memory s, address v3Factory, address weth, address create2Deployer)
        internal
    {
        bytes memory args = abi.encode(c.poolManager, IUniswapV3Factory(v3Factory), weth);
        bytes32 initHash = keccak256(abi.encodePacked(type(V3BridgeHook).creationCode, args));
        bytes32 salt = mineHookSalt(create2Deployer, initHash, V3_BRIDGE_FLAGS);
        s.v3Bridge = new V3BridgeHook{salt: salt}(c.poolManager, IUniswapV3Factory(v3Factory), weth);
        s.v3 = V3RouteAdapter(
            proxy(
                address(new V3RouteAdapter()),
                c.proxyAdminOwner,
                abi.encodeCall(V3RouteAdapter.initialize, (s.v3Bridge, address(s.house), c.deployer))
            )
        );
        s.v3.setV4Adapter(IV4AdapterDepth(address(s.v4)));
        s.v3.setListingPolicy(s.policy);
        s.house.setRouteAdapter(address(s.v3), true);
    }

    /// @notice Deploy the WETH wrapper hook (at an address carrying its permission bits), create its 1:1 ETH/WETH
    ///         pool, and pin the hook and whitelist that pool in the ListingPolicy, so anyone can register and list
    ///         WETH on the v4 adapter with the route [WETH/ETH wrapper, ETH/$FLIPPER].
    /// @notice ETH that buys exactly `tokensOut` of the self-launched token in the router's launch transaction: the
    ///         router seeds `poolSupply` single-sided from the tick at or below `sqrtPriceX96` down to the minimum
    ///         tick (`RevenueRouter._launchV4`), so the buy first crosses the empty gap to the position's top at no
    ///         cost, then takes `tokensOut` out of that one liquidity range. Fee included; exact up to the pool's
    ///         rounding (the router's minimum-out check enforces `tokensOut`).
    function openingBuyEth(uint256 poolSupply, uint160 sqrtPriceX96, int24 tickSpacing, uint24 fee, uint256 tokensOut)
        internal
        pure
        returns (uint256)
    {
        int24 t0 = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 upper = (t0 / tickSpacing) * tickSpacing;
        if (upper > t0) upper -= tickSpacing;
        uint160 su = TickMath.getSqrtPriceAtTick(upper);
        uint160 sl = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(tickSpacing));
        uint128 liquidity = uint128(FullMath.mulDiv(poolSupply, 1 << 96, su - sl));
        (, uint256 amountIn,, uint256 feeAmount) = SwapMath.computeSwapStep(su, sl, liquidity, int256(tokensOut), fee);
        return amountIn + feeAmount;
    }

    /// @notice The immutable, ownerless LiquidityKeeper that will hold the router's launch position, registered on the
    ///         router (before the launch). `locker` ≠ 0: it also locks the position NFT in UNCX, within the fee caps.
    function deployLiquidityKeeper(
        IPoolManager pm,
        RevenueRouter router,
        address positionManager,
        address locker,
        uint256 maxFlatFee,
        uint256 maxLpFeeBps,
        uint256 maxCollectFeeBps
    ) internal returns (LiquidityKeeper keeper) {
        keeper = new LiquidityKeeper(
            pm,
            IV4PositionManager(positionManager),
            address(router),
            IUNCXV4Locker(locker),
            maxFlatFee,
            maxLpFeeBps,
            maxCollectFeeBps
        );
        router.setLiquidityKeeper(address(keeper));
    }

    /// @notice The team's stake: a PrincipalLock paying `devAddress` (which `owner` may later change), staking
    ///         `amount` $FLIPPER (pulled from the caller) into the vault for good.
    function deployPrincipalLock(System memory s, IERC20 flipper, address devAddress, address owner, uint256 amount)
        internal
        returns (PrincipalLock lock)
    {
        lock = new PrincipalLock(IStakingVault(address(s.vault)), devAddress, owner);
        flipper.approve(address(lock), amount);
        lock.stake{gas: VAULT_CALL_GAS}(amount); // (a vault deposit: see VAULT_CALL_GAS)
    }

    /// @param create2Deployer as in `deployV3`
    function deployWethWrapper(Config memory c, System memory s, address weth, address create2Deployer)
        internal
        returns (PoolKey memory key)
    {
        bytes memory args = abi.encode(c.poolManager, weth);
        bytes32 initHash = keccak256(abi.encodePacked(type(WethWrapperHook).creationCode, args));
        bytes32 salt = mineHookSalt(create2Deployer, initHash, V3_BRIDGE_FLAGS);
        s.wethWrapper = new WethWrapperHook{salt: salt}(c.poolManager, weth);
        key = s.wethWrapper.initialize();
        s.policy.pinHook(address(s.wethWrapper), true);
        s.policy.setPoolWhitelisted(key, true);
    }

    /// @notice First CREATE2 salt whose address has exactly `flags` in its low 14 bits (v4 hook permissions).
    function mineHookSalt(address deployer, bytes32 initHash, uint160 flags) internal view returns (bytes32 salt) {
        uint160 mask = uint160((1 << 14) - 1);
        for (uint256 i; i < 2_000_000; ++i) {
            salt = bytes32(i);
            address a =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
            if (uint160(a) & mask == flags && a.code.length == 0) return salt;
        }
        revert("mineHookSalt: none found");
    }

    /// @notice Robinhood verifiers (not attached by default): [0] pons v2 launches (registry + token template + meme
    ///         hook pinned at its current code), [1] Robinhood Stock Tokens (BeaconProxy codehash, hookless pools).
    function deployRobinhoodVerifiers(address v3Bridge) internal returns (ILaunchpadVerifier[] memory vs) {
        vs = new ILaunchpadVerifier[](2);
        vs[0] = new PonsVerifier(
            IPonsV2Factory(RobinhoodAddresses.PONS_V2_FACTORY),
            RobinhoodAddresses.PONS_V2_MEME_HOOK,
            RobinhoodAddresses.PONS_V2_MEME_HOOK.codehash,
            RobinhoodAddresses.PONS_TOKEN_TEMPLATE,
            RobinhoodAddresses.PONS_TOKEN_SIZE,
            RobinhoodAddresses.PONS_TOKEN_IMMUTABLES
        );
        vs[1] = new CodehashVerifier(RobinhoodAddresses.STOCK_TOKEN_CODEHASH, "robinhood-stock", v3Bridge);
    }

    /// @notice Ink verifier: hookit Master-rail launches (both factories; hooks pinned at their current code).
    function deployInkVerifiers() internal returns (ILaunchpadVerifier[] memory vs) {
        HookitVerifier.Rail[] memory r = new HookitVerifier.Rail[](2);
        r[0] = HookitVerifier.Rail(
            IHookitLaunchFactory(InkAddresses.HOOKIT_FACTORY_V1),
            InkAddresses.HOOKIT_HOOK_V1,
            InkAddresses.HOOKIT_HOOK_V1.codehash
        );
        r[1] = HookitVerifier.Rail(
            IHookitLaunchFactory(InkAddresses.HOOKIT_FACTORY_V2),
            InkAddresses.HOOKIT_HOOK_V2,
            InkAddresses.HOOKIT_HOOK_V2.codehash
        );
        vs = new ILaunchpadVerifier[](1);
        vs[0] = new HookitVerifier(
            r,
            InkAddresses.HOOKIT_FORBIDDEN_FLAGS,
            InkAddresses.HOOKIT_TOKEN_TEMPLATE,
            InkAddresses.HOOKIT_TOKEN_SIZE,
            InkAddresses.HOOKIT_TOKEN_IMMUTABLES
        );
    }

    /// @notice Listing policy: attach `verifiers` and allowlist `trusted` tokens on the shared ListingPolicy.
    function applyVetting(System memory s, ILaunchpadVerifier[] memory verifiers, address[] memory trusted) internal {
        for (uint256 i; i < verifiers.length; ++i) {
            s.policy.attach(verifiers[i]);
        }
        for (uint256 i; i < trusted.length; ++i) {
            s.policy.setTokenAllowlisted(trusted[i], true);
        }
    }

    function addHookitRail(System memory s, address factory) internal {
        IHookitLaunchFactory f = IHookitLaunchFactory(factory);
        s.hookit.addRail(f, IHookitMasterHook(f.masterHook()));
    }

    /// @notice Offer ownership of every contract to `c.owner` (no-op when the deployer is the owner).
    function handOver(System memory s, Config memory c) internal {
        if (c.owner == c.deployer) return;
        s.house.transferOwnership(c.owner);
        OwnableUpgradeable(address(s.randomness)).transferOwnership(c.owner);
        s.router.transferOwnership(c.owner);
        if (address(s.hookit) != address(0)) s.hookit.transferOwnership(c.owner);
        s.v4.transferOwnership(c.owner);
        s.vault.transferOwnership(c.owner);
        if (address(s.v3) != address(0)) s.v3.transferOwnership(c.owner);
        if (address(s.policy) != address(0)) s.policy.transferOwnership(c.owner);
        if (address(s.converter) != address(0)) s.converter.transferOwnership(c.owner);
        if (address(s.partners) != address(0)) s.partners.transferOwnership(c.owner);
    }

    function proxy(address impl, address adminOwner, bytes memory data) internal returns (address) {
        return address(new TransparentUpgradeableProxy(impl, adminOwner, data));
    }
}
