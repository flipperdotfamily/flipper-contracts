// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {FlipperHouse} from "../../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../../src/house/FlipperHouseBase.sol";
import {RevenueRouter} from "../../src/RevenueRouter.sol";
import {FlipperRewardToken} from "../../src/FlipperRewardToken.sol";
import {IEntropyV2} from "../../src/interfaces/IEntropyV2.sol";
import {IWETH9} from "../../src/interfaces/IUniswapV3.sol";
import {MockEntropyV2} from "../../src/mocks/MockEntropyV2.sol";
import {DevSwapRouter} from "../../src/mocks/DevSwapRouter.sol";
import {FlipperDeploy} from "../../script/lib/FlipperDeploy.sol";
import {InkAddresses} from "../../script/lib/InkAddresses.sol";

/// @notice The default Ink deployment (LAUNCHPAD=v4, reward-bearing $FLIPPER) on a fork of Ink mainnet's real
///         PoolManager and WETH: launch, seal, WETH wrapper; a flip loss's holder share and a trade's LP fees are
///         harvested by anyone into `distribute`; a wallet and a vault staker accrue and claim.
///         Run: INK_RPC_URL=… [INK_FORK_BLOCK=…] forge test --match-contract InkRewardFork -vv
contract InkRewardForkTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    FlipperDeploy.System internal sys;
    FlipperRewardToken internal token;
    MockEntropyV2 internal entropy;
    DevSwapRouter internal dex;
    PoolKey internal key;
    address internal provider = makeAddr("provider");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("INK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 forkBlock = vm.envOr("INK_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        forked = true;
        vm.deal(address(this), 100 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        entropy = new MockEntropyV2(provider, 1, 1e7);
        FlipperDeploy.Config memory c = FlipperDeploy.Config({
            poolManager: IPoolManager(InkAddresses.POOL_MANAGER),
            entropy: IEntropyV2(address(entropy)),
            entropyProvider: provider,
            deployer: address(this),
            owner: address(this),
            proxyAdminOwner: address(this),
            params: InkAddresses.defaultParams()
        });
        RevenueRouter router = FlipperDeploy.deployRouter(c);
        FlipperDeploy.deployLiquidityKeeper(c.poolManager, router, InkAddresses.POSITION_MANAGER, address(0), 0, 0, 0);
        token = FlipperDeploy.deployRewardToken(c, router, "Flipper", "FLIPPER", SUPPLY);
        // as Deploy.s.sol: 1% pool, tick spacing 200, whole supply seeded single-sided, ~$5k FDV, opening buy
        uint160 sqrtP = uint160(Math.sqrt(SUPPLY * (1 << 96) / 2 ether) << 48);
        router.launchFlipperV4Token{value: 0.4 ether}(token, SUPPLY, 10_000, 200, sqrtP, 0.4 ether, 1, address(this));
        (key,,) = router.lpPosition();
        sys = FlipperDeploy.deployCore(c, router, token, FlipperDeploy.deployPythAdapter(c));
        FlipperDeploy.sealRewardToken(sys, token);
        router.setTreasuryShareBps(0);
        sys.v4.setFlipperPool(key);
        PoolKey memory wk = FlipperDeploy.deployWethWrapper(c, sys, InkAddresses.WETH, address(this));
        sys.v4.registerAndList(InkAddresses.WETH, wk);

        uint256 bank = token.balanceOf(address(this)) * 9 / 10;
        token.approve(address(sys.house), bank);
        sys.house.depositTreasury(bank);
        sys.vault.crystallize();
        uint256 rest = token.balanceOf(address(this));
        token.transfer(alice, rest / 2);
        token.transfer(bob, rest / 2);
        vm.startPrank(alice);
        token.approve(address(sys.house), type(uint256).max);
        token.approve(address(sys.vault), type(uint256).max);
        vm.stopPrank();
        dex = new DevSwapRouter(IPoolManager(InkAddresses.POOL_MANAGER));
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _flip(address who, address t, uint256 amount, uint256 word) internal returns (FlipperHouseBase.Status st) {
        FlipperHouseBase.Preview memory pv = sys.house.previewFlip(t, amount);
        assertEq(pv.code, 0, "preview ok");
        vm.prank(who, who);
        uint256 id = sys.house.flip{value: pv.randomnessFee}(t, amount, 0, block.timestamp);
        (,,,,,,,,,, uint256 requestId,) = sys.house.flips(id);
        entropy.reveal{gas: 8_000_000}(provider, uint64(requestId), bytes32(word));
        (,,,, st,,,,,,,) = sys.house.flips(id);
    }

    function test_fork_rewards_end_to_end() public {
        if (!forked) return;
        uint256 stake = token.balanceOf(alice) / 4;
        vm.prank(alice);
        sys.vault.deposit(stake, 0); // alice stakes a quarter of her tokens; bob keeps his in the wallet

        // a $FLIPPER loss (holder share skimmed) and trading through the protocol's pool (LP fees)
        assertEq(uint8(_flip(alice, address(token), sys.house.maxLiability() / 3, 0)), uint8(FlipperHouseBase.Status.Lost));
        PoolKey[] memory path = new PoolKey[](1);
        path[0] = key;
        vm.prank(bob);
        dex.swapExactIn{value: 1 ether}(path, address(0), address(token), 1 ether, 1, bob);

        vm.prank(bob, bob);
        (uint256 bEth, uint256 bFl) = sys.router.harvest();
        console2.log("harvest bounty ETH / FLIPPER", bEth, bFl);
        console2.log("distributed", token.totalDistributed());
        assertGt(token.totalDistributed(), 0);
        assertEq(sys.converter.lotsLength(), 1, "ETH leg auctioned");

        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 w = token.claimable(bob);
        uint256 v = sys.vault.pendingRewards(alice);
        console2.log("bob (wallet) claimable", w);
        console2.log("alice (staker) pending", v);
        assertGt(w, 0);
        assertGt(v, 0);
        vm.prank(bob);
        assertEq(token.claim(), w);
        vm.prank(alice);
        assertEq(sys.vault.claimRewards(), v);
        assertEq(token.claimable(address(sys.house)), 0);
        assertEq(token.claimable(InkAddresses.POOL_MANAGER), 0);
    }

    function test_fork_weth_flip_on_reward_stack() public {
        if (!forked) return;
        vm.startPrank(alice);
        IWETH9(InkAddresses.WETH).deposit{value: 1 ether}();
        IERC20(InkAddresses.WETH).approve(address(sys.house), type(uint256).max);
        vm.stopPrank();
        FlipperHouseBase.Preview memory pv = sys.house.previewFlip(InkAddresses.WETH, 0.01 ether);
        console2.log("WETH route cost bps", pv.routeCostBps);
        uint256 w0 = IERC20(InkAddresses.WETH).balanceOf(alice);
        assertEq(uint8(_flip(alice, InkAddresses.WETH, 0.01 ether, 9_999)), uint8(FlipperHouseBase.Status.Won));
        assertEq(IERC20(InkAddresses.WETH).balanceOf(alice), w0 + 0.01 ether);
    }
}
