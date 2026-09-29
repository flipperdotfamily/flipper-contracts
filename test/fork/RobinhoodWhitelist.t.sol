// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {FlipperHouseBase} from "../../src/house/FlipperHouseBase.sol";
import {RevenueRouter} from "../../src/RevenueRouter.sol";
import {V4SwapEngine} from "../../src/base/V4SwapEngine.sol";
import {MockVRFWrapper} from "../../src/mocks/MockVRFWrapper.sol";
import {IEntropyV2} from "../../src/interfaces/IEntropyV2.sol";
import {IVRFV2PlusWrapper} from "../../src/interfaces/IVRFV2PlusWrapper.sol";
import {IPonsV2Factory} from "../../src/interfaces/IPons.sol";
import {ILaunchpadVerifier} from "../../src/interfaces/ILaunchpadVerifier.sol";
import {CodeTemplate} from "../../src/libraries/CodeTemplate.sol";
import {FlipperDeploy} from "../../script/lib/FlipperDeploy.sol";
import {RobinhoodAddresses as RH} from "../../script/lib/RobinhoodAddresses.sol";

/// @dev pons v1 `PonsLaunchFactory.getLaunchedToken` (legacy 0x0c37…77a4 and 0xA5aA…FeB share the layout)
interface IPonsV1Factory {
    struct LaunchedToken {
        address token;
        address deployer;
        address pairedToken;
        address positionManager;
        uint256 positionId;
        uint256 dexId;
        uint256 launchConfigId;
        uint256 restrictionsEndBlock;
        uint256 supply;
        bool isToken0;
        uint24 poolFee;
        bool exists;
        uint256 initialBuyAmount;
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
}

interface IPonsV1Token {
    function liquidityPool() external view returns (address);
    function restrictionEndBlock() external view returns (uint256);
}

interface IPonsMemeHookLaunches {
    function launches(bytes32 poolId)
        external
        view
        returns (bool, bool, address, address, address, address, address, uint16, uint16, uint16, uint16, uint16, bool);
}

interface IIndexToken {
    function owner() external view returns (address);
}

interface IIndexFeeHook {
    function FEE_BPS() external view returns (uint256);
    function treasury() external view returns (address);
}

/// @notice The house's own swap engine behind two entry points, so a route's swap gas and prices are measured with
///         exactly the code that settles flips (`_trySwap` / `_tryQuote`, same gas caps).
contract RouteHarness is V4SwapEngine {
    constructor(IPoolManager pm) V4SwapEngine(pm) {}

    receive() external payable {}

    function quote(bool exactIn, PoolKey[] memory path, Currency cIn, Currency cOut, uint256 amount)
        external
        returns (bool ok, uint256 amountIn, uint256 amountOut)
    {
        return _tryQuote(_request(exactIn ? EXACT_IN : EXACT_OUT, path, cIn, cOut, amount, 0), 5_000_000);
    }

    /// @dev `gasUsed`: gas of the whole `unlock` (every hop, hook and token transfer), as one settlement attempt
    function swap(bool exactIn, PoolKey[] memory path, Currency cIn, Currency cOut, uint256 amount, uint256 limit)
        external
        returns (bool ok, uint256 amountIn, uint256 amountOut, uint256 gasUsed)
    {
        uint256 g = gasleft();
        (ok, amountIn, amountOut) =
            _trySwap(_request(exactIn ? EXACT_IN : EXACT_OUT, path, cIn, cOut, amount, limit), 5_000_000);
        gasUsed = g - gasleft();
    }
}

/// @notice Launch whitelist (pons partners) on a Robinhood Chain fork: the five tokens of
///         `RobinhoodAddresses.launchWhitelist()` through the real ListingPolicy, V4 / V3 route adapters, v3 bridge
///         hook and house, wired as Deploy.s.sol's Robinhood branch does (stock-token verifier only; pons detached).
///         Checks each token's identity and code, that only the pool whitelist vets it, that it lists
///         permissionlessly (the house's listing probe), and quotes, buys (a won flip) and sells (a lost flip) at a
///         small and at the max-bet size, logging swap gas and price impact.
///
///   Run (an archive RPC: the fork is pinned to FORK_BLOCK; ROBINHOOD_FORK_BLOCK=0 forks the head):
///     ROBINHOOD_RPC_URL=https://rpc.ordofi.network forge test --match-contract RobinhoodWhitelist -vv
///   Cold-storage gas (each call its own transaction, as in a keeper's fulfilment):
///     … --match-test test_routes --isolate -vv
///   Randomness is delivered through the Chainlink-interface test wrapper at the production callback budget
///   (`callbackGasLimit`): settlement, not the randomness source, is what these routes exercise.
contract RobinhoodWhitelistForkTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant FORK_BLOCK = 72_650_000;
    uint256 internal constant GAS_PRICE = 53_718_000;
    uint256 internal constant WIN_WORD = 9_999;
    uint256 internal constant LOSS_WORD = 0;
    uint256 internal constant BPS = 10_000;

