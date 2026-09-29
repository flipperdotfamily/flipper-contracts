// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {RevenueRouter} from "../../src/RevenueRouter.sol";
import {LiquidityKeeper, IUNCXV4Locker} from "../../src/LiquidityKeeper.sol";
import {IEntropyV2} from "../../src/interfaces/IEntropyV2.sol";
import {FlipperDeploy} from "../../script/lib/FlipperDeploy.sol";
import {RobinhoodAddresses as RH} from "../../script/lib/RobinhoodAddresses.sol";

interface IERC721Owner {
    function ownerOf(uint256 id) external view returns (address);
}

/// @notice The UNCX_LOCK=1 launch on a Robinhood Chain fork: the keeper mints the launch position and locks it forever in
///         UNCX's live v4 locker (paying its flat fee, within the caps), with the RevenueRouter as the collect address;
///         `collect()` then goes through UNCX (less its 4% collect fee) to the router.
///         Run: ROBINHOOD_RPC_URL=https://rpc.ordofi.network [ROBINHOOD_FORK_BLOCK=…] forge test
///              --match-contract LiquidityKeeperUncx -vv
contract LiquidityKeeperUncxForkTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    IUNCXV4Locker internal constant L = IUNCXV4Locker(RH.UNCX_V4_LOCKER);
    IPoolManager internal constant PM = IPoolManager(RH.POOL_MANAGER);

    FlipperDeploy.Config internal c;
    RevenueRouter internal r;
    LiquidityKeeper internal k;
    address internal player = makeAddr("player");
    address internal mallory = makeAddr("mallory");
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(72_650_000)));
        forked = true;
        vm.deal(address(this), 100 ether);
        c = FlipperDeploy.Config({
            poolManager: PM,
            entropy: IEntropyV2(address(0)),
            entropyProvider: address(0),
            deployer: address(this),
            owner: address(this),
            proxyAdminOwner: address(this),
            params: RH.defaultParams()
        });
        r = FlipperDeploy.deployRouter(c);
        k = FlipperDeploy.deployLiquidityKeeper(
            PM,
            r,
            RH.POSITION_MANAGER,
            RH.UNCX_V4_LOCKER,
            RH.UNCX_MAX_FLAT_FEE,
            RH.UNCX_MAX_LP_FEE_BPS,
            RH.UNCX_MAX_COLLECT_FEE_BPS
        );
    }

    receive() external payable {} // the launch refunds unused ETH

    function _sqrtP() internal pure returns (uint160) {
        return uint160(Math.sqrt(SUPPLY * (1 << 96) / 1.86 ether) << 48); // ~$5k FDV
    }

    function _launch(uint256 value) internal returns (address token, uint256 out) {
        (token, out) = r.launchFlipperV4{value: value}(
            "Flipper", "FLIPPER", SUPPLY, SUPPLY, 10_000, 200, _sqrtP(), 0.37 ether, 1, player
        );
    }

    function test_uncx_eternal_lock_and_collect_to_the_router() public {
        if (!forked) return;
        uint256 fee = L.whitelistedForFreeLock(address(k)) ? 0 : L.flatFee();
        assertLe(fee, RH.UNCX_MAX_FLAT_FEE);
        uint256 eth0 = address(this).balance;
        (address token, uint256 out) = _launch(0.37 ether + fee + 1 ether); // the excess comes back
        assertEq(eth0 - address(this).balance, 0.37 ether + fee, "opening buy + UNCX's flat fee, the rest refunded");
        assertGt(out, 0);

        uint256 lid = k.lockId();
        IUNCXV4Locker.LockInfo memory li = L.getLockInfo(lid);
        assertEq(li.lockId, lid);
        assertEq(li.owner, address(k), "the keeper owns the lock");
        assertEq(li.collectAddress, address(r), "fees go to the router");
        assertEq(li.unlockTime, type(uint256).max, "eternal");
        assertEq(li.tokenId, k.tokenId());
        assertEq(IERC721Owner(RH.POSITION_MANAGER).ownerOf(k.tokenId()), RH.UNCX_V4_LOCKER, "the NFT sits in UNCX");

        // UNCX took its LP fee as liquidity: ≈99% of the minted position is locked
        (,, int24 lower, int24 upper, uint128 liq) = k.position();
        uint256 minted =
            FullMath.mulDiv(SUPPLY, 1 << 96, TickMath.getSqrtPriceAtTick(upper) - TickMath.getSqrtPriceAtTick(lower));
        assertApproxEqRel(liq, minted * (10_000 - L.lpFee()) / 10_000, 0.001e18);
        (uint256 e, uint256 f) = k.positionAmounts();
        assertGt(e, 0.3 ether, "the opening buy's ETH is in the position");
        assertGt(f, 0);

        // trade through the pool, then anyone collects: the fees (less UNCX's collect fee) reach the router
        PoolKey memory key = k.poolKey();
        PoolSwapTest swapper = new PoolSwapTest(PM);
        swapper.swap{value: 1 ether}(
            key, IPoolManager.SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
        );
        uint256 re = address(r).balance;
        uint256 rt = IERC20(token).balanceOf(address(r));
        vm.prank(mallory);
        uint256 g = gasleft();
        (uint256 a0, uint256 a1) = k.collect();
        g -= gasleft();
        emit log_named_uint("collect() through UNCX, gas", g);
        assertLt(g, 280_000, "inside harvest's 300k floor for a swallowed call");
        // 1% of the 0.37 ETH opening buy (after the lock, same transaction) and of the 1 ETH buy, less UNCX's 4%
        assertApproxEqRel(a0, 0.0137 ether * (10_000 - L.collectFee()) / 10_000, 0.02e18, "fees less UNCX's cut");
        assertEq(address(r).balance - re, a0);
        assertEq(IERC20(token).balanceOf(address(r)) - rt, a1);
        assertEq(mallory.balance, 0);

        // nobody but the keeper may act on the lock, and the keeper has no function that does more than collect
        vm.startPrank(mallory);
        vm.expectRevert();
        L.collect(lid, mallory);
        vm.expectRevert();
        L.setCollectAddress(lid, mallory);
        vm.stopPrank();
        vm.prank(address(r));
        vm.expectRevert();
        L.setCollectAddress(lid, address(r));
    }

    function test_uncx_fee_guard_refuses_a_fee_above_the_cap() public {
        if (!forked) return;
        if (L.whitelistedForFreeLock(address(this))) return;
        RevenueRouter r2 = FlipperDeploy.deployRouter(c);
        uint256 fee = L.flatFee();
        FlipperDeploy.deployLiquidityKeeper(PM, r2, RH.POSITION_MANAGER, RH.UNCX_V4_LOCKER, fee - 1, 100, 400);
        vm.expectRevert(LiquidityKeeper.UncxFeeTooHigh.selector);
        r2.launchFlipperV4{value: 0.37 ether + fee}(
            "Flipper", "FLIPPER", SUPPLY, SUPPLY, 10_000, 200, _sqrtP(), 0.37 ether, 1, player
        );
    }
}
