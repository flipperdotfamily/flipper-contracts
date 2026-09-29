// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

import {FlipperBase} from "./utils/FlipperBase.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {LiquidityKeeper, IV4PositionManager, IUNCXV4Locker} from "../src/LiquidityKeeper.sol";
import {IEntropyV2} from "../src/interfaces/IEntropyV2.sol";
import {FlipperDeploy} from "../script/lib/FlipperDeploy.sol";
import {FlipperRewardToken} from "../src/FlipperRewardToken.sol";

interface IERC721Min {
    function ownerOf(uint256 id) external view returns (address);
    function getApproved(uint256 id) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function approve(address spender, uint256 id) external;
    function setApprovalForAll(address operator, bool approved) external;
    function transferFrom(address from, address to, uint256 id) external;
}

/// @notice What a malicious router upgrade could try against the launch position.
contract EvilRouter {
    receive() external payable {}

    function rug(IV4PositionManager posm, uint256 id, uint128 liq, PoolKey calldata key) external {
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(id, uint256(liq), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, msg.sender);
        posm.modifyLiquidities(abi.encode(abi.encodePacked(uint8(0x01), uint8(0x11)), params), block.timestamp);
    }

    function grab(address posm, address keeper, uint256 id) external {
        IERC721Min(posm).transferFrom(keeper, msg.sender, id);
    }

    function relaunch(LiquidityKeeper k, PoolKey calldata key) external {
        k.launch(key, TickMath.getSqrtPriceAtTick(0), -600, 0, 1);
    }
}

