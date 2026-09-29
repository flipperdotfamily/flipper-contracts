// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {FlipperHouse} from "../../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../../src/house/FlipperHouseBase.sol";
import {RevenueRouter} from "../../src/RevenueRouter.sol";
import {MockVRFWrapper} from "../../src/mocks/MockVRFWrapper.sol";
import {DevSwapRouter} from "../../src/mocks/DevSwapRouter.sol";
import {IEntropyV2} from "../../src/interfaces/IEntropyV2.sol";
import {IVRFV2PlusWrapper} from "../../src/interfaces/IVRFV2PlusWrapper.sol";
import {IPonsV2Factory, IPonsV2Curve} from "../../src/interfaces/IPons.sol";
import {ILaunchpadVerifier} from "../../src/interfaces/ILaunchpadVerifier.sol";
import {CodehashVerifier} from "../../src/verifiers/CodehashVerifier.sol";
import {V4RouteAdapter} from "../../src/adapters/V4RouteAdapter.sol";
import {V3RouteAdapter} from "../../src/adapters/V3RouteAdapter.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FlipperDeploy} from "../../script/lib/FlipperDeploy.sol";
import {RobinhoodAddresses as RH} from "../../script/lib/RobinhoodAddresses.sol";

interface ISwapRouter02Like {
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

interface IPonsMemeHookSweep {
    function feeSweepOperator() external view returns (address);
    function sweepPoolFees(bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external;
}

/// @notice End-to-end on a fork of Robinhood Chain: real pons v2 factory / curve / meme hook, real Uniswap v4
///         PoolManager, real Uniswap v3 (PONS), and a local wrapper priced like Chainlink's VRFV2PlusWrapper at
///         Robinhood's gas price (Chainlink VRF is not deployed on Robinhood Chain yet).
///         Run: ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract RobinhoodFork -vv
contract RobinhoodForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant GAS_PRICE = 53_718_000; // live 2026-09-23
    uint256 internal constant WIN_WORD = 9_999;
    uint256 internal constant LOSS_WORD = 0;
    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address internal constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address internal constant BNKR = 0x178E54df3D091EE4D0B2534742eF9e3692b76526;
    address internal constant SGOV = 0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5;
    address internal constant USDG_WETH_V3_001 = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address internal constant BNKR_WETH_V3_1 = 0x559Ec27d7DD5512783126ceCae5266E6d346abC2;
    address internal constant SGOV_USDG_V3_03 = 0xfAb520051f96F4D2a32c22B6a3dD7fFfdf231bFe;
    address internal constant DEGEN = 0x0830A9Dd26a04e959657AB6788d45f5725590c32;
    address internal constant DEGEN_WETH_V3_1 = 0x5408AD4b4F1D5091B99953Af963500a792f47bc3;

    IPoolManager internal pm = IPoolManager(RH.POOL_MANAGER);
    IPonsV2Factory internal pons = IPonsV2Factory(RH.PONS_V2_FACTORY);
    MockVRFWrapper internal wrapper;
    FlipperDeploy.System internal sys;
    RevenueRouter internal router;
    IERC20 internal flipper;
    PoolKey internal flipperKey;
    DevSwapRouter internal dex;
    uint256 internal launchOut;
    address internal player = makeAddr("player");
    bool internal forked;
    ILaunchpadVerifier[] internal verifiers;

    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 forkBlock = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        forked = true;
        vm.txGasPrice(GAS_PRICE);
        vm.deal(address(this), 1000 ether);
        vm.deal(player, 100 ether);