    address internal constant PONS_V1_LEGACY_FACTORY = 0x0c37a24F5D23A486FA692d1500881d698B1F77a4;
    address internal constant PONS_V1_FACTORY = 0xA5aAb3F0c6EeadF30Ef1D3Eb997108E976351feB;
    address internal constant PONS_V1_NEW_FACTORY = 0xF4fC0CD27fC8EcF17E55eE4c3f7201897dF3eb75;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant MU = 0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD;
    /// an impostor: same name and socials as $DICE, launched later on pons v1; its pool is drained
    address internal constant DICE_COPYCAT = 0x07a87769C81d946Ead11F5C8B21b17e12E5f72cC;
    /// INDEX's launch pool (ETH, INDEX, 1%, 200) and its fee hook: immutable and ownerless, FEE_BPS 300 and treasury
    /// are constants; seeded by INDEX's deployer 30 blocks after the mint
    address internal constant INDEX_FEE_HOOK = 0x2cD91bD228ff4c537031d6b8204782090c84c0cC;
    bytes32 internal constant INDEX_LAUNCH_POOL_ID = 0x00dd2df2f17d431cf3a0938f06c9cf9abc5e9643b6cc466ca3f71f3af246edf3;
    bytes32 internal constant EIP1967_IMPL = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// INDEX's largest EOA holder (13.7M INDEX at FORK_BLOCK)
    address internal constant INDEX_WHALE = 0x14e468E79D14606035A86A6B068A93BeaDa853f8;
    /// pons v1 PonsLauncherToken (5,274 B): its 13 immutable words and the CBOR metadata hash, zeroed
    uint256 internal constant V1_SIZE = 5274;
    uint256 internal constant V1_IMMUTABLES = 381 | (587 << 16) | (646 << 32) | (704 << 48) | (910 << 64)
        | (1516 << 80) | (1875 << 96) | (2289 << 112) | (2541 << 128) | (3952 << 144) | (4008 << 160)
        | (4197 << 176) | (4511 << 192) | (5231 << 208);

    IPoolManager internal pm = IPoolManager(RH.POOL_MANAGER);
    IPonsV2Factory internal pons = IPonsV2Factory(RH.PONS_V2_FACTORY);
    MockVRFWrapper internal wrapper;
    FlipperDeploy.System internal sys;
    RevenueRouter internal router;
    IERC20 internal flipper;
    PoolKey internal flipperKey;
    RouteHarness internal harness;
    address internal player = makeAddr("player");
    bool internal forked;

    struct Size {
        uint256 amount;
        FlipperHouseBase.Preview pv;
    }

    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 blk = vm.envOr("ROBINHOOD_FORK_BLOCK", FORK_BLOCK);
        if (blk == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blk);
        forked = true;
        vm.txGasPrice(GAS_PRICE);
        vm.deal(address(this), 1000 ether);
        vm.deal(player, 100 ether);