/// @notice The launch position lives in an immutable, ownerless LiquidityKeeper as a v4 PositionManager NFT: minted
///         atomically inside the router's launch, never decreasable or movable by anyone, its fees collectable by
///         anyone and always paid to the RevenueRouter.
contract LiquidityKeeperTest is FlipperBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    RevenueRouter internal r;
    LiquidityKeeper internal k;
    address internal token;
    uint256 internal out;
    PoolKey internal key;

    function setUp() public override {
        super.setUp();
        r = FlipperDeploy.deployRouter(_config());
        k = _lpKeeper(r);
    }

    function _config() internal view returns (FlipperDeploy.Config memory c) {
        c = FlipperDeploy.Config({
            poolManager: manager,
            entropy: IEntropyV2(address(entropy)),
            entropyProvider: provider,
            deployer: address(this),
            owner: address(this),
            proxyAdminOwner: proxyAdminOwner,
            params: defaultParams()
        });
    }

    /// FDV 2 ETH: 5e8 FLIPPER per ETH
    function _sqrtP() internal pure returns (uint160) {
        return uint160(_sqrt(SUPPLY * (1 << 96) / 2 ether) << 48);
    }

    function _launch(uint256 buyEth) internal {
        (token, out) = r.launchFlipperV4{value: buyEth}("Flipper", "FLIPPER", SUPPLY, SUPPLY, FEE, TS, _sqrtP(), buyEth, 1, alice);
        key = k.poolKey();
    }

    /// @dev trade both ways through the pool: ETH buys, then $FLIPPER sells (the position earns 1% of each)
    function _trade() internal {
        vm.prank(alice);
        IERC20(token).transfer(address(this), out / 2);
        IERC20(token).approve(address(swapper), type(uint256).max);
        _buyWithEth(key, 10 ether);
        _sellForEth(key, out / 4);
    }

    function _liquidity() internal view returns (uint128 liq) {
        (,,,, liq) = k.position();
    }

    // ── launch ───────────────────────────────────────────────────────────────────────────────────────

    function test_launch_mints_the_position_to_the_keeper() public {
        assertEq(k.router(), address(r));
        assertEq(r.liquidityKeeper(), address(k));
        address posm = address(k.positionManager());
        uint256 id = IV4PositionManager(posm).nextTokenId();

        _launch(0); // no opening buy: the pool sits at the start price
        (bytes32 pid, uint256 tokenId, int24 lower, int24 upper, uint128 liq) = k.position();
        assertTrue(k.launched());
        assertEq(tokenId, id);
        assertEq(k.tokenId(), id);
        assertEq(k.lockId(), 0);
        assertEq(IERC721Min(posm).ownerOf(id), address(k), "the keeper holds the NFT");
        assertEq(pid, PoolId.unwrap(key.toId()));
        assertEq(Currency.unwrap(key.currency1), token);
        assertEq(Currency.unwrap(key.currency0), address(0), "native ETH");

        // the router's range and liquidity, exactly as before: single-sided below the start price
        (PoolKey memory rk, int24 rl, int24 ru) = r.lpPosition();
        assertEq(keccak256(abi.encode(rk)), keccak256(abi.encode(key)));
        assertEq(lower, rl);
        assertEq(upper, ru);
        assertEq(lower, TickMath.minUsableTick(TS));
        assertEq(upper % TS, 0);
        uint256 want =
            FullMath.mulDiv(SUPPLY, 1 << 96, TickMath.getSqrtPriceAtTick(upper) - TickMath.getSqrtPriceAtTick(lower));
        assertEq(liq, want);
        (uint128 pmLiq,,) = manager.getPositionInfo(key.toId(), posm, lower, upper, bytes32(id));
        assertEq(pmLiq, liq, "the PoolManager's record of the NFT");
        assertEq(manager.getLiquidity(key.toId()), 0, "range below the price: no active liquidity yet");
        (uint160 sp,,,) = manager.getSlot0(key.toId());
        assertEq(sp, _sqrtP(), "initialised at the start price");

        // the supply sits in the pool; dust went back through the router to the recipient; nothing stays behind
        (uint256 a0, uint256 a1) = k.positionAmounts();
        assertEq(a0, 0);
        assertApproxEqAbs(a1, SUPPLY, 1e6);
        assertEq(IERC20(token).balanceOf(address(manager)) + IERC20(token).balanceOf(alice), SUPPLY);
        assertEq(IERC20(token).balanceOf(address(k)), 0);
        assertEq(IERC20(token).balanceOf(address(r)), 0);
        assertEq(address(k).balance, 0);
        assertEq(IERC20(token).allowance(address(k), IV4PositionManager(posm).permit2()), 0, "no allowance left");
    }

    function test_launch_with_opening_buy_is_one_transaction() public {
        uint256 aliceEth = alice.balance;
        _launch(1 ether);
        assertApproxEqRel(out, SUPPLY * 99 / 100 / 3, 0.02e18, "opening buy");
        assertEq(IERC20(token).balanceOf(alice), out);
        assertEq(alice.balance, aliceEth);
        assertEq(address(r).balance, 0);
        assertEq(address(k).balance, 0);
        assertGt(manager.getLiquidity(key.toId()), 0, "the buy moved the price into the range");
    }

    function test_launch_is_one_shot_and_router_only() public {
        PoolKey memory pk;
        vm.expectRevert(LiquidityKeeper.NotLaunched.selector);
        k.collect();
        (uint256 a0, uint256 a1) = k.positionAmounts();
        assertEq(a0 + a1, 0);
        vm.prank(mallory);
        vm.expectRevert(LiquidityKeeper.Unauthorized.selector);
        k.launch(pk, _sqrtP(), -600, 0, 1);
        vm.expectRevert(LiquidityKeeper.Unauthorized.selector);
        k.launch(pk, _sqrtP(), -600, 0, 1); // the router's owner is no exception

        _launch(1 ether);
        vm.prank(address(r));
        vm.expectRevert(LiquidityKeeper.AlreadyLaunched.selector);
        k.launch(key, _sqrtP(), -600, 0, 1);
        vm.expectRevert(RevenueRouter.AlreadyConfigured.selector);
        r.launchFlipperV4{value: 1 ether}("X", "X", SUPPLY, SUPPLY, FEE, TS, _sqrtP(), 1 ether, 1, alice);
        vm.expectRevert(RevenueRouter.AlreadyConfigured.selector);
        r.setLiquidityKeeper(address(k)); // the keeper can't be swapped out after the launch
    }

    /// The token's address is public between its deployment and the launch: pre-initialising its pool at or above the
    /// start price changes nothing (the opening buy walks down through empty ticks into the range); below it reverts.
    function test_pre_initialised_pool() public {
        FlipperRewardToken t = FlipperDeploy.deployRewardToken(_config(), r, "Flipper", "FLIPPER", SUPPLY);
        PoolKey memory pk = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(t)), FEE, TS, IHooks(address(0)));
        uint256 snap = vm.snapshotState();
        manager.initialize(pk, _sqrtP() - 1e18); // below the start
        vm.expectRevert(LiquidityKeeper.PoolPreInitialized.selector);
        r.launchFlipperV4Token{value: 1 ether}(t, SUPPLY, FEE, TS, _sqrtP(), 1 ether, 1, alice);
        vm.revertToState(snap);

        manager.initialize(pk, _sqrtP() * 4); // 16x the start price
        uint256 got = r.launchFlipperV4Token{value: 1 ether}(t, SUPPLY, FEE, TS, _sqrtP(), 1 ether, 1, alice);
        assertApproxEqRel(got, SUPPLY * 99 / 100 / 3, 0.02e18, "the same opening buy as a clean launch");
        (,,,, uint128 liq) = k.position();
        assertGt(liq, 0);
    }

    function test_set_liquidity_keeper_is_owner_only_and_checks_the_router() public {
        RevenueRouter r2 = FlipperDeploy.deployRouter(_config());
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, mallory));
        r2.setLiquidityKeeper(address(k));
        vm.expectRevert(RevenueRouter.InvalidParams.selector);
        r2.setLiquidityKeeper(address(k)); // k pays another router
        LiquidityKeeper k2 = _lpKeeper(r2);
        assertEq(r2.liquidityKeeper(), address(k2));
    }

    // ── nobody can take the liquidity ────────────────────────────────────────────────────────────────

    function test_nobody_can_decrease_or_move_the_position() public {
        _launch(1 ether);
        _trade();
        IV4PositionManager posm = k.positionManager();
        uint256 id = k.tokenId();
        uint128 liq = _liquidity();

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(id, uint256(liq), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, mallory);
        bytes memory drain = abi.encode(abi.encodePacked(uint8(0x01), uint8(0x11)), params);

        // the router's owner, the router itself, the proxy admin's owner, anyone
        address[4] memory who = [address(this), address(r), proxyAdminOwner, mallory];
        for (uint256 i; i < who.length; ++i) {
            vm.startPrank(who[i]);
            vm.expectRevert(abi.encodeWithSignature("NotApproved(address)", who[i]));
            posm.modifyLiquidities(drain, block.timestamp);
            vm.expectRevert("NOT_AUTHORIZED");
            IERC721Min(address(posm)).transferFrom(address(k), who[i], id);
            vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
            IERC721Min(address(posm)).approve(who[i], id);
            vm.stopPrank();
            assertFalse(IERC721Min(address(posm)).isApprovedForAll(address(k), who[i]));
        }
        assertEq(IERC721Min(address(posm)).getApproved(id), address(0));

        // a router upgrade gains nothing: the keeper's router is an address, not an authority over the NFT
        EvilRouter evil = new EvilRouter();
        address admin = address(uint160(uint256(vm.load(address(r), ERC1967Utils.ADMIN_SLOT))));
        vm.prank(proxyAdminOwner);
        ProxyAdmin(admin).upgradeAndCall(ITransparentUpgradeableProxy(address(r)), address(evil), "");
        EvilRouter er = EvilRouter(payable(address(r)));
        vm.expectRevert(abi.encodeWithSignature("NotApproved(address)", address(r)));
        er.rug(posm, id, liq, key);
        vm.expectRevert("NOT_AUTHORIZED");
        er.grab(address(posm), address(k), id);
        vm.expectRevert(LiquidityKeeper.AlreadyLaunched.selector);
        er.relaunch(k, key);

        assertEq(IERC721Min(address(posm)).ownerOf(id), address(k));
        assertEq(_liquidity(), liq, "liquidity untouched");
        // fees still go to the (upgraded) router address, never anywhere else
        uint256 e0 = address(r).balance;
        (uint256 f0,) = k.collect();
        assertEq(address(r).balance - e0, f0);
        assertEq(_liquidity(), liq);
    }

    // ── fees ─────────────────────────────────────────────────────────────────────────────────────────

    function test_collect_sends_fees_to_the_router() public {
        _launch(1 ether);
        _trade();
        uint128 liq = _liquidity();
        uint256 e0 = address(r).balance;
        uint256 t0 = IERC20(token).balanceOf(address(r));

        vm.expectEmit(false, false, false, false, address(k));
        emit LiquidityKeeper.Collected(0, 0);
        vm.prank(mallory);
        uint256 g = gasleft();
        (uint256 a0, uint256 a1) = k.collect();
        g -= gasleft();
        emit log_named_uint("collect() gas", g);
        assertLt(g, 200_000, "well inside harvest's 300k floor for a swallowed call");
        assertApproxEqRel(a0, 0.11 ether, 0.01e18, "1% of the 1 ETH opening buy + 10 ETH bought");
        assertApproxEqRel(a1, out / 4 / 100, 0.01e18, "1% of the tokens sold");
        assertEq(address(r).balance - e0, a0);
        assertEq(IERC20(token).balanceOf(address(r)) - t0, a1);
        assertEq(IERC20(token).balanceOf(mallory), 0, "the caller gets nothing here");
        assertEq(_liquidity(), liq, "principal untouched");

        (a0, a1) = k.collect();
        assertEq(a0 + a1, 0, "nothing accrued since");

        // anything sent to the keeper goes along to the router
        vm.deal(address(k), 1 ether);
        IERC20(token).transfer(address(k), 5 ether);
        e0 = address(r).balance;
        t0 = IERC20(token).balanceOf(address(r));
        k.collect();
        assertEq(address(r).balance - e0, 1 ether);
        assertEq(IERC20(token).balanceOf(address(r)) - t0, 5 ether);
        assertEq(address(k).balance, 0);
    }

    function test_harvest_collects_the_fees_and_pays_the_bounty_on_them() public {
        FlipperDeploy.Config memory c = _config();
        _launch(1 ether);
        FlipperDeploy.System memory s = FlipperDeploy.deployCore(c, r, IERC20(token), FlipperDeploy.deployPythAdapter(c));
        s; // the converter and house the harvest routes into
        _trade();

        uint256 snap = vm.snapshotState();
        (uint256 a0, uint256 a1) = k.collect();
        vm.revertToState(snap);
        assertGt(a0, 0);
        assertGt(a1, 0);

        uint256 bEth = _min(a0 * r.bountyBps() / 10_000, r.bountyCapEth());
        uint256 bFl = _min(a1 * r.bountyBps() / 10_000, r.bountyCapFlipper());
        vm.expectEmit(address(r));
        emit RevenueRouter.Harvested(mallory, a0, a1, bEth, bFl);
        vm.prank(mallory, mallory);
        (uint256 gotEth, uint256 gotFl) = r.harvest();
        assertEq(gotEth, bEth);
        assertEq(gotFl, bFl);
        assertEq(IERC20(token).balanceOf(mallory), bFl);
        (a0, a1) = k.collect();
        assertEq(a0 + a1, 0, "harvest collected everything");
    }

    // ── views ────────────────────────────────────────────────────────────────────────────────────────

    /// positionAmounts is what burning the whole position would pay out now (fees excluded)
    function test_position_amounts_match_the_pool_manager() public {
        _launch(1 ether);
        _trade();
        k.collect(); // fees out of the way
        (uint256 e, uint256 f) = k.positionAmounts();
        assertGt(e, 0);
        assertGt(f, 0);

        IV4PositionManager posm = k.positionManager();
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(k.tokenId(), uint256(_liquidity()), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(0xBEEF));
        vm.prank(address(k)); // what the owner would receive (the keeper itself has no way to do this)
        posm.modifyLiquidities(abi.encode(abi.encodePacked(uint8(0x01), uint8(0x11)), params), block.timestamp);
        assertApproxEqAbs(address(0xBEEF).balance, e, 1, "ETH");
        assertApproxEqAbs(IERC20(token).balanceOf(address(0xBEEF)), f, 1, "FLIPPER");
    }

    // ── UNCX guards (the lock itself is exercised on a Robinhood fork) ───────────────────────────────

    function test_uncx_fee_guards_refuse_a_raised_fee() public {
        MockUncx m = new MockUncx();
        RevenueRouter r2 = FlipperDeploy.deployRouter(_config());
        LiquidityKeeper k2 = FlipperDeploy.deployLiquidityKeeper(
            manager, r2, _positionManager(), address(m), 0.1 ether, 100, 400
        );
        m.set(0.2 ether, 100, 400, false); // flat fee above the cap
        vm.expectRevert(LiquidityKeeper.UncxFeeTooHigh.selector);
        r2.launchFlipperV4{value: 1.2 ether}("F", "F", SUPPLY, SUPPLY, FEE, TS, _sqrtP(), 1 ether, 1, alice);
        m.set(0.1 ether, 101, 400, false); // LP fee above the cap
        vm.expectRevert(LiquidityKeeper.UncxFeeTooHigh.selector);
        r2.launchFlipperV4{value: 1.1 ether}("F", "F", SUPPLY, SUPPLY, FEE, TS, _sqrtP(), 1 ether, 1, alice);
        m.set(0, 0, 401, true); // whitelisted, but the collect fee is above the cap
        vm.expectRevert(LiquidityKeeper.UncxFeeTooHigh.selector);
        r2.launchFlipperV4{value: 1 ether}("F", "F", SUPPLY, SUPPLY, FEE, TS, _sqrtP(), 1 ether, 1, alice);
        k2;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

/// @dev fee views only: the guards revert before any lock call
contract MockUncx {
    uint256 public flatFee;
    uint256 public lpFee;
    uint256 public collectFee;
    bool internal wl;

    function set(uint256 f, uint256 l, uint256 c, bool w) external {
        (flatFee, lpFee, collectFee, wl) = (f, l, c, w);
    }

    function whitelistedForFreeLock(address) external view returns (bool) {
        return wl;
    }
}
