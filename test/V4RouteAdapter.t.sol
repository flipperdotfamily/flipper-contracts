// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {FlipperBase} from "./utils/FlipperBase.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {V4RouteAdapter} from "../src/adapters/V4RouteAdapter.sol";
import {IRouteAdapter} from "../src/interfaces/IRouteAdapter.sol";

/// @notice Token that can refuse transfers *out of* one address (e.g. a blocklist aimed at the house).
contract BlockingToken is MockERC20 {
    address public blockedFrom;

    constructor() MockERC20("Blocking", "BLK", 18) {}

    function setBlockedFrom(address a) external {
        blockedFrom = a;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(msg.sender != blockedFrom, "blocked");
        return super.transfer(to, amount);
    }
}

/// @notice Token that skims a tax on transfers *into* one address once armed (after the flip's exact pull).
contract TaxToken is MockERC20 {
    address public taxed;

    constructor() MockERC20("Tax", "TAX", 18) {}

    function setTaxed(address a) external {
        taxed = a;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == taxed) {
            uint256 tax = amount / 10;
            super.transfer(address(0xdead), tax);
            return super.transfer(to, amount - tax);
        }
        return super.transfer(to, amount);
    }
}

/// @notice Token whose balanceOf/transfer revert with a forged SettledQuoteResult once armed.
contract ForgingToken is MockERC20 {
    bool public armed;

    constructor() MockERC20("Forge", "FRG", 18) {}

    function arm() external {
        armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed && to != address(0) && msg.sender != to) {
            // SettledQuoteResult(bytes32 tag, uint256 amountIn, uint256 amountOut) with a guessed tag
            bytes memory fake = abi.encodeWithSignature(
                "SettledQuoteResult(bytes32,uint256,uint256)", bytes32(uint256(1)), amount, 1e40
            );
            assembly {
                revert(add(fake, 32), mload(fake))
            }
        }
        return super.transfer(to, amount);
    }
}