        // Deploy.s.sol, Robinhood branch: router, $FLIPPER on pons (curve bought out → graduated v4 pool), core,
        // 90% of the buy seeded as bankroll, the v4 adapter (meme hook, USDG quote), the v3 bridge + adapter (same
        // $FLIPPER pool and USDG quote), the listing policy with the trusted majors.
        wrapper = new MockVRFWrapper(MockVRFWrapper.Config(13_400, 104_500, 435, 60, 0, 2_500_000, 0));
        FlipperDeploy.Config memory c = _config();
        router = FlipperDeploy.deployRouter(c);
        (address token,, uint256 out) = router.launchFlipperPons{value: pons.launchFee() + RH.PONS_CURVE_BUYOUT_ETH}(
            pons, RH.flipperPonsParams(keccak256("flipper-whitelist-fork")), RH.PONS_CURVE_BUYOUT_ETH, address(this)
        );
        flipper = IERC20(token);
        flipperKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(token), 0, 200, IHooks(RH.PONS_V2_MEME_HOOK));
        sys = FlipperDeploy.deployCore(
            c, router, flipper, FlipperDeploy.deployChainlinkAdapter(c, IVRFV2PlusWrapper(address(wrapper)), 1)
        );
        wrapper.setFulfiller(address(this), true);
        flipper.approve(address(sys.house), type(uint256).max);
        sys.house.depositTreasury(out * 9 / 10);
        sys.v4.setFlipperPool(flipperKey);
        sys.v4.setHookAllowed(RH.PONS_V2_MEME_HOOK, true);
        sys.v4.setQuote(RH.USDG, _usdgEthKey());
        FlipperDeploy.System memory s = sys;
        FlipperDeploy.deployV3(c, s, RH.V3_FACTORY, RH.WETH, address(this));
        sys.v3 = s.v3;
        sys.v3Bridge = s.v3Bridge;
        sys.v3.setFlipperPool(flipperKey);
        sys.v3.setQuote(RH.USDG, _usdgEthKey());
        // as Deploy: the majors allowlisted and only the stock-token verifier attached (pons verifier detached)
        ILaunchpadVerifier[] memory attach = new ILaunchpadVerifier[](1);
        attach[0] = FlipperDeploy.deployRobinhoodVerifiers(address(sys.v3Bridge))[1];
        FlipperDeploy.applyVetting(sys, attach, RH.trustedTokens());

        harness = new RouteHarness(pm);
        vm.deal(address(harness), 100 ether);
    }

    function _config() internal view returns (FlipperDeploy.Config memory) {
        return FlipperDeploy.Config({
            poolManager: pm,
            entropy: IEntropyV2(address(0)),
            entropyProvider: address(0),
            deployer: address(this),
            owner: address(this),
            proxyAdminOwner: address(this),
            params: RH.defaultParams()
        });
    }

    // ── 1. identity and code ─────────────────────────────────────────────────────────────────────────

    function test_tokens_resolve() public {
        if (!forked) return;
        _meta(RH.PONS, "PONS");
        _meta(RH.ORBIO, "ORBIO");
        _meta(RH.SHROOM, "SHROOM");
        _meta(RH.INDEX, "Index");
        _meta(RH.DICE_TOKEN, "DICE");

        // pons v2 (graduated): registry, pair, creator tax, and the audited PonsV2LauncherToken template
        _ponsV2(RH.ORBIO, NVDA, 80);
        _ponsV2(RH.SHROOM, MU, 333);

        // pons v1 (Uniswap v3 WETH 1% launch pools): registry + one executable template, launch window long over
        IPonsV1Factory.LaunchedToken memory p = IPonsV1Factory(PONS_V1_LEGACY_FACTORY).getLaunchedToken(RH.PONS);
        assertTrue(p.exists && p.token == RH.PONS && p.pairedToken == RH.WETH && p.poolFee == 10_000, "PONS: v1 legacy");
        IPonsV1Factory.LaunchedToken memory d = IPonsV1Factory(PONS_V1_FACTORY).getLaunchedToken(RH.DICE_TOKEN);
        assertTrue(d.exists && d.token == RH.DICE_TOKEN && d.pairedToken == RH.WETH, "DICE: v1");
        assertEq(d.deployer, RH.DICE_ADMIN, "$DICE deployed by Dice Protocol's DiceEntropy admin");
        assertEq(IPonsV1Token(RH.PONS).liquidityPool(), RH.PONS_WETH_V3_1PCT, "PONS launch pool");
        assertEq(IPonsV1Token(RH.DICE_TOKEN).liquidityPool(), RH.DICE_WETH_V3_1PCT, "DICE launch pool");
        bytes32 v1 = CodeTemplate.maskedHash(RH.PONS, V1_SIZE, V1_IMMUTABLES);
        assertTrue(v1 != bytes32(0), "PONS: v1 runtime size");
        assertEq(CodeTemplate.maskedHash(RH.DICE_TOKEN, V1_SIZE, V1_IMMUTABLES), v1, "DICE: same v1 template");
        console2.log("pons v1 PonsLauncherToken masked codehash");
        console2.logBytes32(v1);
        // the copycat "Dice Protocol" is a real v1 launch too, with no liquidity left
        assertTrue(IPonsV1Factory(PONS_V1_FACTORY).getLaunchedToken(DICE_COPYCAT).exists, "copycat is a v1 launch");
        assertLt(IERC20(RH.WETH).balanceOf(IPonsV1Token(DICE_COPYCAT).liquidityPool()), 0.1 ether, "copycat drained");

        // INDEX ("The Index") is not a pons launch: Ownable ERC20 + holder registry (owner: an EOA; its only
        // powers are the rewards-exclusion list and the minimum share balance — no pause, blacklist, tax or mint)
        assertFalse(pons.getLaunchedToken(RH.INDEX).exists, "INDEX: not pons v2");
        assertFalse(IPonsV1Factory(PONS_V1_LEGACY_FACTORY).getLaunchedToken(RH.INDEX).exists, "INDEX: not legacy v1");
        assertFalse(IPonsV1Factory(PONS_V1_FACTORY).getLaunchedToken(RH.INDEX).exists, "INDEX: not v1");
        assertFalse(IPonsV1Factory(PONS_V1_NEW_FACTORY).getLaunchedToken(RH.INDEX).exists, "INDEX: not new v1");
        address owner = IIndexToken(RH.INDEX).owner();
        assertEq(owner.code.length, 0, "INDEX owner is an EOA");
        console2.log("INDEX owner", owner);

        // the pons tokens have no owner at all
        _noOwner(RH.PONS);
        _noOwner(RH.ORBIO);
        _noOwner(RH.SHROOM);
        _noOwner(RH.DICE_TOKEN);
    }

    // ── 2. vetting: the pool whitelist is what admits them ───────────────────────────────────────────

    function test_vetting_requires_the_whitelist() public {
        if (!forked) return;
        RH.Listing[] memory w = RH.launchWhitelist();
        assertEq(w.length, 5);
        for (uint256 i; i < w.length; ++i) {
            (uint8 r, uint8 path,,) = _evaluate(w[i]);
            if (sys.policy.isTokenAllowlisted(w[i].token)) {
                assertEq(path, sys.policy.PATH_TOKEN(), "a trusted token");
            } else {
                assertEq(r, sys.policy.NOT_VETTED(), "not vetted before the whitelist");
            }
        }
        _whitelist();
        for (uint256 i; i < w.length; ++i) {
            (uint8 r, uint8 path,,) = _evaluate(w[i]);
            assertEq(r, 0, "vetted");
            assertEq(path, sys.policy.PATH_POOL(), "by the pool whitelist");
            (uint8 reason, uint256 depth) =
                w[i].v3Pool != address(0) ? sys.v3.check(w[i].token, w[i].v3Pool) : sys.v4.check(w[i].token, w[i].key);
            assertEq(reason, 0, "adapter check");
            console2.log(IERC20Metadata(w[i].token).symbol(), "adapter depth (pair-currency wei, in range)", depth);
        }
        // exactly the listed pools: the tokens' other pools stay unvetted
        PoolKey memory orbioMeme =
            PoolKey(Currency.wrap(RH.ORBIO), Currency.wrap(NVDA), 0, 200, IHooks(RH.PONS_V2_MEME_HOOK));
        (uint8 rr,,,) = sys.policy.evaluate(RH.ORBIO, orbioMeme, address(0));
        assertEq(rr, sys.policy.NOT_VETTED(), "ORBIO's pons pool is not whitelisted");
        assertEq(PoolId.unwrap(w[1].key.toId()), RH.ORBIO_USDG_POOL_ID, "ORBIO key");
        assertEq(PoolId.unwrap(w[2].key.toId()), RH.SHROOM_USDG_POOL_ID, "SHROOM key");
    }

    // ── 3. list, quote, buy and sell through our routes ──────────────────────────────────────────────

    /// Each token: permissionless registerAndList (the house's listing probe), then at a small and at the max-bet
    /// size a quote, a won flip (the house buys the stake back through the route: exact output) and a lost flip
    /// (it sells the stake: exact input), each from the same state; plus the harness's swap gas and the price
    /// impact of the whole route and of the token's own leg (token → ETH, without the $FLIPPER pool).
    function test_routes() public {
        if (!forked) return;
        _whitelist();
        RH.Listing[] memory w = RH.launchWhitelist();
        console2.log("max liability ($FLIPPER wei)", sys.house.maxLiability());
        console2.log("max liability in ETH (sell quote, wei)", _flipperToEth(sys.house.maxLiability()));
        for (uint256 i; i < w.length; ++i) {
            _listAndExercise(w[i]);
        }
    }

    /// INDEX's own launch pool: v4 (ETH, INDEX, 1%, 200) behind a 3% fee hook (before/afterSwap with return deltas,
    /// no storage, no owner, not a proxy). Whitelisted, it passes vetting, but at 4% a swap the house's listing probe
    /// refuses it; listed by the owner, the route still settles both ways at a small and the max size.
    function test_index_launch_pool_fee_hook() public {
        if (!forked) return;
        PoolKey memory k =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(RH.INDEX), 10_000, 200, IHooks(INDEX_FEE_HOOK));
        assertEq(PoolId.unwrap(k.toId()), INDEX_LAUNCH_POOL_ID, "INDEX launch pool");
        assertEq(IIndexFeeHook(INDEX_FEE_HOOK).FEE_BPS(), 300, "3% hook fee");
        assertEq(vm.load(INDEX_FEE_HOOK, EIP1967_IMPL), bytes32(0), "not an EIP-1967 proxy");
        (bool hasOwner,) = INDEX_FEE_HOOK.staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(hasOwner, "no owner");
        console2.log("INDEX fee hook treasury", IIndexFeeHook(INDEX_FEE_HOOK).treasury());

        (uint8 before,) = sys.v4.check(RH.INDEX, k);
        assertEq(before, sys.v4.NOT_VETTED(), "unvetted until whitelisted");
        sys.policy.setPoolWhitelisted(k, true);
        (uint8 r, uint256 depth) = sys.v4.check(RH.INDEX, k);
        assertEq(r, 0, "vetted by the pool whitelist (no pin needed on PATH_POOL)");
        console2.log("adapter depth (ETH wei, in range)", depth);
        vm.prank(player);
        try sys.v4.registerAndList(RH.INDEX, k) {
            console2.log("listed permissionlessly");
        } catch (bytes memory err) {
            console2.log("permissionless listing refused by the house's listing probe:");
            console2.logBytes(err);
            sys.house.setTokenRoute(RH.INDEX, _two(k, flipperKey)); // the owner lists it to exercise settlement
        }
        console2.log("===== INDEX through its launch pool (3% fee hook)");
        _exercise(RH.INDEX);
    }

    // ── 4. candidate pools (why these) ───────────────────────────────────────────────────────────────

    /// Token leg only (token ↔ ETH, the $FLIPPER hop is common to all): round-trip cost of spending X ETH on the
    /// token and selling it back, at 0.01 ETH and at the max bet's ETH value, for every pool worth considering.
    function test_compare_candidate_pools() public {
        if (!forked) return;
        uint256 maxEth = _flipperToEth(sys.house.maxLiability() * BPS / 10_500); // stake value at the liability cap
        console2.log("max-bet ETH value (wei)", maxEth);
        PoolKey memory usdgEth = _usdgEthKey();
        PoolKey memory nvdaEth = PoolKey(Currency.wrap(address(0)), Currency.wrap(NVDA), 500, 10, IHooks(address(0)));
        PoolKey memory muEth = PoolKey(Currency.wrap(address(0)), Currency.wrap(MU), 1800, 18, IHooks(address(0)));
        PoolKey memory nvdaEthV3 = sys.v3Bridge.bridge(0x62AB521f71431f78ac374CdbadC6cda3c8916b6C); // WETH/NVDA 0.05%

        _cmp("PONS  v3 WETH 0.3%", RH.PONS, _one(sys.v3Bridge.bridge(RH.PONS_WETH_V3_03PCT)), maxEth);
        _cmp("PONS  v3 WETH 1%", RH.PONS, _one(sys.v3Bridge.bridge(RH.PONS_WETH_V3_1PCT)), maxEth);

        PoolKey memory orbioMeme =
            PoolKey(Currency.wrap(RH.ORBIO), Currency.wrap(NVDA), 0, 200, IHooks(RH.PONS_V2_MEME_HOOK));
        _cmp("ORBIO v4 USDG 0.8% hookless +USDG/ETH", RH.ORBIO, _two(RH.launchWhitelist()[1].key, usdgEth), maxEth);
        _cmp("ORBIO pons NVDA pool +ETH/NVDA v4 0.05%", RH.ORBIO, _two(orbioMeme, nvdaEth), maxEth);
        _cmp("ORBIO pons NVDA pool +WETH/NVDA v3 0.05%", RH.ORBIO, _two(orbioMeme, nvdaEthV3), maxEth);
        _cmp(
            "ORBIO v4 ETH 0.9% hookless",
            RH.ORBIO,
            _one(PoolKey(Currency.wrap(address(0)), Currency.wrap(RH.ORBIO), 9000, 90, IHooks(address(0)))),
            maxEth
        );

        PoolKey memory shroomMeme =
            PoolKey(Currency.wrap(RH.SHROOM), Currency.wrap(MU), 0, 200, IHooks(RH.PONS_V2_MEME_HOOK));
        _cmp("SHROOM v4 USDG 0.9% hookless +USDG/ETH", RH.SHROOM, _two(RH.launchWhitelist()[2].key, usdgEth), maxEth);
        _cmp("SHROOM v3 WETH 1%", RH.SHROOM, _one(sys.v3Bridge.bridge(0xC641a0DC848E7aadd7c69d800BAE2FEA9b258610)), maxEth);
        _cmp("SHROOM pons MU pool +ETH/MU v4 0.18%", RH.SHROOM, _two(shroomMeme, muEth), maxEth);
        _cmp(
            "SHROOM v4 ETH 1.0014% hookless",
            RH.SHROOM,
            _one(PoolKey(Currency.wrap(address(0)), Currency.wrap(RH.SHROOM), 10_014, 200, IHooks(address(0)))),
            maxEth
        );

        _cmp("INDEX v3 WETH 1%", RH.INDEX, _one(sys.v3Bridge.bridge(RH.INDEX_WETH_V3_1PCT)), maxEth);
        _cmp(
            "INDEX v4 USDG 0.7% hookless +USDG/ETH",
            RH.INDEX,
            _two(PoolKey(Currency.wrap(RH.INDEX), Currency.wrap(RH.USDG), 7000, 100, IHooks(address(0))), usdgEth),
            maxEth
        );
        _cmp("DICE  v3 WETH 1%", RH.DICE_TOKEN, _one(sys.v3Bridge.bridge(RH.DICE_WETH_V3_1PCT)), maxEth);

        // the pons meme hooks' fee terms, frozen per pool at graduation
        _memeTerms("ORBIO", orbioMeme);
        _memeTerms("SHROOM", shroomMeme);
    }

    // ── helpers: identity ────────────────────────────────────────────────────────────────────────────

    function _meta(address t, string memory sym) internal view {
        IERC20Metadata m = IERC20Metadata(t);
        assertEq(m.symbol(), sym, "symbol");
        assertEq(m.decimals(), 18, "decimals");
        console2.log(string.concat(m.symbol(), " / ", m.name()), t);
        console2.log("  totalSupply (whole tokens)", m.totalSupply() / 1e18);
    }

    function _ponsV2(address t, address pair, uint16 taxBps) internal view {
        IPonsV2Factory.LaunchedToken memory l = pons.getLaunchedToken(t);
        assertTrue(l.exists && l.token == t, "pons v2 launch");
        assertEq(l.phase, 2, "graduated (v4 pool seeded)");
        assertEq(l.pairToken, pair, "pair token");
        assertEq(l.creatorTaxBps, taxBps, "creator tax");
        assertFalse(l.buybackEnabled, "no buyback");
        assertEq(
            CodeTemplate.maskedHash(t, RH.PONS_TOKEN_SIZE, RH.PONS_TOKEN_IMMUTABLES), RH.PONS_TOKEN_TEMPLATE, "template"
        );
    }

    function _noOwner(address t) internal view {
        (bool ok, bytes memory ret) = t.staticcall(abi.encodeWithSignature("owner()"));
        assertTrue(!ok || ret.length == 0, "no owner()");
    }

    function _memeTerms(string memory label, PoolKey memory key) internal view {
        (bool registered,,,,,,, uint16 creatorTax,,, uint16 hookFee,, bool buyback) =
            IPonsMemeHookLaunches(RH.PONS_V2_MEME_HOOK).launches(PoolId.unwrap(key.toId()));
        assertTrue(registered);
        console2.log(string.concat(label, " pons pool: hook fee / creator tax (bps) / buyback"), hookFee, creatorTax, buyback);
    }

    // ── helpers: listing ─────────────────────────────────────────────────────────────────────────────

    function _whitelist() internal {
        RH.Listing[] memory w = RH.launchWhitelist();
        for (uint256 i; i < w.length; ++i) {
            if (w[i].v3Pool != address(0)) sys.policy.setV3PoolWhitelisted(w[i].v3Pool, true);
            else sys.policy.setPoolWhitelisted(w[i].key, true);
        }
    }

    function _evaluate(RH.Listing memory l) internal view returns (uint8, uint8, bytes32, uint8) {
        return l.v3Pool != address(0)
            ? sys.policy.evaluate(l.token, sys.v3Bridge.keyFor(l.v3Pool), l.v3Pool)
            : sys.policy.evaluate(l.token, l.key, address(0));
    }

    function _listAndExercise(RH.Listing memory l) internal {
        string memory sym = IERC20Metadata(l.token).symbol();
        console2.log("");
        console2.log("=====", sym, l.v3Pool != address(0) ? "(v3 pool, V3RouteAdapter)" : "(v4 pool, V4RouteAdapter)");
        uint256 g = gasleft();
        vm.prank(player);
        if (l.v3Pool != address(0)) sys.v3.registerAndList(l.token, l.v3Pool);
        else sys.v4.registerAndList(l.token, l.key);
        console2.log("registerAndList gas (incl. listing probe)", g - gasleft());
        (bool enabled,, address adapter,) = sys.house.tokenConfig(l.token);
        assertTrue(enabled, "listed");
        assertEq(adapter, l.v3Pool != address(0) ? address(sys.v3) : address(sys.v4), "by the adapter");
        _exercise(l.token);
    }

    /// max stake, then quotes / impact, a won and a lost flip and the harness's swap gas at a small and the max size
    function _exercise(address token) internal {
        PoolKey[] memory route = _route(token);
        console2.log("route hops", route.length);
        uint256 maxAmt = _maxStake(token);
        uint256 smallAmt = maxAmt / 50;
        Size memory small = Size(smallAmt, sys.house.previewFlip(token, smallAmt));
        Size memory big = Size(maxAmt, sys.house.previewFlip(token, maxAmt));
        assertEq(small.pv.code, 0, "small flippable");
        assertEq(big.pv.code, 0, "max flippable");
        console2.log("max stake is capped by the liability (0) or the route cost (1)", _capKind(token, maxAmt));

        // price impact vs a tiny reference trade (same route, so fees cancel out)
        uint256 tiny = maxAmt / 10_000;
        FlipperHouseBase.Preview memory ref = sys.house.previewFlip(token, tiny);
        _sizeReport("small", token, small, ref, tiny, route);
        _sizeReport("max", token, big, ref, tiny, route);

        _settleBoth("small", token, smallAmt);
        _settleBoth("max", token, maxAmt);
        _harnessGas(token, route, maxAmt);
    }

    /// largest stake the house accepts right now (liability cap or route-cost cap, whichever binds first)
    function _maxStake(address t) internal returns (uint256 lo) {
        (bool ok,, uint256 got) = harness.quote(
            true, _reverse(_route(t)), Currency.wrap(address(flipper)), Currency.wrap(t), sys.house.maxLiability() / 100
        );
        assertTrue(ok && got != 0, "probe quote");
        lo = got;
        assertEq(sys.house.previewFlip(t, lo).code, 0, "1% of the max liability is flippable");
        uint256 hi = lo;
        while (sys.house.previewFlip(t, hi).code == 0) {
            lo = hi;
            hi *= 2;
        }
        while (hi - lo > lo / 1000) {
            uint256 mid = (lo + hi) / 2;
            if (sys.house.previewFlip(t, mid).code == 0) lo = mid;
            else hi = mid;
        }
    }

    function _capKind(address t, uint256 maxAmt) internal returns (uint256) {
        uint8 code = sys.house.previewFlip(t, maxAmt * 101 / 100).code;
        console2.log("  reject code just above it", code);
        return code == 7 ? 0 : 1; // REJECT_BET_SIZE = 7 (FlipperHouseBase)
    }

    function _sizeReport(
        string memory label,
        address t,
        Size memory s,
        FlipperHouseBase.Preview memory ref,
        uint256 tiny,
        PoolKey[] memory route
    ) internal {
        console2.log(string.concat("-- ", label, " stake (token wei)"), s.amount);
        console2.log("  stake value (sell quote -> ETH, wei)", _flipperToEth(s.pv.sellQuote));
        console2.log("  sell quote / buy quote ($FLIPPER wei)", s.pv.sellQuote, s.pv.buyQuote);
        console2.log("  route cost / win chance (bps)", s.pv.routeCostBps, s.pv.winChanceBps);
        // impact (bps): how much worse the per-token price is than the tiny reference, per direction
        console2.log(
            "  impact, whole route: sell / buy (bps)",
            _impact(s.pv.sellQuote, s.amount, ref.sellQuote, tiny, true),
            _impact(s.pv.buyQuote, s.amount, ref.buyQuote, tiny, false)
        );
        // the token's own leg (token -> ETH), without the $FLIPPER pool
        PoolKey[] memory leg = _leg(route);
        (, , uint256 legRef) = harness.quote(true, leg, Currency.wrap(t), Currency.wrap(address(0)), tiny);
        (, , uint256 legOut) = harness.quote(true, leg, Currency.wrap(t), Currency.wrap(address(0)), s.amount);
        (, uint256 legInRef,) = harness.quote(false, _reverse(leg), Currency.wrap(address(0)), Currency.wrap(t), tiny);
        (, uint256 legIn,) = harness.quote(false, _reverse(leg), Currency.wrap(address(0)), Currency.wrap(t), s.amount);
        console2.log(
            "  impact, token leg only: sell / buy (bps)",
            _impact(legOut, s.amount, legRef, tiny, true),
            _impact(legIn, s.amount, legInRef, tiny, false)
        );
        console2.log("  token leg round trip (bps, (in-out)/(in+out))", (legIn - legOut) * BPS / (legIn + legOut));
    }

    /// @dev how much worse (bps) the per-token price of `amt` is than that of the reference trade: less out per
    ///      token for a sell, more in per token for a buy (0 if it is not worse)
    function _impact(uint256 v, uint256 amt, uint256 vRef, uint256 amtRef, bool sell) internal pure returns (uint256) {
        uint256 r = v * amtRef * BPS / (vRef * amt); // BPS = same per-token price
        if (sell) return r < BPS ? BPS - r : 0;
        return r > BPS ? r - BPS : 0;
    }

    /// a won and a lost flip of `amt`, each from the same state: the house buys (win) / sells (loss) in the callback
    function _settleBoth(string memory label, address t, uint256 amt) internal {
        uint256 gw = _settleOne(t, amt, WIN_WORD, FlipperHouseBase.Status.Won);
        uint256 gl = _settleOne(t, amt, LOSS_WORD, FlipperHouseBase.Status.Lost);
        console2.log(string.concat("  ", label, ": settlement callback gas, win (buy) / loss (sell)"), gw, gl);
    }

    function _settleOne(address t, uint256 amt, uint256 word, FlipperHouseBase.Status want)
        internal
        returns (uint256 gasUsed)
    {
        uint256 snap = vm.snapshotState();
        _fund(t, player, amt);
        vm.prank(player);
        IERC20(t).approve(address(sys.house), type(uint256).max);
        uint256 before = IERC20(t).balanceOf(player);
        uint256 id;
        (id, gasUsed) = _flipAndSettle(t, amt, word);
        assertEq(uint8(_status(id)), uint8(want), "settled in kind (won: the buy executed; lost: the sell executed)");
        if (want == FlipperHouseBase.Status.Won) assertEq(IERC20(t).balanceOf(player), before + amt, "paid 2x");
        vm.revertToState(snap);
    }

    /// the house's swap engine on the full route: the buy (exact output, $FLIPPER → token) and the sell (exact
    /// input, token → $FLIPPER) of the max stake, each from the same state
    function _harnessGas(address t, PoolKey[] memory route, uint256 amt) internal {
        uint256 snap = vm.snapshotState();
        deal(address(flipper), address(harness), sys.house.maxLiability() * 2);
        (bool okB, uint256 spent,, uint256 gasBuy) =
            harness.swap(false, _reverse(route), Currency.wrap(address(flipper)), Currency.wrap(t), amt, type(uint256).max);
        assertTrue(okB, "harness buy");
        vm.revertToState(snap);
        snap = vm.snapshotState();
        _fund(t, address(harness), amt);
        (bool okS,, uint256 got, uint256 gasSell) =
            harness.swap(true, route, Currency.wrap(t), Currency.wrap(address(flipper)), amt, 0);
        assertTrue(okS, "harness sell");
        vm.revertToState(snap);
        console2.log("  swap gas at max stake (house engine): buy / sell", gasBuy, gasSell);
        console2.log("  executed: buy cost / sell proceeds ($FLIPPER wei)", spent, got);
    }

    // ── helpers: candidates ──────────────────────────────────────────────────────────────────────────

    function _cmp(string memory label, address t, PoolKey[] memory leg, uint256 maxEth) internal {
        console2.log(label);
        _roundTrip(t, leg, 0.01 ether);
        _roundTrip(t, leg, maxEth);
    }

    /// spend `eth` on `t` through `leg` (exact input), sell what arrives back (exact input): cost in bps
    function _roundTrip(address t, PoolKey[] memory leg, uint256 eth) internal {
        (bool ok1,, uint256 got) = harness.quote(true, _reverse(leg), Currency.wrap(address(0)), Currency.wrap(t), eth);
        if (!ok1 || got == 0) {
            console2.log("  buy quote failed at (wei)", eth);
            return;
        }
        (bool ok2,, uint256 back) = harness.quote(true, leg, Currency.wrap(t), Currency.wrap(address(0)), got);
        if (!ok2) {
            console2.log("  sell quote failed at (wei)", eth);
            return;
        }
        console2.log("  ETH in / round trip (bps, (in-out)/(in+out))", eth, eth > back ? (eth - back) * BPS / (eth + back) : 0);
    }

    // ── helpers: flips ───────────────────────────────────────────────────────────────────────────────

    function _fund(address t, address to, uint256 amt) internal {
        if (t != RH.INDEX) {
            deal(t, to, IERC20(t).balanceOf(to) + amt);
            return;
        }
        // INDEX keeps a holder registry in its transfer path (`deal` would bypass it): move real tokens from its
        // largest EOA holder
        require(IERC20(t).balanceOf(INDEX_WHALE) >= amt, "INDEX whale too small");
        vm.prank(INDEX_WHALE);
        IERC20(t).transfer(to, amt);
    }

    function _flipAndSettle(address t, uint256 amt, uint256 word) internal returns (uint256 id, uint256 gasUsed) {
        uint256 fee = sys.house.randomnessFeeFor(t);
        vm.prank(player);
        id = sys.house.flip{value: fee * 12 / 10}(t, amt, 0, block.timestamp);
        (,,,,,,,,,, uint256 requestId,) = sys.house.flips(id);
        uint256 g = gasleft();
        assertTrue(wrapper.fulfillWithWord{gas: 3_000_000}(requestId, word), "callback succeeded");
        gasUsed = g - gasleft();
    }

    function _status(uint256 id) internal view returns (FlipperHouseBase.Status st) {
        (,,,, st,,,,,,,) = sys.house.flips(id);
    }

    // ── helpers: routes ──────────────────────────────────────────────────────────────────────────────

    function _route(address t) internal view returns (PoolKey[] memory route) {
        (,,, route) = sys.house.tokenConfig(t);
    }

    /// the route without its last hop (ETH → $FLIPPER): token → ETH
    function _leg(PoolKey[] memory route) internal pure returns (PoolKey[] memory leg) {
        leg = new PoolKey[](route.length - 1);
        for (uint256 i; i < leg.length; ++i) {
            leg[i] = route[i];
        }
    }

    function _flipperToEth(uint256 amt) internal returns (uint256 out) {
        (,, out) = harness.quote(true, _one(flipperKey), Currency.wrap(address(flipper)), Currency.wrap(address(0)), amt);
    }

    function _usdgEthKey() internal pure returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(address(0)), Currency.wrap(RH.USDG), RH.USDG_POOL_FEE, RH.USDG_POOL_TICK_SPACING, IHooks(address(0))
        );
    }

    function _reverse(PoolKey[] memory p) internal pure returns (PoolKey[] memory r) {
        r = new PoolKey[](p.length);
        for (uint256 i; i < p.length; ++i) {
            r[i] = p[p.length - 1 - i];
        }
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