        wrapper = new MockVRFWrapper(MockVRFWrapper.Config(13_400, 104_500, 435, 60, 0, 2_500_000, 720 * 259_241_824));
        FlipperDeploy.Config memory c = _config();
        router = FlipperDeploy.deployRouter(c);
        (address token,, uint256 out) = router.launchFlipperPons{value: pons.launchFee() + RH.PONS_CURVE_BUYOUT_ETH}(
            pons, RH.flipperPonsParams(keccak256("flipper-fork")), RH.PONS_CURVE_BUYOUT_ETH, address(this)
        );
        flipper = IERC20(token);
        launchOut = out;
        flipperKey = _ponsKey(token);
        sys = FlipperDeploy.deployCore(
            c, router, flipper, FlipperDeploy.deployChainlinkAdapter(c, IVRFV2PlusWrapper(address(wrapper)), 1)
        );
        flipper.approve(address(sys.house), type(uint256).max);
        sys.house.depositTreasury(out * 9 / 10);
        sys.v4.setHookAllowed(RH.PONS_V2_MEME_HOOK, true);
        sys.v4.setFlipperPool(flipperKey);
        sys.v4.setQuote(
            RH.USDG,
            PoolKey(Currency.wrap(address(0)), Currency.wrap(RH.USDG), RH.USDG_POOL_FEE, RH.USDG_POOL_TICK_SPACING, IHooks(address(0)))
        );
        router.addHarvestCall(RH.PONS_V2_FEE_ESCROW, abi.encodeWithSignature("claim()"));
        dex = new DevSwapRouter(pm);
        // listing policy: the Robinhood majors allowlisted (as Deploy.s.sol does), plus the pons and stock-token
        // verifiers attached (built for the Robinhood config; not attached by default) so their logic is exercised
        verifiers = FlipperDeploy.deployRobinhoodVerifiers(address(0));
        FlipperDeploy.applyVetting(sys, verifiers, RH.trustedTokens());
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

    function test_pons_launch_buys_out_the_curve_and_graduates_in_one_tx() public {
        if (!forked) return;
        IPonsV2Factory.LaunchedToken memory lt = pons.getLaunchedToken(address(flipper));
        assertEq(lt.phase, 2, "graduated: v4 pool seeded");
        assertEq(lt.deployer, address(router), "router is the creator");
        assertEq(lt.creatorFeeRecipient, address(router), "creator fees accrue to the protocol");
        assertApproxEqRel(launchOut, 714_285_714 ether, 0.001e18, "the whole curve (71.4% of supply)");
        assertGt(pm.getLiquidity(flipperKey.toId()), 0);
        assertEq(address(router).balance, 0, "unused ETH refunded");
        console2.log("FLIPPER bought at launch", launchOut / 1e18);
        console2.log("bankroll", sys.house.treasury() / 1e18);
    }

    function test_flipper_flips_settle_on_the_pons_pool() public {
        if (!forked) return;
        uint256 got = _buy(flipperKey, address(flipper), 0.05 ether);
        vm.startPrank(player);
        flipper.approve(address(sys.house), type(uint256).max);
        vm.stopPrank();
        uint256 a = _flipAndSettle(address(flipper), got / 2, WIN_WORD);
        uint256 b = _flipAndSettle(address(flipper), got / 4, LOSS_WORD);
        assertEq(uint8(_status(a)), uint8(FlipperHouseBase.Status.Won));
        assertEq(uint8(_status(b)), uint8(FlipperHouseBase.Status.Lost));
    }

    /// Any graduated pons token: permissionless listing through the V4RouteAdapter (meme hook allowlisted), then
    /// token flips that actually swap through two pons pools inside the VRF callback (≤ Chainlink's 2.5M cap).
    function test_any_pons_token_lists_and_settles_both_ways() public {
        if (!forked) return;
        address t = _launchGraduatedPonsToken("Other", "OTHER");
        PoolKey memory key = _ponsKey(t);
        (uint8 reason, uint256 depth) = sys.v4.check(t, key);
        assertEq(reason, 0, "eligible");
        console2.log("pool ETH-side depth (wei)", depth);
        uint256 g0 = gasleft();
        sys.v4.registerAndList(t, key);
        console2.log("registerAndList gas (pons launch, verifier)", g0 - gasleft());

        uint256 got = _buy(key, t, 0.2 ether);
        vm.prank(player);
        IERC20(t).approve(address(sys.house), type(uint256).max);
        FlipperHouseBase.Preview memory pv = sys.house.previewFlip(t, got / 10);
        assertEq(pv.code, 0, "flippable");
        console2.log("route cost (bps)", pv.routeCostBps);
        console2.log("win chance (bps)", pv.winChanceBps);

        uint256 before = IERC20(t).balanceOf(player);
        uint256 w = _flipAndSettle(t, got / 10, WIN_WORD);
        assertEq(uint8(_status(w)), uint8(FlipperHouseBase.Status.Won), "won in kind: the buy fit in the callback gas");
        assertEq(IERC20(t).balanceOf(player), before + got / 10, "paid 2x (net +1x)");

        uint256 l = _flipAndSettle(t, got / 10, LOSS_WORD);
        assertEq(uint8(_status(l)), uint8(FlipperHouseBase.Status.Lost), "stake sold for $FLIPPER");
    }

