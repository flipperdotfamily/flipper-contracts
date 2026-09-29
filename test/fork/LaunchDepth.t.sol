// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {FlipperHouse} from "../../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../../src/house/FlipperHouseBase.sol";
import {RevenueRouter} from "../../src/RevenueRouter.sol";
import {LiquidityKeeper} from "../../src/LiquidityKeeper.sol";
import {V4RouteAdapter} from "../../src/adapters/V4RouteAdapter.sol";
import {RobinhoodAddresses as RH} from "../../script/lib/RobinhoodAddresses.sol";

interface IFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IWETH {
    function deposit() external payable;
}

/// @notice The largest flip each token accepts right after launch (previewFlip's verdict: the route cap, the pool's
///         depth and the half-Kelly bet cap together), measured on a stack Deploy.s.sol deployed
///         (production mode) on a Robinhood Chain fork, and whether a win at that size really routes (settles `Won`,
///         not `WinPending` / `WonFallback`). Rows: the single-sided launch as deployed, then the same launch with an
///         ETH seed next to the $FLIPPER at the start price (emulating a two-sided router position: the router's own
///         liquidity continued above the start price, as far as the ETH seed reaches). Each row can then be grown by
///         organic buys (ETH → $FLIPPER through the pool) to higher market caps and measured again.
///   Env: LAUNCH_DEPTH_SEEDS  ETH seeds in USD, comma-separated (default 0,5000,25000,100000; 0 = as deployed)
///        LAUNCH_DEPTH_GROW   market caps in USD to buy the price up to, in order (default none)
///   Run (one FDV per deploy):
///     anvil --fork-url https://rpc.ordofi.network --fork-block-number 72650000 --chain-id 31338 --port 18747
///     DEPLOYER_PRIVATE_KEY=<anvil key 0> V4_POOL_BPS=3333 V4_START_MCAP_USD=<fdv> DEPLOYMENT_FILE=deployments/<f>.json \
///       forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:18747 --broadcast
///     LAUNCH_DEPTH_RPC=http://127.0.0.1:18747 LAUNCH_DEPTH_HOUSE=<manifest .contracts.house> LAUNCH_DEPTH_FDV=<fdv> \
///       forge test --match-contract LaunchDepth -vv --no-storage-caching
contract LaunchDepthForkTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager internal constant PM = IPoolManager(RH.POOL_MANAGER);
    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    uint256 internal constant WIN_WORD = 9_999;

    FlipperHouse internal house;
    address internal flipper;
    address internal rnd;
    RevenueRouter internal router;
    V4RouteAdapter internal v4;
    PoolKey internal fKey;
    PoolKey internal tKey;
    int24 internal lower;
    int24 internal upper;
    uint256 internal ethUsd; // 8 decimals
    uint256 internal fdv;
    PoolModifyLiquidityTest internal lp;
    PoolSwapTest internal swapper;
    address internal player = makeAddr("depth-player");
    bool internal forked;

    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("LAUNCH_DEPTH_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        house = FlipperHouse(payable(vm.envAddress("LAUNCH_DEPTH_HOUSE")));
        fdv = vm.envOr("LAUNCH_DEPTH_FDV", uint256(0));
        flipper = address(house.flipper());
        rnd = address(house.randomness());
        router = RevenueRouter(payable(house.revenueRouter()));
        (fKey, lower, upper) = router.lpPosition();
        (,, address adapter,) = house.tokenConfig(RH.WETH);
        v4 = V4RouteAdapter(adapter);
        (, int256 px,,,) = IFeed(RH.CHAINLINK_ETH_USD).latestRoundData();
        ethUsd = uint256(px);
        tKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(TSLA), 1800, 18, IHooks(address(0)));
        lp = new PoolModifyLiquidityTest(PM);
        swapper = new PoolSwapTest(PM);
        vm.deal(address(this), 100_000 ether);
    }

    function test_launch_depth() public {
        if (!forked) return;
        // a stock token lists permissionlessly through the attached verifier
        v4.registerAndList(TSLA, tKey);
        console2.log("start FDV (USD)", fdv, "ETH/USD (8 dec)", ethUsd);
        uint256[] memory dflt = new uint256[](4);
        (dflt[1], dflt[2], dflt[3]) = (5_000, 25_000, 100_000);
        uint256[] memory seeds = vm.envOr("LAUNCH_DEPTH_SEEDS", ",", dflt);
        uint256[] memory grow = vm.envOr("LAUNCH_DEPTH_GROW", ",", new uint256[](0));
        for (uint256 i; i < seeds.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 placed = seeds[i] == 0 ? 0 : _seedEth(seeds[i] * 1e8 * 1e18 / ethUsd);
            console2.log("===== ETH seed (USD) asked / placed", seeds[i], _ethToUsd(placed));
            _row("at launch", placed, 0);
            uint256 bought;
            for (uint256 j; j < grow.length; ++j) {
                bought += _growTo(grow[j]);
                _row("grown to FDV (USD)", placed, grow[j]);
                console2.log("  organic buys so far (USD)", _ethToUsd(bought));
            }
            vm.revertToState(snap);
        }
    }

    // ── one row ──────────────────────────────────────────────────────────────────────────────────────────

    function _row(string memory label, uint256 placedWei, uint256 target) internal {
        console2.log(string.concat("----- ", label), target);
        uint256 supply = IERC20(flipper).totalSupply();
        console2.log("  FDV now (USD)", _flipperUsd(supply));
        console2.log("  treasury share of supply (bps) / bankroll (USD)", house.treasury() * 10_000 / supply, _flipperUsd(house.treasury()));
        console2.log("  max liability (USD)", _flipperUsd(house.maxLiability()));
        console2.log("  pool ETH (router position + seed, USD)", _ethToUsd(_routerEth() + _seedLeft(placedWei)));
        _measure("WETH", RH.WETH, 300 ether);
        _measure("TSLA", TSLA, _fromEth(TSLA, 300 ether));
        _measure("FLIPPER", flipper, house.treasury());
    }

    function _measure(string memory label, address token, uint256 hi) internal {
        (uint256 amt, uint8 codeAbove, uint256 rc) = _maxStake(token, hi);
        uint256 usd = _valueUsd(token, amt);
        uint8 st = amt == 0 ? 0 : _forceWin(token, amt);
        console2.log(string.concat("  ", label, " max stake (USD) / route cost bps / code above"), usd, rc, codeAbove);
        console2.log(string.concat("  ", label, " forced win at max: status (2 = Won)"), st);
    }

    /// @return amt the largest stake previewFlip accepts; codeAbove its reject code just above; rc route cost at amt
    function _maxStake(address token, uint256 hi) internal returns (uint256 amt, uint8 codeAbove, uint256 rc) {
        uint256 lo = hi / 1e9;
        if (house.previewFlip(token, lo).code != 0) return (0, house.previewFlip(token, lo).code, 0);
        FlipperHouseBase.Preview memory top = house.previewFlip(token, hi);
        if (top.code == 0) return (hi, 0, top.routeCostBps);
        codeAbove = top.code;
        // geometric then linear bisection (the reject edge spans many orders of magnitude across rows)
        for (uint256 i; i < 48 && hi - lo > lo / 2000; ++i) {
            uint256 mid = hi / lo > 4 ? _sqrt(lo * hi) : (lo + hi) / 2;
            FlipperHouseBase.Preview memory pv = house.previewFlip(token, mid);
            if (pv.code == 0) {
                lo = mid;
                rc = pv.routeCostBps;
            } else {
                hi = mid;
                codeAbove = pv.code;
            }
        }
        amt = lo;
        if (rc == 0) rc = house.previewFlip(token, lo).routeCostBps;
    }

    function _forceWin(address token, uint256 amt) internal returns (uint8) {
        uint256 snap = vm.snapshotState();
        uint256 fee = house.randomnessFeeFor(token);
        vm.deal(player, amt + fee + 1 ether);
        if (token == RH.WETH) {
            vm.prank(player);
            IWETH(RH.WETH).deposit{value: amt}();
        } else if (token == flipper) {
            // bought through the pool (the deployer may keep none); the snapshot undoes the buy
            swapper.swap{value: 50_000 ether}(
                fKey, IPoolManager.SwapParams(true, int256(amt), TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
            );
            IERC20(flipper).transfer(player, amt);
        } else {
            deal(token, player, amt);
        }
        vm.startPrank(player, player);
        IERC20(token).approve(address(house), amt);
        uint256 id = house.flip{value: fee}(token, amt, 0, block.timestamp);
        vm.stopPrank();
        (,,,,,,,,,, uint256 req,) = house.flips(id);
        vm.prank(rnd);
        house.onRandomness{gas: 5_000_000}(req, WIN_WORD, false);
        (,,,, FlipperHouseBase.Status st,,,,,,,) = house.flips(id);
        vm.revertToState(snap);
        return uint8(st);
    }

    // ── organic buys ─────────────────────────────────────────────────────────────────────────────────────

    /// @dev buy $FLIPPER with ETH through the pool until its FDV reaches `fdvUsd`; returns the ETH spent
    function _growTo(uint256 fdvUsd) internal returns (uint256 spent) {
        uint256 fdvWei = fdvUsd * 1e8 * 1e18 / ethUsd;
        uint160 target = uint160(_sqrt(FullMath.mulDiv(IERC20(flipper).totalSupply(), 1 << 96, fdvWei) << 96));
        (uint160 sp,,,) = PM.getSlot0(fKey.toId());
        if (target >= sp) return 0; // already there (FDV up = $FLIPPER per ETH down)
        uint256 budget = 50_000 ether;
        int256 d0 = swapper.swap{value: budget}(
            fKey,
            IPoolManager.SwapParams(true, -int256(budget), target),
            PoolSwapTest.TestSettings(false, false),
            ""
        ).amount0();
        spent = uint256(-d0);
    }

    // ── the two-sided emulation ──────────────────────────────────────────────────────────────────────────

    /// @dev continue the router's liquidity above its range with the same L, as far as `eth` reaches (the whole
    ///      range above when it would reach further): what one two-sided position seeded with `eth` would hold
    function _seedEth(uint256 eth) internal returns (uint256 placed) {
        uint128 liq = _lpLiquidity();
        uint160 a = TickMath.getSqrtPriceAtTick(upper);
        uint256 l96 = uint256(liq) << 96;
        int24 top = TickMath.maxUsableTick(fKey.tickSpacing);
        int24 tU = top;
        if (eth * a < l96) {
            // amount0 = L·2^96·(1/a − 1/u)  ⇒  u = a·L·2^96 / (L·2^96 − eth·a)
            uint256 u = FullMath.mulDiv(a, l96, l96 - eth * a);
            if (u < TickMath.MAX_SQRT_PRICE) {
                tU = TickMath.getTickAtSqrtPrice(uint160(u));
                tU = (tU / fKey.tickSpacing) * fKey.tickSpacing; // round down: never more than `eth`
                if (tU > top) tU = top;
            }
        }
        uint256 before = address(this).balance;
        lp.modifyLiquidity{value: eth}(fKey, IPoolManager.ModifyLiquidityParams(upper, tU, int256(uint256(liq)), 0), "");
        placed = before - address(this).balance;
        (seeded, seedUpper) = (true, tU);
    }

    // ── valuation ────────────────────────────────────────────────────────────────────────────────────────

    bool internal seeded;
    int24 internal seedUpper; // upper tick of the seeded range

    /// @dev ETH still in the seeded range above the router's position (all of it until the price enters the range)
    function _seedLeft(uint256 placedWei) internal view returns (uint256) {
        if (placedWei == 0 || !seeded) return 0;
        (uint160 sp,,,) = PM.getSlot0(fKey.toId());
        uint160 a = TickMath.getSqrtPriceAtTick(upper);
        if (sp <= a) return placedWei;
        (uint128 liq,,) = PM.getPositionInfo(fKey.toId(), address(lp), upper, seedUpper, bytes32(0));
        uint160 u = TickMath.getSqrtPriceAtTick(seedUpper);
        return sp >= u ? 0 : SqrtPriceMath.getAmount0Delta(sp, u, liq, false);
    }

    /// @dev ETH in the router's position (bought in since launch): what selling $FLIPPER back can take out of it
    function _routerEth() internal view returns (uint256) {
        uint128 liq = _lpLiquidity();
        (uint160 sp,,,) = PM.getSlot0(fKey.toId());
        uint160 a = TickMath.getSqrtPriceAtTick(upper);
        return sp < a ? SqrtPriceMath.getAmount0Delta(sp, a, liq, false) : 0;
    }

    /// @dev the launch position's liquidity (a PositionManager NFT held by the router's LiquidityKeeper)
    function _lpLiquidity() internal view returns (uint128 liq) {
        (,,,, liq) = LiquidityKeeper(payable(router.liquidityKeeper())).position();
    }

    function _ethToUsd(uint256 wei_) internal view returns (uint256) {
        return wei_ * ethUsd / 1e8 / 1e18;
    }

    /// @dev token wei per ETH wei at the pool's spot price (currency0 = ETH)
    function _perEth(PoolKey memory key, uint256 ethWei) internal view returns (uint256) {
        (uint160 sp,,,) = PM.getSlot0(key.toId());
        return FullMath.mulDiv(FullMath.mulDiv(ethWei, sp, 1 << 96), sp, 1 << 96);
    }

    function _toEth(PoolKey memory key, uint256 amt) internal view returns (uint256) {
        (uint160 sp,,,) = PM.getSlot0(key.toId());
        return FullMath.mulDiv(FullMath.mulDiv(amt, 1 << 96, sp), 1 << 96, sp);
    }

    function _fromEth(address token, uint256 ethWei) internal view returns (uint256) {
        return token == TSLA ? _perEth(tKey, ethWei) : _perEth(fKey, ethWei);
    }

    function _flipperUsd(uint256 amt) internal view returns (uint256) {
        return _ethToUsd(_toEth(fKey, amt));
    }

    function _valueUsd(address token, uint256 amt) internal view returns (uint256) {
        if (token == RH.WETH) return _ethToUsd(amt);
        if (token == TSLA) return _ethToUsd(_toEth(tKey, amt));
        return _flipperUsd(amt);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
