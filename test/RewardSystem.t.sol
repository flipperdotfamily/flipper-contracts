// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {TreasuryVault} from "../src/TreasuryVault.sol";
import {FlipperRewardToken} from "../src/FlipperRewardToken.sol";
import {PrincipalLock, IStakingVault} from "../src/PrincipalLock.sol";
import {IEntropyV2} from "../src/interfaces/IEntropyV2.sol";
import {MockEntropyV2} from "../src/mocks/MockEntropyV2.sol";
import {FlipperDeploy} from "../script/lib/FlipperDeploy.sol";
import {GasSearch} from "./utils/GasSearch.sol";
import {LocalPositionManager} from "./utils/LocalPositionManager.sol";
import {LiquidityKeeper} from "../src/LiquidityKeeper.sol";

/// @notice The reward-bearing $FLIPPER wired as Deploy.s.sol wires it (v4 self-launch, sealed exclusions, the
///         vault's virtual balance, the router's holders' share through `distribute`): house profit share and LP
///         fees stream to wallets and, through the vault, to stakers; protocol contracts and POL earn nothing.
contract RewardSystemTest is GasSearch {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant LOSS_WORD = 0;
    int24 internal constant TS = 200;
    uint24 internal constant FEE = 10_000;

    IPoolManager internal manager;
    PoolSwapTest internal swapper;
    MockEntropyV2 internal entropy;
    FlipperRewardToken internal token;
    FlipperDeploy.System internal sys;
    PoolKey internal key;
    FlipperHouse internal house;
    RevenueRouter internal router;
    TreasuryVault internal vault;

    address internal provider = makeAddr("provider");
    address internal alice = makeAddr("alice"); // flips, stakes
    address internal bob = makeAddr("bob"); // plain wallet holder
    address internal mallory = makeAddr("mallory"); // harvests

    function _params() internal pure returns (FlipperHouseBase.Params memory p) {
        p.baseWinChanceBps = 4500;
        p.minWinChanceBps = 4000;
        p.flipperPayoutBps = 20_500;
        p.minHouseEdgeBps = 200;
        p.maxRouteCostBps = 1000;
        p.lossSlippageBps = 500;
        p.maxBetBps = 500;
        p.kellyBps = 5000;
        p.rewardsShareBps = 5000;
        p.listingMaxRouteCostBps = 400;
        p.listingProbeBps = 2000;
        p.callbackGasLimit = 2_000_000;
        p.swapGasLimit = 800_000;
        p.guardianCancelDelay = 1 days;
        p.playerCancelDelay = 7 days;
        p.minListingProbe = 1e18;
        p.flipperCallbackGasLimit = 400_000;
        p.pendingTimeout = 1 days;
    }

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.deal(address(this), 1000 ether);
        manager = IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapper = new PoolSwapTest(manager);
        entropy = new MockEntropyV2(provider, 5e12, 1e7);
        FlipperDeploy.Config memory c = FlipperDeploy.Config({
            poolManager: manager,
            entropy: IEntropyV2(address(entropy)),
            entropyProvider: provider,
            deployer: address(this),
            owner: address(this),
            proxyAdminOwner: makeAddr("proxyAdminOwner"),
            params: _params()
        });
        router = FlipperDeploy.deployRouter(c);
        FlipperDeploy.deployLiquidityKeeper(manager, router, LocalPositionManager.deploy(manager), address(0), 0, 0, 0);
        token = FlipperDeploy.deployRewardToken(c, router, "Flipper", "FLIPPER", SUPPLY);
        // FDV 20 ETH, half the supply seeded single-sided, a 1 ETH opening buy
        uint160 sqrtP = uint160(Math.sqrt(SUPPLY * (1 << 96) / 20 ether) << 48);
        router.launchFlipperV4Token{value: 1 ether}(token, SUPPLY / 2, FEE, TS, sqrtP, 1 ether, 1, address(this));
        (key,,) = router.lpPosition();
        sys = FlipperDeploy.deployCore(c, router, token, FlipperDeploy.deployPythAdapter(c));
        FlipperDeploy.sealRewardToken(sys, token);
        router.setTreasuryShareBps(0);
        house = sys.house;
        vault = sys.vault;

        // bankroll: 200M, bootstrapped as protocol-owned
        token.approve(address(house), type(uint256).max);
        house.depositTreasury(200_000_000 ether);
        vault.crystallize();

        token.transfer(alice, 100_000_000 ether);
        token.transfer(bob, 50_000_000 ether);
        token.approve(address(swapper), type(uint256).max);
        vm.startPrank(alice);
        token.approve(address(house), type(uint256).max);
        token.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.deal(alice, 10 ether);
    }

    /// @dev lost $FLIPPER flips staking `amount` in all, in pieces of at most 2M (each within the half-Kelly cap)
    function _lose(uint256 amount) internal {
        uint256 fee = house.randomnessFeeFor(address(token));
        for (uint256 left = amount; left != 0;) {
            uint256 a = left < 2_000_000 ether ? left : 2_000_000 ether;
            vm.prank(alice);
            uint256 id = house.flip{value: fee}(address(token), a, 0, block.timestamp);
            (,,,,,,,,,, uint256 requestId,) = house.flips(id);
            entropy.reveal{gas: 5_000_000}(provider, uint64(requestId), bytes32(LOSS_WORD));
            left -= a;
        }
    }

    function _warp(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
    }

    function test_wiring() public view {
        assertTrue(token.rewardExempt(address(house)));
        assertTrue(token.rewardExempt(address(router)));
        assertTrue(token.rewardExempt(address(sys.converter)));
        assertTrue(token.rewardExempt(address(manager)));
        assertTrue(token.rewardExempt(router.liquidityKeeper()), "the LP keeper");
        assertTrue(token.rewardExempt(address(vault)), "real balance");
        assertEq(address(token.vault()), address(vault));
        assertEq(token.sealer(), address(0));
        assertEq(router.rewards(), address(token));
        assertEq(token.vaultBalance(), 0, "only protocol-owned shares so far: they never earn");
    }

    /// Losses skim the holders' share into the house; anyone's `harvest` flushes it through the router into
    /// `distribute`; wallets accrue over the 7-day stream and claim.
    function test_house_profit_share_streams_to_wallet_holders() public {
        _lose(4_000_000 ether);
        uint256 skim = house.rewardsAccrued();
        assertGt(skim, 0);
        vm.prank(mallory, mallory);
        (, uint256 bountyFl) = router.harvest();
        assertEq(house.rewardsAccrued(), 0);
        // the whole house share (no bounty on it) plus the opening buy's LP fees less their bounty
        assertGe(token.totalDistributed(), skim);
        assertEq(router.rewardsFlipperPending(), 0);
        assertLe(bountyFl, 1000 ether);

        _warp(7 days);
        uint256 e = token.eligibleSupply();
        uint256 expectBob = token.totalDistributed() * token.balanceOf(bob) / e;
        assertApproxEqRel(token.claimable(bob), expectBob, 1e12);
        uint256 b0 = token.balanceOf(bob);
        vm.prank(bob);
        uint256 got = token.claim();
        assertEq(token.balanceOf(bob), b0 + got);
        assertEq(token.claimable(address(house)), 0);
        assertEq(token.claimable(address(router)), 0);
        assertEq(token.claimable(address(manager)), 0);
    }

    /// A staker earns through the vault like a wallet holding their depositor assets; protocol-owned shares
    /// (the seeded bankroll) earn nothing.
    function test_vault_stakers_earn_like_holders_pol_does_not() public {
        vm.prank(alice);
        vault.deposit(50_000_000 ether, 0); // alice: 50M staked + 50M in her wallet; bob: 50M in his wallet
        assertApproxEqAbs(token.vaultBalance(), 50_000_000 ether, 1e9, "virtual = depositor assets, not POL");

        uint256 id;
        {
            uint256 fee = house.randomnessFeeFor(address(token));
            vm.prank(alice);
            id = house.flip{value: fee}(address(token), 1_000_000 ether, 0, block.timestamp);
        }
        (,,,,,,,,,, uint256 requestId,) = house.flips(id);
        entropy.reveal{gas: 5_000_000}(provider, uint64(requestId), bytes32(LOSS_WORD));
        router.harvest();
        _warp(7 days);

        uint256 viaVault = vault.pendingRewards(alice);
        uint256 wallet = token.claimable(bob);
        // the loss raised the bankroll: alice's stake is now worth a bit more than bob's 50M (20% of her share of
        // the gain), but the vault's balance was synced at the harvest right after the loss
        assertApproxEqRel(viaVault, wallet, 0.01e18, "staked 50M earns like 50M in a wallet");
        vm.prank(alice);
        uint256 got = vault.claimRewards();
        assertEq(got, viaVault);
        assertEq(vault.pendingRewards(alice), 0);
        assertEq(token.claimable(address(vault)), 0, "pulled through");
    }

    /// The team's PrincipalLock earns holder rewards through the vault like any staker (plus the token's own on
    /// its wallet balance), and a withdrawal of its excess sweeps both to the dev address.
    function test_principal_lock_withdrawal_sweeps_both_reward_sources() public {
        address dev = makeAddr("dev");
        PrincipalLock lock = new PrincipalLock(IStakingVault(address(vault)), dev, address(this));
        token.approve(address(lock), 50_000_000 ether);
        lock.stake(50_000_000 ether);
        _lose(4_000_000 ether); // treasury gains: the lock's excess (the profit share is still in the house)
        _warp(30 days); // the vault's lock period
        vm.prank(dev);
        lock.requestExcess(type(uint256).max);
        (uint256 qShares,,) = lock.pendingWithdrawal();
        assertGt(qShares, 0);

        token.transfer(address(lock), 1_000_000 ether); // a wallet balance the token credits holder rewards to
        router.harvest(); // the profit share streams to holders for 7 days
        _warp(7 days);
        uint256 vr = lock.pendingVaultRewards();
        uint256 hr = lock.pendingHolderRewards();
        assertGt(vr, 0, "vault pass-through");
        assertGt(hr, 0, "token rewards on the lock's own balance");
        uint256 before = token.balanceOf(dev);
        vm.expectEmit(address(lock));
        emit PrincipalLock.RewardsSwept(vr, hr);
        vm.prank(dev);
        uint256 assets = lock.withdrawExcess();
        assertGt(assets, 0);
        assertEq(token.balanceOf(dev) - before, assets + vr + hr + 1_000_000 ether, "all of it to the dev address");
        assertEq(token.balanceOf(address(lock)), 0);
        assertGe(lock.value(), lock.principal(), "the principal stays staked");

        // later rewards: anyone may sweep them, always to the dev address
        _lose(2_000_000 ether);
        router.harvest();
        _warp(7 days);
        uint256 due = lock.pendingVaultRewards();
        assertGt(due, 0);
        vm.prank(mallory);
        lock.sweepRewards();
        assertEq(lock.pendingVaultRewards(), 0);
        assertEq(token.balanceOf(dev) - before, assets + vr + hr + 1_000_000 ether + due);
    }

    /// Stakers' shares move rewards exactly: a later staker doesn't dilute what earlier stakers earned.
    function test_vault_pass_through_is_exact_across_deposits() public {
        vm.prank(alice);
        vault.deposit(40_000_000 ether, 0);
        _lose(2_000_000 ether);
        router.harvest();
        _warp(3 days);
        uint256 a3 = vault.pendingRewards(alice);
        assertGt(a3, 0);
        // bob stakes now: alice's accrued part stays hers
        vm.startPrank(bob);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(40_000_000 ether, 0);
        vm.stopPrank();
        assertApproxEqAbs(vault.pendingRewards(alice), a3, 1e6);
        assertEq(vault.pendingRewards(bob), 0);
        _warp(4 days);
        assertGt(vault.pendingRewards(bob), 0);
        assertApproxEqRel(vault.pendingRewards(alice) - a3, vault.pendingRewards(bob), 0.02e18, "equal stakes");
    }

    /// Lazy sync: the vault's virtual balance only moves on vault actions, `distribute`, or `syncVault()`.
    function test_vault_balance_is_lazily_synced() public {
        vm.prank(alice);
        vault.deposit(50_000_000 ether, 0);
        uint256 v0 = token.vaultBalance();
        _lose(4_000_000 ether); // bankroll grows: depositors' assets grow (20% of their share of the gain)
        assertEq(token.vaultBalance(), v0, "stale until synced");
        uint256 fresh = vault.depositorAssets();
        assertGt(fresh, v0);
        vm.prank(mallory);
        token.syncVault();
        assertEq(token.vaultBalance(), fresh);
    }

    // ── swallowed calls at the estimate (eth_estimateGas must not starve them) ─────────────────────────────

    /// a deposit sent with exactly its estimate re-syncs the vault's virtual balance on the token
    function test_deposit_at_the_estimate_syncs_the_vault() public {
        _callAtEstimate(alice, address(vault), abi.encodeCall(TreasuryVault.deposit, (50_000_000 ether, 0)), 0);
        assertEq(token.vaultBalance(), vault.depositorAssets(), "synced");
        assertGt(token.vaultBalance(), 0);
    }

    /// claimRewards at its estimate pulls the vault's rewards from the token and pays the staker
    function test_claim_rewards_at_the_estimate_pulls_through() public {
        vm.prank(alice);
        vault.deposit(50_000_000 ether, 0);
        _lose(4_000_000 ether);
        router.harvest();
        _warp(1 days);
        uint256 owed = vault.pendingRewards(alice);
        assertGt(owed, 0);
        uint256 b0 = token.balanceOf(alice);
        _callAtEstimate(alice, address(vault), abi.encodeCall(TreasuryVault.claimRewards, ()), 0);
        assertEq(token.balanceOf(alice) - b0, owed, "pulled from the token and paid");
        assertEq(token.claimable(address(vault)), 0);
    }

    /// harvest at its estimate flushes the house share, distributes it, and syncs the vault
    function test_harvest_at_the_estimate_distributes() public {
        vm.prank(alice);
        vault.deposit(50_000_000 ether, 0);
        _lose(4_000_000 ether);
        uint256 skim = house.rewardsAccrued();
        _callAtEstimate(mallory, address(router), abi.encodeWithSignature("harvest()"), 0);
        (uint256 lpEth, uint256 lpFl) = LiquidityKeeper(payable(router.liquidityKeeper())).collect();
        assertEq(lpEth + lpFl, 0, "the LP fees (the opening buy's) were collected at the estimate too");
        assertEq(house.rewardsAccrued(), 0, "flushed");
        assertGe(token.totalDistributed(), skim, "distributed");
        assertEq(router.rewardsFlipperPending(), 0);
        assertEq(token.vaultBalance(), vault.depositorAssets(), "synced by distribute");
    }

    /// process at its estimate distributes what the router holds
    function test_process_at_the_estimate_distributes() public {
        token.transfer(address(router), 1000 ether);
        uint256 d0 = token.totalDistributed();
        _callAtEstimate(mallory, address(router), abi.encodeWithSignature("process()"), 0);
        assertEq(token.totalDistributed(), d0 + 1000 ether);
    }

    /// Gas of a vault re-sync (what an optional settlement-time callback sync would add per flip).
    function test_gas_sync_vault() public {
        vm.prank(alice);
        vault.deposit(50_000_000 ether, 0);
        _lose(4_000_000 ether);
        vm.cool(address(token));
        vm.cool(address(vault));
        vm.cool(address(house));
        uint256 g = gasleft();
        token.syncVault();
        console2.log("syncVault (cold, balance changed)", g - gasleft());
    }

    /// The router's own LP position: fees in both legs go to holders ($FLIPPER streamed directly, ETH auctioned
    /// for $FLIPPER first).
    function test_lp_fees_flow_to_holders() public {
        // trades through the protocol-owned pool
        swapper.swap{value: 5 ether}(
            key, IPoolManager.SwapParams(true, -5 ether, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
        );
        swapper.swap(
            key,
            IPoolManager.SwapParams(false, -10_000_000 ether, TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 t0 = house.treasury();
        vm.prank(mallory, mallory);
        router.harvest();
        assertEq(house.treasury(), t0, "treasury share 0: everything to holders");
        assertGt(token.totalDistributed(), 99_000 ether, "the FLIPPER leg (1% of 10M, less the bounty)");
        assertEq(sys.converter.lotsLength(), 1, "the ETH leg is auctioned");

        // someone takes the ETH lot once it is cheap enough; the proceeds are distributed on the next process
        _warp(12 hours);
        uint256 lotEth = sys.converter.lot(0).remaining;
        uint256 p = sys.converter.priceOf(0);
        while (p > 5e24) {
            _warp(30 minutes);
            p = sys.converter.priceOf(0);
        }
        uint256 d0 = token.totalDistributed();
        token.approve(address(sys.converter), type(uint256).max);
        uint256 paid = sys.converter.take(0, lotEth, p);
        router.process();
        assertEq(token.totalDistributed(), d0 + paid);
    }

    receive() external payable {}
}
