// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {FlipperBase} from "./utils/FlipperBase.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {TreasuryVault} from "../src/TreasuryVault.sol";
import {FlipperLens} from "../src/lens/FlipperLens.sol";
import {IRandomnessAdapter} from "../src/interfaces/IRandomness.sol";
import {IEntropyV2} from "../src/interfaces/IEntropyV2.sol";
import {FlipperDeploy} from "../script/lib/FlipperDeploy.sol";

/// @notice Bankroll staking: 20% of depositors' pro-rata gains accrue to them, 80% becomes protocol-owned, under a
///         high-water mark; lock + cooldown exits out of the free bankroll; non-transferable receipt.
contract TreasuryVaultTest is FlipperBase {
    uint256 internal constant M = 1_000_000 ether;
    uint256 internal constant SEED = 100_000_000 ether; // FlipperBase's bankroll
    uint256 internal constant ONE = 1e27; // TreasuryVault.PPS_SCALE

    function setUp() public override {
        super.setUp();
        address[3] memory users = [alice, bob, mallory];
        for (uint256 i; i < 3; ++i) {
            vm.prank(users[i]);
            flipperToken.approve(address(vault), type(uint256).max);
        }
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────────────

    function _stake(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(assets, 0);
    }

    /// @dev an inflow that isn't a deposit (router revenue, donations): anyone may add to the bankroll
    function _donate(uint256 amount) internal {
        flipperToken.mint(address(this), amount);
        house.depositTreasury(amount);
    }

    function _value(address who) internal view returns (uint256 assets) {
        (, assets,,,) = vault.positionOf(who);
    }

    function _pol() internal view returns (uint256 assets) {
        (,,,,, assets,) = vault.stats();
    }

    /// @dev request everything not yet pending, wait out lock and cooldown, withdraw
    function _exit(address who) internal returns (uint256 assets) {
        uint256 until = vault.unlockAt(who);
        if (vm.getBlockTimestamp() < until) vm.warp(until);
        (uint256 pend,) = vault.pending(who);
        uint256 shares = vault.balanceOf(who) - pend;
        vm.prank(who);
        vault.requestWithdraw(shares);
        vm.warp(vm.getBlockTimestamp() + vault.withdrawCooldown());
        vm.prank(who);
        assets = vault.withdraw(0);
    }

    /// @dev won $FLIPPER flips staking `amount` in all: the bankroll pays 1.05x the stake. In pieces of at most 1M,
    ///      each within the half-Kelly bet cap (≈1.45% of the free bankroll)
    function _winFlip(address who, uint256 amount) internal returns (uint256 houseLoss) {
        uint256 t0 = house.treasury();
        _flips(who, amount, WIN_WORD);
        houseLoss = t0 - house.treasury();
    }

    /// @dev lost $FLIPPER flips staking `amount` in all: the bankroll keeps the stake less the holders' share
    function _loseFlip(address who, uint256 amount) internal returns (uint256 houseGain) {
        uint256 t0 = house.treasury();
        _flips(who, amount, LOSS_WORD);
        houseGain = house.treasury() - t0;
    }

    function _flips(address who, uint256 amount, uint256 word) internal {
        for (uint256 left = amount; left != 0;) {
            uint256 a = left < M ? left : M;
            _reveal(_flip(who, address(flipperToken), a), word);
            left -= a;
        }
    }

    function _freshSystem() internal returns (FlipperDeploy.System memory) {
        FlipperDeploy.Config memory c = FlipperDeploy.Config({
            poolManager: manager,
            entropy: IEntropyV2(address(entropy)),
            entropyProvider: provider,
            deployer: address(this),
            owner: address(this),
            proxyAdminOwner: proxyAdminOwner,
            params: defaultParams()
        });
        return FlipperDeploy.deployCore(
            c, FlipperDeploy.deployRouter(c), IERC20(address(flipperToken)), FlipperDeploy.deployPythAdapter(c)
        );
    }

    // ── deployment ───────────────────────────────────────────────────────────────────────────────────

    function test_deployment_wiring_and_defaults() public view {
        assertEq(house.vault(), address(vault));
        assertEq(address(vault.house()), address(house));
        assertEq(address(vault.flipper()), address(flipperToken));
        assertEq(vault.owner(), owner);
        assertEq(vault.name(), "Staked FLIPPER");
        assertEq(vault.symbol(), "sFLIPPER");
        assertEq(vault.decimals(), 18);
        assertEq(vault.performanceFeeBps(), 8000);
        assertEq(vault.lockDuration(), 7 days);
        assertEq(vault.withdrawCooldown(), 2 days);
        assertEq(vault.PPS_SCALE(), ONE);
    }

    // ── the user's worked example ────────────────────────────────────────────────────────────────────

    /// The vault holds 10 FLIPPER, a user deposited 1 of them, the vault earns 1: the user's value rises by 0.02
    /// (20% of their 0.1 pro-rata share), not by 0.1; the protocol's by 0.98.
    function test_worked_example() public {
        // a fresh system whose whole bankroll is 9 FLIPPER of protocol-owned liquidity
        TreasuryVault v = _freshSystem().vault;
        FlipperHouse h = FlipperHouse(payable(address(v.house())));
        flipperToken.mint(address(this), 10 ether);
        flipperToken.approve(address(h), type(uint256).max);
        h.depositTreasury(9 ether);
        v.crystallize();
        assertEq(v.protocolShares(), 9 ether);
        assertEq(v.totalAssets(), 9 ether);

        vm.startPrank(alice);
        flipperToken.approve(address(v), type(uint256).max);
        assertEq(v.deposit(1 ether, 0), 1 ether, "1:1");
        vm.stopPrank();
        assertEq(v.totalAssets(), 10 ether);

        h.depositTreasury(1 ether);
        (, uint256 value,,,) = v.positionOf(alice);
        (,,,,, uint256 pol,) = v.stats();
        assertApproxEqAbs(value, 1.02 ether, 1, "user +0.02");
        assertLe(value, 1.02 ether, "never above the exact share");
        assertApproxEqAbs(pol, 9.98 ether, 1, "protocol +0.98");

        // price after the fee 1 + 20%·0.1 = 1.02: the protocol is minted f shares with 11 / (10 + f) = 1.02
        uint256 feeShares = Math.mulDiv(11 ether, ONE, 1.02e27, Math.Rounding.Ceil) - 10 ether;
        uint256 ppsAfter = Math.mulDiv(11 ether, ONE, 10 ether + feeShares);
        vm.expectEmit(address(v));
        emit TreasuryVault.Crystallized(11 ether, ppsAfter, 0.08 ether, feeShares);
        v.crystallize();
        assertEq(v.protocolShares(), 9 ether + feeShares);

        vm.warp(v.unlockAt(alice));
        vm.prank(alice);
        v.requestWithdraw(1 ether);
        vm.warp(vm.getBlockTimestamp() + v.withdrawCooldown());
        vm.prank(alice);
        uint256 out = v.withdraw(0);
        assertApproxEqAbs(out, 1.02 ether, 1);
        assertLe(out, 1.02 ether);
        (,,,,, pol,) = v.stats();
        assertApproxEqAbs(pol, 9.98 ether, 1);
        assertEq(pol, h.treasury(), "everything left is protocol-owned");
    }

    // ── bootstrap ────────────────────────────────────────────────────────────────────────────────────

    function test_seeded_bankroll_bootstraps_as_protocol_owned() public {
        assertEq(vault.totalShares(), 0, "bootstrap is lazy");
        (uint256 a, uint256 d, uint256 p, uint256 pps, uint256 h, uint256 polA, uint256 dA) = vault.stats();
        assertEq(a, SEED);
        assertEq(d, 0);
        assertEq(p, SEED, "previewed 1:1");
        assertEq(pps, ONE);
        assertEq(h, ONE);
        assertEq(polA, SEED);
        assertEq(dA, 0);

        vm.expectEmit(address(vault));
        emit TreasuryVault.Bootstrapped(SEED);
        vault.crystallize();
        assertEq(vault.protocolShares(), SEED);
        assertEq(vault.hwm(), ONE);

        // protocol-only growth: nothing to charge, the mark follows the price
        _donate(10 * M);
        vault.crystallize();
        assertEq(vault.protocolShares(), SEED, "no fee shares without depositors");
        assertEq(vault.hwm(), 1.1e27);
        // a depositor then enters at the current price (and is only ever charged on gains above it)
        assertEq(_stake(alice, 11 * M), 10 * M);
        assertApproxEqAbs(_value(alice), 11 * M, 1);
    }

    function test_empty_vault_first_deposit_is_1to1() public {
        TreasuryVault v = _freshSystem().vault;
        FlipperHouse h = FlipperHouse(payable(address(v.house())));
        assertEq(v.totalAssets(), 0);
        vm.startPrank(alice);
        flipperToken.approve(address(v), type(uint256).max);
        assertEq(v.previewDeposit(5 ether), 5 ether);
        assertEq(v.deposit(5 ether, 5 ether), 5 ether, "1:1 into an empty vault");
        vm.stopPrank();
        assertEq(v.protocolShares(), 0);

        // alone in the vault she still keeps only 20% of her gain; the rest becomes protocol-owned
        flipperToken.mint(address(this), 5 ether);
        flipperToken.approve(address(h), type(uint256).max);
        h.depositTreasury(5 ether);
        (, uint256 assets,,,) = v.positionOf(alice);
        assertApproxEqAbs(assets, 6 ether, 1);

        vm.warp(v.unlockAt(alice));
        vm.prank(alice);
        v.requestWithdraw(5 ether);
        vm.warp(vm.getBlockTimestamp() + v.withdrawCooldown());
        vm.prank(alice);
        assertApproxEqAbs(v.withdraw(0), 6 ether, 1);
        // the rest of her gain stays in the bankroll as protocol-owned liquidity, for good
        (,,,,, uint256 pol,) = v.stats();
        assertApproxEqAbs(pol, 4 ether, 1);
        assertEq(v.totalShares(), v.protocolShares());
    }

    function test_wiped_out_bankroll_rejects_deposits() public {
        _stake(alice, M);
        vm.mockCall(address(house), abi.encodeWithSelector(house.treasury.selector), abi.encode(uint256(0)));
        assertEq(vault.previewDeposit(M), 0);
        vm.prank(bob);
        vm.expectRevert(TreasuryVault.NoAssets.selector);
        vault.deposit(M, 0);
        vm.clearMockedCalls();
    }

    // ── fee split ────────────────────────────────────────────────────────────────────────────────────

    function test_multi_depositor_pro_rata() public {
        vault.crystallize();
        _stake(alice, 10 * M);
        _stake(bob, 30 * M);
        assertEq(vault.balanceOf(bob), 3 * vault.balanceOf(alice));

        _donate(14 * M); // +10% on 140M
        assertApproxEqAbs(_value(alice), 10 * M + M / 5, 2, "alice keeps 20% of her 1M");
        assertApproxEqAbs(_value(bob), 30 * M + 3 * M / 5, 2, "bob keeps 20% of his 3M");
        assertApproxEqAbs(_pol(), 113 * M + M / 5, 2, "10M own + 3.2M of fees");
        vault.crystallize();
        assertApproxEqAbs(_value(bob) - 30 * M, 3 * (_value(alice) - 10 * M), 3);
    }

    function test_high_water_mark_charges_only_above_the_previous_high() public {
        vault.crystallize();
        _stake(alice, 50 * M); // 1/3 of 150M

        uint256 loss = _winFlip(bob, 2 * M);
        assertEq(loss, 2 * M * WIN_COST / BPS);
        uint256 pol0 = vault.protocolShares();
        vault.crystallize();
        assertEq(vault.protocolShares(), pol0, "no fee in a drawdown");
        assertEq(vault.hwm(), ONE);
        assertApproxEqAbs(_value(alice), 50 * M - loss / 3, 1, "bears her share of the loss");

        _donate(loss); // back to exactly the previous high
        vault.crystallize();
        assertEq(vault.protocolShares(), pol0, "recovery up to the mark is fee-free");
        assertApproxEqAbs(_value(alice), 50 * M, 1);

        _donate(15 * M); // +10% above the mark
        assertApproxEqAbs(_value(alice), 51 * M, 2, "20% of her share of the excess only");
        vault.crystallize();
        assertApproxEqAbs(vault.hwm(), 1.02e27, 1e3); // (1e-24 relative)

        // a second drawdown and recovery to the new mark: fee-free again
        uint256 pol1 = vault.protocolShares();
        uint256 loss2 = _winFlip(bob, 3 * M);
        vault.crystallize();
        assertEq(vault.protocolShares(), pol1);
        _donate(loss2);
        vault.crystallize();
        assertEq(vault.protocolShares(), pol1, "no fee up to the new mark");
        assertApproxEqAbs(_value(alice), 51 * M, 2);
    }

    /// A deposit during a drawdown buys in at the lower price and never moves existing depositors' value. The mark
    /// is global: the recovery up to it is fee-free for everyone present, then all pay on the excess.
    function test_deposit_after_drawdown() public {
        vault.crystallize();
        _stake(alice, 50 * M);
        uint256 loss;
        for (uint256 i; i < 3; ++i) {
            loss += _winFlip(mallory, 5 * M);
        }
        assertEq(loss, 15 * M * WIN_COST / BPS); // 15.75M at 2.05x
        uint256 pps = (150 * M - loss) * ONE / (150 * M);
        assertEq(vault.previewPricePerShare(), pps); // 0.895

        uint256 aliceBefore = _value(alice);
        uint256 bobIn = 10 * M * pps / ONE;
        assertEq(_stake(bob, bobIn), 10 * M, "buys in at the lower price");
        assertApproxEqAbs(_value(alice), aliceBefore, 1, "others' value unchanged");
        assertApproxEqAbs(_value(bob), bobIn, 1);

        _donate(160 * M - (150 * M - loss + bobIn)); // back to 1.0 (the mark)
        vault.crystallize();
        assertEq(vault.hwm(), ONE, "no fee below the mark");
        assertApproxEqAbs(_value(alice), 50 * M, 2);
        assertApproxEqAbs(_value(bob), 10 * M, 2);

        _donate(16 * M); // 176 / 160 = 1.1
        assertApproxEqAbs(_value(alice), 51 * M, 2);
        assertApproxEqAbs(_value(bob), 10 * M + M / 5, 2);
    }

    function test_real_flip_pnl_moves_the_price() public {
        vault.crystallize();
        _stake(alice, 50 * M); // 1/3 of the vault
        uint256 aShares = vault.balanceOf(alice);

        // a lost $FLIPPER flip: the bankroll keeps the stake less the holders' share (half the 7.75% edge ÷ 55%),
        // alice keeps 20% of her third of it
        uint256 g1 = _loseFlip(bob, 3 * M);
        assertEq(g1, 3 * (M - M * 775 * 5000 / (BPS * 5500)));
        assertApproxEqAbs(_value(alice), 50 * M + g1 / 15, 2);
        vault.crystallize();

        // a lost token flip: the stake is sold through the pools into the bankroll
        uint256 v1 = _value(alice);
        uint256 s1 = vault.totalShares();
        uint256 t0 = house.treasury();
        uint256 id = _flip(bob, address(tokenT), 10 * M);
        _reveal(id, LOSS_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Lost));
        uint256 g2 = house.treasury() - t0;
        assertGt(g2, 0);
        assertApproxEqAbs(_value(alice), v1 + Math.mulDiv(g2, aShares, s1) / 5, 2);
        vault.crystallize();

        // a won $FLIPPER flip: the bankroll pays out, alice bears her full pro-rata share, no fee is minted
        uint256 v2 = _value(alice);
        uint256 s2 = vault.totalShares();
        uint256 pol = vault.protocolShares();
        uint256 l1 = _winFlip(bob, 2 * M);
        vault.crystallize();
        assertEq(vault.protocolShares(), pol);
        assertApproxEqAbs(_value(alice), v2 - Math.mulDiv(l1, aShares, s2), 2);
        _assertSolvent();
    }

    function test_router_creator_fee_deposit_counts_as_inflow() public {
        vault.crystallize();
        _stake(alice, 50 * M);
        flipperToken.mint(address(router), 3 * M); // creator fees paid in $FLIPPER
        uint256 t0 = house.treasury();
        router.process();
        uint256 inflow = house.treasury() - t0;
        assertEq(inflow, 3 * M / 2, "the router's treasury share");
        assertApproxEqAbs(_value(alice), 50 * M + inflow / 15, 2, "20% of her third");

        uint256 pol = vault.protocolShares();
        vault.crystallize();
        assertGt(vault.protocolShares(), pol, "80% became protocol-owned");
    }

    // ── lock / cooldown / cancel ─────────────────────────────────────────────────────────────────────

    function test_lock_blocks_requests_and_a_new_deposit_extends_it() public {
        uint256 t0 = vm.getBlockTimestamp();
        _stake(alice, M);
        assertEq(vault.unlockAt(alice), t0 + 7 days);
        vm.warp(t0 + 3 days);
        _stake(alice, M);
        uint256 until = t0 + 10 days;
        assertEq(vault.unlockAt(alice), until, "all shares relocked");

        vm.warp(until - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.Locked.selector, until));
        vault.requestWithdraw(1);

        // shortening the lock applies to new deposits only
        vm.prank(owner);
        vault.setParams(8000, 1 days, 2 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.Locked.selector, until));
        vault.requestWithdraw(1);

        vm.warp(until);
        vm.prank(alice);
        vault.requestWithdraw(1);
    }

    function test_cooldown_resets_per_request_and_pending_shares_stay_staked() public {
        vault.crystallize();
        uint256 shares = _stake(alice, 30 * M);
        uint256 t = vault.unlockAt(alice);
        vm.warp(t);
        vm.expectEmit(address(vault));
        emit TreasuryVault.WithdrawRequested(alice, shares / 2, t + 2 days);
        vm.prank(alice);
        vault.requestWithdraw(shares / 2);

        vm.warp(t + 1 days);
        vm.prank(alice);
        vault.requestWithdraw(shares - shares / 2);
        (uint256 pend, uint256 ready) = vault.pending(alice);
        assertEq(pend, shares);
        assertEq(ready, t + 3 days, "cooldown restarted");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.ExceedsBalance.selector, 0));
        vault.requestWithdraw(1);

        vm.warp(t + 3 days - 1);
        assertEq(vault.maxWithdrawable(alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.CoolingDown.selector, t + 3 days));
        vault.withdraw(0);

        // pending shares keep earning (and paying the fee)
        _donate(13 * M); // +10% on 130M
        vm.warp(t + 3 days);
        uint256 expected = vault.maxWithdrawable(alice);
        assertApproxEqAbs(expected, 30 * M + 3 * M / 5, 2);
        vm.expectEmit(true, false, false, false, address(vault));
        emit TreasuryVault.Withdraw(alice, 0, 0);
        vm.prank(alice);
        uint256 out = vault.withdraw(expected);
        assertEq(out, expected);
        assertEq(vault.balanceOf(alice), 0);
        (pend, ready) = vault.pending(alice);
        assertEq(pend + ready, 0);
        assertEq(flipperToken.balanceOf(alice), 20 * M + out);
    }

    function test_cancel_withdraw() public {
        uint256 shares = _stake(alice, M);
        vm.warp(vault.unlockAt(alice));
        vm.startPrank(alice);
        vm.expectRevert(TreasuryVault.NothingPending.selector);
        vault.cancelWithdraw();
        vault.requestWithdraw(shares);
        vm.expectEmit(address(vault));
        emit TreasuryVault.WithdrawCancelled(alice, shares);
        vault.cancelWithdraw();
        (uint256 pend, uint256 ready) = vault.pending(alice);
        assertEq(pend + ready, 0);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(TreasuryVault.NothingPending.selector);
        vault.withdraw(0);
        vault.requestWithdraw(shares); // still unlocked: can re-request
        vm.stopPrank();
    }

    function test_min_shares_min_assets_and_zero_amounts() public {
        vault.crystallize();
        vm.startPrank(alice);
        vm.expectRevert(TreasuryVault.ZeroAmount.selector);
        vault.deposit(0, 0);
        uint256 preview = vault.previewDeposit(M);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.Slippage.selector, preview, preview + 1));
        vault.deposit(M, preview + 1);
        assertEq(vault.deposit(M, preview), preview);

        vm.warp(vault.unlockAt(alice));
        vm.expectRevert(TreasuryVault.ZeroAmount.selector);
        vault.requestWithdraw(0);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.ExceedsBalance.selector, preview));
        vault.requestWithdraw(preview + 1);
        vault.requestWithdraw(preview);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        uint256 out = vault.maxWithdrawable(alice);
        assertEq(out, vault.previewRedeem(preview));
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.Slippage.selector, out, out + 1));
        vault.withdraw(out + 1);
        assertEq(vault.withdraw(out), out);
        vm.stopPrank();

        // too small to buy a single share at the current price
        _donate(SEED);
        vm.prank(bob);
        vm.expectRevert(TreasuryVault.ZeroShares.selector);
        vault.deposit(1, 0);
    }

    // ── free bankroll ────────────────────────────────────────────────────────────────────────────────

    function test_withdrawal_limited_by_reserved_liabilities() public {
        vault.crystallize();
        flipperToken.mint(alice, 400 * M);
        flipperToken.mint(bob, 200 * M);
        uint256 shares = _stake(alice, 400 * M); // alice owns 80% of 500M
        vm.warp(vault.unlockAt(alice));
        vm.prank(alice);
        vault.requestWithdraw(shares);
        vm.warp(vm.getBlockTimestamp() + 2 days);

        // pending flips reserve their worst case out of the bankroll (each at its half-Kelly cap)
        uint256[] memory ids = new uint256[](40);
        uint256 n;
        while (house.treasury() - house.reserved() >= 400 * M) {
            ids[n++] = _flip(bob, address(flipperToken), house.previewFlip(address(flipperToken), 1).maxLiability * BPS / WIN_COST - 1 ether);
        }
        uint256 free = house.treasury() - house.reserved();
        assertLt(free, 400 * M);
        assertEq(vault.maxWithdrawable(alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.InsufficientFreeBankroll.selector, free));
        vault.withdraw(0);

        // the flips settle (the house wins): reservations are released and alice exits with 20% of her share
        uint256 t0 = house.treasury();
        for (uint256 i; i < n; ++i) {
            _reveal(ids[i], LOSS_WORD);
        }
        uint256 gain = house.treasury() - t0;
        assertEq(house.reserved(), 0);
        uint256 out = vault.maxWithdrawable(alice);
        assertApproxEqAbs(out, 400 * M + gain * 4 / 25, 3);
        vm.prank(alice);
        assertEq(vault.withdraw(0), out);
        _assertSolvent();
    }

    // ── protocol-owned liquidity / admin ─────────────────────────────────────────────────────────────

    function test_protocol_owned_liquidity_never_leaves() public {
        vault.crystallize();
        _stake(alice, 50 * M);
        _donate(15 * M);
        vault.crystallize();
        uint256 polShares = vault.protocolShares();
        assertGt(polShares, SEED);

        // nothing moves the protocol's shares or their assets out, not even for the owner
        vm.prank(owner);
        (bool ok,) = address(vault).call(abi.encodeWithSignature("withdrawProtocol(address,uint256)", owner, 1));
        assertFalse(ok, "no withdrawProtocol");

        // every depositor leaves; the protocol-owned liquidity stays behind as the whole bankroll
        _exit(alice);
        assertEq(vault.totalShares(), vault.protocolShares());
        assertGe(vault.protocolShares(), polShares);
        assertEq(_pol(), house.treasury());
        assertGt(_pol(), SEED);
    }

    function test_params_are_bounded_owner_only_and_never_retroactive() public {
        vault.crystallize();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vault.setParams(0, 0, 0);
        vm.startPrank(owner);
        vm.expectRevert(TreasuryVault.InvalidParams.selector);
        vault.setParams(9501, 30 days, 2 days);
        vm.expectRevert(TreasuryVault.InvalidParams.selector);
        vault.setParams(8000, 365 days + 1, 2 days);
        vm.expectRevert(TreasuryVault.InvalidParams.selector);
        vault.setParams(8000, 30 days, 30 days + 1);
        vm.expectEmit(address(vault));
        emit TreasuryVault.ParamsUpdated(9500, 365 days, 30 days);
        vault.setParams(9500, 365 days, 30 days);
        vault.setParams(8000, 30 days, 2 days);
        vm.stopPrank();

        _stake(alice, 50 * M);
        _donate(15 * M); // +10%: charged at 80% even though the fee is about to change
        vm.prank(owner);
        vault.setParams(0, 30 days, 2 days);
        assertApproxEqAbs(_value(alice), 51 * M, 2);
        _donate(16_500_000 ether); // +10% again, now fee-free
        assertApproxEqAbs(_value(alice), 56_100_000 ether, 3);
    }

    function test_views_preview_the_crystallized_state() public {
        vault.crystallize();
        _stake(alice, 50 * M);
        _donate(15 * M);
        uint256 preview = vault.previewPricePerShare();
        (uint256 a, uint256 d, uint256 p, uint256 pps, uint256 h, uint256 polA, uint256 dA) = vault.stats();
        assertEq(pps, preview);
        assertEq(h, preview);
        assertEq(a, house.treasury());
        assertEq(d, vault.balanceOf(alice));
        (uint256 shares, uint256 v, uint256 unlocksAt, uint256 pend, uint256 ready) = vault.positionOf(alice);
        assertEq(shares, d);
        assertEq(v, dA);
        assertEq(vault.previewRedeem(shares), v);
        assertEq(unlocksAt, vault.unlockAt(alice));
        assertEq(pend + ready, 0);
        assertLe(polA + dA, a);
        uint256 previewShares = vault.previewDeposit(M);

        vault.crystallize();
        assertEq(vault.hwm(), preview);
        assertEq(vault.protocolShares(), p);
        assertEq(vault.totalShares(), p + d);
        assertEq(_stake(bob, M), previewShares);
    }

    function test_lens_vault_section() public {
        vault.crystallize();
        _stake(alice, 10 * M);
        _donate(11 * M);
        _flip(bob, address(flipperToken), M); // something reserved
        (FlipperLens.VaultView memory v, FlipperLens.VaultPositionView memory p) = lens.vault(vault, alice);
        (uint256 a, uint256 d, uint256 pol, uint256 pps, uint256 h, uint256 polA, uint256 dA) = vault.stats();
        assertEq(v.vault, address(vault));
        assertEq(v.totalAssets, a);
        assertEq(v.freeAssets, house.treasury() - house.reserved());
        assertLt(v.freeAssets, a);
        assertEq(v.depositorShares, d);
        assertEq(v.protocolShares, pol);
        assertEq(v.pricePerShare, pps);
        assertEq(v.highWaterMark, h);
        assertEq(v.protocolOwnedAssets, polA);
        assertEq(v.depositorAssets, dA);
        assertEq(v.performanceFeeBps, 8000);
        assertEq(v.lockDuration, 7 days);
        assertEq(v.withdrawCooldown, 2 days);
        (uint256 shares, uint256 assets, uint256 unlocksAt,,) = vault.positionOf(alice);
        assertEq(p.shares, shares);
        assertEq(p.assets, assets);
        assertEq(p.unlockAt, unlocksAt);
        assertEq(p.pendingShares + p.readyAt + p.maxWithdrawable, 0);
        assertEq(p.flipperBalance, flipperToken.balanceOf(alice));
        assertEq(p.flipperAllowance, type(uint256).max);
        (, p) = lens.vault(vault, address(0));
        assertEq(p.shares + p.assets + p.flipperBalance, 0, "totals only");
    }

    // ── receipt / house access ───────────────────────────────────────────────────────────────────────

    function test_receipt_is_non_transferable() public {
        _stake(alice, M);
        IERC20 receipt = IERC20(address(vault));
        vm.startPrank(alice);
        vm.expectRevert(TreasuryVault.NonTransferable.selector);
        receipt.transfer(bob, 1);
        vm.expectRevert(TreasuryVault.NonTransferable.selector);
        receipt.approve(bob, 1);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(TreasuryVault.NonTransferable.selector);
        receipt.transferFrom(alice, bob, 1);
        assertEq(receipt.allowance(alice, bob), 0);
        assertEq(receipt.balanceOf(alice), M);
    }

    function test_house_setVault_is_one_time_and_owner_only() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, mallory));
        house.setVault(address(lens));
        vm.prank(owner);
        vm.expectRevert(FlipperHouseBase.VaultAlreadySet.selector);
        house.setVault(address(lens));
        assertEq(house.vault(), address(vault));
    }

    function test_house_withdrawTreasury_is_vault_only_once_set() public {
        // a house without a vault: the owner manages the bankroll
        FlipperHouse h = FlipperHouse(
            payable(
                FlipperDeploy.proxy(
                    address(
                        new FlipperHouse(
                            manager, IERC20(address(flipperToken)), IRandomnessAdapter(address(adapter)), house.module()
                        )
                    ),
                    proxyAdminOwner,
                    abi.encodeCall(FlipperHouse.initialize, (owner, defaultParams()))
                )
            )
        );
        flipperToken.mint(address(this), 10 ether);
        flipperToken.approve(address(h), 10 ether);
        h.depositTreasury(10 ether);
        vm.prank(mallory);
        vm.expectRevert(FlipperHouseBase.Unauthorized.selector);
        h.withdrawTreasury(mallory, 1 ether);
        vm.startPrank(owner);
        h.withdrawTreasury(owner, 1 ether);
        vm.expectRevert(FlipperHouseBase.InvalidAddress.selector);
        h.setVault(mallory); // not a contract
        vm.expectEmit(address(h));
        emit FlipperHouseBase.VaultSet(address(vault));
        h.setVault(address(vault));
        vm.expectRevert(FlipperHouseBase.Unauthorized.selector);
        h.withdrawTreasury(owner, 1 ether);
        vm.stopPrank();
        vm.prank(address(vault));
        h.withdrawTreasury(alice, 1 ether);
        assertEq(h.treasury(), 8 ether);

        // the deployed house: the owner can't touch stakers' bankroll; the vault can, within the free part only
        vm.prank(owner);
        vm.expectRevert(FlipperHouseBase.Unauthorized.selector);
        house.withdrawTreasury(owner, 1);
        _flip(alice, address(flipperToken), M);
        uint256 free = house.treasury() - house.reserved();
        vm.startPrank(address(vault));
        vm.expectRevert(FlipperHouseBase.ExceedsAvailable.selector);
        house.withdrawTreasury(bob, free + 1);
        house.withdrawTreasury(bob, free);
        vm.stopPrank();
        _assertSolvent();
    }

    // ── rounding ─────────────────────────────────────────────────────────────────────────────────────

    /// Each depositor gets at most principal + 20% of their pro-rata gain (exact rational bound, no tolerance
    /// in their favour), and loses at most a few wei to rounding.
    function testFuzz_withdrawals_never_exceed_the_exact_share(uint256 a, uint256 b, uint256 gain) public {
        a = bound(a, 1, 40 * M);
        b = bound(b, 1, 40 * M);
        gain = bound(gain, 0, 60 * M);
        vault.crystallize();
        uint256 sa = _stake(alice, a);
        uint256 sb = _stake(bob, b);
        uint256 a0 = house.treasury();
        uint256 s0 = vault.totalShares();
        assertEq(a0, s0, "entered at 1:1");
        _donate(gain);

        uint256 outA = _exit(alice);
        uint256 outB = _exit(bob);
        // entitlement = shares/S0 · (A0 + gain/5), i.e. out·S0·5 <= shares·(5·A0 + gain)
        assertLe(outA * s0 * 5, sa * (5 * a0 + gain), "alice over-paid");
        // bob may pick up < 1 wei of alice's rounding dust
        assertLe(outB * s0 * 5, sb * (5 * a0 + gain) + s0 * 5, "bob over-paid");
        assertGe(outA + 3, sa * (5 * a0 + gain) / (s0 * 5), "alice under-paid");
        assertGe(outB + 3, sb * (5 * a0 + gain) / (s0 * 5), "bob under-paid");
        assertLe(_pol(), house.treasury());
    }

    /// Without PnL in between, a deposit followed by a full exit never returns more than was put in.
    function testFuzz_round_trip_without_pnl_never_profits(uint256 donation, uint256 x, uint256 y) public {
        donation = bound(donation, 0, 50 * M);
        x = bound(x, 1, 40 * M);
        y = bound(y, 0, 40 * M);
        vault.crystallize();
        if (y != 0) _stake(bob, y);
        _donate(donation); // an arbitrary price, with or without a fee crystallized on bob
        if (vault.previewDeposit(x) == 0) return;
        _stake(alice, x);
        assertLe(_exit(alice), x);
    }
}
