// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {FlipperHouse} from "../../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../../src/house/FlipperHouseBase.sol";
import {RevenueRouter} from "../../src/RevenueRouter.sol";
import {DevSwapRouter} from "../../src/mocks/DevSwapRouter.sol";
import {HookitRouteAdapter} from "../../src/adapters/HookitRouteAdapter.sol";
import {IEntropyV2} from "../../src/interfaces/IEntropyV2.sol";
import {IHookitLaunchFactory, IHookitMasterHook} from "../../src/interfaces/IHookit.sol";
import {FlipperDeploy} from "../../script/lib/FlipperDeploy.sol";
import {InkAddresses} from "../../script/lib/InkAddresses.sol";
import {IWETH9} from "../../src/interfaces/IUniswapV3.sol";

interface IEntropyAdmin {
    function register(uint128 feeInWei, bytes32 commitment, bytes calldata meta, uint64 chainLength, bytes calldata uri)
        external;
    function setDefaultGasLimit(uint32 gasLimit) external;
    function revealWithCallback(address provider, uint64 seq, bytes32 userContribution, bytes32 providerContribution)
        external;
}

interface IChainlinkFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IFactoryMcap {
    function launchMcapQuoteWei() external view returns (uint256);
}

/// hookit's HktHolderDropVault (0xf457…Cd7F): pushes each token's HKT-holder drop in batches of ≤48 transfers
interface IHktDropVault {
    function secondsUntilDrop(address token) external view returns (uint256);
    function potOf(address token) external view returns (uint256);
    function holderCount() external view returns (uint256);
    function epochSeconds() external view returns (uint32);
}

