// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FlipperBase} from "./utils/FlipperBase.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {DutchAuctionConverter} from "../src/DutchAuctionConverter.sol";

/// @notice holders' $FLIPPER sink stand-in (the reward-bearing token's `distribute`)
contract MockDistributor {
    IERC20 internal immutable token;
    uint256 public received;
    bool internal broken;

    constructor(IERC20 t) {
        token = t;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function distribute(uint256 amount) external {
        require(!broken, "broken");
        token.transferFrom(msg.sender, address(this), amount);
        received += amount;
    }
}

/// @notice creator-fee escrow stand-in: `claim()` pays its creator's accrued ETH and $FLIPPER
contract MockEscrow {
    address internal creator;
    uint256 internal eth;
    uint256 internal fl;
    IERC20 internal token;

    function setOwed(address c, uint256 e, uint256 f, IERC20 t) external {
        (creator, eth, fl, token) = (c, e, f, t);
    }

    function claim() external {
        (uint256 e, uint256 f) = (eth, fl);
        (eth, fl) = (0, 0);
        if (f != 0) token.transfer(creator, f);
        if (e != 0) {
            (bool ok,) = creator.call{value: e}("");
            require(ok, "eth");
        }
    }

    receive() external payable {}
}

contract RevenueTest is FlipperBase {
    function _lose(address who, uint256 amount) internal {
        uint256 id = _flip(who, address(flipperToken), amount);
        _reveal(id, LOSS_WORD);
    }

    /// ETH creator revenue is auctioned for $FLIPPER; what the lot fetches is split like creator $FLIPPER.
    function test_creator_fees_in_eth_auctioned_then_split_between_treasury_and_rewards() public {
        vm.deal(address(router), 10 ether);
        vm.prank(mallory);
        router.process();
        assertEq(address(router).balance, 0);
        assertEq(address(converter).balance, 10 ether);
        (address asset, uint128 remaining,, address kicker,) = _lot(0);
        assertEq(asset, address(0));
        assertEq(remaining, 10 ether);
        assertEq(kicker, address(router));

        // no reference yet: starts at the default and halves every 30 minutes
        uint256 p = converter.priceOf(0);
        assertEq(p, type(uint128).max);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        assertEq(converter.priceOf(0), p >> 1);

        // wait until it is below the pool price (1 ETH = 1M FLIPPER) and take it
        uint256 target = 900_000 ether;
        while (converter.priceOf(0) > target) vm.warp(vm.getBlockTimestamp() + 30 minutes);
        uint256 price = converter.priceOf(0);
        uint256 t0 = house.treasury();
        vm.startPrank(bob);
        flipperToken.approve(address(converter), type(uint256).max);
        uint256 paid = converter.take(0, 10 ether, price);
        vm.stopPrank();
        assertEq(paid, 10 * price);
        assertEq(bob.balance, 1010 ether);
        assertEq(flipperToken.balanceOf(address(router)), paid, "proceeds return to the router");
        assertEq(converter.lastPrice(address(0)), price);

        router.process();
        assertEq(house.treasury(), t0 + paid / 2, "50% to the bankroll");
        assertEq(router.rewardsFlipperPending(), paid - paid / 2, "50% held for holders (no distributor yet)");

        // the next ETH lot starts at 4x the last clearing price
        vm.deal(address(router), 1 ether);
        router.process();
        assertEq(converter.priceOf(1), price * 4);
    }

    function test_creator_fees_in_flipper_split_house_skim_all_to_rewards() public {
        _lose(alice, 1_000_000 ether);
        house.flushRewards(); // FLIPPER earmarked 100% rewards
        uint256 skim = router.houseRewardsPending();
        assertGt(skim, 0);
        flipperToken.mint(address(router), 1_000_000 ether); // creator fees paid in FLIPPER
        uint256 t0 = house.treasury();
        router.process();
        assertEq(house.treasury(), t0 + 500_000 ether, "50% of creator fees to bankroll");
        assertEq(router.rewardsFlipperPending(), skim + 500_000 ether);
        assertEq(router.houseRewardsPending(), 0);

        // a distributor streams everything held, pending included
        MockDistributor d = new MockDistributor(IERC20(address(flipperToken)));
        vm.prank(owner);
        router.setRewards(address(d));
        router.process();
        assertEq(d.received(), skim + 500_000 ether);
        assertEq(router.rewardsFlipperPending(), 0);
        assertEq(flipperToken.balanceOf(address(router)), 0);
    }

    function test_reverting_distributor_keeps_rewards_pending() public {
        flipperToken.mint(address(router), 1_000 ether);
        MockDistributor d = new MockDistributor(IERC20(address(flipperToken)));
        d.setBroken(true);
        vm.prank(owner);
        router.setRewards(address(d));
        router.process();
        assertEq(router.rewardsFlipperPending(), 500 ether);
        assertEq(flipperToken.allowance(address(router), address(d)), 0);
        d.setBroken(false);
        router.process();
        assertEq(d.received(), 500 ether);
    }

    function test_harvest_claims_fee_sources_and_pays_capped_bounty() public {
        MockEscrow esc = new MockEscrow();
        vm.deal(address(esc), 100 ether);
        flipperToken.mint(address(esc), 1_000_000 ether);
        esc.setOwed(address(router), 4 ether, 1_000_000 ether, IERC20(address(flipperToken)));
        vm.prank(owner);
        router.addHarvestCall(address(esc), abi.encodeCall(MockEscrow.claim, ()));
        _lose(alice, 1_000_000 ether); // house skim: flushed by harvest, no bounty on it

        uint256 capF = router.bountyCapFlipper();
        uint256 t0 = house.treasury();
        vm.prank(mallory, mallory);
        (uint256 bEth, uint256 bFl) = router.harvest();
        assertEq(bEth, 4 ether * 10 / 10_000, "0.1% of the ETH brought in");
        assertEq(bFl, capF < 1_000 ether ? capF : 1_000 ether, "0.1% of the FLIPPER, capped");
        assertEq(mallory.balance, 1000 ether + bEth);
        assertEq(flipperToken.balanceOf(mallory), 50_000_000 ether + bFl);
        assertEq(house.rewardsAccrued(), 0, "house share flushed");
        assertEq(house.treasury(), t0 + (1_000_000 ether - bFl) / 2);
        assertEq(address(converter).balance, 4 ether - bEth, "ETH auctioned");

        // nothing new: no bounty
        vm.prank(mallory, mallory);
        (bEth, bFl) = router.harvest();
        assertEq(bEth + bFl, 0);
        // pre-existing balances earn no bounty either
        vm.deal(address(router), 1 ether);
        vm.prank(mallory, mallory);
        (bEth, bFl) = router.harvest();
        assertEq(bEth, 0);
    }

    function test_harvest_bounty_capped_in_eth() public {
        MockEscrow esc = new MockEscrow();
        vm.deal(address(esc), 100 ether);
        esc.setOwed(address(router), 100 ether, 0, IERC20(address(flipperToken)));
        vm.prank(owner);
        router.addHarvestCall(address(esc), abi.encodeCall(MockEscrow.claim, ()));
        vm.prank(mallory, mallory);
        (uint256 bEth,) = router.harvest();
        assertEq(bEth, router.bountyCapEth());
    }

    function test_failing_harvest_call_is_skipped() public {
        MockEscrow esc = new MockEscrow();
        esc.setOwed(address(router), 1 ether, 0, IERC20(address(flipperToken))); // escrow has no ETH → reverts
        vm.startPrank(owner);
        router.addHarvestCall(address(esc), abi.encodeCall(MockEscrow.claim, ()));
        vm.stopPrank();
        vm.expectEmit(address(router));
        emit RevenueRouter.HarvestCallFailed(address(esc));
        router.harvest();
    }

    function test_harvest_targets_cannot_be_custodians_and_admin_is_owner_only() public {
        vm.startPrank(owner);
        vm.expectRevert(RevenueRouter.InvalidParams.selector);
        router.addHarvestCall(address(flipperToken), "");
        vm.expectRevert(RevenueRouter.InvalidParams.selector);
        router.addHarvestCall(address(house), "");
        vm.expectRevert(RevenueRouter.InvalidParams.selector);
        router.addHarvestCall(address(converter), "");
        vm.expectRevert(RevenueRouter.InvalidParams.selector);
        router.addHarvestCall(address(manager), "");
        vm.expectRevert(RevenueRouter.InvalidParams.selector);
        router.setUpkeepParams(address(converter), 101, 0, 0, 0);
        vm.stopPrank();
        vm.startPrank(mallory);
        vm.expectRevert();
        router.addHarvestCall(address(this), "");
        vm.expectRevert();
        router.setUpkeepParams(address(0), 0, 0, 0, 0);
        vm.expectRevert();
        router.setRewards(mallory);
        vm.stopPrank();
    }

    function test_eth_below_min_lot_waits() public {
        vm.deal(address(router), 0.0005 ether);
        router.process();
        assertEq(converter.lotsLength(), 0);
        vm.deal(address(router), 0.001 ether);
        router.process();
        assertEq(converter.lotsLength(), 1);
    }

    function _lot(uint256 id)
        internal
        view
        returns (address asset, uint128 remaining, uint64 startedAt, address kicker, uint256 startPrice)
    {
        DutchAuctionConverter.Lot memory l = converter.lot(id);
        assertEq(l.floorPrice, l.startPrice == type(uint128).max ? 0 : l.startPrice / 8, "floor: half the reference");
        return (l.asset, l.remaining, l.startedAt, l.kicker, l.startPrice);
    }
}
