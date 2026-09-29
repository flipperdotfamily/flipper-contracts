// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {FlipperRewardToken, IRewardVault} from "../src/FlipperRewardToken.sol";
import {FlipperToken} from "../src/FlipperToken.sol";

/// @notice stands in for the TreasuryVault: a settable depositor-assets figure
contract MockRewardVault is IRewardVault {
    uint256 public depositorAssets;
    FlipperRewardToken public token;

    function set(uint256 a) external {
        depositorAssets = a;
    }

    function setToken(FlipperRewardToken t) external {
        token = t;
    }

    function claimFromToken() external returns (uint256) {
        return token.claim();
    }
}

/// @notice The reward-bearing $FLIPPER in isolation: streaming, exact accounting across transfers, exclusions,
///         the vault's virtual balance, the one-time seal.
contract RewardTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant WEEK = 7 days;

    FlipperRewardToken internal token;
    MockRewardVault internal vault;
    address internal pm = makeAddr("poolManager");
    address internal house = makeAddr("house");
    address internal router = makeAddr("router");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal funder = makeAddr("funder");

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new FlipperRewardToken("Flipper", "FLIPPER", SUPPLY, address(this), pm);
        vault = new MockRewardVault();
        vault.setToken(token);
        address[] memory ex = new address[](2);
        ex[0] = house;
        ex[1] = router;
        token.seal(ex, IRewardVault(address(vault)), address(0));

        token.transfer(alice, 300_000_000 ether);
        token.transfer(bob, 100_000_000 ether);
        token.transfer(pm, 200_000_000 ether); // pool liquidity: excluded
        token.transfer(house, 100_000_000 ether); // excluded
        token.transfer(funder, 100_000_000 ether);
        // this contract keeps 200M (eligible), funder 100M (eligible)
    }

    function _fund(uint256 amount) internal {
        vm.prank(funder);
        token.distribute(amount);
    }

    function _warp(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
    }

    // ── streaming ────────────────────────────────────────────────────────────────────────────────────────

    function test_streams_linearly_over_seven_days_pro_rata() public {
        // alice 300M + bob 100M + this 200M + funder 100M; the PoolManager and the house are excluded
        assertEq(token.eligibleSupply(), 700_000_000 ether);
        _fund(7000 ether);
        uint256 eligible = token.eligibleSupply(); // the funder paid 7000 into the (excluded) reserve
        assertEq(eligible, 700_000_000 ether - 7000 ether);
        _warp(1 days);
        // 1000 streamed in a day, alice holds 300M of `eligible`
        assertApproxEqAbs(token.claimable(alice), 1000 ether * 300_000_000 ether / eligible, 1e6);
        assertApproxEqAbs(token.claimable(bob), 1000 ether * 100_000_000 ether / eligible, 1e6);
        assertEq(token.claimable(pm), 0, "pool liquidity earns nothing");
        assertEq(token.claimable(house), 0, "house earns nothing");
        assertApproxEqAbs(token.pendingStream(), 6000 ether, 1e6);
        _warp(WEEK);
        assertApproxEqAbs(token.claimable(alice), 7000 ether * 300_000_000 ether / eligible, 1e6, "capped at the stream");
        assertEq(token.pendingStream(), 0);
    }

    function test_small_distribution_extends_at_the_current_rate() public {
        _fund(7000 ether);
        uint256 rate = token.rewardRate();
        uint256 finish = token.periodFinish();
        _warp(3.5 days);
        _fund(1000 ether);
        // 3500 left + 1000 new, at the unchanged 1000/day: the end moves out by one day, not to a fresh week
        assertApproxEqAbs(token.pendingStream(), 4500 ether, 1e6);
        assertGe(token.rewardRate(), rate, "never slower");
        assertApproxEqRel(token.rewardRate(), rate, 1e13, "the same rate (to the whole-second rounding of the end)");
        assertApproxEqAbs(token.periodFinish(), finish + 1 days, 2);
        _warp(WEEK);
        uint256 e = token.eligibleSupply();
        // (the second distribution also shrank the eligible supply by 1000: a ~1e-6 relative effect)
        assertApproxEqRel(token.claimable(alice), 8000 ether * 300_000_000 ether / e, 1e13);
        assertEq(token.totalDistributed(), 8000 ether);
    }

    function test_large_distribution_speeds_up_over_seven_days() public {
        _fund(7000 ether);
        _warp(3.5 days);
        _fund(70_000 ether);
        // 73,500 unstreamed: faster than 1000/day, so spread over a fresh week
        assertEq(token.periodFinish(), vm.getBlockTimestamp() + WEEK);
        assertApproxEqRel(token.rewardRate(), 73_500 ether * 2 ** 96 / WEEK, 1e12);
        _warp(WEEK);
        assertEq(token.pendingStream(), 0);
    }

    /// Stress-test F-2: `distribute(0)` (or 1 wei) every hour used to re-spread the remainder over a fresh week,
    /// delaying ~37% of a stream past its window. Now a zero call only checkpoints, and a dust call only extends the
    /// end by its own worth: the stream arrives on time.
    function test_hourly_dust_distributions_cannot_stretch_the_stream() public {
        _fund(7000 ether);
        uint256 finish = token.periodFinish();
        uint256 rate = token.rewardRate();
        address griefer = makeAddr("griefer");
        deal(address(token), griefer, 1 ether);
        uint256 a0 = token.accrued(alice);
        for (uint256 i; i < 167; ++i) {
            _warp(1 hours);
            vm.prank(griefer);
            token.distribute(i % 2 == 0 ? 0 : 1);
            assertGe(token.rewardRate(), rate, "never slower");
        }
        assertLe(token.periodFinish(), finish + 1, "the end didn't move (dust is worth < 1 s)");
        _warp(1 hours); // the week is over
        assertLt(token.pendingStream(), 1e6, "all of it streamed within the week");
        uint256 e = token.eligibleSupply();
        assertApproxEqRel(token.accrued(alice) - a0, 7000 ether * 300_000_000 ether / e, 1e12, "on time");
    }

    function test_zero_distribution_only_checkpoints() public {
        _fund(7000 ether);
        _warp(1 days);
        (uint256 r, uint64 f, uint256 d) = (token.rewardRate(), token.periodFinish(), token.totalDistributed());
        token.distribute(0);
        assertEq(token.rewardRate(), r);
        assertEq(token.periodFinish(), f);
        assertEq(token.totalDistributed(), d);
        assertEq(token.lastUpdate(), vm.getBlockTimestamp(), "checkpointed");
    }

    function test_claim_pays_from_reserve() public {
        _fund(7000 ether);
        _warp(WEEK);
        uint256 c = token.claimable(alice);
        uint256 b0 = token.balanceOf(alice);
        vm.prank(alice);
        assertEq(token.claim(), c);
        assertEq(token.balanceOf(alice), b0 + c);
        assertEq(token.claimable(alice), 0);
        vm.prank(alice);
        assertEq(token.claim(), 0);
        assertEq(token.totalClaimed(), c);
    }

    // ── transfers move no rewards ────────────────────────────────────────────────────────────────────────

    function test_transfer_keeps_accrued_with_sender() public {
        _fund(7000 ether);
        _warp(2 days);
        uint256 a = token.claimable(alice);
        uint256 b = token.claimable(bob);
        vm.prank(alice);
        token.transfer(bob, 300_000_000 ether);
        assertEq(token.claimable(alice), a, "alice keeps what she earned");
        assertEq(token.claimable(bob), b, "bob gains nothing retroactively");
        _warp(1 days);
        assertEq(token.claimable(alice), a, "alice earns no more");
        assertGt(token.claimable(bob), b);
    }

    function test_self_transfer_and_churn_create_nothing() public {
        _fund(7000 ether);
        _warp(1 days);
        uint256 total0 = token.accrued(alice) + token.accrued(bob) + token.accrued(address(this));
        for (uint256 i; i < 20; ++i) {
            vm.prank(alice);
            token.transfer(alice, 1000 ether);
            vm.prank(alice);
            token.transfer(bob, 12_345 ether);
            vm.prank(bob);
            token.transfer(alice, 12_345 ether);
            token.transfer(bob, 1 ether);
        }
        uint256 total1 = token.accrued(alice) + token.accrued(bob) + token.accrued(address(this));
        assertEq(total1, total0, "same block: nothing created or lost");
    }

    function test_flash_balance_earns_nothing() public {
        _fund(7000 ether);
        _warp(1 days);
        uint256 c0 = token.claimable(carol);
        vm.prank(alice);
        token.transfer(carol, 300_000_000 ether); // borrowed
        vm.prank(carol);
        token.transfer(alice, 300_000_000 ether); // repaid in the same block
        assertEq(token.claimable(carol), c0);
        assertEq(c0, 0);
    }

    function test_excluded_to_included_moves_no_value() public {
        _fund(7000 ether);
        _warp(1 days);
        uint256 sum0 = token.accrued(alice) + token.accrued(bob) + token.accrued(carol) + token.accrued(address(this));
        uint256 e0 = token.eligibleSupply();
        // a "pool buy": the PoolManager (excluded) pays carol
        vm.prank(pm);
        token.transfer(carol, 50_000_000 ether);
        assertEq(token.eligibleSupply(), e0 + 50_000_000 ether);
        assertEq(token.claimable(carol), 0);
        // a "pool sell": alice pays the PoolManager
        vm.prank(alice);
        token.transfer(pm, 100_000_000 ether);
        uint256 sum1 = token.accrued(alice) + token.accrued(bob) + token.accrued(carol) + token.accrued(address(this));
        assertEq(sum1, sum0);
        // from here carol earns on 50M, alice on 200M
        uint256 a0 = token.accrued(alice);
        _warp(1 days);
        assertApproxEqRel((token.accrued(alice) - a0), 4 * token.accrued(carol), 1e12);
    }

    function test_burn_reduces_eligible_supply() public {
        uint256 e0 = token.eligibleSupply();
        vm.prank(bob);
        token.burn(10 ether);
        assertEq(token.eligibleSupply(), e0 - 10 ether);
    }

    // ── nobody eligible ──────────────────────────────────────────────────────────────────────────────────

    function test_stream_with_nothing_eligible_carries_to_next_distribution() public {
        FlipperRewardToken t = new FlipperRewardToken("F", "F", SUPPLY, address(this), pm);
        t.transfer(pm, SUPPLY - 1000 ether); // only 1000 eligible (this)
        t.transfer(funder, 1000 ether - 0.5 ether); // 0.5 left: below the minimum eligible supply
        vm.prank(funder);
        t.transfer(pm, 1000 ether - 0.5 ether - 70 ether);
        vm.prank(funder);
        t.distribute(70 ether);
        _warp(1 days);
        assertEq(t.claimable(address(this)), 0);
        t.distribute(0); // checkpoint: the day's 10 goes to carry, and joins the next distribution
        assertApproxEqAbs(t.pendingStream(), 60 ether, 1e6);
        assertApproxEqAbs(t.carry(), 10 ether, 1e6);
        t.distribute(0.4 ether); // (this contract's 0.5)
        assertEq(t.carry(), 0);
        assertApproxEqAbs(t.pendingStream(), 70.4 ether, 1e6);
    }

    // ── vault ────────────────────────────────────────────────────────────────────────────────────────────

    function test_vault_earns_on_virtual_balance_not_real_balance() public {
        token.transfer(address(vault), 50_000_000 ether); // real balance: never earns
        vault.set(100_000_000 ether);
        token.syncVault();
        assertEq(token.vaultBalance(), 100_000_000 ether);
        assertEq(token.eligibleBalanceOf(address(vault)), 100_000_000 ether);
        _fund(7000 ether);
        _warp(WEEK);
        assertApproxEqRel(token.claimable(address(vault)), token.claimable(bob), 1e12, "vault 100M virtual = bob 100M");
        uint256 got = vault.claimFromToken();
        assertGt(got, 0);
        assertEq(token.claimable(address(vault)), 0);
    }

    function test_vault_resync_is_not_retroactive() public {
        _fund(7000 ether);
        _warp(1 days);
        vault.set(300_000_000 ether);
        token.syncVault();
        assertEq(token.claimable(address(vault)), 0, "no back pay");
        uint256 a0 = token.accrued(alice);
        _warp(1 days);
        assertApproxEqRel(token.claimable(address(vault)), token.accrued(alice) - a0, 1e12, "300M virtual = alice's 300M");
        vault.set(0);
        token.syncVault();
        uint256 v = token.claimable(address(vault));
        _warp(1 days);
        assertEq(token.claimable(address(vault)), v, "stopped earning, kept what it earned");
    }

    function test_distribute_syncs_the_vault() public {
        vault.set(42 ether);
        _fund(1 ether);
        assertEq(token.vaultBalance(), 42 ether);
    }

    // ── seal ─────────────────────────────────────────────────────────────────────────────────────────────

    function test_seal_is_one_time_sealer_only_and_before_distribution() public {
        FlipperRewardToken t = new FlipperRewardToken("F", "F", SUPPLY, address(this), pm);
        address[] memory ex = new address[](1);
        ex[0] = house;
        vm.prank(alice);
        vm.expectRevert(FlipperRewardToken.NotSealer.selector);
        t.seal(ex, IRewardVault(address(0)), address(0));
        t.distribute(0); // a zero distribution doesn't count
        t.seal(ex, IRewardVault(address(0)), address(0));
        assertTrue(t.rewardExempt(house));
        assertEq(t.sealer(), address(0));
        vm.expectRevert(FlipperRewardToken.NotSealer.selector);
        t.seal(ex, IRewardVault(address(0)), address(0));

        FlipperRewardToken u = new FlipperRewardToken("F", "F", SUPPLY, address(this), pm);
        u.distribute(1 ether);
        vm.expectRevert(FlipperRewardToken.AlreadyDistributed.selector);
        u.seal(ex, IRewardVault(address(0)), address(0));
    }

    function test_fixed_exclusions() public view {
        assertTrue(token.rewardExempt(address(token)), "reserve");
        assertTrue(token.rewardExempt(token.DEAD()), "dead");
        assertTrue(token.rewardExempt(pm), "PoolManager");
        assertTrue(token.rewardExempt(house));
        assertTrue(token.rewardExempt(router));
        assertTrue(token.rewardExempt(address(vault)), "vault's real balance");
        assertFalse(token.rewardExempt(alice));
    }

    // ── gas ──────────────────────────────────────────────────────────────────────────────────────────────

    function test_gas_per_transfer() public {
        _fund(7000 ether);
        _warp(1 days);
        vm.prank(alice);
        token.transfer(bob, 1 ether); // warm both
        _warp(1);
        vm.cool(address(token));
        vm.prank(alice);
        uint256 g = gasleft();
        token.transfer(bob, 1 ether);
        console2.log("transfer holder -> holder (cold)", g - gasleft());
        vm.cool(address(token));
        vm.prank(alice);
        g = gasleft();
        token.transfer(makeAddr("fresh"), 1 ether);
        console2.log("transfer holder -> new holder (cold)", g - gasleft());
        vm.cool(address(token));
        vm.prank(pm);
        g = gasleft();
        token.transfer(bob, 1 ether);
        console2.log("transfer PoolManager -> holder (cold, a pool buy)", g - gasleft());
        vm.cool(address(token));
        vm.prank(alice);
        g = gasleft();
        token.claim();
        console2.log("claim (cold)", g - gasleft());

        // baseline: the plain $FLIPPER (OpenZeppelin ERC20)
        FlipperToken plain = new FlipperToken("F", "F", SUPPLY, alice);
        vm.prank(alice);
        plain.transfer(bob, 1 ether);
        vm.cool(address(plain));
        vm.prank(alice);
        g = gasleft();
        plain.transfer(bob, 1 ether);
        console2.log("plain ERC20 transfer holder -> holder (cold)", g - gasleft());
        vm.cool(address(plain));
        vm.prank(alice);
        g = gasleft();
        plain.transfer(makeAddr("fresh2"), 1 ether);
        console2.log("plain ERC20 transfer holder -> new holder (cold)", g - gasleft());
    }
}