    /// Keeperless revenue on pons: anyone harvests the escrow (creator fees accrue as ETH there), earning the
    /// capped bounty; the ETH is auctioned for $FLIPPER and the proceeds split to the bankroll and holders.
    function test_harvest_pons_creator_fees_and_auction() public {
        if (!forked) return;
        _buy(flipperKey, address(flipper), 2 ether); // 1% hook fee, 70% to the creator (the router)
        _sweep(flipperKey); // pons' operator sweeps hook fees into the escrow
        vm.prank(player, player);
        (uint256 bEth,) = router.harvest();
        uint256 lots = sys.converter.lotsLength();
        assertEq(address(router).balance, 0, "ETH leg auctioned (or below the minimum lot)");
        if (lots != 0) {
            uint256 eth = sys.converter.lot(0).remaining;
            assertEq(bEth, (eth + bEth) * 10 / 10_000);
        }
    }

    /// The plain-v4 alternative on Robinhood: FLIPPER on a hookless pool seeded single-sided by the router.
    // ── settlement gas (sizes `swapGasLimit` / `callbackGasLimit`) ─────────────────────────────────────
    // Every settlement below is fulfilled through the wrapper with exactly the default callback budget and must
    // settle in kind (no degraded path). Per-attempt gas is read from the trace:
    //   ROBINHOOD_RPC_URL=… forge test --match-contract RobinhoodFork --match-test test_gas --isolate -vvvv
    // (--isolate: each call is its own transaction, so storage is cold exactly as in a keeper's fulfilment tx).

    /// Heaviest pons case: a token with a creator tax and buyback on, both pools' hook fees just swept by the
    /// pons operator (every afterSwap fee slot and the hook's token balance start at zero), and the fallback path
    /// ($FLIPPER dumped between request and callback → the capped buy fails, the settled sell quote runs).
    function test_gas_pons_taxed_buyback_swept() public {
        if (!forked) return;
        address t = _launchPonsToken("Taxed", "TAX", 100, true);
        PoolKey memory key = _ponsKey(t);
        sys.v4.registerAndList(t, key);
        uint256 got = _buy(key, t, 0.2 ether);
        vm.prank(player);
        IERC20(t).approve(address(sys.house), type(uint256).max);
        uint256 stake = got / 10;

        _sweep(key);
        _sweep(flipperKey);
        console2.log("== pons taxed+buyback swept: win");
        assertEq(uint8(_status(_flipAndSettle(t, stake, WIN_WORD))), uint8(FlipperHouseBase.Status.Won));
        _sweep(key);
        _sweep(flipperKey);
        console2.log("== pons taxed+buyback swept: loss");
        assertEq(uint8(_status(_flipAndSettle(t, stake, LOSS_WORD))), uint8(FlipperHouseBase.Status.Lost));

        uint256 id = _flip(t, stake);
        _dumpFlipper();
        _sweep(key);
        _sweep(flipperKey);
        console2.log("== pons taxed+buyback swept: fallback win");
        _settle(id, WIN_WORD);
        // the settled quote needs ~262k here; at the default budget it gets ~226k (the rest is the settlement
        // reserve), so this compound case — heaviest route AND a price move — is left pending for the keeper
        FlipperHouseBase.Status st = _status(id);
        assertTrue(st == FlipperHouseBase.Status.WonFallback || st == FlipperHouseBase.Status.WinPending, "settled safely");
        if (st == FlipperHouseBase.Status.WinPending) {
            // anyone resolves it: buy in kind if that executes now, else (after pendingTimeout) the reserved
            // liability in $FLIPPER. Here $FLIPPER is still dumped, so buying in kind stays over the cap.
            try sys.house.resolvePendingWin(id) {}
            catch {
                vm.warp(block.timestamp + RH.defaultParams().pendingTimeout);
                sys.house.resolvePendingWin(id);
            }
            st = _status(id);
            assertTrue(st == FlipperHouseBase.Status.Won || st == FlipperHouseBase.Status.WonFallback, "resolved");
        }
    }