contract V4RouteAdapterTest is FlipperBase {
    uint256 internal constant STAKE = 1_000_000 ether;

    /// @dev a trusted token (listing policy) with a hookless pool: the hostile-token tests below show that even a
    ///      token vetted in error can't drain the house through settlement
    function _newTokenWithPool(MockERC20 t) internal returns (PoolKey memory key) {
        _trust(address(t));
        key = _pool(t, IHooks(address(0)), 10_000_000, 200 ether);
        t.mint(alice, 100_000_000 ether);
        vm.prank(alice);
        t.approve(address(house), type(uint256).max);
    }

    function test_register_and_list_trusted_token_on_hookless_pool() public {
        MockERC20 t = new MockERC20("Any", "ANY", 18);
        PoolKey memory key = _newTokenWithPool(t);
        (uint8 reason, uint256 depth) = sys.v4.check(address(t), key);
        assertEq(reason, 0);
        assertApproxEqRel(depth, 200 ether, 0.01e18, "ETH-side depth");

        vm.prank(mallory); // anyone
        sys.v4.registerAndList(address(t), key);
        (bool enabled,, address a, PoolKey[] memory route) = house.tokenConfig(address(t));
        assertTrue(enabled);
        assertEq(a, address(sys.v4));
        assertEq(route.length, 2);

        uint256 id = _flip(alice, address(t), STAKE);
        _reveal(id, WIN_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Won));
        _assertSolvent();
    }

    function test_check_reason_codes() public {
        MockERC20 t = new MockERC20("Any", "ANY", 18);
        PoolKey memory key = _newTokenWithPool(t);
        assertEq(_reason(address(0xBEEF), key), sys.v4.NO_CODE());
        assertEq(_reason(address(flipperToken), flipperPool), sys.v4.IS_FLIPPER());
        assertEq(_reason(address(t), flipperPool), sys.v4.NOT_IN_POOL());
        // T isn't vetted; once allowlisted, its pool's hook isn't pinned
        assertEq(_reason(address(tokenT), tPool), sys.v4.NOT_VETTED());
        _trust(address(tokenT));
        assertEq(_reason(address(tokenT), tPool), sys.v4.HOOK_NOT_PINNED());
        // token paired with a non-allowlisted quote
        MockERC20 q = new MockERC20("Quote", "Q", 18);
        PoolKey memory tq = _pairPool(t, q);
        assertEq(_reason(address(t), tq), sys.v4.UNSUPPORTED_QUOTE());
        // uninitialized pool
        PoolKey memory ghost = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(t)), 500, 10, IHooks(address(0)));
        assertEq(_reason(address(t), ghost), sys.v4.NOT_INITIALIZED());
        // a shallower pool can't displace a registered deeper one
        sys.v4.register(address(t), key);
        PoolKey memory shallow = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(t)), 3000, 60, IHooks(address(0)));
        manager.initialize(shallow, uint160(_sqrt(10_000_000) * 2 ** 96));
        lp.modifyLiquidity{value: 2 ether}(
            shallow, _fullRange(shallow.tickSpacing, int256(1 ether * _sqrt(10_000_000))), ""
        );
        assertEq(_reason(address(t), shallow), sys.v4.DEEPER_REGISTERED());
    }

    function test_quote_currency_routes_through_three_hops() public {
        // HOOKIT is an allowlisted quote with a HOOKIT/ETH pool; three 1% hops need a smaller listing probe
        FlipperHouseBase.Params memory p = defaultParams();
        p.listingProbeBps = 100;
        vm.startPrank(owner);
        house.setParams(p);
        sys.v4.setQuote(address(hookit), hookitPool);
        vm.stopPrank();
        MockERC20 t = new MockERC20("QuotedToken", "QT", 18);
        _trust(address(t));
        PoolKey memory key = _pairPool(t, hookit);
        t.mint(alice, 100_000_000 ether);
        vm.prank(alice);
        t.approve(address(house), type(uint256).max);
        sys.v4.registerAndList(address(t), key);
        (,,, PoolKey[] memory route) = house.tokenConfig(address(t));
        assertEq(route.length, 3);
        uint256 id = _flip(alice, address(t), 100_000 ether);
        _reveal(id, LOSS_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Lost));
        _assertSolvent();
    }

    /// A token that blocks the house's outbound transfers, combined with a failed buy: the fallback's settled
    /// simulation can't move the stake, so no $FLIPPER fallback is paid — it becomes a keeper-resolved WinPending,
    /// and the loss branch keeps the tokens as inventory. The token can't turn a win into free $FLIPPER.
    function test_blocking_token_cannot_extract_fallback() public {
        BlockingToken t = new BlockingToken();
        PoolKey memory key = _newTokenWithPool(MockERC20(address(t)));
        sys.v4.registerAndList(address(t), key);

        uint256 id = _flip(alice, address(t), STAKE);
        _buyWithEth(key, 60 ether); // price runs away → the capped buy fails
        t.setBlockedFrom(address(house)); // …and the house can't move the stake
        uint256 f0 = flipperToken.balanceOf(alice);
        _reveal(id, WIN_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.WinPending), "no fallback without a settleable path");
        assertEq(flipperToken.balanceOf(alice), f0, "no $FLIPPER paid");
        _assertSolvent();

        uint256 id2 = _flip(bob, address(flipperToken), 1 ether); // unrelated flips unaffected
        _reveal(id2, LOSS_WORD);
        _assertSolvent();
    }

    /// A transfer-taxing token (armed after the exact pull at entry) makes the purchase deliver less; the winner is
    /// paid what actually arrived and other players' escrow of the same token is never touched.
    function test_taxing_token_cannot_drain_escrow() public {
        TaxToken t = new TaxToken();
        PoolKey memory key = _newTokenWithPool(MockERC20(address(t)));
        sys.v4.registerAndList(address(t), key);
        t.mint(bob, 100_000_000 ether);
        vm.prank(bob);
        t.approve(address(house), type(uint256).max);

        uint256 other = _flip(bob, address(t), STAKE); // escrow that must stay intact
        uint256 id = _flip(alice, address(t), STAKE);
        t.setTaxed(address(house));
        uint256 before = t.balanceOf(alice);
        _reveal(id, WIN_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Won));
        uint256 paid = t.balanceOf(alice) - before;
        assertEq(paid, STAKE + STAKE * 9 / 10, "stake + what actually arrived");
        assertGe(t.balanceOf(address(house)), house.escrowed(address(t)), "other escrow intact");
        _reveal(other, LOSS_WORD);
        _assertSolvent();
    }

    /// A token whose transfer reverts with a forged SettledQuoteResult can't spoof the fallback valuation: the tag
    /// is derived from the random word, which token code never sees.
    function test_forged_settled_quote_is_rejected() public {
        ForgingToken t = new ForgingToken();
        PoolKey memory key = _newTokenWithPool(MockERC20(address(t)));
        sys.v4.registerAndList(address(t), key);
        uint256 id = _flip(alice, address(t), STAKE);
        _buyWithEth(key, 60 ether); // buy fails on price
        t.arm();
        uint256 f0 = flipperToken.balanceOf(alice);
        _reveal(id, WIN_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.WinPending));
        assertEq(flipperToken.balanceOf(alice), f0);
        _assertSolvent();
    }

    function test_owner_can_pin_and_unpin_a_hook() public {
        MockERC20 t = new MockERC20("Hooked", "HKD", 18);
        _trust(address(t));
        PoolKey memory key = _pool(t, IHooks(address(toggle)), 10_000_000, 200 ether);
        assertEq(_reason(address(t), key), sys.v4.HOOK_NOT_PINNED());
        vm.prank(owner);
        sys.policy.pinHook(address(toggle), true);
        assertEq(_reason(address(t), key), 0);
        assertEq(sys.policy.pinnedCodehash(address(toggle)), address(toggle).codehash);
        vm.prank(owner);
        sys.policy.pinHook(address(toggle), false);
        assertEq(_reason(address(t), key), sys.v4.HOOK_NOT_PINNED());
    }

    /// A pinned hook whose runtime code changes (redeployed, or a proxy stub) is no longer accepted.
    function test_hook_codehash_mismatch_is_refused() public {
        vm.prank(owner);
        sys.policy.pinHook(address(toggle), true);
        MockERC20 t = new MockERC20("Hooked", "HKD", 18);
        _trust(address(t));
        PoolKey memory key = _pool(t, IHooks(address(toggle)), 10_000_000, 200 ether);
        assertEq(_reason(address(t), key), 0);
        vm.etch(address(toggle), abi.encodePacked(address(toggle).code, hex"00"));
        assertEq(_reason(address(t), key), sys.v4.HOOK_NOT_PINNED());
        vm.expectRevert(abi.encodeWithSelector(V4RouteAdapter.NotVetted.selector, sys.v4.HOOK_NOT_PINNED(), 0));
        sys.v4.register(address(t), key);
    }

    /// A token nobody vetted can't be listed permissionlessly — not through the adapter, and not by calling the
    /// house directly with a pool the owner registered — while the owner can still list it on the house.
    function test_unvetted_token_is_refused_and_owner_can_override() public {
        MockERC20 t = new MockERC20("Random", "RND", 18);
        PoolKey memory key = _pool(t, IHooks(address(0)), 10_000_000, 200 ether);
        assertEq(_reason(address(t), key), sys.v4.NOT_VETTED());
        vm.expectRevert(abi.encodeWithSelector(V4RouteAdapter.NotVetted.selector, sys.v4.NOT_VETTED(), 0));
        vm.prank(mallory);
        sys.v4.registerAndList(address(t), key);
        vm.prank(owner);
        sys.v4.setPool(address(t), key);
        vm.expectRevert(abi.encodeWithSelector(V4RouteAdapter.NotVetted.selector, sys.v4.NOT_VETTED(), 0));
        vm.prank(mallory);
        house.listToken(address(t), sys.v4);

        vm.prank(owner);
        house.setTokenRoute(address(t), _route1(key, flipperPool));
        (bool enabled,,,) = house.tokenConfig(address(t));
        assertTrue(enabled, "owner listing");
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────────────

    function _trust(address token) internal {
        vm.prank(owner);
        sys.policy.setTokenAllowlisted(token, true);
    }

    function _reason(address token, PoolKey memory key) internal view returns (uint8 r) {
        (r,) = sys.v4.check(token, key);
    }

    function _fullRange(int24 ts, int256 liq) internal pure returns (IPoolManagerLike.ModifyLiquidityParams memory p) {
        p = IPoolManagerLike.ModifyLiquidityParams(-887220 / ts * ts, 887220 / ts * ts, liq, 0);
    }

    /// @dev token/quote pool at 1 quote = 100 token, 20M quote deep
    function _pairPool(MockERC20 t, MockERC20 q) internal returns (PoolKey memory key) {
        (address a, address b) = address(t) < address(q) ? (address(t), address(q)) : (address(q), address(t));
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), FEE, TS, IHooks(address(0)));
        // price = currency1 per currency0
        uint256 px = a == address(q) ? 100 : 1;
        uint160 sqrtP = a == address(q) ? uint160(10 * 2 ** 96) : uint160(uint256(2 ** 96) / 10);
        px;
        manager.initialize(key, sqrtP);
        t.mint(address(this), type(uint128).max);
        q.mint(address(this), type(uint128).max);
        t.approve(address(lp), type(uint256).max);
        q.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, _fullRange(TS, int256(20_000_000 ether * 10)), "");
    }
}

import {IPoolManager as IPoolManagerLike} from "v4-core/interfaces/IPoolManager.sol";
