// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FlipperHouse} from "../../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../../src/house/FlipperHouseBase.sol";
import {IPonsV2Factory} from "../../src/interfaces/IPons.sol";
import {DiceEntropyAdapter} from "../../src/randomness/DiceEntropyAdapter.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/// @notice Robinhood Chain mainnet (4663, Arbitrum Nitro) addresses and protocol defaults.
///         Verified on-chain 2026-09-23 (research/ROBINHOOD_REPORT.md).
///
///   Randomness: Dice Protocol (DiceEntropy, a Pyth Entropy v2 fork) through the DiceEntropyAdapter — neither
///   Chainlink VRF nor Pyth Entropy is deployed on Robinhood Chain. Facts, threat model and parameters:
///   research/DICE_INTEGRATION.md (verified 2026-09-25).
library RobinhoodAddresses {
    uint256 internal constant CHAIN_ID = 4663;

    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address internal constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address internal constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address internal constant UNIVERSAL_ROUTER_212 = 0x204FAca1764B154221e35c0d20aBb3c525710498;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @notice UNCX's v4 liquidity locker (`UniV4LiquidityLockerV3`, `positionManager()` = POSITION_MANAGER)
    address internal constant UNCX_V4_LOCKER = 0x128A800cBc615cc110Bff16E475865c67631603A;
    /// @notice the most the LiquidityKeeper lets UNCX charge when it locks: its flat fee, LP fee and collect fee today
    ///         (0.1 ETH, 1% of the liquidity, 4% of collected fees)
    uint256 internal constant UNCX_MAX_FLAT_FEE = 0.1 ether;
    uint256 internal constant UNCX_MAX_LP_FEE_BPS = 100;
    uint256 internal constant UNCX_MAX_COLLECT_FEE_BPS = 400;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73; // aeWETH (pons pools use native ETH)

    // Uniswap v3 (PONS only trades on v3)
    address internal constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant V3_SWAP_ROUTER02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address internal constant V3_QUOTER_V2 = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;
    address internal constant PONS_WETH_V3_1PCT = 0x10CC6BD38112cAc182db90B6a71d8Bb5939526bA; // ≈836 WETH deep
    address internal constant PONS_WETH_V3_03PCT = 0xEd50bDeeA8aDC232f159486192a4157281D722ff; // ≈751 WETH deep

    // ── Dice Protocol randomness (immutable, no proxy; verified source on Blockscout) ──
    address internal constant DICE_ENTROPY = 0xd8A0680e7699526B57140ED4EAfdCc7219Dc0A0c;
    /// the default (and only) provider: Dice's Tyche keeper EOA, which also sends the reveals
    address internal constant DICE_PROVIDER = 0x8741b8a825644D9Ef18Faf2DAB5e9b47B900F2b6;
    /// DiceEntropy admin (setFee, registerFor, setDefaultProvider, withdrawFees) and fee vault
    address internal constant DICE_ADMIN = 0x4ACD2C88a239a924E47Fc4995114ca1Bb0CA3CaD;
    address internal constant DICE_VAULT = 0x918EAF0b2589710B0D85ef48C12a343E68263841;
    /// flat fee per request, paid exactly (admin-settable)
    uint256 internal constant DICE_FEE = 25_000_000_000_000;
    /// refundRequest delay, in `block.number` units (L1 blocks on Nitro: ≈72 s)
    uint64 internal constant DICE_REFUND_DELAY_BLOCKS = 6;
    /// Arbitrum's ArbSys precompile (L2 block numbers / hashes)
    address internal constant ARB_SYS = address(100);

    address internal constant CHAINLINK_ETH_USD = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address internal constant LINK = 0x492641F648a4986844848E0beFE66D14817bCE34;

    /// USDG (Paxos, 6 dp) — the chain's main stablecoin — and its deepest hookless ETH pool (fee 460, ts 9)
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint24 internal constant USDG_POOL_FEE = 460;
    int24 internal constant USDG_POOL_TICK_SPACING = 9;

    // pons v2: bonding curve → Uniswap v4 (ETH, token, fee 0, tickSpacing 200, meme hook)
    address internal constant PONS_V2_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address internal constant PONS_V2_MEME_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address internal constant PONS_V2_FEE_ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;
    address internal constant PONS_V2_BUYBACK_VAULT = 0x42df2a798f82289E177311362e8f5ccC45c1219c;
    address internal constant PONS_V2_LAUNCH_LOCKER = 0x267444D099b10fB5Ed7c3Cc7B7c767AdcA574952;
    address internal constant PONS_V2_LAUNCH_AND_BUY = 0xe33E9E479dF8802cb0866d5d05258bEc4cF62948;
    address internal constant PONS_V2_LAUNCH_DEPLOYER = 0x3711ceA4feaDE896C913C68F01Eda97Cb06D1A42;
    address internal constant PONS_V2_GRADUATION_EXECUTOR = 0xC7819B64A1dAECD7eC19856d026cb14EfBd89046;
    address internal constant PONS_V2_GRADUATION_GUARD = 0xf5695117b99B6f6401e67d4195BD653628176C6C;
    /// PONS, the launchpad's own token (a v1/v3 launch) — default holder-reward token on Robinhood
    address internal constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    /// cbBTC (Coinbase; issuer-controlled proxy: a trusted issuer, allowlisted)
    address internal constant CBBTC = 0xCEC185eB182c47d1bA1EFc84e6959e18cd620Be4;

    // ── listing policy (VettedListing) ──
    /// PonsV2LauncherToken runtime (OZ ERC20 + ERC20Burnable, no owner/pause/blacklist/tax) with its immutables
    /// (deployer ×2, curve, launchFactory) zeroed; identical across launches (checked 2026-09-25)
    bytes32 internal constant PONS_TOKEN_TEMPLATE = 0xfaa55f9f9b0db66181468400d0609ed9b9499520e5c0dbb04561042781ef391f;
    uint256 internal constant PONS_TOKEN_SIZE = 3248;
    /// packed 16-bit offsets 379, 529, 1094, 1357
    uint256 internal constant PONS_TOKEN_IMMUTABLES = 379 | (529 << 16) | (1094 << 32) | (1357 << 48);
    /// every Robinhood Stock Token is an OZ BeaconProxy embedding beacon 0xe10b6f6b…1b00: one runtime codehash
    bytes32 internal constant STOCK_TOKEN_CODEHASH = 0x6c1fdd40002dcb440c7fff6a84171404d279ccb057803b65826f7546acd65630;

    /// ETH needed to buy out a pons v2 curve (4.2 ETH net + 1% curve fee = 4.2424); the curve refunds any excess
    uint256 internal constant PONS_CURVE_BUYOUT_ETH = 4.25 ether;

    /// @notice Tokens listable permissionlessly on any pool with a pinned hook (or none): the majors — USDG (the USD
    ///         quote), WETH, cbBTC. pons tokens list only through the launch whitelist's exact pools below.
    function trustedTokens() internal pure returns (address[] memory t) {
        t = new address[](3);
        t[0] = USDG;
        t[1] = WETH;
        t[2] = CBBTC;
    }

    // ── launch whitelist (curated Robinhood Chain tokens) ──
    /// Launch-day listings, whitelisted by exact pool (ListingPolicy PATH_POOL); no launchpad verifier is attached at
    /// launch. Resolved onchain 2026-09-25 (fork block 72,650,000);
    /// test/fork/RobinhoodWhitelist.t.sol vets, lists, quotes and settles each through the real adapters.
    ///   PONS    pons v1 (legacy factory 0x0c37…77a4)                    v3 WETH 0.3%         V3RouteAdapter
    ///   ORBIO   pons v2, graduated on an NVDA pair (Orbio.so)            v4 USDG 0.8% hookless V4RouteAdapter (USDG quote)
    ///   SHROOM  pons v2, graduated on an MU pair (MUSHROOM)              v4 USDG 0.9% hookless V4RouteAdapter (USDG quote)
    ///   INDEX   "The Index": pre-pons Ownable ERC20, a pons v2 pair token v3 WETH 1%           V3RouteAdapter
    ///   DICE    Dice Protocol's $DICE, pons v1 (deployer = DICE_ADMIN)   v3 WETH 1%           V3RouteAdapter
    /// ORBIO's / SHROOM's own graduated pons pools (liquidity locked in the pons locker) charge 1.8% / 4.33% per swap
    /// (1% hook fee + creator tax) and route through a stock token: cheaper, deeper hookless USDG pools are used.
    /// INDEX is not a pons launch (pons only approves it as a v2 pair token). Its own launch pool is v4 (ETH, INDEX,
    /// 1%, 200) with fee hook 0x2cD91bD228ff4c537031d6b8204782090c84c0cC: 3% of every swap to a fixed treasury
    /// (before/afterSwap return deltas), no storage, owner or proxy, so its behaviour can't change. Our route settles
    /// through it, but at 4% a swap the listing probe refuses it; its v3 WETH 1% pool has similar TVL (≈340 ETH) and
    /// ~10x the 7-day volume. No pinHook: PATH_POOL doesn't consult pins; a pin would only admit allowlisted tokens.
    /// Measured on the fork (cold, the house's swap engine): swap attempts 239k–461k gas (heaviest: the INDEX buy
    /// through the v3 bridge); all five pass the listing probe; at launch each flip is capped by maxRouteCostBps at
    /// ≈0.22–0.30 ETH of stake, the thin new $FLIPPER pool (not these pools) being the binding hop.
    address internal constant ORBIO = 0xAa07A0e9209e16aC99708C3EC70159c6eF3128A3;
    address internal constant SHROOM = 0xab093dEF657F15dF31b33922A95e047aDd645B29;
    address internal constant INDEX = 0x56910D4409F3a0C78C64DD8D0545FF0705389870;
    address internal constant DICE_TOKEN = 0x3F9f0b6073Ee8c495Aed96869AF31850fED40FeB;
    /// (USDG, ORBIO, 8000, 80, no hook)
    bytes32 internal constant ORBIO_USDG_POOL_ID = 0xea9f200e13055b82f175f44f592c4c13dd8c9d9320a66487d3c5cd90d68550ef;
    /// (USDG, SHROOM, 9000, 90, no hook)
    bytes32 internal constant SHROOM_USDG_POOL_ID = 0x778a632fdd85577efe9cfce4a2c9ac91b9decdb24c351f9b56e25d38fbe587b4;
    address internal constant INDEX_WETH_V3_1PCT = 0xD29893fFac8b29eC4Db2cfE0CDB3FE1377c028Ff;
    address internal constant DICE_WETH_V3_1PCT = 0x399eaE9D063Cff3f0b05aa94256348c475001022;

    /// @notice One launch listing: `v3Pool` set → a Uniswap v3 pool (bridged; V3RouteAdapter), else the v4 `key`
    ///         (V4RouteAdapter; a USDG-paired key routes through the adapter's USDG quote pool).
    struct Listing {
        address token;
        address v3Pool;
        PoolKey key;
    }

    /// @notice The launch whitelist. Deploy, after the adapters' $FLIPPER pool, USDG quote and the listing policy
    ///         are set: for each entry `policy.setV3PoolWhitelisted(v3Pool, true)` + `v3.registerAndList(token,
    ///         v3Pool)`, or `policy.setPoolWhitelisted(key, true)` + `v4.registerAndList(token, key)`.
    function launchWhitelist() internal pure returns (Listing[] memory l) {
        PoolKey memory none;
        l = new Listing[](5);
        l[0] = Listing(PONS, PONS_WETH_V3_03PCT, none);
        l[1] = Listing(ORBIO, address(0), _usdgKey(ORBIO, 8000, 80));
        l[2] = Listing(SHROOM, address(0), _usdgKey(SHROOM, 9000, 90));
        l[3] = Listing(INDEX, INDEX_WETH_V3_1PCT, none);
        l[4] = Listing(DICE_TOKEN, DICE_WETH_V3_1PCT, none);
    }

    // Robinhood Stock Tokens listed at launch (addresses: Robinhood's asset API, api.robinhood.com/rhj/assets)
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address internal constant SPCX = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa; // SpaceX
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant CRCL = 0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5; // Circle
    address internal constant GME = 0x1b0E319c6A659F002271B69dB8A7df2F911c153E;
    address internal constant AMC_STOCK = 0x05a3d1Cd21d0C88145E82600E62e7E496e0F222B; // AMC Entertainment
    address internal constant META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
    address internal constant GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3; // Alphabet Class A
    address internal constant MSTR = 0xec262a75e413fAfD0dF80480274532C79D42da09; // Strategy
    address internal constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C; // SPDR S&P 500 ETF
    address internal constant GLD = 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e; // SPDR Gold Trust
    address internal constant USO = 0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344; // United States Oil Fund

    /// @notice Stock tokens listed at launch, each on its deepest hookless ETH or USDG pool (measured 2026-09-28 at
    ///         block ≈75.06M by in-range quote-side depth; every one passes V4RouteAdapter.check). The stock-token
    ///         verifier vets them, so no pool whitelisting: Deploy probes each listing off the broadcast and lists
    ///         only those that pass.
    function launchStocks() internal pure returns (Listing[] memory l) {
        l = new Listing[](13);
        l[0] = Listing(NVDA, address(0), _usdgKey(NVDA, 3000, 60)); // ≈$7.6M USDG in range
        l[1] = Listing(TSLA, address(0), _usdgKey(TSLA, 3000, 60)); // ≈$9.8M
        l[2] = Listing(SPCX, address(0), _usdgKey(SPCX, 10_000, 200)); // ≈$6.7M
        l[3] = Listing(AAPL, address(0), _usdgKey(AAPL, 3000, 60)); // ≈$13.3M
        l[4] = Listing(CRCL, address(0), _ethKey(CRCL, 2500, 25)); // ≈$2.8M of ETH
        l[5] = Listing(GME, address(0), _ethKey(GME, 10_000, 200)); // ≈$1.1M of ETH
        l[6] = Listing(AMC_STOCK, address(0), _usdgKey(AMC_STOCK, 1000, 10)); // ≈$6.7M
        l[7] = Listing(META, address(0), _usdgKey(META, 3000, 60)); // ≈$106M
        l[8] = Listing(GOOGL, address(0), _ethKey(GOOGL, 2100, 21)); // ≈$17M of ETH
        l[9] = Listing(MSTR, address(0), _usdgKey(MSTR, 2400, 24)); // ≈$9.0M
        l[10] = Listing(SPY, address(0), _usdgKey(SPY, 3000, 60)); // ≈$151M
        l[11] = Listing(GLD, address(0), _usdgKey(GLD, 2100, 21)); // ≈$0.11M (thin; listed only if the probe passes)
        l[12] = Listing(USO, address(0), _usdgKey(USO, 1200, 15)); // ≈$3.0M
    }

    // Robinhood memecoins added to the launch lineup (the originals: Blockscout's most-held token of each name)
    address internal constant CASHCAT = 0x020bfC650A365f8BB26819deAAbF3E21291018b4; // Cash Cat (Uniswap's default list)
    address internal constant ARTIFICIAL_INU = 0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18; // AI
    address internal constant A_MEME_COIN = 0x385F4f8ae47651ce5F58F5265395a669f8281e18; // AMC

    /// @notice Memecoins added at launch, on their deepest hookless USDG pools (measured as launchStocks). Unlike
    ///         launchWhitelist, a pool is whitelisted only together with a listing that passes its probe: a token that
    ///         doesn't qualify is left out entirely.
    function launchMemes() internal pure returns (Listing[] memory l) {
        l = new Listing[](3);
        l[0] = Listing(CASHCAT, address(0), _usdgKey(CASHCAT, 2690, 54)); // ≈$3.2M USDG in range
        l[1] = Listing(ARTIFICIAL_INU, address(0), _usdgKey(ARTIFICIAL_INU, 2300, 23)); // ≈$2.3M
        l[2] = Listing(A_MEME_COIN, address(0), _usdgKey(A_MEME_COIN, 2969, 30)); // ≈$1.7M
    }

    /// @dev a hookless `token`/USDG v4 pool key (currencies sorted)
    function _usdgKey(address token, uint24 fee, int24 tickSpacing) private pure returns (PoolKey memory) {
        (address c0, address c1) = USDG < token ? (USDG, token) : (token, USDG);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, tickSpacing, IHooks(address(0)));
    }

    /// @dev a hookless native-ETH/`token` v4 pool key (native ETH is always currency0)
    function _ethKey(address token, uint24 fee, int24 tickSpacing) private pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), fee, tickSpacing, IHooks(address(0)));
    }

    /// @notice hard ceiling on one flip's liability, as a share of the unreserved bankroll (owner decision: 5%)
    uint16 internal constant MAX_BET_BPS = 500;
    /// @notice drawdown-scaled Kelly: half Kelly (KELLY_BPS) down to quarter Kelly at the breaker's 50% drawdown
    uint16 internal constant KELLY_MIN_BPS = 2500;
    uint16 internal constant KELLY_DD_START_BPS = 0;
    uint16 internal constant KELLY_DD_END_BPS = 5000;

    /// @notice the edge schedule's thresholds: the house's ratcheted net buybacks (ETH) where the edge starts stepping
    ///         down, and where it reaches its end (owner decision; the tokenomics model checks these)
    uint96 internal constant EDGE_FROM_ETH = 10 ether; // calibrated: research/tokenomics/REPORT.md, variant (g)
    uint96 internal constant EDGE_TO_ETH = 350 ether;

    /// @notice The edge schedule: 45% × 2.05× (a 7.75% $FLIPPER edge, 10% gross on token flips) until the house's own
    ///         net buybacks reach 10 ETH, then down linearly to 47.5% × 2.0× (5% on both) at 350 ETH, never back up.
    function edgeSchedule() internal pure returns (FlipperHouseBase.EdgeSchedule memory s) {
        s.fromEth = EDGE_FROM_ETH;
        s.toEth = EDGE_TO_ETH;
        s.winStartBps = 4500;
        s.winEndBps = 4750;
        s.payoutStartBps = 20_500;
        s.payoutEndBps = 20_000;
    }

    /// @notice at most this many flips per player waiting for randomness (the adapter's open-request cap is global)
    uint16 internal constant MAX_OPEN_PER_PLAYER = 4;
    /// @notice the smallest liability a flip may carry: 50,000 $FLIPPER ≈ $0.34 at the $6.9k launch FDV, about five of
    ///         Dice's flat randomness fees (2.5e13 wei ≈ $0.067), so a slot held open costs real value at risk, not dust.
    ///         A fixed $FLIPPER amount reads no price, so nothing can move it; it scales with the $FLIPPER price (≈ $7 at
    ///         a $100k FDV, $50 at $1M), so the owner lowers it with `setFlipLimits` as the price rises.
    uint128 internal constant MIN_LIABILITY = 50_000 ether;
    /// @notice each flip's liability is capped at this share of its own Kelly fraction of the unreserved bankroll (owner
    ///         decision: half Kelly); this is what normally binds, the 5% ceiling only above a ~10% Kelly fraction
    uint16 internal constant KELLY_BPS = 5000;
    /// @notice all pending flips' liabilities together may not exceed this share of the treasury (what a randomness
    ///         stall can leave at stake)
    uint16 internal constant MAX_RESERVED_BPS = 3000;

    function defaultParams() internal pure returns (FlipperHouseBase.Params memory p) {
        p.baseWinChanceBps = 4500; // 45% → "rand*100 > 55 wins"
        p.minWinChanceBps = 4000;
        // 2.05x on $FLIPPER (owner decision): a 7.75% edge, half-Kelly cap ≈ 2.1% of the bankroll; the token-flip
        // fallback bonus is a fixed 5% (FlipperHouseBase.TOKEN_FALLBACK_BPS)
        p.flipperPayoutBps = 20_500;
        p.minHouseEdgeBps = 200; // ≥2% expected profit per flip after every swap cost the house sponsors
        p.maxRouteCostBps = 1000;
        p.lossSlippageBps = 500;
        p.maxBetBps = MAX_BET_BPS;
        p.maxReservedBps = MAX_RESERVED_BPS;
        p.kellyBps = KELLY_BPS;
        p.rewardsShareBps = 5000; // half of each flip's expected profit → $FLIPPER holders
        p.listingMaxRouteCostBps = 400;
        // listing probe: 2% of the max bet (thin pons pools would reject a larger probe on impact alone); large flips
        // are still priced by their own route cost
        p.listingProbeBps = 200;
        // Callback budgets. Dice charges a flat fee per request (2.5e13 wei for any gas limit from 100k to 2.5M), so
        // the budget costs nothing extra: it is sized for safety. Every swap attempt keeps the 350k settlement reserve
        // back (FlipperHouse._attemptGas), so the callback can't run out of gas whatever a token or pool does; the
        // fallback quote runs on what is left. Measured swap attempts (Robinhood fork, cold storage): pons token over
        // pons hops 171k–267k, TSLA (ETH pool) 176k–196k, SPY (USDG pool, 3 hops) 230k–244k, and the launch
        // whitelist's heaviest, the INDEX buy, 461k (v3 bridge + INDEX's holder-registry writes); whole settlements
        // measured at most ~484k including overhead (test/fork/RobinhoodWhitelist.t.sol). Dice's keeper pays the gas a
        // settlement uses, so the budget is right-sized: swapGasLimit 560k ≈ 1.2x the heaviest attempt, and the
        // callback the least setParams allows for it (+ the 350k reserve). A normal settlement uses ≤ ~484k; only the
        // heaviest route's fallback quote after a failed buy may not fit, and is then left WinPending for anyone.
        p.swapGasLimit = 560_000;
        p.callbackGasLimit = 910_000;
        p.guardianCancelDelay = 1 days;
        p.playerCancelDelay = 7 days;
        p.minListingProbe = 1000 ether;
        p.flipperCallbackGasLimit = 400_000; // $FLIPPER flips never swap: ~6x the measured 63k-72k (flat fee)
        // a WinPending flip whose buy still can't execute after this long is paid its reserved liability in $FLIPPER
        // by whoever calls resolvePendingWin
        p.pendingTimeout = 1 days;
    }

    /// @notice DiceEntropyAdapter limits while randomness rests on one anonymous provider (research/DICE_INTEGRATION.md)
    function diceAdapterConfig() internal pure returns (DiceEntropyAdapter.Config memory c) {
        // Dice's first reveals: p50 1 s, p99 9 s over the last 500 (2026-09); later ones settle market-free
        c.promptWindow = 30;
        // an unrevealed, non-computable request this old refuses new flips (Dice's worst slow spells ran minutes)
        c.stallTimeout = 5 minutes;
        // open requests at once, across all players: roomy for honest load (a player may hold only
        // FlipperHouse.maxOpenPerPlayer of them, and each flip needs at least the house's minLiability, so filling it
        // takes 64+ funded addresses and 256 fees per ~block). A total provider halt can leave at most this many flips
        // cancellable, their liabilities together capped by maxReservedBps. The adapter's loops don't scale with it
        // (they scan a constant ADVANCE_STEPS / STALL_SCAN from the head).
        c.maxOpen = 256;
        // 10x today's fee: an admin fee spike can't silently reprice flips
        c.maxFee = uint128(DICE_FEE * 10);
        c.revealer = address(0); // the provider's own EOA (Tyche reveals from it)
    }

    /// @notice $FLIPPER on pons v2: ETH-quoted (config 0), creator fees to the RevenueRouter (0 = the launcher),
    ///         no extra creator tax (it would be paid on every house trade), no buyback.
    function flipperPonsParams(bytes32 salt) internal pure returns (IPonsV2Factory.TokenParams memory p) {
        p.name = "Flipper";
        p.symbol = "FLIPPER";
        p.logo = "";
        p.description = "flipper.family: flip any token against the house";
        p.creatorFeeRecipient = address(0);
        p.creatorTaxBps = 0;
        p.buybackEnabled = false;
        p.expectedEconomics = bytes32(0);
        p.salt = salt;
    }

    /// @dev pons infrastructure that can hold $FLIPPER without being a holder (reward-exempt)
    function rewardExempt() internal pure returns (address[] memory ex) {
        ex = new address[](12);
        ex[0] = PONS_V2_FACTORY;
        ex[1] = PONS_V2_MEME_HOOK;
        ex[2] = PONS_V2_FEE_ESCROW;
        ex[3] = PONS_V2_BUYBACK_VAULT;
        ex[4] = PONS_V2_LAUNCH_LOCKER;
        ex[5] = PONS_V2_LAUNCH_AND_BUY;
        ex[6] = PONS_V2_LAUNCH_DEPLOYER;
        ex[7] = PONS_V2_GRADUATION_EXECUTOR;
        ex[8] = PONS_V2_GRADUATION_GUARD;
        ex[9] = UNIVERSAL_ROUTER;
        ex[10] = UNIVERSAL_ROUTER_212;
        ex[11] = PERMIT2;
    }
}
