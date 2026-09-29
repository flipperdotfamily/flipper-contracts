// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {FlipperBase} from "./utils/FlipperBase.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {WethWrapperHook} from "../src/adapters/WethWrapperHook.sol";
import {FlipperDeploy} from "../script/lib/FlipperDeploy.sol";

/// @notice WETH flips through the 1:1 wrapper-hook pool: route [WETH/ETH wrapper, ETH/$FLIPPER].
contract WethWrapperTest is FlipperBase {
    WETH internal weth;
    WethWrapperHook internal hook;
    PoolKey internal wkey;

    function setUp() public override {
        super.setUp();
        weth = new WETH();
        address hookAddr = address(FlipperDeploy.V3_BRIDGE_FLAGS | (uint160(0x3e3e) << 144));
        deployCodeTo("src/adapters/WethWrapperHook.sol:WethWrapperHook", abi.encode(manager, address(weth)), hookAddr);
        hook = WethWrapperHook(payable(hookAddr));
        wkey = hook.initialize();
        vm.startPrank(owner);
        sys.policy.pinHook(address(hook), true);
        sys.policy.setPoolWhitelisted(wkey, true);
        vm.stopPrank();

        vm.startPrank(alice);
        weth.deposit{value: 100 ether}();
        weth.approve(address(house), type(uint256).max);
        vm.stopPrank();
    }

    function test_listing_is_permissionless_and_unbounded_depth() public {
        (uint8 reason, uint256 depth) = sys.v4.check(address(weth), wkey);
        assertEq(reason, 0);
        assertEq(depth, sys.v4.CUSTOM_CURVE_DEPTH());
        vm.prank(mallory);
        sys.v4.registerAndList(address(weth), wkey);
        (bool enabled,, address adapter, PoolKey[] memory route) = house.tokenConfig(address(weth));
        assertTrue(enabled);
        assertEq(adapter, address(sys.v4));
        assertEq(route.length, 2);
        assertEq(address(route[0].hooks), address(hook));
        assertEq(keccak256(abi.encode(route[1])), keccak256(abi.encode(flipperPool)));

        // an AMM ETH/WETH pool can't displace the wrapper (even with WETH allowlisted, as on Ink)
        vm.prank(owner);
        sys.policy.setTokenAllowlisted(address(weth), true);
        MockPoolRef memory r = _ammWethPool();
        (reason,) = sys.v4.check(address(weth), r.key);
        assertEq(reason, sys.v4.DEEPER_REGISTERED());
    }

    function test_weth_flip_full_odds_win_and_loss() public {
        sys.v4.registerAndList(address(weth), wkey);
        FlipperHouseBase.Preview memory pv = house.previewFlip(address(weth), 1 ether);
        assertEq(pv.code, 0);
        console2.log("WETH route cost bps", pv.routeCostBps);
        console2.log("WETH win chance bps", pv.winChanceBps);
        // only the $FLIPPER hop costs anything (1% pool fee each way here)
        assertLe(pv.routeCostBps, 250);

        uint256 w0 = weth.balanceOf(alice);
        uint256 id = _flip(alice, address(weth), 1 ether);
        _reveal(id, WIN_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Won));
        assertEq(weth.balanceOf(alice), w0 + 1 ether, "stake back + 1 WETH bought through the wrapper");

        id = _flip(alice, address(weth), 1 ether);
        _reveal(id, LOSS_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Lost), "WETH sold through the wrapper");
        assertEq(weth.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        _assertSolvent();
    }

    /// Like v4-periphery's WETHHook, the hook takes the input from the PoolManager's reserves before the swapper
    /// pays (routers that pay after the swap need the PoolManager to hold that much of the input; on Ink it holds
    /// both ETH and WETH, and the house always prepays exact inputs).
    function test_swaps_are_exactly_one_to_one() public {
        _ammWethPool(); // the PoolManager holds some WETH, as on a live chain
        // ETH → WETH exact in
        uint256 w0 = weth.balanceOf(address(this));
        swapper.swap{value: 3 ether}(
            wkey, IPoolManager.SwapParams(true, -3 ether, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
        );
        assertEq(weth.balanceOf(address(this)) - w0, 3 ether);
        // WETH → ETH exact out
        weth.approve(address(swapper), type(uint256).max);
        uint256 e0 = address(this).balance;
        swapper.swap(
            wkey, IPoolManager.SwapParams(false, 2 ether, TickMath.MAX_SQRT_PRICE - 1), PoolSwapTest.TestSettings(false, false), ""
        );
        assertEq(address(this).balance - e0, 2 ether);
        assertEq(weth.balanceOf(address(this)) - w0, 1 ether);
    }

    function test_no_liquidity_no_second_pool_pm_only() public {
        vm.expectRevert();
        lp.modifyLiquidity(wkey, IPoolManager.ModifyLiquidityParams(-10, 10, 1e18, 0), "");
        vm.expectRevert();
        hook.initialize(); // once
        PoolKey memory other = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(weth)), 500, 10, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(other, 79228162514264337593543950336);
        vm.expectRevert(WethWrapperHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), wkey, IPoolManager.SwapParams(true, -1, 0), "");
        vm.deal(mallory, 1 ether);
        vm.prank(mallory);
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok, "no stray ETH");
    }

    struct MockPoolRef {
        PoolKey key;
    }

    /// @dev a thin hookless ETH/WETH AMM pool (like the one on Ink)
    function _ammWethPool() internal returns (MockPoolRef memory r) {
        r.key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(weth)), 3000, 60, IHooks(address(0)));
        manager.initialize(r.key, 79228162514264337593543950336);
        weth.deposit{value: 10 ether}();
        weth.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity{value: 10 ether}(
            r.key, IPoolManager.ModifyLiquidityParams(-600, 600, 100 ether, 0), ""
        );
    }
}