/// @notice Random transfers, pool trades, distributions, claims, vault syncs and time: holders can never be owed
///         more than was distributed, and the reserve always covers what is claimable.
contract RewardTokenHandler is Test {
    FlipperRewardToken internal token;
    MockRewardVault internal vault;
    address internal pm;
    address[] internal actors;

    constructor(FlipperRewardToken t, MockRewardVault v, address _pm, address[] memory _actors) {
        token = t;
        vault = v;
        pm = _pm;
        actors = _actors;
    }

    function transfer(uint256 from, uint256 to, uint256 amount) external {
        address f = _actor(from);
        address t = _actor(to);
        amount = bound(amount, 0, token.balanceOf(f));
        vm.prank(f);
        token.transfer(t, amount);
    }

    function distribute(uint256 who, uint256 amount) external {
        address f = _actor(who);
        if (f == address(vault)) return;
        amount = bound(amount, 0, token.balanceOf(f) / 10);
        vm.prank(f);
        token.distribute(amount);
    }

    function claim(uint256 who) external {
        address a = _actor(who);
        vm.prank(a);
        token.claim();
    }

    function vaultSet(uint256 amount) external {
        vault.set(bound(amount, 0, 300_000_000 ether));
        if (amount % 2 == 0) token.syncVault();
    }

    function warp(uint256 dt) external {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 0, 3 days));
    }

    function _actor(uint256 i) internal view returns (address) {
        return actors[i % actors.length];
    }
}

