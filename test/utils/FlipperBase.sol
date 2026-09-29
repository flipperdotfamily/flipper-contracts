// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {FlipperHouse} from "../../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../../src/house/FlipperHouseBase.sol";
import {RevenueRouter} from "../../src/RevenueRouter.sol";
import {PythEntropyAdapter} from "../../src/randomness/PythEntropyAdapter.sol";
import {FlipperLens} from "../../src/lens/FlipperLens.sol";
import {TreasuryVault} from "../../src/TreasuryVault.sol";
import {DutchAuctionConverter} from "../../src/DutchAuctionConverter.sol";
import {FlipperDeploy} from "../../script/lib/FlipperDeploy.sol";
import {IEntropyV2} from "../../src/interfaces/IEntropyV2.sol";
import {IFlipRewards} from "../../src/interfaces/IFlipRewards.sol";
import {MockEntropyV2} from "../../src/mocks/MockEntropyV2.sol";
import {ToggleHook} from "./TestHooks.sol";
import {LocalPositionManager} from "./LocalPositionManager.sol";
import {LiquidityKeeper} from "../../src/LiquidityKeeper.sol";

abstract contract FlipperBase is Test {
    uint256 internal constant BPS = 10_000;
    int24 internal constant TS = 200;
    uint24 internal constant FEE = 10_000; // 1% pools, like a launchpad pool
    uint256 internal constant WIN_WORD = 9_999; // roll 9999 → always a win
    uint256 internal constant PAYOUT = 20_500; // $FLIPPER flips pay 2.05x
    uint256 internal constant WIN_COST = PAYOUT - 10_000; // a $FLIPPER win costs the bankroll 1.05x the stake
    uint256 internal constant LOSS_WORD = 0; // roll 0 → always a loss

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal lp;
    PoolSwapTest internal swapper;

    MockERC20 internal flipperToken;
    MockERC20 internal tokenT;
    MockERC20 internal hookit;

    ToggleHook internal toggle;
    PoolKey internal flipperPool; // ETH / FLIPPER
    PoolKey internal tPool; // ETH / T (behind ToggleHook)
    PoolKey internal hookitPool; // ETH / HOOKIT

    MockEntropyV2 internal entropy;
    PythEntropyAdapter internal adapter;
    FlipperHouse internal house;
    RevenueRouter internal router;
    FlipperLens internal lens;
    TreasuryVault internal vault;
    DutchAuctionConverter internal converter;
    FlipperDeploy.System internal sys;
    address internal proxyAdminOwner = makeAddr("proxyAdminOwner");

    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    address internal provider = makeAddr("provider");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal mallory = makeAddr("mallory");

    function defaultParams() internal pure returns (FlipperHouseBase.Params memory p) {
        p.baseWinChanceBps = 4500;
        p.minWinChanceBps = 4000;
        p.flipperPayoutBps = uint16(PAYOUT);
        p.minHouseEdgeBps = 200; // ≥2% expected profit per flip after every swap cost the house sponsors
        p.maxRouteCostBps = 1000;
        p.lossSlippageBps = 500;
        p.maxBetBps = 500;
        p.kellyBps = 5000; // half Kelly
        p.rewardsShareBps = 5000; // half of each flip's expected profit → $FLIPPER holders (as HKT)
        p.listingMaxRouteCostBps = 400; // permissionless listing: probe round trip ≤ 4%
        p.listingProbeBps = 2000;
        p.callbackGasLimit = 2_000_000;
        p.swapGasLimit = 800_000;
        p.guardianCancelDelay = 1 days;
        p.playerCancelDelay = 7 days;
        p.minListingProbe = 1e18;
        p.flipperCallbackGasLimit = 400_000;
        p.pendingTimeout = 1 days;
    }

    function setUp() public virtual {
        vm.deal(address(this), 1e30);
        manager = IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        lp = new PoolModifyLiquidityTest(manager);
        swapper = new PoolSwapTest(manager);

        flipperToken = new MockERC20("Flipper", "FLIPPER", 18);
        tokenT = new MockERC20("Target", "TGT", 18);
        hookit = new MockERC20("Hookit", "HOOKIT", 18);

        address hookAddr = address(uint160(Hooks.BEFORE_SWAP_FLAG) | uint160(0x4444 << 144));
        deployCodeTo("test/utils/TestHooks.sol:ToggleHook", hookAddr);
        toggle = ToggleHook(hookAddr);

        // 1 ETH = 1,000,000 FLIPPER ; 1 ETH = 10,000,000 T ; 1 ETH = 100,000 HOOKIT
        flipperPool = _pool(flipperToken, IHooks(address(0)), 1_000_000, 200 ether);
        tPool = _pool(tokenT, IHooks(hookAddr), 10_000_000, 200 ether);
        hookitPool = _pool(hookit, IHooks(address(0)), 100_000, 200 ether);

        entropy = new MockEntropyV2(provider, 5e12, 1e7);
        FlipperDeploy.Config memory c = FlipperDeploy.Config({
            poolManager: manager,
            entropy: IEntropyV2(address(entropy)),
            entropyProvider: provider,
            deployer: address(this),
            owner: owner,
            proxyAdminOwner: proxyAdminOwner,
            params: defaultParams()
        });
        RevenueRouter r = FlipperDeploy.deployRouter(c);
        sys = FlipperDeploy.deployCore(c, r, IERC20(address(flipperToken)), FlipperDeploy.deployPythAdapter(c));
        house = sys.house;
        adapter = PythEntropyAdapter(address(sys.randomness));
        router = sys.router;
        lens = sys.lens;
        vault = sys.vault;
        converter = sys.converter;
        house.setTokenRoute(address(tokenT), _route1(tPool, flipperPool));
        FlipperDeploy.handOver(sys, c);
        vm.startPrank(owner);
        house.acceptOwnership();
        adapter.acceptOwnership();
        router.acceptOwnership();
        sys.hookit.acceptOwnership();
        sys.v4.acceptOwnership();
        vault.acceptOwnership();
        sys.policy.acceptOwnership();
        converter.acceptOwnership();
        sys.partners.acceptOwnership();
        sys.v4.setFlipperPool(flipperPool);
        // the unit suites stack many flips per player; the per-player cap and the dust floor have their own tests
        house.setFlipLimits(255, 0);
        vm.stopPrank();

        // bankroll: 100M FLIPPER (= 100 ETH)
        flipperToken.mint(address(this), 100_000_000 ether);
        flipperToken.approve(address(house), type(uint256).max);
        house.depositTreasury(100_000_000 ether);

        for (uint256 i; i < 3; ++i) {
            address u = [alice, bob, mallory][i];
            vm.deal(u, 1000 ether);
            flipperToken.mint(u, 50_000_000 ether);
            tokenT.mint(u, 500_000_000 ether);
            vm.startPrank(u);
            flipperToken.approve(address(house), type(uint256).max);
            tokenT.approve(address(house), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ── pools ────────────────────────────────────────────────────────────────────────────────────────

    function _pool(MockERC20 token, IHooks hooks, uint256 tokensPerEth, uint256 ethDepth)
        internal
        returns (PoolKey memory key)
    {
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), FEE, TS, hooks);
        uint160 sqrtP = uint160(_sqrt(tokensPerEth) * 2 ** 96);
        manager.initialize(key, sqrtP);
        token.mint(address(this), type(uint128).max);
        token.approve(address(lp), type(uint256).max);
        token.approve(address(swapper), type(uint256).max);
        _addFullRange(key, ethDepth, tokensPerEth);
    }

    function _addFullRange(PoolKey memory key, uint256 ethDepth, uint256 tokensPerEth) internal {
        // full range: L ≈ sqrt(x·y) = ethDepth · sqrt(price)
        int256 liq = int256(ethDepth * _sqrt(tokensPerEth));
        lp.modifyLiquidity{value: ethDepth * 101 / 100}(
            key,
            IPoolManager.ModifyLiquidityParams(TickMath.minUsableTick(TS), TickMath.maxUsableTick(TS), liq, 0),
            ""
        );
    }

    function _removeFullRange(PoolKey memory key, uint256 ethDepth, uint256 tokensPerEth) internal {
        int256 liq = int256(ethDepth * _sqrt(tokensPerEth));
        lp.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(TickMath.minUsableTick(TS), TickMath.maxUsableTick(TS), -liq, 0),
            ""
        );
    }

    /// @dev market trade through the pool from the test contract: buy `token` with `ethIn` ETH
    function _buyWithEth(PoolKey memory key, uint256 ethIn) internal {
        swapper.swap{value: ethIn}(
            key,
            IPoolManager.SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    /// @dev market trade: sell `tokenIn` of currency1 for ETH
    function _sellForEth(PoolKey memory key, uint256 tokenIn) internal {
        swapper.swap(
            key,
            IPoolManager.SwapParams(false, -int256(tokenIn), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _single(PoolKey memory a) internal pure returns (PoolKey[] memory r) {
        r = new PoolKey[](1);
        r[0] = a;
    }

    function _route1(PoolKey memory a, PoolKey memory b) internal pure returns (PoolKey[] memory r) {
        r = new PoolKey[](2);
        r[0] = a;
        r[1] = b;
    }

    // ── launch position ──────────────────────────────────────────────────────────────────────────────

    address internal posm;

    /// @dev a local v4 PositionManager on `manager` (and the canonical Permit2), deployed once
    function _positionManager() internal returns (address) {
        if (posm == address(0)) posm = LocalPositionManager.deploy(manager);
        return posm;
    }

    /// @dev a LiquidityKeeper for `r` (no UNCX lock), set as its keeper; `r` must be launchable and owned here
    function _lpKeeper(RevenueRouter r) internal returns (LiquidityKeeper) {
        return FlipperDeploy.deployLiquidityKeeper(manager, r, _positionManager(), address(0), 0, 0, 0);
    }

    // ── flips ────────────────────────────────────────────────────────────────────────────────────────

    function _flip(address player, address token, uint256 amount) internal returns (uint256 flipId) {
        uint256 fee = house.randomnessFeeFor(token);
        vm.prank(player);
        flipId = house.flip{value: fee}(token, amount, 0, block.timestamp);
    }

    function _seq(uint256 flipId) internal view returns (uint64) {
        (,,,,,,,,,, uint256 requestId,) = house.flips(flipId);
        return uint64(requestId);
    }

    function _status(uint256 flipId) internal view returns (FlipperHouseBase.Status st) {
        (,,,, st,,,,,,,) = house.flips(flipId);
    }

    function _reveal(uint256 flipId, uint256 word) internal {
        entropy.reveal{gas: 5_000_000}(provider, _seq(flipId), bytes32(word));
    }

    // ── invariants ───────────────────────────────────────────────────────────────────────────────────

    /// @dev The ETH the house's own swaps moved through the $FLIPPER pool, read independently of the house from the
    ///      PoolManager's `Swap` events (sender = the house): + ETH it paid in (sales), − ETH it took out (buys).
    function _houseHopEth(Vm.Log[] memory logs) internal view returns (int256 net) {
        bytes32 sig = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        bytes32 id = keccak256(abi.encode(flipperPool));
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(manager) || l.topics.length < 3 || l.topics[0] != sig || l.topics[1] != id) continue;
            if (address(uint160(uint256(l.topics[2]))) != address(house)) continue;
            (int128 a0,,,,,) = abi.decode(l.data, (int128, int128, uint160, uint128, int24, uint24));
            net -= int256(a0);
        }
    }

    function _assertSolvent() internal view {
        uint256 fBal = flipperToken.balanceOf(address(house));
        uint256 fAccounted = house.treasury() + house.rewardsAccrued() + house.escrowed(address(flipperToken))
            + house.claimableTotal(address(flipperToken)) + house.partnerAccruedTotal();
        assertGe(fBal, fAccounted, "FLIPPER under-collateralised");
        uint256 tBal = tokenT.balanceOf(address(house));
        uint256 tAccounted = house.escrowed(address(tokenT)) + house.inventory(address(tokenT))
            + house.claimableTotal(address(tokenT));
        assertGe(tBal, tAccounted, "T under-collateralised");
        assertLe(house.reserved(), house.treasury(), "reserved > treasury");
        // the monitoring view agrees
        assertEq(lens.surplus(house, address(flipperToken)), int256(fBal) - int256(fAccounted), "lens FLIPPER surplus");
        assertEq(lens.surplus(house, address(tokenT)), int256(tBal) - int256(tAccounted), "lens T surplus");
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

    receive() external payable {}
}
