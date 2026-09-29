// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {FlipperBase} from "./utils/FlipperBase.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {MockEntropyV2} from "../src/mocks/MockEntropyV2.sol";

/// @notice ERC20 whose transferFrom can trigger an Entropy reveal — used to deliver randomness *inside* one of
///         the house's own external calls (the nested-delivery / reentrancy scenario).
contract ReentrantToken is MockERC20 {
    MockEntropyV2 public entropy;
    address public provider;
    uint64 public armedSeq;
    bytes32 public armedWord;

    constructor() MockERC20("Reentrant", "RENT", 18) {}

    function arm(MockEntropyV2 e, address p, uint64 seq, bytes32 word) external {
        entropy = e;
        provider = p;
        armedSeq = seq;
        armedWord = word;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armedSeq != 0) {
            uint64 s = armedSeq;
            armedSeq = 0;
            entropy.reveal(provider, s, armedWord);
        }
        return super.transferFrom(from, to, amount);
    }
}

contract AdversarialTest is FlipperBase {
    uint256 internal constant STAKE = 1_000_000 ether; // ≈ 0.1 ETH of T

    /// Flash-inflate the target token at flip time, then make the house's *buy* fail at settlement (gas grief on
    /// the ETH→T direction) so the flip falls back to a $FLIPPER payout. The fallback must be valued at the
    /// settle-time price, not the inflated flip-time quote.
    function test_flashInflatedQuote_cannot_inflate_fallback() public {
        // control: honest quote
        FlipperHouseBase.Preview memory honest = house.previewFlip(address(tokenT), STAKE);

        // attacker pumps T hard, flips at the inflated price, and unwinds in the same transaction
        uint256 tBefore = tokenT.balanceOf(address(this));
        _buyWithEth(tPool, 100 ether);
        uint256 bought = tokenT.balanceOf(address(this)) - tBefore;
        uint256 id = _flip(mallory, address(tokenT), STAKE);
        _sellForEth(tPool, bought);
        (,,,,,,, uint128 liability, uint128 s, uint128 b,,) = house.flips(id);
        assertGt(b, honest.buyQuote * 2, "quote was inflated");

        // the house's buy is griefed (ETH→T is zeroForOne in the T pool); sells still work
        toggle.set(false, false, true, false);
        uint256 fBefore = flipperToken.balanceOf(mallory);
        _reveal(id, WIN_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.WonFallback));
        uint256 paid = flipperToken.balanceOf(mallory) - fBefore;

        // paid ≈ settle-time value × spread × 1.05, i.e. about the honest fallback — not the inflated one
        uint256 honestFallback = honest.buyQuote * 21_000 / 20_000;
        assertLe(paid, honestFallback * 101 / 100, "fallback bounded by settle-time value");
        assertLt(paid, uint256(b) * 21_000 / 20_000 / 2, "far below the inflated quote");
        liability;
        s;
        _assertSolvent();
    }

    /// Deflating the token at flip time only hurts the attacker: the cap and fallback are computed from the
    /// deflated quote, so a win at normal prices pays out at most the deflated value.
    function test_flashDeflatedQuote_only_hurts_attacker() public {
        FlipperHouseBase.Preview memory honest = house.previewFlip(address(tokenT), STAKE);
        uint256 dumped = 300_000_000 ether;
        _sellForEth(tPool, dumped);
        uint256 id = _flip(mallory, address(tokenT), STAKE);
        // unwind: buy back roughly what was dumped
        _buyWithEth(tPool, 45 ether);
        (,,,,,,,,, uint128 b,,) = house.flips(id);
        assertLt(b, honest.buyQuote, "deflated");

        uint256 fBefore = flipperToken.balanceOf(mallory);
        uint256 tBefore = tokenT.balanceOf(mallory);
        _reveal(id, WIN_WORD);
        // either the capped buy fails (fallback at the deflated quote) or it succeeds within the deflated cap
        uint256 flipperPaid = flipperToken.balanceOf(mallory) - fBefore;
        uint256 tokenPaid = tokenT.balanceOf(mallory) - tBefore;
        if (_status(id) == FlipperHouseBase.Status.WonFallback) {
            assertEq(tokenPaid, STAKE);
            assertLe(flipperPaid, uint256(b) * 21_000 / 20_000);
        } else {
            assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Won));
        }
        _assertSolvent();
    }

    /// The user's scenario: request, then dump the target in the next transaction so the lost stake is worth
    /// less. Payouts are denominated in the staked token, so the attacker gains nothing; the house's loss-side
    /// sale is protected by the slippage floor (beyond it the house simply keeps the tokens).
    function test_dump_between_request_and_callback() public {
        uint256 id = _flip(mallory, address(tokenT), STAKE);
        _sellForEth(tPool, 150_000_000 ether); // ~7.5% of the T reserve → ~-14% price
        _reveal(id, LOSS_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.LostInventory), "floor protects the house");

        id = _flip(mallory, address(tokenT), STAKE);
        _sellForEth(tPool, 150_000_000 ether);
        uint256 tBefore = tokenT.balanceOf(mallory);
        _reveal(id, WIN_WORD);
        // a cheaper token only makes the house's purchase cheaper; the winner still gets exactly 2x tokens
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Won));
        assertEq(tokenT.balanceOf(mallory) - tBefore, 2 * STAKE);
        _assertSolvent();
    }

    /// Asymmetric pool shutoff (sell works, buy refused): winners get the $FLIPPER fallback valued at the
    /// settle-time sell quote, which is exactly what the house would realise on the loss branch.
    function test_asymmetric_shutoff_fallback_is_symmetric_with_loss_branch() public {
        uint256 id = _flip(mallory, address(tokenT), STAKE);
        (,,,,,,,, uint128 s, uint128 b,,) = house.flips(id);
        toggle.set(true, false, false, false); // ETH→T refused
        uint256 fBefore = flipperToken.balanceOf(mallory);
        _reveal(id, WIN_WORD);
        uint256 paid = flipperToken.balanceOf(mallory) - fBefore;
        // base = min(B, S_settle · B / S); prices unchanged → base ≈ B → paid ≈ 1.05·B
        assertApproxEqRel(paid, uint256(b) * 21_000 / 20_000, 1e15);
        s;
        _assertSolvent();
    }

    /// Randomness delivered from inside the house's own external call (a token transfer hook) settles in safe
    /// mode: no swaps, no pushes, no reentrancy into accounting.
    function test_nested_delivery_forces_safe_mode() public {
        ReentrantToken rt = new ReentrantToken();
        PoolKey memory rtPool = _pool(MockERC20(address(rt)), IHooks(address(0)), 10_000_000, 200 ether);
        vm.prank(owner);
        house.setTokenRoute(address(rt), _route1(rtPool, flipperPool));
        rt.mint(mallory, 100_000_000 ether);
        vm.prank(mallory);
        rt.approve(address(house), type(uint256).max);

        uint256 first = _flip(mallory, address(rt), STAKE);
        rt.arm(entropy, provider, _seq(first), bytes32(WIN_WORD));
        uint256 treasuryBefore = house.treasury();
        uint256 second = _flip(mallory, address(rt), STAKE); // delivers `first` mid-transferFrom

        assertEq(uint8(_status(first)), uint8(FlipperHouseBase.Status.WinPending), "safe mode");
        assertEq(house.claimable(mallory, address(rt)), STAKE);
        assertEq(house.treasury(), treasuryBefore, "no market interaction");
        assertEq(uint8(_status(second)), uint8(FlipperHouseBase.Status.Pending));
        _reveal(second, LOSS_WORD);
        _assertSolvent();
    }

    /// Adding just-in-time liquidity to shrink the route cost (and dodge the chance-based fee), then pulling it,
    /// can at most restore the 45% base chance — still negative EV for the player — and settlement stays safe.
    function test_jit_liquidity_cannot_beat_base_odds() public {
        // a bankroll big enough for this stake under the half-Kelly cap at its ~9% route cost
        flipperToken.mint(address(this), 3_000_000_000 ether);
        house.depositTreasury(3_000_000_000 ether);
        uint256 amount = 75_000_000 ether;
        FlipperHouseBase.Preview memory before = house.previewFlip(address(tokenT), amount);
        assertLt(before.winChanceBps, 4500);
        _addFullRange(tPool, 2000 ether, 10_000_000);
        _addFullRange(flipperPool, 2000 ether, 1_000_000);
        FlipperHouseBase.Preview memory jit = house.previewFlip(address(tokenT), amount);
        assertEq(jit.winChanceBps, 4500, "capped at base odds");
        uint256 id = _flip(mallory, address(tokenT), amount);
        _removeFullRange(tPool, 2000 ether, 10_000_000);
        _removeFullRange(flipperPool, 2000 ether, 1_000_000);
        _reveal(id, WIN_WORD);
        // either bought within the cap or paid the capped fallback
        FlipperHouseBase.Status st = _status(id);
        assertTrue(st == FlipperHouseBase.Status.Won || st == FlipperHouseBase.Status.WonFallback);
        _assertSolvent();
    }

    /// Worst case for a Pyth out-of-order reveal: the attacker knows the outcome and triggers settlement inside
    /// their own transaction after manipulating the pool. Extraction is bounded by the loss floor and the
    /// fallback bonus, and the house stays EV-positive.
    function test_attacker_timed_settlement_is_bounded() public {
        // loss known → dump just under the floor, then deliver
        uint256 id = _flip(mallory, address(tokenT), STAKE);
        (,,,,,,,, uint128 s,,,) = house.flips(id);
        uint256 t0 = house.treasury() + house.rewardsAccrued();
        _sellForEth(tPool, 4_000_000 ether); // small dump
        _reveal(id, LOSS_WORD);
        uint256 received = house.treasury() + house.rewardsAccrued() - t0;
        if (_status(id) == FlipperHouseBase.Status.Lost) {
            assertGe(received, uint256(s) * 9500 / BPS, "loss proceeds >= 95% of quote");
        }

        // win known → pump well past the cap, then deliver
        id = _flip(mallory, address(tokenT), STAKE);
        (,,,,,,, uint128 liability,, uint128 b,,) = house.flips(id);
        _buyWithEth(tPool, 50 ether);
        uint256 f0 = flipperToken.balanceOf(mallory);
        _reveal(id, WIN_WORD);
        uint256 paid = flipperToken.balanceOf(mallory) - f0;
        assertLe(paid, liability, "never more than B * 1.05");
        assertLe(paid, uint256(b) * 21_000 / 20_000);

        // with a 5% floor and 5% bonus the house keeps ≥ 0.55·0.95 − 0.45·1.05 = 5.0% of stake value per flip
        assertGt(uint256(5500 * 9500), uint256(4500 * 10_500));
        _assertSolvent();
    }

    /// Many flips in flight can never over-commit the bankroll.
    function test_concurrent_flips_never_overcommit() public {
        uint256[] memory ids = new uint256[](40);
        for (uint256 i; i < ids.length; ++i) {
            uint256 maxL = house.previewFlip(address(flipperToken), 1).maxLiability; // the flip's own (Kelly) cap
            uint256 amt = maxL * BPS / WIN_COST;
            if (amt == 0) break;
            ids[i] = _flip(i % 2 == 0 ? alice : bob, address(flipperToken), amt);
            assertLe(house.reserved(), house.treasury());
        }
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] != 0) _reveal(ids[i], WIN_WORD); // every single one wins
            _assertSolvent();
        }
        // that many max-size wins halve the bankroll: the drawdown breaker locks and later outcomes wait
        // (settling the recorded wins can halve it again: the unlocker — this contract, the deployer — unlocks each time)
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == 0 || _status(ids[i]) != FlipperHouseBase.Status.Pending) continue;
            if (house.locked()) house.unlock(true);
            house.settleDeferred(ids[i]);
            _assertSolvent();
        }
        assertEq(house.reserved(), 0);
        assertGt(house.treasury(), 0);
        _assertSolvent();
    }
}