/// @notice End-to-end on a fork of Ink mainnet: real hookit factory/hooks, real Uniswap v4 PoolManager, real Pyth
///         Entropy (with a locally registered provider so the test can reveal).
///         Run: INK_RPC_URL=https://rpc-gel.inkonchain.com forge test --match-contract InkFork -vv
contract InkForkTest is Test {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant REQUESTED_TOPIC = keccak256("Requested(address,address,uint64,bytes32,uint32,bytes)");
    uint64 internal constant CHAIN_LEN = 256;
    uint256 internal constant WIN_WORD = 9_999;
    uint256 internal constant LOSS_WORD = 0;
    IHktDropVault internal constant DROP_VAULT = IHktDropVault(0xf4574ef795A758E74B1e3815F2E5158945BFCd7F);
    DevSwapRouter internal dex;

    address internal provider = makeAddr("entropyProvider");
    address internal keeper = makeAddr("fortunaKeeper");
    address internal player = makeAddr("player");
    bytes32[] internal chain;
    uint64 internal providerBase;

    FlipperDeploy.System internal sys;
    IERC20 internal flipper;
    IERC20 internal hkt = IERC20(InkAddresses.HKT);
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("INK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        // INK_FORK_BLOCK pins the fork (repeat runs then hit forge's RPC cache instead of the public endpoint)
        uint256 forkBlock = vm.envOr("INK_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        forked = true;
        vm.deal(address(this), 1000 ether);
        vm.deal(player, 100 ether);

        _registerProvider();

        FlipperDeploy.Config memory c = FlipperDeploy.Config({
            poolManager: IPoolManager(InkAddresses.POOL_MANAGER),
            entropy: IEntropyV2(InkAddresses.ENTROPY),
            entropyProvider: provider,
            deployer: address(this),
            owner: address(this),
            proxyAdminOwner: address(this),
            params: InkAddresses.defaultParams()
        });

        // launch $FLIPPER from the router (router = permanent creator) with a $1000 opening buy in the same tx
        RevenueRouter router = FlipperDeploy.deployRouter(c);
        address factory = vm.envOr("HOOKIT_FACTORY", InkAddresses.HOOKIT_FACTORY_V2);
        (uint256 value, uint256 devBuy, uint256 extra) = _openingBuy(factory, 1000e8);
        IHookitLaunchFactory.LaunchParams memory lp = InkAddresses.flipperLaunchParams(devBuy);
        uint256 g = gasleft();
        (address token,,) = router.launchFlipper{value: value}(IHookitLaunchFactory(factory), lp, extra, 1, address(this));
        console2.log("launch+buy gas", g - gasleft());
        flipper = IERC20(token);
        console2.log("FLIPPER", token, "bought", flipper.balanceOf(address(this)) / 1e18);

        sys = FlipperDeploy.deployCore(c, router, flipper, FlipperDeploy.deployPythAdapter(c));
        FlipperDeploy.addHookitRail(sys, InkAddresses.HOOKIT_FACTORY_V1);
        FlipperDeploy.addHookitRail(sys, InkAddresses.HOOKIT_FACTORY_V2);
        // listing policy, as Deploy.s.sol configures it: hookit launches (module policy), trusted majors
        FlipperDeploy.applyVetting(sys, FlipperDeploy.deployInkVerifiers(), InkAddresses.trustedTokens());

        // bankroll: 90% of the opening buy
        uint256 bank = flipper.balanceOf(address(this)) * 9 / 10;
        flipper.approve(address(sys.house), bank);
        sys.house.depositTreasury(bank);

        // player gets HKT and FLIPPER
        deal(address(hkt), player, 200_000 ether);
        flipper.transfer(player, flipper.balanceOf(address(this)));
        vm.startPrank(player);
        hkt.approve(address(sys.house), type(uint256).max);
        flipper.approve(address(sys.house), type(uint256).max);
        vm.stopPrank();
        dex = new DevSwapRouter(IPoolManager(InkAddresses.POOL_MANAGER));
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_launch_wiring() public onlyFork {
        PoolKey memory k = sys.hookit.ethPoolOf(address(flipper));
        address hook = address(k.hooks);
        IHookitMasterHook.LaunchState memory st = IHookitMasterHook(hook).launchState(PoolId.unwrap(k.toId()));
        assertEq(st.creator, address(sys.router), "router is the permanent creator");
        assertTrue(st.initialized);
        assertEq(address(sys.router.flipper()), address(flipper));
        PoolKey[] memory route = _hktRoute();
        assertEq(route.length, 2);
        console2.log("treasury FLIPPER", sys.house.treasury() / 1e18);
        console2.log("max liability", sys.house.maxLiability() / 1e18);
    }

    function test_fork_hkt_listing_and_route_costs() public onlyFork {
        // permissionless listing (probe); fall back to an owner listing so the rest of the suite can run
        try sys.house.listToken(address(hkt), sys.hookit) {
            console2.log("HKT listed permissionlessly");
        } catch (bytes memory err) {
            console2.log("permissionless listing rejected (probe):");
            console2.logBytes(err);
            sys.house.setTokenRoute(address(hkt), _hktRoute());
        }
        uint256[6] memory amts = [uint256(100 ether), 1000 ether, 5000 ether, 20_000 ether, 50_000 ether, 150_000 ether];
        for (uint256 i; i < amts.length; ++i) {
            FlipperHouseBase.Preview memory pv = sys.house.previewFlip(address(hkt), amts[i]);
            console2.log("HKT stake", amts[i] / 1e18);
            console2.log("  code / routeCostBps / winChanceBps", pv.code, pv.routeCostBps, pv.winChanceBps);
        }
    }

    function test_fork_flip_hkt_real_hooks() public onlyFork {
        sys.house.setTokenRoute(address(hkt), _hktRoute());
        _flipUntilBoth(address(hkt), 1000 ether);
    }

    /// hookit pools push HKT-holder drops (up to 48 transfers) inside beforeSwap when a drop is due; whoever swaps
    /// pays. Measure a preview (two full-route quotes) with generous caps.
    function test_fork_measure_quote_gas() public onlyFork {
        FlipperHouseBase.Params memory p = InkAddresses.defaultParams();
        p.swapGasLimit = 9_000_000;
        p.callbackGasLimit = 19_000_000;
        sys.house.setParams(p);
        sys.house.setTokenRoute(address(hkt), _hktRoute());
        for (uint256 i; i < 3; ++i) {
            uint256 g = gasleft();
            FlipperHouseBase.Preview memory pv = sys.house.previewFlip(address(hkt), 1000 ether);
            console2.log("preview code", pv.code, "gas", g - gasleft());
        }
    }

    function test_fork_flip_flipper() public onlyFork {
        uint256 amount = flipper.balanceOf(player) / 50;
        _flipUntilBoth(address(flipper), amount);
    }

    // ── listing policy ─────────────────────────────────────────────────────────────────────────────────

    /// hookit launches list permissionlessly only with settlement-safe, frozen module flags: a plain launch is
    /// vetted; ANTI_MEV (one swap per origin per block) and MAX_TX (capped trades) launches are refused, and so is HKT
    /// (the owner lists it directly, as the tests above do).
    function test_fork_vetting_hookit_modules() public onlyFork {
        address good = _launchHookit("Plain", "PLN", 0);
        address mev = _launchHookit("Guarded", "GRD", 1 << 2);
        address capped = _launchHookit("Capped", "CAP", (1 << 3) | (uint256(100) << 39));
        _drainDrop(address(flipper)); // $FLIPPER's first HKT-holder drop would eat the probe quotes' gas
        uint8 notVetted = sys.hookit.NOT_VETTED();
        uint256 g0 = gasleft();
        (uint8 reason, uint8 path, bytes32 launchpadId,) =
            sys.policy.evaluate(good, sys.hookit.ethPoolOf(good), address(0));
        console2.log("policy.evaluate gas (hookit verifier path)", g0 - gasleft());
        assertEq(reason, 0);
        assertEq(path, sys.policy.PATH_LAUNCHPAD());
        assertEq(launchpadId, bytes32("hookit"));
        assertEq(sys.hookit.check(good), 0, "plain launch vetted");
        assertEq(sys.hookit.check(mev), notVetted, "ANTI_MEV refused");
        assertEq(sys.hookit.check(capped), notVetted, "MAX_TX refused");
        assertEq(sys.hookit.check(address(hkt)), notVetted, "HKT (ANTI_MEV) refused");

        vm.expectRevert(
            abi.encodeWithSelector(HookitRouteAdapter.NotVetted.selector, notVetted, uint8(5)) // FORBIDDEN_MODULES
        );
        sys.house.listToken(mev, sys.hookit);
        uint256 g = gasleft();
        try sys.hookit.registerAndList(good) {
            console2.log("plain hookit launch listed permissionlessly; gas", g - gasleft());
            (bool enabled,,,) = sys.house.tokenConfig(good);
            assertTrue(enabled);
        } catch (bytes memory err) {
            // a brand-new $5k-FDV pool can't fill the house's liquidity probe (PartialFill): the policy passed it,
            // only the house's own liquidity check refuses it
            assertEq(bytes4(err), FlipperHouseBase.ListingProbeFailed.selector, "only the liquidity probe may refuse");
            console2.log("plain launch vetted; refused only by the house's liquidity probe (too thin)");
        }
    }

    /// HKT's canonical route, for the owner's direct listing (HKT isn't vetted: its pool runs ANTI_MEV)
    function _hktRoute() internal view returns (PoolKey[] memory route) {
        route = new PoolKey[](2);
        route[0] = sys.hookit.ethPoolOf(address(hkt));
        route[1] = sys.hookit.ethPoolOf(address(flipper));
    }

    function _launchHookit(string memory name, string memory symbol, uint256 bitmask) internal returns (address token) {
        IHookitLaunchFactory f = IHookitLaunchFactory(InkAddresses.HOOKIT_FACTORY_V2);
        IHookitLaunchFactory.LaunchParams memory lp = InkAddresses.flipperLaunchParams(0.001 ether);
        lp.name = name;
        lp.symbol = symbol;
        lp.bitmask = bitmask;
        (, token,) = f.launch{value: f.launchFee() + 0.001 ether}(lp);
    }

    // ── settlement gas (sizes `swapGasLimit` / `callbackGasLimit`) ─────────────────────────────────────
    // hookit pools push an HKT-holder drop (≤48 transfers per swap, 466 holders → ~10 swaps per drop) inside
    // beforeSwap whenever a token's 15-minute drop epoch has elapsed; whoever swaps pays. Per-attempt gas is read
    // from the trace: INK_RPC_URL=… forge test --match-contract InkFork --match-test test_fork_gas --isolate -vvvv

    /// Measured with generous caps: normal (no drop due), one drop batch due (HKT's, on the HKT hop), both due.
    function test_fork_gas_hkt_paths() public onlyFork {
        FlipperHouseBase.Params memory p = InkAddresses.defaultParams();
        p.swapGasLimit = 9_000_000;
        p.callbackGasLimit = 19_000_000;
        sys.house.setParams(p);
        sys.house.setTokenRoute(address(hkt), _hktRoute());
        _drainDrop(address(flipper));
        _drainDrop(address(hkt));

        console2.log("== HKT normal: win");
        _deliver(_flip(address(hkt), 1000 ether), WIN_WORD, 18_000_000);
        console2.log("== HKT normal: loss");
        _deliver(_flip(address(hkt), 1000 ether), LOSS_WORD, 18_000_000);

        uint256 w = _flip(address(hkt), 1000 ether);
        uint256 l = _flip(address(hkt), 1000 ether);
        vm.warp(block.timestamp + DROP_VAULT.epochSeconds());
        _drainDrop(address(flipper));
        console2.log("== HKT one drop batch (HKT hop): win");
        _deliver(w, WIN_WORD, 18_000_000);
        console2.log("== HKT one drop batch (HKT hop): loss");
        _deliver(l, LOSS_WORD, 18_000_000);

        w = _flip(address(hkt), 1000 ether);
        l = _flip(address(hkt), 1000 ether);
        vm.warp(block.timestamp + DROP_VAULT.epochSeconds());
        console2.log("== HKT two drop batches (both hops): win");
        _deliver(w, WIN_WORD, 18_000_000);
        console2.log("== HKT two drop batches (both hops): loss");
        _deliver(l, LOSS_WORD, 18_000_000);
    }

    /// The default budgets, delivered with exactly the gas Entropy gives the callback: normal and one-batch
    /// settlements swap in kind; with both pools' batches due the attempts run out of their caps and settle safely
    /// (pending win / inventory), and anyone resolves them (inventory: swept into the Dutch auction).
    function test_fork_default_budgets_cover_one_drop_batch() public onlyFork {
        sys.house.setTokenRoute(address(hkt), _hktRoute());
        _drainDrop(address(flipper));
        _drainDrop(address(hkt));
        uint256 g = _entropyGas();
        console2.log("callback gas delivered", g);

        uint256 id = _flip(address(hkt), 1000 ether);
        _deliver(id, WIN_WORD, g);
        assertEq(uint8(_statusOf(id)), uint8(FlipperHouseBase.Status.Won), "normal win");
        id = _flip(address(hkt), 1000 ether);
        _deliver(id, LOSS_WORD, g);
        assertEq(uint8(_statusOf(id)), uint8(FlipperHouseBase.Status.Lost), "normal loss");

        uint256 w = _flip(address(hkt), 1000 ether);
        uint256 l = _flip(address(hkt), 1000 ether);
        vm.warp(block.timestamp + DROP_VAULT.epochSeconds());
        _drainDrop(address(flipper));
        _deliver(w, WIN_WORD, g);
        assertEq(uint8(_statusOf(w)), uint8(FlipperHouseBase.Status.Won), "win with one drop batch");
        _deliver(l, LOSS_WORD, g);
        assertEq(uint8(_statusOf(l)), uint8(FlipperHouseBase.Status.Lost), "loss with one drop batch");

        w = _flip(address(hkt), 1000 ether);
        l = _flip(address(hkt), 1000 ether);
        vm.warp(block.timestamp + DROP_VAULT.epochSeconds());
        _deliver(w, WIN_WORD, g);
        _deliver(l, LOSS_WORD, g);
        FlipperHouseBase.Status sw = _statusOf(w);
        FlipperHouseBase.Status sl = _statusOf(l);
        console2.log("two drop batches: win / loss status", uint8(sw), uint8(sl));
        assertTrue(sw != FlipperHouseBase.Status.Pending && sl != FlipperHouseBase.Status.Pending, "settled");
        _assertSolvent();
        // anyone resolves whatever degraded (their own transactions carry the drop pushes)
        vm.roll(vm.getBlockNumber() + 1);
        vm.startPrank(keeper, keeper);
        if (sw == FlipperHouseBase.Status.WinPending) sys.house.resolvePendingWin{gas: 12_000_000}(w);
        if (sl == FlipperHouseBase.Status.LostInventory) {
            sys.house.sweepInventory(address(hkt), sys.house.inventory(address(hkt)));
        }
        vm.stopPrank();
        assertEq(sys.house.inventory(address(hkt)), 0, "inventory swept into the auction");
        sw = _statusOf(w);
        assertTrue(sw == FlipperHouseBase.Status.Won || sw == FlipperHouseBase.Status.WonFallback, "win resolved");
        _assertSolvent();
    }

    /// WETH through the 1:1 wrapper-hook pool on Ink's real WETH (0x4200…0006) and PoolManager: listed by anyone
    /// once the pool is whitelisted, full odds (only the $FLIPPER hop costs), win and loss settled in kind with the
    /// callback gas Entropy delivers at the default budget.
    function test_fork_weth_wrapper_flips() public onlyFork {
        FlipperDeploy.Config memory c;
        c.poolManager = IPoolManager(InkAddresses.POOL_MANAGER);
        PoolKey memory wk = FlipperDeploy.deployWethWrapper(c, sys, InkAddresses.WETH, address(this));
        sys.v4.setFlipperPool(sys.hookit.ethPoolOf(address(flipper)));
        vm.prank(player);
        sys.v4.registerAndList(InkAddresses.WETH, wk);
        (,,, PoolKey[] memory route) = sys.house.tokenConfig(InkAddresses.WETH);
        assertEq(route.length, 2);
        assertEq(address(route[0].hooks), address(wk.hooks));

        IERC20 weth = IERC20(InkAddresses.WETH);
        vm.startPrank(player);
        IWETH9(InkAddresses.WETH).deposit{value: 1 ether}();
        weth.approve(address(sys.house), type(uint256).max);
        vm.stopPrank();
        _drainDrop(address(flipper));

        uint256 stake = 0.005 ether;
        FlipperHouseBase.Preview memory pv = sys.house.previewFlip(InkAddresses.WETH, stake);
        console2.log("WETH route cost bps", pv.routeCostBps);
        console2.log("WETH win chance bps", pv.winChanceBps);
        uint256 g = _entropyGas();
        uint256 w0 = weth.balanceOf(player);
        uint256 id = _flip(InkAddresses.WETH, stake);
        _deliver(id, WIN_WORD, g);
        assertEq(uint8(_statusOf(id)), uint8(FlipperHouseBase.Status.Won), "win paid in WETH");
        assertEq(weth.balanceOf(player), w0 + stake);
        id = _flip(InkAddresses.WETH, stake);
        _deliver(id, LOSS_WORD, g);
        assertEq(uint8(_statusOf(id)), uint8(FlipperHouseBase.Status.Lost), "WETH sold for $FLIPPER");
        assertEq(weth.balanceOf(address(wk.hooks)), 0);
        _assertSolvent();
    }

    /// Two settlements in one block from the same keeper origin on an anti-MEV pool (HKT): the second one cannot
    /// swap. It must degrade safely (inventory / pending win), never revert or mis-account.
    function test_fork_same_block_anti_mev_collision() public onlyFork {
        sys.house.setTokenRoute(address(hkt), _hktRoute());
        uint256 a = _flip(address(hkt), 1000 ether);
        uint256 b = _flip(address(hkt), 1000 ether);
        vm.roll(vm.getBlockNumber() + 2);
        _reveal(a);
        _reveal(b); // same block, same tx.origin
        (,,,, FlipperHouseBase.Status sa,,,,,,,) = sys.house.flips(a);
        (,,,, FlipperHouseBase.Status sb,,,,,,,) = sys.house.flips(b);
        console2.log("status a / b", uint8(sa), uint8(sb));
        assertTrue(sa != FlipperHouseBase.Status.Pending && sb != FlipperHouseBase.Status.Pending);
        _assertSolvent();
    }

    // ── helpers ─────────────────────────────────────────────────────────────────────────────────────────

    /// swap on `token`'s hookit pool until its HKT-holder drop is fully paid (then nothing is due for an epoch)
    function _drainDrop(address token) internal {
        PoolKey[] memory path = new PoolKey[](1);
        path[0] = sys.hookit.ethPoolOf(token);
        for (uint256 i; i < 16 && DROP_VAULT.secondsUntilDrop(token) == 0 && DROP_VAULT.potOf(token) != 0; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            dex.swapExactIn{value: 1e14}(path, address(0), token, 1e14, 1, address(this));
        }
        vm.roll(vm.getBlockNumber() + 1); // anti-MEV: one swap per origin per pool per block
        console2.log("drop drained: seconds until the next", DROP_VAULT.secondsUntilDrop(token));
    }

    /// what Entropy's first attempt gives the house for a token flip: the request's gas limit (callback budget + the
    /// adapter's 60k, rounded up to 10k) minus the adapter's own ~21k, of which 63/64 reach the house
    function _entropyGas() internal view returns (uint256) {
        uint256 limit = (uint256(sys.house.params().callbackGasLimit) + 60_000 + 9_999) / 10_000 * 10_000;
        return (limit - 21_000) * 63 / 64;
    }

    /// deliver a chosen outcome as the adapter's first attempt would, with `gas_` for the house callback. Everything
    /// a settlement touches is cooled first, so gas is accounted as in a fresh fulfilment transaction (the drop
    /// drains don't run under `--isolate`: forge's isolation fails mid-drain on this fork).
    function _deliver(uint256 id, uint256 word, uint256 gas_) internal {
        (,,,,,,,,,, uint256 requestId,) = sys.house.flips(id);
        vm.roll(vm.getBlockNumber() + 1);
        address[16] memory touched = [
            address(sys.house),
            address(sys.randomness),
            InkAddresses.POOL_MANAGER,
            address(hkt),
            address(flipper),
            address(DROP_VAULT),
            InkAddresses.HOOKIT_HOOK_V1,
            InkAddresses.HOOKIT_HOOK_V2,
            InkAddresses.HOOKIT_FEE_ESCROW,
            0xaf9AA3268aa4fCc2a71cE82a24cf717b9E8746E0, // ProtocolRevenueDistributor
            0xb445A93Ae8E7aDdeBD84Fc3c06eBb42251e2d584, // HolderAirdropVault
            0x843150EF540f2CF296e6fFCd8020938C86f903d7,
            0x784634C0916a97076bbA3A4Ff5fB51eA2c3DEC34,
            0xa4BDb2FDA7c6fB60184D41d185CD9529c2057b73,
            0x86a8FDbAE87c8E6656AB12582f16Ada9B732C3f5,
            0x8F23aa86C058341B64133b1208b10FaB720782CA
        ];
        for (uint256 i; i < touched.length; ++i) {
            vm.cool(touched[i]);
        }
        vm.prank(address(sys.randomness), keeper);
        sys.house.onRandomness{gas: gas_}(requestId, word, false);
        console2.log("status", uint8(_statusOf(id)));
    }

    function _statusOf(uint256 id) internal view returns (FlipperHouseBase.Status st) {
        (,,,, st,,,,,,,) = sys.house.flips(id);
    }

    function _flipUntilBoth(address token, uint256 amount) internal {
        bool sawWin;
        bool sawLoss;
        for (uint256 i; i < 16 && !(sawWin && sawLoss); ++i) {
            uint256 id = _flip(token, amount);
            vm.roll(vm.getBlockNumber() + 2);
            uint256 g = gasleft();
            _reveal(id);
            uint256 used = g - gasleft();
            (,,,, FlipperHouseBase.Status st,,,,,,,) = sys.house.flips(id);
            console2.log("status", uint8(st), "reveal gas", used);
            if (st == FlipperHouseBase.Status.Won) sawWin = true;
            if (st == FlipperHouseBase.Status.Lost) sawLoss = true;
            assertTrue(
                st == FlipperHouseBase.Status.Won || st == FlipperHouseBase.Status.Lost, "settled through the real pools"
            );
            _assertSolvent();
        }
        assertTrue(sawWin && sawLoss, "observed both outcomes");
    }

    function _flip(address token, uint256 amount) internal returns (uint256 id) {
        FlipperHouseBase.Preview memory pv = sys.house.previewFlip(token, amount);
        assertEq(pv.code, 0, "preview ok");
        vm.recordLogs();
        vm.prank(player, player);
        uint256 g = gasleft();
        id = sys.house.flip{value: pv.randomnessFee}(token, amount, uint16(pv.winChanceBps), block.timestamp);
        console2.log("flip gas", g - gasleft(), "fee (wei)", pv.randomnessFee);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == REQUESTED_TOPIC && logs[i].emitter == InkAddresses.ENTROPY) {
                (bytes32 userContribution,,) = abi.decode(logs[i].data, (bytes32, uint32, bytes));
                uint64 seq = uint64(uint256(logs[i].topics[3]));
                userContributions[seq] = userContribution;
            }
        }
    }

    mapping(uint64 => bytes32) internal userContributions;

    function _reveal(uint256 flipId) internal {
        (,,,,,,,,,, uint256 requestId,) = sys.house.flips(flipId);
        uint64 seq = uint64(requestId);
        vm.prank(keeper, keeper);
        IEntropyAdmin(InkAddresses.ENTROPY).revealWithCallback{gas: 8_000_000}(
            provider, seq, userContributions[seq], chain[seq - providerBase]
        );
    }

    function _registerProvider() internal {
        chain = new bytes32[](CHAIN_LEN + 1);
        chain[CHAIN_LEN] = keccak256("flipper.family local provider secret");
        for (uint256 i = CHAIN_LEN; i > 0; --i) {
            chain[i - 1] = keccak256(bytes.concat(chain[i]));
        }
        vm.startPrank(provider);
        IEntropyAdmin(InkAddresses.ENTROPY).register(1, chain[0], "", CHAIN_LEN, "");
        IEntropyAdmin(InkAddresses.ENTROPY).setDefaultGasLimit(500_000);
        vm.stopPrank();
        // first request after registration gets sequenceNumber = base + 1
        providerBase = 0;
    }

    function _openingBuy(address factory, uint256 usdX8) internal view returns (uint256 value, uint256 devBuy, uint256 extra) {
        (, int256 px,,,) = IChainlinkFeed(InkAddresses.CHAINLINK_ETH_USD).latestRoundData();
        uint256 totalEth = usdX8 * 1e18 / uint256(px);
        uint256 maxDev = IFactoryMcap(factory).launchMcapQuoteWei() * 250 / 10_000 * 99 / 100;
        devBuy = totalEth < maxDev ? totalEth : maxDev;
        extra = totalEth - devBuy;
        value = IHookitLaunchFactory(factory).launchFee() + devBuy + extra;
    }

    function _assertSolvent() internal view {
        FlipperHouse h = sys.house;
        uint256 fBal = flipper.balanceOf(address(h));
        assertGe(fBal, h.treasury() + h.rewardsAccrued() + h.escrowed(address(flipper)) + h.claimableTotal(address(flipper)));
        uint256 tBal = hkt.balanceOf(address(h));
        assertGe(tBal, h.escrowed(address(hkt)) + h.inventory(address(hkt)) + h.claimableTotal(address(hkt)));
        assertLe(h.reserved(), h.treasury());
    }
}

import {PoolId} from "v4-core/types/PoolId.sol";