contract RewardTokenInvariantTest is Test {
    FlipperRewardToken internal token;
    MockRewardVault internal vault;
    RewardTokenHandler internal handler;
    address[] internal actors;

    function setUp() public {
        address pm = makeAddr("pm");
        token = new FlipperRewardToken("Flipper", "FLIPPER", 1_000_000_000 ether, address(this), pm);
        vault = new MockRewardVault();
        vault.setToken(token);
        token.seal(new address[](0), IRewardVault(address(vault)), address(0));
        actors.push(makeAddr("a"));
        actors.push(makeAddr("b"));
        actors.push(makeAddr("c"));
        actors.push(pm); // pool liquidity (excluded)
        actors.push(address(vault)); // real vault balance (excluded)
        for (uint256 i; i < actors.length; ++i) {
            token.transfer(actors[i], 150_000_000 ether);
        }
        handler = new RewardTokenHandler(token, vault, pm, actors);
        targetContract(address(handler));
    }

    function _sumClaimable() internal view returns (uint256 s) {
        for (uint256 i; i < actors.length; ++i) {
            s += token.claimable(actors[i]);
        }
        s += token.claimable(address(this));
    }

    function invariant_owed_never_exceeds_distributed() public view {
        assertLe(_sumClaimable() + token.totalClaimed(), token.totalDistributed());
    }

    function invariant_reserve_covers_claimable() public view {
        assertGe(token.balanceOf(address(token)), _sumClaimable());
    }

    function invariant_eligible_supply_is_the_sum_of_eligible_balances() public view {
        uint256 s;
        for (uint256 i; i < actors.length; ++i) {
            s += token.eligibleBalanceOf(actors[i]);
        }
        s += token.eligibleBalanceOf(address(this));
        assertEq(token.eligibleSupply(), s);
    }
}
