// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {RevenueRouter} from "../../src/RevenueRouter.sol";
import {FlipperRewardToken} from "../../src/FlipperRewardToken.sol";
import {DevSwapRouter} from "../../src/mocks/DevSwapRouter.sol";
import {IDiceEntropy} from "../../src/interfaces/IDiceEntropy.sol";
import {IEntropyV2} from "../../src/interfaces/IEntropyV2.sol";
import {IRandomnessAdapter} from "../../src/interfaces/IRandomness.sol";
import {ILaunchpadVerifier} from "../../src/interfaces/ILaunchpadVerifier.sol";
import {FlipperDeploy} from "../../script/lib/FlipperDeploy.sol";
import {DiceDeploy} from "../../script/lib/DiceDeploy.sol";
import {RobinhoodAddresses as RH} from "../../script/lib/RobinhoodAddresses.sol";
import {SimTypes} from "./SimTypes.sol";

/// @notice Deploys flipper.family exactly as script/Deploy.s.sol does on Robinhood Chain with LAUNCHPAD=v4 (the
///         reward-bearing $FLIPPER), ENTROPY_MODE=dice-mock and PRINCIPAL_LOCK=1 — through the same FlipperDeploy /
///         DiceDeploy library code — against a local PoolManager. This contract is the deployer (the broadcaster in
///         Deploy): owner of every contract, unlocker, receiver of the opening buy and the PrincipalLock's creator.
///
///   Deploy.s.sol steps, in order (numbers as in its `run`):
///     1  router; the reward token and the v4 self-launch with the opening buy in the same transaction
///     2  randomness (dice-mock: a local DiceEntropy, keeper = admin and default provider), deployCoreWith(hookit off)
///        sealRewardToken + setTreasuryShareBps(0); the "demo" partner (tier 1, half its cut back as odds)
///     3  _seedBankroll (TREASURY_SEED_BPS of what the deployer holds beyond the locked opening buy: 0 with the whole
///        supply in the pool), _configureVault (setParams + crystallize), the PrincipalLock staking the opening buy,
///        setLockMinTreasury(treasury / 10), setKellySchedule (half Kelly at the ATH → quarter at a 50% drawdown),
///        setFlipLimits(MAX_OPEN_PER_PLAYER, MIN_LIABILITY), the converter's ETH price seeded from the pool
///     4  the adapters' $FLIPPER pool and USD quote, the listing policy (trusted tokens allowlisted), the WETH wrapper
///        pool and the WETH listing; DEV=1: guardian = keeper; handOver (a no-op: owner = deployer); DevSwapRouter
///   Chain-specific pieces with no local counterpart are left out: the Uniswap v3 bridge and adapter, the Robinhood
///   launchpad verifiers (pons, stock tokens) and the launch whitelist's pools. They don't touch the $FLIPPER
///   economics (every listed route ends in the same $FLIPPER pool).
contract SimDeployer {
    address internal immutable creator;

    constructor() {
        creator = msg.sender;
    }

    receive() external payable {}

    function exec(address target, bytes calldata data) external payable returns (bytes memory r) {
        require(msg.sender == creator, "SimDeployer: creator only");
        bool ok;
        (ok, r) = target.call{value: msg.value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 0x20), mload(r))
            }
        }
    }

    function deploy(SimTypes.Cfg calldata cfg) external payable returns (SimTypes.Out memory o) {
        require(msg.sender == creator, "SimDeployer: creator only");
        FlipperDeploy.Config memory c = FlipperDeploy.Config({
            poolManager: cfg.poolManager,
            entropy: IEntropyV2(address(0)),
            entropyProvider: address(0),
            deployer: address(this),
            owner: address(this),
            proxyAdminOwner: address(this),
            params: RH.defaultParams()
        });

        // 1. router, then $FLIPPER launch + opening buy in one transaction
        RevenueRouter router = FlipperDeploy.deployRouter(c);
        o.liquidityKeeper = address(
            FlipperDeploy.deployLiquidityKeeper(cfg.poolManager, router, cfg.positionManager, address(0), 0, 0, 0)
        );
        FlipperRewardToken token = _launchV4(cfg, c, router, o);

        // 2. randomness (dice-mock), then everything else (Robinhood: no hookit adapter)
        IDiceEntropy dice = DiceDeploy.deployLocalDice(cfg.keeper, cfg.keeper, address(this));
        IRandomnessAdapter rnd = DiceDeploy.deployAdapter(c, dice, address(0), false, RH.diceAdapterConfig());
        FlipperDeploy.System memory s = FlipperDeploy.deployCoreWith(c, router, IERC20(address(token)), rnd, false);
        FlipperDeploy.sealRewardToken(s, token);
        router.setTreasuryShareBps(0);
        s.partners.approve(s.partners.register("demo", address(this), 5000), 1);

        // 3. bankroll: protocol-owned seed, vault parameters, the team's opening buy staked for good
        _seedBankroll(cfg, s, token, o.bought);
        s.vault.setParams(cfg.vaultFeeBps, cfg.vaultLock, cfg.vaultCooldown);
        s.vault.crystallize();
        if (cfg.principalLock && o.bought != 0) {
            o.principalLock =
                address(FlipperDeploy.deployPrincipalLock(s, IERC20(address(token)), cfg.devPayout, address(this), o.bought));
        }
        s.house.setLockMinTreasury(uint128(s.house.treasury() / 10));
        // Kelly backs off from half to quarter as the drawdown nears the breaker
        // the edge steps down as the house's own net buybacks grow (Robinhood's schedule)
        s.house.setEdgeSchedule(RH.edgeSchedule());
        s.house.setKellySchedule(RH.KELLY_BPS, RH.KELLY_MIN_BPS, RH.KELLY_DD_START_BPS, RH.KELLY_DD_END_BPS);
        // a player holds at most a few of the adapter's open requests, and each needs a real liability
        s.house.setFlipLimits(RH.MAX_OPEN_PER_PLAYER, RH.MIN_LIABILITY);
        // the revenue auction's first ETH lot: a reference (and so a floor) from the pool's price right after launch
        s.converter.seedPrice(address(0), _flipperPerEth(cfg, o.flipperKey));

        // 4. listings, routes, roles
        s.v4.setFlipperPool(o.flipperKey);
        s.v4.setHookAllowed(RH.PONS_V2_MEME_HOOK, true);
        s.v4.setQuote(cfg.usdQuote, cfg.usdQuotePool);
        address[] memory trusted = new address[](2);
        trusted[0] = cfg.usdQuote;
        trusted[1] = cfg.weth;
        FlipperDeploy.applyVetting(s, new ILaunchpadVerifier[](0), trusted);
        o.wethKey = FlipperDeploy.deployWethWrapper(c, s, cfg.weth, address(this));
        s.v4.registerAndList(cfg.weth, o.wethKey);
        if (cfg.dev) s.house.setGuardian(cfg.keeper);
        FlipperDeploy.handOver(s, c);
        if (cfg.dev) o.devSwap = address(new DevSwapRouter(cfg.poolManager));

        o.router = address(router);
        o.flipper = address(token);
        o.house = address(s.house);
        o.module = s.house.module();
        o.randomness = address(rnd);
        o.dice = address(dice);
        o.lens = address(s.lens);
        o.v4 = address(s.v4);
        o.vault = address(s.vault);
        o.policy = address(s.policy);
        o.converter = address(s.converter);
        o.partners = address(s.partners);
        o.wethWrapper = address(s.wethWrapper);
        // everything the deployer holds beyond the lock (nothing with the whole supply in the pool) stays here
    }

    /// @dev Deploy.s.sol `_launchV4` with REWARD_BEARING=1
    function _launchV4(
        SimTypes.Cfg calldata cfg,
        FlipperDeploy.Config memory c,
        RevenueRouter router,
        SimTypes.Out memory o
    ) internal returns (FlipperRewardToken token) {
        uint256 supply = cfg.supply;
        uint256 poolSupply = supply * cfg.poolBps / 10_000;
        uint256 fdvWei = cfg.startMcapUsd * 1e8 * 1e18 / cfg.ethUsd;
        uint160 sqrtP = uint160(Math.sqrt(FullMath.mulDiv(supply, 1 << 96, fdvWei) << 96));
        uint256 want = supply * cfg.openingBuySupplyBps / 10_000;
        require(want <= poolSupply, "OPENING_BUY_SUPPLY_BPS above V4_POOL_BPS");
        uint256 buyEth = FlipperDeploy.openingBuyEth(poolSupply, sqrtP, cfg.tickSpacing, cfg.fee, want);
        uint256 minOut = want != 0 ? want : 1;
        token = FlipperDeploy.deployRewardToken(c, router, "Flipper", "FLIPPER", supply);
        uint256 out = router.launchFlipperV4Token{value: buyEth}(
            IERC20(address(token)), poolSupply, cfg.fee, cfg.tickSpacing, sqrtP, buyEth, minOut, address(this)
        );
        o.bought = out - (supply - poolSupply);
        (o.flipperKey,,) = router.lpPosition();
        o.openingBuyEth = buyEth;
        o.sqrtPriceX96 = sqrtP;
    }

    /// @dev Deploy.s.sol `_flipperPerEth`: $FLIPPER wei per 1e18 ETH wei at the pool's spot price
    function _flipperPerEth(SimTypes.Cfg calldata cfg, PoolKey memory key) internal view returns (uint256) {
        (uint160 sp,,,) = StateLibrary.getSlot0(cfg.poolManager, PoolIdLibrary.toId(key));
        return FullMath.mulDiv(FullMath.mulDiv(1e18, sp, 1 << 96), sp, 1 << 96);
    }

    /// @dev Deploy.s.sol `_seedBankroll`
    function _seedBankroll(SimTypes.Cfg calldata cfg, FlipperDeploy.System memory s, FlipperRewardToken token, uint256 bought)
        internal
    {
        uint256 bal = token.balanceOf(address(this));
        uint256 locked = cfg.principalLock ? Math.min(bought, bal) : 0;
        uint256 bank = (bal - locked) * cfg.treasurySeedBps / 10_000;
        if (bank == 0) return;
        token.approve(address(s.house), bank);
        s.house.depositTreasury(bank);
    }
}
