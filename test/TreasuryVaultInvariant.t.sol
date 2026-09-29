// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FlipperBase} from "./utils/FlipperBase.sol";

/// @notice Random stakes, requests, cancels and withdrawals interleaved with real flips (settled at once or left
///         pending, so reservations bite), donations, crystallizations and time.
contract VaultHandler is Test {
    TreasuryVaultInvariantTest internal t;

    constructor(TreasuryVaultInvariantTest _t) {
        t = _t;
    }

    function deposit(uint256 who, uint256 amount) external {
        t.doDeposit(who, amount);
    }

    function request(uint256 who, uint256 shares) external {
        t.doRequest(who, shares);
    }

    function withdraw(uint256 who) external {
        t.doWithdraw(who);
    }

    function cancel(uint256 who) external {
        t.doCancel(who);
    }

    function flip(uint256 amount, bool settleNow, bool win) external {
        t.doFlip(amount, settleNow, win);
    }

    function settle(uint256 idx, bool win) external {
        t.doSettle(idx, win);
    }

    function donate(uint256 amount) external {
        t.doDonate(amount);
    }

    function crystallize() external {
        t.doCrystallize();
    }

    function warp(uint256 secs) external {
        t.doWarp(secs);
    }
}

contract TreasuryVaultInvariantTest is FlipperBase {
    uint256 internal constant Q = 1e27;

    /// @dev a staker's reference point, reset at each of their deposits (every share evolves identically from
    ///      then on, whenever it was bought): post-crystallization price and mark, and the gross index
    struct Base {
        uint256 pps;
        uint256 hwm;
        uint256 gross;
    }

    VaultHandler internal handler;
    address internal carol = makeAddr("carol"); // flips against the house
    address[3] internal stakers;
    uint256[] internal pendingFlips;
    mapping(address => Base) internal base;

    /// @notice what one share would be worth had no performance fee ever been charged: the product of the
    ///         bankroll's PnL ratios (deposits and withdrawals happen at the share price and don't move it)
    uint256 public gross = Q;

    function setUp() public override {
        super.setUp();
        stakers = [alice, bob, mallory];
        for (uint256 i; i < 3; ++i) {
            vm.prank(stakers[i]);
            flipperToken.approve(address(vault), type(uint256).max);
        }
        vm.deal(carol, 1e24);
        vm.prank(carol);
        flipperToken.approve(address(house), type(uint256).max);
        vault.crystallize(); // the seeded bankroll becomes POL at 1:1

        handler = new VaultHandler(this);
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](9);
        sels[0] = VaultHandler.deposit.selector;
        sels[1] = VaultHandler.request.selector;
        sels[2] = VaultHandler.withdraw.selector;
        sels[3] = VaultHandler.cancel.selector;
        sels[4] = VaultHandler.flip.selector;
        sels[5] = VaultHandler.settle.selector;
        sels[6] = VaultHandler.donate.selector;
        sels[7] = VaultHandler.crystallize.selector;
        sels[8] = VaultHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    // ── actions ──────────────────────────────────────────────────────────────────────────────────────

    function doDeposit(uint256 who, uint256 amount) external {
        address u = stakers[who % 3];
        amount = bound(amount, 1, 20_000_000 ether); // dust included
        if (vault.previewDeposit(amount) == 0) return;
        flipperToken.mint(u, amount);
        vm.prank(u);
        vault.deposit(amount, 0);
        (,,, uint256 pps, uint256 h,,) = vault.stats();
        base[u] = Base(pps, h, gross);
    }

    function doRequest(uint256 who, uint256 shares) external {
        address u = stakers[who % 3];
        uint256 until = vault.unlockAt(u);
        if (vm.getBlockTimestamp() < until) vm.warp(until); // time passes until the lock ends
        (uint256 pend,) = vault.pending(u);
        uint256 available = vault.balanceOf(u) - pend;
        if (available == 0) return;
        shares = bound(shares, 1, available);
        vm.prank(u);
        vault.requestWithdraw(shares);
    }

    function doWithdraw(uint256 who) external {
        address u = stakers[who % 3];
        (uint256 pend, uint256 ready) = vault.pending(u);
        if (pend == 0) return;
        if (vm.getBlockTimestamp() < ready) vm.warp(ready); // time passes until the cooldown ends
        uint256 expected = vault.maxWithdrawable(u);
        if (expected == 0) return; // bankroll busy with pending flips (or a dust position)
        uint256 bal = flipperToken.balanceOf(u);
        vm.prank(u);
        assertEq(vault.withdraw(expected), expected);
        assertEq(flipperToken.balanceOf(u) - bal, expected);
    }

    function doCancel(uint256 who) external {
        address u = stakers[who % 3];
        (uint256 pend,) = vault.pending(u);
        if (pend == 0) return;
        vm.prank(u);
        vault.cancelWithdraw();
    }

    function doFlip(uint256 amount, bool settleNow, bool win) external {
        amount = bound(amount, 1 ether, 5_000_000 ether);
        if (house.previewFlip(address(flipperToken), amount).code != 0) return;
        flipperToken.mint(carol, amount);
        uint256 id = _flip(carol, address(flipperToken), amount); // reserves; the bankroll doesn't move yet
        if (settleNow) _settle(id, win);
        else pendingFlips.push(id);
    }

    function doSettle(uint256 idx, bool win) external {
        if (pendingFlips.length == 0) return;
        idx = bound(idx, 0, pendingFlips.length - 1);
        uint256 id = pendingFlips[idx];
        pendingFlips[idx] = pendingFlips[pendingFlips.length - 1];
        pendingFlips.pop();
        _settle(id, win);
    }

    function doDonate(uint256 amount) external {
        amount = bound(amount, 1, 10_000_000 ether);
        flipperToken.mint(address(this), amount);
        uint256 a0 = house.treasury();
        house.depositTreasury(amount);
        _pnl(a0);
    }

    function doCrystallize() external {
        vault.crystallize();
    }

    function doWarp(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1 hours, 4 days));
    }

    function _settle(uint256 id, bool win) internal {
        uint256 a0 = house.treasury();
        _reveal(id, win ? WIN_WORD : LOSS_WORD);
        _pnl(a0);
    }

    /// @dev a PnL event scales every share's fee-free value by the bankroll's ratio (shares don't change)
    function _pnl(uint256 a0) internal {
        gross = Math.mulDiv(gross, house.treasury(), a0);
    }

    // ── invariants ───────────────────────────────────────────────────────────────────────────────────

    /// The sum of all depositor claims plus the protocol-owned liquidity never exceeds the bankroll.
    /// forge-config: default.invariant.depth = 100
    function invariant_claims_never_exceed_assets() public view {
        (uint256 a, uint256 d,, uint256 pps, uint256 h, uint256 polA, uint256 dA) = vault.stats();
        uint256 claims;
        uint256 balances;
        for (uint256 i; i < 3; ++i) {
            (uint256 shares, uint256 assets,, uint256 pend,) = vault.positionOf(stakers[i]);
            claims += assets;
            balances += shares;
            assertLe(pend, shares, "pending <= balance");
        }
        assertEq(balances, d, "only stakers hold sFLIPPER");
        assertLe(claims + polA, a, "depositor claims + POL > totalAssets");
        assertLe(dA + polA, a);
        assertLe(pps, h, "post-crystallization price above the mark");
        assertEq(a, house.treasury());
    }

    /// A depositor's value never rises by more than 20% of their pro-rata gain. Per share, from the reference
    /// point (p0, mark m0, gross index g0) of their last deposit, with g the fee-free price today:
    ///     price <= g                         while g <= m0   (at or below the mark: gains and losses in full,
    ///                                                          i.e. recovery up to the mark is fee-free)
    ///     price <= m0 + 20% · (g − m0)       above it        (for p0 = m0: exactly "+20% of the pro-rata gain")
    /// forge-config: default.invariant.depth = 100
    function invariant_depositors_keep_at_most_20pct_of_their_gain() public view {
        uint256 pps = vault.previewPricePerShare();
        for (uint256 i; i < 3; ++i) {
            address u = stakers[i];
            if (vault.balanceOf(u) == 0) continue;
            Base memory b = base[u];
            uint256 g = Math.mulDiv(b.pps, gross, b.gross);
            uint256 cap = g <= b.hwm ? g : b.hwm + (g - b.hwm) / 5;
            // rounding: deposits and withdrawals leave < 1 wei per operation to the remaining shares
            assertLe(pps, cap + cap / 1e18 + 1e5, "depositor kept more than 20% of their pro-rata gain");
        }
    }

    /// forge-config: default.invariant.depth = 100
    function invariant_house_solvent() public view {
        _assertSolvent();
    }
}
