// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {FlipperHouse} from "../../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../../src/house/FlipperHouseBase.sol";
import {RevenueRouter} from "../../src/RevenueRouter.sol";
import {FlipperRewardToken} from "../../src/FlipperRewardToken.sol";
import {DevSwapRouter} from "../../src/mocks/DevSwapRouter.sol";
import {IEntropyV2} from "../../src/interfaces/IEntropyV2.sol";
import {IDiceEntropy} from "../../src/interfaces/IDiceEntropy.sol";
import {ILaunchpadVerifier} from "../../src/interfaces/ILaunchpadVerifier.sol";
import {FlipperDeploy} from "../../script/lib/FlipperDeploy.sol";
import {DiceDeploy} from "../../script/lib/DiceDeploy.sol";
import {RobinhoodAddresses as RH} from "../../script/lib/RobinhoodAddresses.sol";

/// @notice The default Robinhood deployment (Deploy.s.sol's defaults) on a Robinhood Chain fork: the reward-bearing
///         $FLIPPER on its own v4 pool, the real DiceEntropy through the DiceEntropyAdapter, no hookit adapter, the
///         stock-token verifier attached, the pons verifier detached, the launch whitelist listed by pool, WETH through
///         the wrapper. Measures what a player's flip transaction costs (the reveal is Dice's provider's).
///         Run: ROBINHOOD_RPC_URL=https://rpc.ordofi.network [ROBINHOOD_FORK_BLOCK=…] forge test
///              --match-contract RobinhoodDefault -vv
contract RobinhoodDefaultForkTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;

    FlipperDeploy.System internal sys;
    FlipperRewardToken internal token;
    DevSwapRouter internal dex;
    PoolKey internal key;
    address internal player = makeAddr("player");
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(72_650_000)));
        forked = true;
        vm.deal(address(this), 100 ether);
        vm.deal(player, 100 ether);

        FlipperDeploy.Config memory c = FlipperDeploy.Config({
            poolManager: IPoolManager(RH.POOL_MANAGER),
            entropy: IEntropyV2(address(0)),
            entropyProvider: address(0),
            deployer: address(this),
            owner: address(this),
            proxyAdminOwner: address(this),
            params: RH.defaultParams()
        });
        RevenueRouter router = FlipperDeploy.deployRouter(c);
        FlipperDeploy.deployLiquidityKeeper(c.poolManager, router, RH.POSITION_MANAGER, address(0), 0, 0, 0);
        token = FlipperDeploy.deployRewardToken(c, router, "Flipper", "FLIPPER", SUPPLY);
        // as Deploy.s.sol: ~$5k FDV (≈1.86 ETH), whole supply seeded single-sided, a $1000 (≈0.37 ETH) opening buy
        uint160 sqrtP = uint160(Math.sqrt(SUPPLY * (1 << 96) / 1.86 ether) << 48);
        router.launchFlipperV4Token{value: 0.37 ether}(token, SUPPLY, 10_000, 200, sqrtP, 0.37 ether, 1, address(this));
        (key,,) = router.lpPosition();
        // the live DiceEntropy and its default provider; L2 block numbers from `block.number` (forge has no ArbSys)
        FlipperDeploy.System memory m = FlipperDeploy.deployCoreWith(
            c,
            router,
            token,
            DiceDeploy.deployAdapter(c, IDiceEntropy(RH.DICE_ENTROPY), address(0), false, RH.diceAdapterConfig()),
            false
        );
        FlipperDeploy.sealRewardToken(m, token);
        router.setTreasuryShareBps(0);

        uint256 bank = token.balanceOf(address(this)) * 9 / 10;
        token.approve(address(m.house), bank);
        m.house.depositTreasury(bank);
        m.vault.crystallize();

        m.v4.setFlipperPool(key);
        PoolKey memory usdgPool =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(RH.USDG), RH.USDG_POOL_FEE, RH.USDG_POOL_TICK_SPACING, IHooks(address(0)));
        m.v4.setQuote(RH.USDG, usdgPool);
        FlipperDeploy.deployV3(c, m, RH.V3_FACTORY, RH.WETH, address(this));
        m.v3.setFlipperPool(key);
        m.v3.setQuote(RH.USDG, usdgPool);
        ILaunchpadVerifier[] memory vs = FlipperDeploy.deployRobinhoodVerifiers(address(m.v3Bridge));
        ILaunchpadVerifier[] memory attach = new ILaunchpadVerifier[](1);
        attach[0] = vs[1];
        FlipperDeploy.applyVetting(m, attach, RH.trustedTokens());
        PoolKey memory wk = FlipperDeploy.deployWethWrapper(c, m, RH.WETH, address(this));
        m.v4.registerAndList(RH.WETH, wk);
        // the launch whitelist, as Deploy.s.sol lists it
        RH.Listing[] memory w = RH.launchWhitelist();
        for (uint256 i; i < w.length; ++i) {
            if (w[i].v3Pool != address(0)) {
                m.policy.setV3PoolWhitelisted(w[i].v3Pool, true);
                m.v3.registerAndList(w[i].token, w[i].v3Pool);
            } else {
                m.policy.setPoolWhitelisted(w[i].key, true);
                m.v4.registerAndList(w[i].token, w[i].key);
            }
        }
        // a stock token, listed permissionlessly through the attached verifier
        m.v4.registerAndList(TSLA, PoolKey(Currency.wrap(address(0)), Currency.wrap(TSLA), 1800, 18, IHooks(address(0))));

        token.transfer(player, token.balanceOf(address(this)));
        sys = m;
        dex = new DevSwapRouter(IPoolManager(RH.POOL_MANAGER));
    }

    function _buy(PoolKey[] memory path, address out, uint256 ethIn) internal {
        vm.prank(player);
        dex.swapExactIn{value: ethIn}(path, address(0), out, ethIn, 1, player);
    }

    /// @return gasUsed execution gas of the player's flip transaction (L2; Arbitrum adds its L1 data component)
    function _flipGas(address t, uint256 amount) internal returns (uint256 gasUsed, uint256 fee) {
        FlipperHouseBase.Preview memory pv = sys.house.previewFlip(t, amount);
        assertEq(pv.code, 0, "preview ok");
        fee = pv.randomnessFee;
        vm.startPrank(player, player);
        IERC20(t).approve(address(sys.house), type(uint256).max);
        uint256 g = gasleft();
        sys.house.flip{value: fee}(t, amount, 0, block.timestamp);
        gasUsed = g - gasleft();
        vm.stopPrank();
    }

    function test_fork_default_wiring() public {
        if (!forked) return;
        assertEq(address(sys.hookit), address(0), "no hookit adapter");
        assertTrue(sys.house.isRouteAdapter(address(sys.v4)));
        assertEq(sys.policy.verifiers().length, 1, "only the stock-token verifier attached");
        RH.Listing[] memory w = RH.launchWhitelist();
        for (uint256 i; i < w.length; ++i) {
            (bool enabled,,,) = sys.house.tokenConfig(w[i].token);
            assertTrue(enabled, "launch whitelist listed");
        }
        assertEq(sys.house.randomnessFeeFor(TSLA), RH.DICE_FEE, "Dice's flat fee");
    }

    /// what a player pays: the flip transaction's gas at Robinhood's base fee, plus Dice's flat fee
    function test_fork_flip_gas() public {
        if (!forked) return;
        PoolKey[] memory p = new PoolKey[](1);
        p[0] = PoolKey(Currency.wrap(address(0)), Currency.wrap(TSLA), 1800, 18, IHooks(address(0)));
        _buy(p, TSLA, 0.01 ether);
        (uint256 gT, uint256 fee) = _flipGas(TSLA, IERC20(TSLA).balanceOf(player) / 2);
        console2.log("token flip (TSLA, 2 v4 hops) gas", gT);
        vm.roll(block.number + 1);
        (uint256 gF,) = _flipGas(address(token), token.balanceOf(player) / 1000);
        console2.log("$FLIPPER flip gas", gF);
        vm.roll(block.number + 1);
        vm.prank(player);
        (bool ok,) = RH.WETH.call{value: 0.01 ether}(abi.encodeWithSignature("deposit()"));
        assertTrue(ok);
        (uint256 gW,) = _flipGas(RH.WETH, 0.004 ether);
        console2.log("WETH flip (wrapper + $FLIPPER pool) gas", gW);
        console2.log("Dice fee (wei)", fee);
        // cost at 0.035 gwei: gas × 3.5e7 wei + fee
        console2.log("token flip cost (wei) at 0.035 gwei", gT * 35_000_000 + fee);
        console2.log("$FLIPPER flip cost (wei) at 0.035 gwei", gF * 35_000_000 + fee);
    }
}