    /// A Robinhood stock token on its native-ETH v4 pool (TSLA, hookless 0.18%): [TSLA/ETH, ETH/$FLIPPER].
    function test_gas_stock_token_eth_pool() public {
        if (!forked) return;
        address t = TSLA;
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(t), 1800, 18, IHooks(address(0)));
        uint256 g0 = gasleft();
        sys.v4.registerAndList(t, key);
        console2.log("registerAndList gas (stock token, verifier)", g0 - gasleft());
        uint256 got = _buy(key, t, 0.05 ether);
        vm.prank(player);
        IERC20(t).approve(address(sys.house), type(uint256).max);
        console2.log("== TSLA (ETH pool): win");
        assertEq(uint8(_status(_flipAndSettle(t, got / 2, WIN_WORD))), uint8(FlipperHouseBase.Status.Won));
        console2.log("== TSLA (ETH pool): loss");
        assertEq(uint8(_status(_flipAndSettle(t, got / 4, LOSS_WORD))), uint8(FlipperHouseBase.Status.Lost));
    }

    /// A stock token whose pool is USDG-quoted (SPY, hookless 0.05%): a 3-hop route
    /// [SPY/USDG, USDG/ETH, ETH/$FLIPPER] through two stock/stablecoin proxies; win, loss and the fallback path
    /// with the $FLIPPER pool's fees just swept — the heaviest realistic Robinhood settlement.
    function test_gas_stock_token_quote_hop() public {
        if (!forked) return;
        address t = SPY;
        PoolKey memory key = PoolKey(Currency.wrap(t), Currency.wrap(RH.USDG), 500, 5, IHooks(address(0)));
        sys.v4.registerAndList(t, key);
        PoolKey[] memory path = new PoolKey[](2);
        path[0] = sys.v4.quotePool(RH.USDG);
        path[1] = key;
        vm.prank(player);
        uint256 got = dex.swapExactIn{value: 0.05 ether}(path, address(0), t, 0.05 ether, 1, player);
        vm.prank(player);
        IERC20(t).approve(address(sys.house), type(uint256).max);
        (,,, PoolKey[] memory route) = sys.house.tokenConfig(t);
        assertEq(route.length, 3, "quote-currency hop");

        _sweep(flipperKey);
        console2.log("== SPY (USDG pool, 3 hops): win");
        assertEq(uint8(_status(_flipAndSettle(t, got / 4, WIN_WORD))), uint8(FlipperHouseBase.Status.Won));
        _sweep(flipperKey);
        console2.log("== SPY (USDG pool, 3 hops): loss");
        assertEq(uint8(_status(_flipAndSettle(t, got / 4, LOSS_WORD))), uint8(FlipperHouseBase.Status.Lost));

        uint256 id = _flip(t, got / 4);
        _dumpFlipper();
        _sweep(flipperKey);
        console2.log("== SPY (USDG pool, 3 hops): fallback win");
        _settle(id, WIN_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.WonFallback), "buy failed, $FLIPPER bonus paid");
    }

    /// $FLIPPER flips never swap: they settle inside `flipperCallbackGasLimit`.
    function test_gas_flipper_flips() public {
        if (!forked) return;
        uint256 got = _buy(flipperKey, address(flipper), 0.05 ether);
        vm.prank(player);
        flipper.approve(address(sys.house), type(uint256).max);
        console2.log("== FLIPPER: win");
        assertEq(uint8(_status(_flipAndSettle(address(flipper), got / 2, WIN_WORD))), uint8(FlipperHouseBase.Status.Won));
        console2.log("== FLIPPER: loss");
        assertEq(uint8(_status(_flipAndSettle(address(flipper), got / 4, LOSS_WORD))), uint8(FlipperHouseBase.Status.Lost));
    }

    // ── Uniswap v3 liquidity through the bridge hook (V3RouteAdapter) ────────────────────────────────────

    /// USDG itself, through the deepest v3 pool on the chain (WETH/USDG 0.01%, ~3,100 WETH)
    function test_v3_usdg_via_weth_pool() public {
        if (!forked) return;
        _deployV3();
        _v3ListAndFlip(RH.USDG, USDG_WETH_V3_001, 0.05 ether, "USDG (v3 WETH 0.01%)");
    }

    /// BNKR: v3-only liquidity (WETH 1%, ~48 WETH)
    /// BNKR: v3-only liquidity (WETH 1%, ~48 WETH). Not a launchpad or issuer token, so it is refused until the
    /// owner puts it on the adapter's trusted list.
    function test_v3_bnkr_via_weth_pool() public {
        if (!forked) return;
        _deployV3();
        (uint8 r,) = sys.v3.check(BNKR, BNKR_WETH_V3_1);
        assertEq(r, sys.v3.NOT_VETTED(), "not vetted");
        sys.policy.setV3PoolWhitelisted(BNKR_WETH_V3_1, true); // the owner whitelists this exact pool
        _v3ListAndFlip(BNKR, BNKR_WETH_V3_1, 0.05 ether, "BNKR (v3 WETH 1%)");
    }

    /// DEGEN (v3 only): refused permissionlessly — through the adapter and directly on the house — and listable by
    /// the owner on the house.
    function test_v3_unvetted_token_refused_owner_lists() public {
        if (!forked) return;
        _deployV3();
        (uint8 r,) = sys.v3.check(DEGEN, DEGEN_WETH_V3_1);
        assertEq(r, sys.v3.NOT_VETTED());
        vm.prank(player);
        vm.expectPartialRevert(V3RouteAdapter.NotVetted.selector);
        sys.v3.registerAndList(DEGEN, DEGEN_WETH_V3_1);

        PoolKey memory bk = sys.v3Bridge.bridge(DEGEN_WETH_V3_1);
        PoolKey[] memory route = new PoolKey[](2);
        route[0] = bk;
        route[1] = flipperKey;
        sys.house.setTokenRoute(DEGEN, route); // the owner vouches for it directly
        (bool enabled,, address adapter,) = sys.house.tokenConfig(DEGEN);
        assertTrue(enabled);
        assertEq(adapter, address(0), "owner listing");
        vm.prank(player);
        uint256 got = dex.swapExactIn{value: 0.02 ether}(_one(bk), address(0), DEGEN, 0.02 ether, 1, player);
        vm.prank(player);
        IERC20(DEGEN).approve(address(sys.house), type(uint256).max);
        uint256 id = _flipAndSettle(DEGEN, got / 4, LOSS_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Lost), "settles through v3");
    }

    /// Trusted majors list permissionlessly: WETH through its hookless WETH/USDG v4 pool (3 hops).
    function test_trusted_weth_lists_via_v4() public {
        if (!forked) return;
        PoolKey memory wk = PoolKey(Currency.wrap(RH.WETH), Currency.wrap(RH.USDG), 500, 10, IHooks(address(0)));
        (uint8 r,) = sys.v4.check(RH.WETH, wk);
        assertEq(r, 0, "trusted");
        uint256 g = gasleft();
        vm.prank(player);
        sys.v4.registerAndList(RH.WETH, wk);
        console2.log("registerAndList gas (trusted WETH)", g - gasleft());
        (,,, PoolKey[] memory route) = sys.house.tokenConfig(RH.WETH);
        assertEq(route.length, 3);
    }

    /// Any other token on a hookless v4 pool is refused permissionlessly.
    function test_unvetted_v4_token_refused() public {
        if (!forked) return;
        MockERC20 t = new MockERC20("Random", "RND", 18);
        PoolKey memory k = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(t)), 3000, 60, IHooks(address(0)));
        (uint8 r,) = sys.v4.check(address(t), k);
        assertEq(r, sys.v4.NOT_VETTED());
        vm.expectPartialRevert(V4RouteAdapter.NotVetted.selector);
        sys.v4.registerAndList(address(t), k);
    }

    /// A stock-token ETF (SGOV) through its USDG-paired v3 pool: [SGOV/USDG v3, USDG/ETH v4, ETH/$FLIPPER]
    function test_v3_stock_token_via_usdg_pool() public {
        if (!forked) return;
        _deployV3();
        _v3ListAndFlip(SGOV, SGOV_USDG_V3_03, 0.05 ether, "SGOV (v3 USDG 0.3%, 3 hops)");
    }

    function test_self_launch_on_a_hookless_v4_pool() public {
        if (!forked) return;
        RevenueRouter r = FlipperDeploy.deployRouter(_config());
        FlipperDeploy.deployLiquidityKeeper(pm, r, RH.POSITION_MANAGER, address(0), 0, 0, 0);
        uint256 supply = 1_000_000_000 ether;
        uint160 sqrtP = uint160(_sqrt(supply * (1 << 96) / 2 ether) << 48); // FDV 2 ETH
        (address token, uint256 out) =
            r.launchFlipperV4{value: 0.37 ether}("Flipper", "FLIPPER", supply, supply, 10_000, 200, sqrtP, 0.37 ether, 1, player);
        assertGt(out, 0);
        assertEq(IERC20(token).balanceOf(player), out);
        (PoolKey memory key,,) = r.lpPosition();
        assertGt(pm.getLiquidity(key.toId()), 0);
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────────────

    function _deployV3() internal {
        FlipperDeploy.System memory s = sys;
        FlipperDeploy.deployV3(_config(), s, RH.V3_FACTORY, RH.WETH, address(this));
        sys.v3 = s.v3;
        sys.v3Bridge = s.v3Bridge;
        sys.v3.setFlipperPool(flipperKey);
        sys.v3.setQuote(RH.USDG, _usdgEthKey());
        // stock tokens on v3 pools arrive with our bridge as their pool's hook
        sys.policy.attach(new CodehashVerifier(RH.STOCK_TOKEN_CODEHASH, "robinhood-stock", address(sys.v3Bridge)));
        console2.log("v3 bridge hook", address(sys.v3Bridge));
    }

    function _usdgEthKey() internal pure returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(address(0)), Currency.wrap(RH.USDG), RH.USDG_POOL_FEE, RH.USDG_POOL_TICK_SPACING, IHooks(address(0))
        );
    }

    /// list `token` through its v3 pool, buy some for the player through the bridge, then a win and a loss
    function _v3ListAndFlip(address token, address v3Pool, uint256 ethIn, string memory label) internal {
        (uint8 reason, uint256 depth) = sys.v3.check(token, v3Pool);
        assertEq(reason, 0, "eligible");
        console2.log("v3 pool in-range depth of the pairing currency", depth);
        sys.v3.registerAndList(token, v3Pool);
        (,,, PoolKey[] memory route) = sys.house.tokenConfig(token);
        PoolKey[] memory buyPath;
        if (route.length == 2) {
            buyPath = _one(route[0]);
        } else {
            buyPath = new PoolKey[](2);
            buyPath[0] = route[1]; // ETH → USDG (v4)
            buyPath[1] = route[0]; // USDG → token (v3, bridged)
        }
        vm.prank(player);
        uint256 got = dex.swapExactIn{value: ethIn}(buyPath, address(0), token, ethIn, 1, player);
        vm.prank(player);
        IERC20(token).approve(address(sys.house), type(uint256).max);
        console2.log(string.concat("== ", label, ": win"));
        uint256 before = IERC20(token).balanceOf(player);
        uint256 id = _flipAndSettle(token, got / 4, WIN_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Won), "bought back through v3");
        assertEq(IERC20(token).balanceOf(player), before + got / 4, "paid 2x (net +1x)");
        console2.log(string.concat("== ", label, ": loss"));
        id = _flipAndSettle(token, got / 4, LOSS_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Lost), "sold through v3");
        assertEq(address(sys.v3Bridge).balance, 0, "bridge keeps no ETH");
        assertEq(IERC20(RH.WETH).balanceOf(address(sys.v3Bridge)), 0, "bridge keeps no WETH");
        assertEq(IERC20(token).balanceOf(address(sys.v3Bridge)), 0, "bridge keeps no tokens");
    }

    function _ponsKey(address token) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), 0, 200, IHooks(RH.PONS_V2_MEME_HOOK));
    }

    function _launchGraduatedPonsToken(string memory name, string memory symbol) internal returns (address token) {
        IPonsV2Factory.TokenParams memory p = RH.flipperPonsParams(keccak256(bytes(name)));
        p.name = name;
        p.symbol = symbol;
        address curve;
        (token, curve) = pons.launchToken{value: pons.launchFee()}(p, 0, address(0));
        IPonsV2Curve(curve).buy{value: RH.PONS_CURVE_BUYOUT_ETH}(RH.PONS_CURVE_BUYOUT_ETH, 0, address(this));
        pons.createGraduatedPool(token);
    }

    function _launchPonsToken(string memory name, string memory symbol, uint16 creatorTaxBps, bool buyback)
        internal
        returns (address token)
    {
        IPonsV2Factory.TokenParams memory p = RH.flipperPonsParams(keccak256(bytes(name)));
        p.name = name;
        p.symbol = symbol;
        p.creatorTaxBps = creatorTaxBps;
        p.buybackEnabled = buyback;
        address curve;
        (token, curve) = pons.launchToken{value: pons.launchFee()}(p, 0, address(0));
        // a creator tax is charged on curve buys too: overpay (the curve refunds what it doesn't use)
        IPonsV2Curve(curve).buy{value: 5 ether}(5 ether, 0, address(this));
        pons.createGraduatedPool(token);
    }

    /// the pons operator's periodic fee sweep: zeroes the pool's pending-fee slots (the next swap re-creates them)
    function _sweep(PoolKey memory key) internal {
        IPonsMemeHookSweep hook = IPonsMemeHookSweep(RH.PONS_V2_MEME_HOOK);
        vm.prank(hook.feeSweepOperator());
        try hook.sweepPoolFees(PoolId.unwrap(key.toId()), 1, 1) {}
        catch {
            console2.log("sweep reverted");
        }
    }

    /// a $FLIPPER sell between request and callback: buying the stake back now costs more than the capped
    /// liability, so the win's exact-output buy runs to completion and fails its limit (the fallback path)
    function _dumpFlipper() internal {
        uint256 amt = flipper.balanceOf(address(this)) / 2;
        flipper.approve(address(dex), amt);
        dex.swapExactIn(_one(flipperKey), address(flipper), address(0), amt, 1, address(this));
    }

    function _buy(PoolKey memory key, address token, uint256 ethIn) internal returns (uint256 out) {
        vm.prank(player);
        out = dex.swapExactIn{value: ethIn}(_one(key), address(0), token, ethIn, 1, player);
    }

    function _flip(address token, uint256 amount) internal returns (uint256 id) {
        FlipperHouseBase.Preview memory pv = sys.house.previewFlip(token, amount);
        assertEq(pv.code, 0, "flippable");
        console2.log("route cost (bps) / win chance (bps)", pv.routeCostBps, pv.winChanceBps);
        uint256 fee = sys.house.randomnessFeeFor(token);
        console2.log("randomness fee (wei)", fee);
        vm.prank(player);
        id = sys.house.flip{value: fee * 12 / 10}(token, amount, 0, block.timestamp);
    }

    /// fulfilled exactly like the real wrapper: the adapter gets callbackGasLimit + its overhead, no more
    function _settle(uint256 id, uint256 word) internal {
        (,,,,,,,,,, uint256 requestId,) = sys.house.flips(id);
        uint256 g = gasleft();
        assertTrue(wrapper.fulfillWithWord{gas: 3_000_000}(requestId, word), "callback succeeded");
        console2.log("fulfillment gas", g - gasleft());
    }

    function _flipAndSettle(address token, uint256 amount, uint256 word) internal returns (uint256 id) {
        id = _flip(token, amount);
        _settle(id, word);
    }

    function _status(uint256 id) internal view returns (FlipperHouseBase.Status st) {
        (,,,, st,,,,,,,) = sys.house.flips(id);
    }

    function _one(PoolKey memory a) internal pure returns (PoolKey[] memory r) {
        r = new PoolKey[](1);
        r[0] = a;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
