// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {FlipperBase} from "./utils/FlipperBase.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {IEntropyV2} from "../src/interfaces/IEntropyV2.sol";
import {FlipperDeploy} from "../script/lib/FlipperDeploy.sol";

contract LaunchTest is FlipperBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant SUPPLY = 1_000_000_000 ether;

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
        return uint160(_sqrtU(SUPPLY * (1 << 96) / 2 ether) << 48);
    }

    function _launchV4(RevenueRouter r, uint256 buyEth) internal returns (address token, uint256 out, PoolKey memory key) {
        _lpKeeper(r);
        (token, out) = r.launchFlipperV4{value: buyEth}("Flipper", "FLIPPER", SUPPLY, SUPPLY, FEE, TS, _sqrtP(), buyEth, 1, alice);
        (key,,) = r.lpPosition();
    }

    function test_v4_launch_single_sided_pool_and_same_tx_opening_buy() public {
        RevenueRouter r = FlipperDeploy.deployRouter(_config());
        uint256 aliceEth = alice.balance;
        (address token, uint256 out, PoolKey memory key) = _launchV4(r, 1 ether);

        // CPMM with 2 ETH virtual reserve: 1 ETH (less the 1% fee) buys ≈ 1/3 of the supply
        assertApproxEqRel(out, SUPPLY * 99 / 100 / 3, 0.02e18, "opening buy");
        assertEq(IERC20(token).balanceOf(alice), out, "bought tokens to the recipient");
        assertEq(IERC20(token).balanceOf(address(r)), 0, "router keeps no loose tokens");
        assertEq(IERC20(token).totalSupply(), SUPPLY);
        assertEq(alice.balance, aliceEth, "recipient paid nothing");
        assertEq(address(r).balance, 0, "all ETH went into the pool");
        assertEq(address(r.flipper()), token);
        assertEq(address(key.hooks), address(0));
        assertGt(manager.getLiquidity(key.toId()), 0);
        (int24 lower, int24 upper) = (r.lpTickLower(), r.lpTickUpper());
        assertEq(lower, TickMath.minUsableTick(TS));
        assertEq(upper % TS, 0);

        vm.expectRevert(RevenueRouter.AlreadyConfigured.selector);
        r.launchFlipperV4{value: 1 ether}("X", "X", SUPPLY, SUPPLY, FEE, TS, _sqrtP(), 1 ether, 1, alice);
    }

    function test_v4_launch_is_owner_only_and_validates() public {
        RevenueRouter r = FlipperDeploy.deployRouter(_config());
        uint160 p = _sqrtP();
        // no LiquidityKeeper yet: nowhere to put the position
        vm.expectRevert(RevenueRouter.InvalidParams.selector);
        r.launchFlipperV4{value: 1 ether}("F", "F", SUPPLY, SUPPLY, FEE, TS, p, 1 ether, 1, alice);
        _lpKeeper(r);
        vm.prank(mallory);
        vm.expectRevert();
        r.launchFlipperV4{value: 1 ether}("F", "F", SUPPLY, SUPPLY, FEE, TS, p, 1 ether, 1, mallory);
        vm.expectRevert(RevenueRouter.InvalidParams.selector);
        r.launchFlipperV4{value: 1 ether}("F", "F", SUPPLY, SUPPLY + 1, FEE, TS, p, 1 ether, 1, alice);
        vm.expectRevert(RevenueRouter.InvalidParams.selector);
        r.launchFlipperV4{value: 0.5 ether}("F", "F", SUPPLY, SUPPLY, FEE, TS, p, 1 ether, 1, alice);
    }

    /// The protocol-owned position earns the pool's LP fee (the self-launch's creator revenue); anyone harvests it
    /// (earning the capped bounty) and it is split like any creator revenue: $FLIPPER → treasury share straight to
    /// the bankroll, the rest to holders; ETH → Dutch-auction lot whose $FLIPPER proceeds are split the same way.
    function test_lp_fees_harvested_and_split() public {
        FlipperDeploy.Config memory c = _config();
        RevenueRouter r = FlipperDeploy.deployRouter(c);
        (address token, uint256 out, PoolKey memory key) = _launchV4(r, 1 ether);
        FlipperDeploy.System memory s = FlipperDeploy.deployCore(c, r, IERC20(token), FlipperDeploy.deployPythAdapter(c));
        vm.prank(alice);
        IERC20(token).transfer(address(this), out / 2);
        IERC20(token).approve(address(swapper), type(uint256).max);

        _buyWithEth(key, 10 ether);
        _sellForEth(key, out / 4);

        uint256 t0 = s.house.treasury();
        uint256 m0 = mallory.balance;
        vm.recordLogs();
        vm.prank(mallory, mallory);
        (uint256 bEth, uint256 bFl) = r.harvest();
        uint256 eth = address(s.converter).balance + bEth;
        assertApproxEqRel(eth, 0.11 ether, 0.01e18, "1% of the 1 ETH opening buy + 10 ETH bought");
        assertEq(bEth, eth * 10 / 10_000, "0.1% ETH bounty");
        assertEq(mallory.balance, m0 + bEth);
        uint256 fl = IERC20(token).balanceOf(mallory) + (s.house.treasury() - t0) + r.rewardsFlipperPending();
        assertApproxEqRel(fl, out / 4 / 100, 0.01e18, "1% of the tokens sold");
        assertEq(IERC20(token).balanceOf(mallory), bFl);
        assertEq(s.house.treasury() - t0, (fl - bFl) / 2, "treasury share of the $FLIPPER leg");
        assertEq(IERC20(token).balanceOf(address(r)), r.rewardsFlipperPending(), "only the holders' share stays");
        assertEq(address(r).balance, 0, "ETH leg auctioned");
        assertEq(s.converter.lotsLength(), 1);
    }

    function _sqrtU(uint256 x) internal pure returns (uint256) {
        return _sqrt(x);
    }
}
