// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {FlipperBase} from "./utils/FlipperBase.sol";
import {MockV3Factory, MockV3Pool} from "./mocks/MockV3.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {V3BridgeHook} from "../src/adapters/V3BridgeHook.sol";
import {V3RouteAdapter, IV4AdapterDepth} from "../src/adapters/V3RouteAdapter.sol";
import {IUniswapV3Factory} from "../src/interfaces/IUniswapV3.sol";
import {FlipperDeploy} from "../script/lib/FlipperDeploy.sol";

/// @notice Uniswap v3 liquidity through the V3BridgeHook + V3RouteAdapter, with constant-price v3 pool mocks that
///         follow v3's swap / callback semantics.
contract V3RouteAdapterTest is FlipperBase {
    using PoolIdLibrary for PoolKey;

    WETH internal weth;
    MockV3Factory internal v3;
    V3BridgeHook internal bridge;
    V3RouteAdapter internal v3a;
    MockERC20 internal tok; // v3-only token paired with WETH
    MockERC20 internal usd; // quote currency: a v4 ETH/USD pool, v3 token/USD pools
    MockERC20 internal qtok; // v3-only token paired with USD
    MockV3Pool internal tokPool;
    MockV3Pool internal qtokPool;
    PoolKey internal usdEthPool;

    function setUp() public override {
        super.setUp();
        weth = new WETH();
        v3 = new MockV3Factory();
        address hookAddr = address(FlipperDeploy.V3_BRIDGE_FLAGS | (uint160(0x3b3b) << 144));
        deployCodeTo(
            "src/adapters/V3BridgeHook.sol:V3BridgeHook",
            abi.encode(manager, IUniswapV3Factory(address(v3)), address(weth)),
            hookAddr
        );
        bridge = V3BridgeHook(payable(hookAddr));
        v3a = V3RouteAdapter(
            FlipperDeploy.proxy(
                address(new V3RouteAdapter()),
                proxyAdminOwner,
                abi.encodeCall(V3RouteAdapter.initialize, (bridge, address(house), owner))
            )
        );

        usd = new MockERC20("USD", "USD", 18);
        usdEthPool = _pool(usd, IHooks(address(0)), 3000, 200 ether); // 1 ETH = 3000 USD
        vm.startPrank(owner);
        house.setRouteAdapter(address(v3a), true);
        v3a.setListingPolicy(sys.policy);
        v3a.setFlipperPool(flipperPool);
        v3a.setQuote(address(usd), usdEthPool);
        vm.stopPrank();

        tok = new MockERC20("V3 only", "TOK", 18);
        tokPool = _v3Pool(address(tok), address(weth), 3000, 60, 1_000_000); // 1 WETH = 1M TOK, 0.3%
        qtok = new MockERC20("V3 USD-paired", "QTOK", 18);
        qtokPool = _v3Pool(address(qtok), address(usd), 10_000, 200, 1000); // 1 USD = 1000 QTOK, 1%

        vm.startPrank(owner);
        sys.policy.setTokenAllowlisted(address(tok), true);
        sys.policy.setTokenAllowlisted(address(qtok), true);
        vm.stopPrank();

        for (uint256 i; i < 2; ++i) {
            address u = [alice, bob][i];
            tok.mint(u, 1_000_000_000 ether);
            qtok.mint(u, 1_000_000_000 ether);
            vm.startPrank(u);
            tok.approve(address(house), type(uint256).max);
            qtok.approve(address(house), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ── listing ─────────────────────────────────────────────────────────────────────────────────────────

    function test_register_and_list_weth_pair() public {
        (uint8 reason, uint256 depth) = v3a.check(address(tok), address(tokPool));
        assertEq(reason, 0, "eligible");
        assertGt(depth, 0);
        v3a.registerAndList(address(tok), address(tokPool));
        (bool enabled,, address adapter, PoolKey[] memory route) = house.tokenConfig(address(tok));
        assertTrue(enabled);
        assertEq(adapter, address(v3a));
        assertEq(route.length, 2);
        assertEq(address(route[0].hooks), address(bridge), "bridged v3 pool");
        assertEq(Currency.unwrap(route[0].currency0), address(0), "WETH is native ETH on the bridge");
        assertEq(route[0].fee, 3000);
        assertEq(bridge.v3PoolOf(route[0].toId()), address(tokPool));
    }

    function test_quote_currency_route_is_three_hops() public {
        v3a.registerAndList(address(qtok), address(qtokPool));
        (,,, PoolKey[] memory route) = house.tokenConfig(address(qtok));
        assertEq(route.length, 3);
        assertEq(address(route[0].hooks), address(bridge));
        assertEq(keccak256(abi.encode(route[1])), keccak256(abi.encode(usdEthPool)), "v4 USD/ETH quote hop");
    }

    function test_check_reason_codes() public {
        (uint8 r,) = v3a.check(makeAddr("eoa"), address(tokPool));
        assertEq(r, v3a.NO_CODE());
        (r,) = v3a.check(address(flipperToken), address(tokPool));
        assertEq(r, v3a.IS_FLIPPER());
        (r,) = v3a.check(address(weth), address(tokPool));
        assertEq(r, v3a.IS_WETH());
        // same tokens and fee as a factory pool, but not the factory's
        (address t0, address t1) = address(tok) < address(weth) ? (address(tok), address(weth)) : (address(weth), address(tok));
        MockV3Pool fake = new MockV3Pool(t0, t1, 3000, 60, 1e18);
        fake.setState(1e24, uint160(1 << 96));
        (r,) = v3a.check(address(tok), address(fake));
        assertEq(r, v3a.NOT_V3_POOL());
        (r,) = v3a.check(address(tokenT), address(tokPool));
        assertEq(r, v3a.NOT_IN_POOL());
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        MockV3Pool daiPool = _v3Pool(address(tok), address(dai), 500, 10, 1);
        (r,) = v3a.check(address(tok), address(daiPool));
        assertEq(r, v3a.UNSUPPORTED_QUOTE());
        MockV3Pool empty = v3.createPool(address(tok), address(weth), 500, 10, 1e18);
        (r,) = v3a.check(address(tok), address(empty));
        assertEq(r, v3a.NOT_INITIALIZED());
        empty.setState(0, uint160(1 << 96));
        (r,) = v3a.check(address(tok), address(empty));
        assertEq(r, v3a.NO_LIQUIDITY());

        // a shallower pool can't replace a deeper registration
        v3a.register(address(tok), address(tokPool));
        empty.setState(1e18, uint160(1 << 96));
        (r,) = v3a.check(address(tok), address(empty));
        assertEq(r, v3a.DEEPER_REGISTERED());
        vm.expectRevert(abi.encodeWithSelector(V3RouteAdapter.Rejected.selector, v3a.DEEPER_REGISTERED()));
        v3a.register(address(tok), address(empty));

        // a token the house already lists through another adapter (here: the owner) is left to the owner
        PoolKey memory k = _pool(qtok, IHooks(address(0)), 1000, 10 ether);
        vm.prank(owner);
        house.setTokenRoute(address(qtok), _route1(k, flipperPool));
        (r,) = v3a.check(address(qtok), address(qtokPool));
        assertEq(r, v3a.LISTED_ELSEWHERE());
    }

    /// v4 is the default venue: a V4RouteAdapter registration at least as deep (same pairing) wins
    function test_defers_to_deeper_v4_registration() public {
        MockERC20 both = new MockERC20("Both", "BOTH", 18);
        vm.prank(owner);
        sys.policy.setTokenAllowlisted(address(both), true);
        PoolKey memory k = _pool(both, IHooks(address(0)), 1000, 200 ether); // ~200 ETH in-range
        sys.v4.register(address(both), k);
        vm.prank(owner);
        v3a.setV4Adapter(IV4AdapterDepth(address(sys.v4)));

        MockV3Pool shallow = _v3Pool(address(both), address(weth), 3000, 60, 1000);
        shallow.setState(1e18, uint160(1 << 96)); // ~1 ETH in range
        (uint8 r,) = v3a.check(address(both), address(shallow));
        assertEq(r, v3a.DEEPER_REGISTERED(), "the v4 pool is deeper");
        MockV3Pool deep = _v3Pool(address(both), address(weth), 10_000, 200, 1000);
        deep.setState(1e24, uint160(1 << 96));
        (r,) = v3a.check(address(both), address(deep));
        assertEq(r, 0, "a deeper v3 pool may register");
    }

    /// listing policy: a token nobody vetted is refused (check, register, and a direct house.listToken)
    function test_unvetted_token_is_refused() public {
        MockERC20 rnd = new MockERC20("Random", "RND", 18);
        MockV3Pool p = _v3Pool(address(rnd), address(weth), 3000, 60, 1_000_000);
        (uint8 r,) = v3a.check(address(rnd), address(p));
        assertEq(r, v3a.NOT_VETTED());
        vm.expectRevert(abi.encodeWithSelector(V3RouteAdapter.NotVetted.selector, v3a.NOT_VETTED(), 0));
        v3a.registerAndList(address(rnd), address(p));
        vm.prank(owner);
        v3a.setPool(address(rnd), address(p));
        vm.expectRevert(abi.encodeWithSelector(V3RouteAdapter.NotVetted.selector, v3a.NOT_VETTED(), 0));
        house.listToken(address(rnd), v3a);
        // whitelisting the v3 pool itself makes it listable
        vm.prank(owner);
        sys.policy.setV3PoolWhitelisted(address(p), true);
        (r,) = v3a.check(address(rnd), address(p));
        assertEq(r, 0, "whitelisted pool");
    }

    // ── flips through the bridge ───────────────────────────────────────────────────────────────────────

    function test_flip_weth_pair_win_and_loss() public {
        v3a.registerAndList(address(tok), address(tokPool));
        FlipperHouseBase.Preview memory pv = house.previewFlip(address(tok), 1_000_000 ether);
        assertEq(pv.code, 0, "flippable");
        emit log_named_uint("route cost bps", pv.routeCostBps);

        uint256 before = tok.balanceOf(alice);
        uint256 id = _flip(alice, address(tok), 1_000_000 ether);
        _reveal(id, WIN_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Won), "bought through the v3 pool");
        assertEq(tok.balanceOf(alice), before + 1_000_000 ether, "paid 2x");

        uint256 t0 = house.treasury();
        id = _flip(alice, address(tok), 1_000_000 ether);
        _reveal(id, LOSS_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Lost), "sold through the v3 pool");
        assertGt(house.treasury(), t0);
        _assertClean(tok);
    }

    function test_flip_quote_pair_win_and_loss() public {
        v3a.registerAndList(address(qtok), address(qtokPool));
        uint256 id = _flip(alice, address(qtok), 1_000_000 ether);
        _reveal(id, WIN_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Won));
        id = _flip(alice, address(qtok), 1_000_000 ether);
        _reveal(id, LOSS_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Lost));
        _assertClean(qtok);
    }

    /// the house's net buybacks count the real ETH through the $FLIPPER pool hop on v3-bridged and USD-quoted routes
    function test_net_buybacks_on_bridged_and_quoted_routes() public {
        v3a.registerAndList(address(tok), address(tokPool)); // [v3 tok/WETH bridged to ETH, ETH/$FLIPPER]
        v3a.registerAndList(address(qtok), address(qtokPool)); // [v3 qtok/USD bridged, USD/ETH, ETH/$FLIPPER]
        address[2] memory tokens = [address(tok), address(qtok)];
        for (uint256 i; i < 2; ++i) {
            uint256[2] memory words = [LOSS_WORD, WIN_WORD];
            for (uint256 j; j < 2; ++j) {
                uint256 id = _flip(alice, tokens[i], 1_000_000 ether);
                int256 n0 = house.netBuybackEth();
                vm.recordLogs();
                _reveal(id, words[j]);
                int256 hop = _houseHopEth(vm.getRecordedLogs());
                int256 d = int256(house.netBuybackEth()) - n0;
                assertEq(d, hop, "exactly the house's own hop through the $FLIPPER pool");
                if (j == 0) assertGt(d, 0, "a loss's sale adds");
                else assertLt(d, 0, "a win's buy subtracts");
            }
        }
    }

    /// v3 running out of liquidity mid-swap is a partial fill: the attempt fails and settlement degrades safely
    function test_partial_fill_degrades_safely() public {
        v3a.registerAndList(address(tok), address(tokPool));
        uint256 w = _flip(alice, address(tok), 1_000_000 ether);
        uint256 l = _flip(alice, address(tok), 1_000_000 ether);
        tokPool.setMaxOut(1);
        _reveal(w, WIN_WORD);
        _reveal(l, LOSS_WORD);
        assertEq(uint8(_status(w)), uint8(FlipperHouseBase.Status.WinPending), "no buy, no quote: keeper resolves");
        assertEq(uint8(_status(l)), uint8(FlipperHouseBase.Status.LostInventory));
        _assertClean(tok);
    }

    // ── bridge safety ───────────────────────────────────────────────────────────────────────────────────

    function test_only_bridge_creates_pools_and_they_take_no_liquidity() public {
        PoolKey memory k = bridge.keyFor(address(tokPool));
        vm.expectRevert();
        manager.initialize(k, uint160(1 << 96));
        bridge.bridge(address(tokPool));
        vm.expectRevert();
        lp.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(-600, 600, 1e18, 0), "");
        PoolKey memory k2 = bridge.bridge(address(tokPool)); // idempotent
        assertEq(keccak256(abi.encode(k)), keccak256(abi.encode(k2)));
    }

    function test_callback_only_from_the_active_pool() public {
        vm.expectRevert(V3BridgeHook.NotActivePool.selector);
        bridge.uniswapV3SwapCallback(1, 0, abi.encode(Currency.wrap(address(0))));
        vm.prank(address(tokPool));
        vm.expectRevert(V3BridgeHook.NotActivePool.selector);
        bridge.uniswapV3SwapCallback(1, 0, abi.encode(Currency.wrap(address(0))));
    }

    function test_rejects_non_canonical_pool() public {
        (address t0, address t1) = address(tok) < address(weth) ? (address(tok), address(weth)) : (address(weth), address(tok));
        MockV3Pool fake = new MockV3Pool(t0, t1, 3000, 60, 1e18);
        vm.expectRevert(V3BridgeHook.NotV3Pool.selector);
        bridge.bridge(address(fake));
    }

    // ── helpers ─────────────────────────────────────────────────────────────────────────────────────────

    /// v3 pool pairing `token` with `quote` at `tokensPerQuote`, funded on both sides, ~1e24 liquidity in range
    function _v3Pool(address token, address quote, uint24 fee, int24 ts, uint256 tokensPerQuote)
        internal
        returns (MockV3Pool p)
    {
        // price = token1 per token0 (1e18)
        uint256 price = token < quote ? 1e18 / tokensPerQuote : tokensPerQuote * 1e18;
        p = v3.createPool(token, quote, fee, ts, price);
        p.setState(1e24, uint160(1 << 96));
        MockERC20(token).mint(address(p), 1e30);
        if (quote == address(weth)) {
            weth.deposit{value: 1000 ether}();
            weth.transfer(address(p), 1000 ether);
        } else {
            MockERC20(quote).mint(address(p), 1e30);
        }
    }

    function _assertClean(MockERC20 t) internal view {
        uint256 bal = t.balanceOf(address(house));
        assertGe(bal, house.escrowed(address(t)) + house.inventory(address(t)) + house.claimableTotal(address(t)));
        assertLe(house.reserved(), house.treasury());
        assertEq(address(bridge).balance, 0, "bridge keeps no ETH");
        assertEq(weth.balanceOf(address(bridge)), 0, "bridge keeps no WETH");
        assertEq(t.balanceOf(address(bridge)), 0, "bridge keeps no tokens");
    }
}
