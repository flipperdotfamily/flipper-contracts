// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FlipperBase} from "./utils/FlipperBase.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

contract FlipperHouseTest is FlipperBase {
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // $FLIPPER flips
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function test_flipperFlip_win_pays_the_payout() public {
        uint256 amount = 100_000 ether;
        uint256 balBefore = flipperToken.balanceOf(alice);
        uint256 treasuryBefore = house.treasury();

        uint256 id = _flip(alice, address(flipperToken), amount);
        assertEq(house.reserved(), amount * WIN_COST / BPS, "liability = payout - 1");
        assertEq(flipperToken.balanceOf(alice), balBefore - amount);

        _reveal(id, WIN_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Won));
        assertEq(flipperToken.balanceOf(alice), balBefore - amount + amount * PAYOUT / BPS, "2.05x payout");
        assertEq(house.treasury(), treasuryBefore - amount * WIN_COST / BPS);
        assertEq(house.reserved(), 0);
        _assertSolvent();
    }

    function test_flipperFlip_loss_goes_to_treasury_with_skim() public {
        uint256 amount = 100_000 ether;
        uint256 treasuryBefore = house.treasury();
        uint256 id = _flip(alice, address(flipperToken), amount);
        _reveal(id, LOSS_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Lost));
        // edge = 1 - 0.45 * 2.05 = 7.75%; holders get half of it, paid out of the loss (÷ P(loss) = 55%) → 7.05%
        uint256 edge = BPS - 4500 * PAYOUT / BPS;
        assertEq(edge, 775);
        uint256 toHolders = amount * edge * 5000 / (BPS * 5500);
        assertEq(house.rewardsAccrued(), toHolders, "half the expected profit to holders");
        assertEq(house.treasury(), treasuryBefore + amount - toHolders);
        _assertSolvent();
    }

    function test_winChance_boundary_matches_spec() public {
        // 45%: roll in [5500, 9999] wins ("rand*100 > 55")
        uint256 id = _flip(alice, address(flipperToken), 1 ether);
        _reveal(id, 5500);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Won));
        id = _flip(alice, address(flipperToken), 1 ether);
        _reveal(id, 5499);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Lost));
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Token flips
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function test_tokenFlip_quotes_and_winChance() public {
        uint256 amount = 1_000_000 ether; // ≈ 0.1 ETH
        FlipperHouseBase.Preview memory pv = house.previewFlip(address(tokenT), amount);
        assertEq(pv.code, 0);
        // two 1% hops each way → S ≈ 98% mid, B ≈ 102% mid → h ≈ 2% < 2.5% allowance
        assertGt(pv.buyQuote, pv.sellQuote);
        assertLt(pv.routeCostBps, 250);
        assertEq(pv.winChanceBps, 4500);
        assertEq(pv.liability, (pv.buyQuote * 21_000 + 20_000 - 1) / 20_000);
        emit log_named_uint("sellQuote", pv.sellQuote);
        emit log_named_uint("buyQuote", pv.buyQuote);
        emit log_named_uint("routeCostBps", pv.routeCostBps);
    }

    function test_tokenFlip_win_pays_exactly_2x_tokens() public {
        uint256 amount = 1_000_000 ether;
        uint256 balBefore = tokenT.balanceOf(alice);
        uint256 treasuryBefore = house.treasury();
        uint256 id = _flip(alice, address(tokenT), amount);
        (,,,,,,, uint128 liability,, uint128 buyQuote,,) = house.flips(id);

        _reveal(id, WIN_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Won));
        assertEq(tokenT.balanceOf(alice), balBefore + amount, "net +amount (2x back)");
        uint256 spent = treasuryBefore - house.treasury();
        assertApproxEqRel(spent, buyQuote, 1e14, "spent the quoted FLIPPER");
        assertLe(spent, liability);
        assertEq(house.reserved(), 0);
        assertEq(house.escrowed(address(tokenT)), 0);
        _assertSolvent();
    }

    function test_tokenFlip_loss_sells_into_treasury() public {
        uint256 amount = 1_000_000 ether;
        uint256 treasuryBefore = house.treasury();
        uint256 id = _flip(alice, address(tokenT), amount);
        (,,,,,,,, uint128 sellQuote,,,) = house.flips(id);

        _reveal(id, LOSS_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Lost));
        (,,,,,,,,, uint128 buyQuote,,) = house.flips(id);
        uint256 h = (uint256(buyQuote) - sellQuote) * BPS / (uint256(buyQuote) + sellQuote) + 1; // ceil
        uint256 edge = BPS - h - 2 * 4500;
        uint256 mid = (uint256(sellQuote) + buyQuote) / 2;
        uint256 basis = mid < sellQuote ? mid : sellQuote;
        uint256 toHolders = basis * (edge * 5000) / (BPS * 5500);
        assertApproxEqAbs(house.rewardsAccrued(), toHolders, 1e12);
        assertEq(house.treasury() + house.rewardsAccrued(), treasuryBefore + sellQuote);
        emit log_named_uint("edge bps (hookit-like 1%+1% route)", edge);
        assertEq(tokenT.balanceOf(address(house)), 0);
        _assertSolvent();
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Chance-based fee, route cost and bet limits
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// The house sponsors route costs out of its edge: odds stay at 45% until sponsoring the route would take the
    /// expected profit below the 2% floor (≈8% one-way), then shift just enough to hold the floor.
    function test_house_sponsors_route_costs_until_the_profit_floor() public {
        // room for large stakes under the half-Kelly cap (~0.6% of the bankroll at a 9% route cost)
        flipperToken.mint(address(this), 3_000_000_000 ether);
        house.depositTreasury(3_000_000_000 ether);
        uint256 amount = 40_000_000 ether; // ≈ 4 ETH into 200-ETH pools: route cost ~6%
        FlipperHouseBase.Preview memory pv = house.previewFlip(address(tokenT), amount);
        assertEq(pv.code, 0);
        assertGt(pv.routeCostBps, 250, "well above the old 2.5% trigger");
        assertLt(pv.routeCostBps, 800);
        assertEq(pv.winChanceBps, 4500, "sponsored: base odds");

        amount = 75_000_000 ether; // route cost > 8%: the chance fee holds the floor
        pv = house.previewFlip(address(tokenT), amount);
        assertEq(pv.code, 0, "accepted");
        assertGt(pv.routeCostBps, 800);
        assertEq(pv.winChanceBps, (BPS - pv.routeCostBps - 200) / 2);
        emit log_named_uint("routeCostBps", pv.routeCostBps);
        emit log_named_uint("winChanceBps", pv.winChanceBps);

        // expected profit at quotes after all swap costs >= 2% of mid
        uint256 mid = (pv.sellQuote + pv.buyQuote) / 2;
        int256 ev = int256((BPS - pv.winChanceBps) * pv.sellQuote) - int256(pv.winChanceBps * pv.buyQuote);
        assertGe(ev * 1e4 / int256(mid * BPS), 199, "house EV >= 2% after sponsoring every swap");
    }

    function test_rejects_route_cost_above_max() public {
        uint256 amount = 400_000_000 ether; // ≈ 40 ETH into 200-ETH pools → ~20%+ impact
        FlipperHouseBase.Preview memory pv = house.previewFlip(address(tokenT), amount);
        assertEq(pv.code, uint8(5));
        uint256 fee = house.randomnessFeeFor(address(tokenT));
        vm.expectRevert(abi.encodeWithSelector(FlipperHouseBase.FlipRejected.selector, uint8(5)));
        vm.prank(alice);
        house.flip{value: fee}(address(tokenT), amount, 0, block.timestamp);
    }

    function test_max_bet_is_half_kelly_under_the_5pct_ceiling() public {
        // the ceiling: 5% of the unreserved bankroll
        assertEq(house.maxLiability(), house.treasury() * 500 / BPS);
        // a $FLIPPER flip's own cap: half its Kelly fraction (4.169% at 2.05x) of the unreserved bankroll
        uint256 maxL = house.previewFlip(address(flipperToken), 1).maxLiability;
        assertApproxEqRel(maxL, house.treasury() * 20_843 / 1_000_000, 1e14);
        // FLIPPER flip whose 1.05x liability is just above the cap
        uint256 tooBig = maxL * BPS / WIN_COST + 1 ether;
        FlipperHouseBase.Preview memory pv = house.previewFlip(address(flipperToken), tooBig);
        assertEq(pv.code, uint8(7));
        assertEq(pv.maxLiability, maxL);
        uint256 ok = maxL * BPS / WIN_COST - 1 ether;
        uint256 id = _flip(alice, address(flipperToken), ok);
        // reservations shrink the next max bet
        assertEq(house.maxLiability(), (house.treasury() - house.reserved()) * 500 / BPS);
        assertLt(house.previewFlip(address(flipperToken), 1).maxLiability, maxL);
        _reveal(id, LOSS_WORD);
        _assertSolvent();
    }

    function test_minWinChance_protects_player() public {
        house.depositTreasury(100_000_000 ether);
        uint256 amount = 75_000_000 ether;
        FlipperHouseBase.Preview memory pv = house.previewFlip(address(tokenT), amount);
        uint256 fee = house.randomnessFeeFor(address(tokenT));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FlipperHouseBase.FlipRejected.selector, uint8(6)));
        house.flip{value: fee}(address(tokenT), amount, uint16(pv.winChanceBps + 1), block.timestamp);
    }

    function test_rejects_unlisted_token_and_zero_amount() public {
        assertEq(house.previewFlip(address(hookit), 1 ether).code, uint8(3));
        assertEq(house.previewFlip(address(tokenT), 0).code, uint8(2));
    }

    function test_excess_fee_refunded_and_insufficient_fee_rejected() public {
        uint256 fee = house.randomnessFeeFor(address(flipperToken));
        assertLt(fee, house.randomnessFeeFor(address(tokenT)), "FLIPPER flips use the smaller callback budget");
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        house.flip{value: fee + 1 ether}(address(flipperToken), 1 ether, 0, block.timestamp);
        assertEq(alice.balance, ethBefore - fee);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FlipperHouseBase.InsufficientFee.selector, fee - 1, fee));
        house.flip{value: fee - 1}(address(flipperToken), 1 ether, 0, block.timestamp);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Fallbacks
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function test_win_fallback_when_price_runs_away() public {
        uint256 amount = 1_000_000 ether;
        uint256 id = _flip(alice, address(tokenT), amount);
        (,,,,,,, uint128 liability, uint128 s, uint128 b,,) = house.flips(id);

        // T pumps ~20% before settlement → buying `amount` costs more than the cap
        _buyWithEth(tPool, 20 ether);

        uint256 tBefore = tokenT.balanceOf(alice);
        uint256 fBefore = flipperToken.balanceOf(alice);
        _reveal(id, WIN_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.WonFallback));
        assertEq(tokenT.balanceOf(alice), tBefore + amount, "stake returned");
        uint256 paid = flipperToken.balanceOf(alice) - fBefore;
        // settle-time value is higher than the flip-time buy quote → fallback = B * 1.05
        assertEq(paid, uint256(b) * 10_500 / 10_000);
        assertLe(paid, liability);
        s;
        _assertSolvent();
    }

    function test_loss_goes_to_inventory_when_price_crashes_then_auctioned() public {
        uint256 amount = 1_000_000 ether;
        uint256 id = _flip(alice, address(tokenT), amount);
        (,,,,,,,, uint128 sellQuote,,,) = house.flips(id);
        _sellForEth(tPool, 400_000_000 ether); // crash T ~ -60%
        _reveal(id, LOSS_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.LostInventory));
        assertEq(house.inventory(address(tokenT)), amount);
        assertEq(house.inventoryValue(address(tokenT)), sellQuote, "flip-time value recorded");
        _assertSolvent();

        // anyone sweeps it into the Dutch auction, referenced at 4x the flip-time value
        vm.prank(mallory);
        house.sweepInventory(address(tokenT), amount);
        assertEq(house.inventory(address(tokenT)), 0);
        assertEq(house.inventoryValue(address(tokenT)), 0);
        assertEq(tokenT.balanceOf(address(converter)), amount);
        assertEq(converter.priceOf(0), uint256(sellQuote) * 1e18 / amount * 4);

        uint256 t0 = house.treasury();
        vm.warp(vm.getBlockTimestamp() + 3 hours); // 6 half-lives: 4x → 1/16x, held at the floor: half the reference
        uint256 p = converter.priceOf(0);
        assertEq(p, uint256(sellQuote) * 1e18 / amount / 2);
        vm.startPrank(bob);
        flipperToken.approve(address(converter), type(uint256).max);
        uint256 paid = converter.take(0, amount, p);
        vm.stopPrank();
        assertEq(tokenT.balanceOf(bob), 500_000_000 ether + amount);
        assertEq(house.treasury(), t0 + paid, "proceeds land in the bankroll");
        _assertSolvent();
    }

    function test_pool_shutoff_between_request_and_callback() public {
        // the user's scenario: the target pool is switched off after the flip is requested
        uint256 amount = 1_000_000 ether;
        uint256 idWin = _flip(alice, address(tokenT), amount);
        uint256 idLoss = _flip(bob, address(tokenT), amount);
        toggle.set(true, true, false, false); // refuse all swaps on the T pool

        uint256 aliceT = tokenT.balanceOf(alice);
        _reveal(idWin, WIN_WORD);
        _reveal(idLoss, LOSS_WORD);

        // loser: loss stands, house keeps the tokens (no free option to void a loss)
        assertEq(uint8(_status(idLoss)), uint8(FlipperHouseBase.Status.LostInventory));
        // winner: stake back now, winnings reserved until anyone resolves it
        assertEq(uint8(_status(idWin)), uint8(FlipperHouseBase.Status.WinPending));
        assertEq(tokenT.balanceOf(alice), aliceT + amount);
        (,,,,,,, uint128 liability,,,,) = house.flips(idWin);
        assertEq(house.reserved(), liability);
        _assertSolvent();

        vm.expectRevert(FlipperHouseBase.TooEarly.selector); // buy still can't execute, timeout not reached
        house.resolvePendingWin(idWin);
        toggle.set(false, false, false, false);
        vm.prank(mallory);
        house.resolvePendingWin(idWin);
        assertEq(uint8(_status(idWin)), uint8(FlipperHouseBase.Status.Won));
        assertEq(tokenT.balanceOf(alice), aliceT + 2 * amount);
        assertEq(house.reserved(), 0);
        _assertSolvent();
    }

    function test_resolvePendingWin_after_timeout_pays_liability_in_flipper() public {
        uint256 id = _flip(alice, address(tokenT), 1_000_000 ether);
        toggle.set(true, true, false, false);
        _reveal(id, WIN_WORD);
        (, uint40 createdAt,,,,,, uint128 liability,,,,) = house.flips(id);
        vm.warp(uint256(createdAt) + 1 days - 1);
        vm.expectRevert(FlipperHouseBase.TooEarly.selector);
        house.resolvePendingWin(id);
        vm.warp(uint256(createdAt) + 1 days);
        uint256 t0 = house.treasury();
        uint256 f0 = flipperToken.balanceOf(alice);
        vm.prank(mallory);
        house.resolvePendingWin(id);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.WonFallback));
        assertEq(flipperToken.balanceOf(alice) - f0, liability);
        assertEq(house.treasury(), t0 - liability);
        assertEq(house.reserved(), 0);
        vm.expectRevert(FlipperHouseBase.BadStatus.selector);
        house.resolvePendingWin(id);
        _assertSolvent();
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Cancellation
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function test_cancel_rules() public {
        uint256 id = _flip(alice, address(tokenT), 1_000_000 ether);

        vm.prank(alice);
        vm.expectRevert(FlipperHouseBase.TooEarly.selector);
        house.cancelFlip(id);
        vm.prank(mallory);
        vm.expectRevert(FlipperHouseBase.Unauthorized.selector);
        house.cancelFlip(id);

        vm.warp(block.timestamp + 7 days);
        uint256 before = tokenT.balanceOf(alice);
        vm.prank(alice);
        house.cancelFlip(id);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Refunded));
        assertEq(tokenT.balanceOf(alice), before + 1_000_000 ether);
        assertEq(house.reserved(), 0);

        // a late delivery for a refunded flip is ignored
        _reveal(id, WIN_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Refunded));
        _assertSolvent();
    }

    function test_failed_delivery_reveals_then_recovers_in_safe_mode() public {
        uint256 amount = 1_000_000 ether;
        uint256 id = _flip(alice, address(tokenT), amount);
        uint64 seq = _seq(id);
        assertTrue(adapter.isPending(seq));

        // first attempt fails → Entropy marks CALLBACK_FAILED and the number is public
        vm.mockCallRevert(address(house), abi.encodeWithSelector(FlipperHouse.onRandomness.selector), "boom");
        _reveal(id, WIN_WORD);
        vm.clearMockedCalls();
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Pending));
        assertFalse(adapter.isPending(seq), "revealed");

        // the player, knowing they won or lost, can never cancel a revealed flip
        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        vm.expectRevert(FlipperHouseBase.RandomnessRevealed.selector);
        house.cancelFlip(id);

        // anyone recovers it at a time of their choosing, with the market manipulated in the same tx —
        // safe mode ignores markets entirely
        _buyWithEth(tPool, 20 ether);
        uint256 t0 = house.treasury();
        vm.prank(mallory);
        entropy.reveal(provider, seq, bytes32(WIN_WORD));
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.WinPending));
        assertEq(house.claimable(alice, address(tokenT)), amount, "stake credited, no push");
        assertEq(house.treasury(), t0, "no market interaction");
        _assertSolvent();

        uint256 before = tokenT.balanceOf(alice);
        vm.prank(alice);
        house.claim(address(tokenT));
        assertEq(tokenT.balanceOf(alice), before + amount);
    }

    function test_safe_mode_loss_goes_to_inventory() public {
        uint256 id = _flip(alice, address(tokenT), 1_000_000 ether);
        vm.mockCallRevert(address(house), abi.encodeWithSelector(FlipperHouse.onRandomness.selector), "boom");
        _reveal(id, LOSS_WORD);
        vm.clearMockedCalls();
        _sellForEth(tPool, 100_000_000 ether); // attacker dumps before recovering
        entropy.reveal(provider, _seq(id), bytes32(LOSS_WORD));
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.LostInventory));
        assertEq(house.inventory(address(tokenT)), 1_000_000 ether);
        _assertSolvent();
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Admin bounds
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function test_params_bounds() public {
        FlipperHouseBase.Params memory p = defaultParams();
        vm.startPrank(owner);
        p.baseWinChanceBps = 5000;
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setParams(p);
        p = defaultParams();
        p.flipperPayoutBps = 22_000;
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setParams(p);
        p = defaultParams();
        p.maxBetBps = 2000;
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setParams(p);
        p = defaultParams();
        p.callbackGasLimit = 1_000_000; // < swapGas + settlement reserve
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        house.setParams(p);
        vm.stopPrank();
    }

    function test_bankroll_withdrawals_are_vault_only_and_exclude_reserved() public {
        _flip(alice, address(flipperToken), 1_000_000 ether);
        uint256 free = house.treasury() - house.reserved();
        // once the staking vault is set, the owner can no longer withdraw bankroll (it belongs to stakers too)
        vm.prank(owner);
        vm.expectRevert(FlipperHouseBase.Unauthorized.selector);
        house.withdrawTreasury(owner, 1);
        vm.startPrank(address(vault));
        vm.expectRevert(FlipperHouseBase.ExceedsAvailable.selector);
        house.withdrawTreasury(owner, free + 1);
        house.withdrawTreasury(owner, free);
        vm.stopPrank();
        _assertSolvent();
    }

    function test_only_randomness_adapter_can_deliver() public {
        uint256 id = _flip(alice, address(flipperToken), 1 ether);
        uint64 seq = _seq(id);
        vm.prank(mallory);
        vm.expectRevert(FlipperHouseBase.OnlyRandomness.selector);
        house.onRandomness(seq, WIN_WORD, false);
    }

    function test_pause_blocks_new_flips_not_settlement() public {
        uint256 id = _flip(alice, address(flipperToken), 1 ether);
        vm.prank(owner);
        house.setPaused(true);
        assertEq(house.previewFlip(address(flipperToken), 1 ether).code, uint8(1));
        _reveal(id, WIN_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Won));
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Gas
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function test_gas_settlement_within_callback_limit() public {
        uint32 cbGas = house.params().callbackGasLimit;
        uint256 id = _flip(alice, address(tokenT), 1_000_000 ether);
        uint256 g = gasleft();
        _reveal(id, WIN_WORD);
        uint256 usedWin = g - gasleft();
        id = _flip(alice, address(tokenT), 1_000_000 ether);
        g = gasleft();
        _reveal(id, LOSS_WORD);
        uint256 usedLoss = g - gasleft();
        emit log_named_uint("win settlement gas (incl. entropy)", usedWin);
        emit log_named_uint("loss settlement gas (incl. entropy)", usedLoss);
        assertLt(usedWin, cbGas);
        assertLt(usedLoss, cbGas);
    }

}
