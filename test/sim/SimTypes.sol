// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Types shared by the simulation deployer (SimDeployer, which embeds every protocol contract's creation code)
///         and the simulation tests (which only talk to it through this interface, so editing a test never recompiles
///         the protocol).
library SimTypes {
    /// @dev the knobs Deploy.s.sol reads from the environment, for the self-launched v4 path on Robinhood Chain
    struct Cfg {
        IPoolManager poolManager;
        uint256 ethUsd; // ETH/USD, 8 decimals (Deploy reads Chainlink)
        uint256 supply; // V4_SUPPLY
        uint256 startMcapUsd; // V4_START_MCAP_USD
        uint256 poolBps; // V4_POOL_BPS
        uint24 fee; // V4_FEE
        int24 tickSpacing; // V4_TICK_SPACING
        uint256 openingBuySupplyBps; // OPENING_BUY_SUPPLY_BPS
        bool principalLock; // PRINCIPAL_LOCK
        address devPayout; // DEV_PAYOUT_ADDRESS
        uint256 treasurySeedBps; // TREASURY_SEED_BPS
        uint16 vaultFeeBps; // VAULT_FEE_BPS
        uint32 vaultLock; // VAULT_LOCK_DAYS × 1 day
        uint32 vaultCooldown; // VAULT_COOLDOWN_HOURS × 1 hour
        address keeper; // KEEPER_ADDRESS: dice-mock admin and provider, the guardian when DEV=1
        bool dev; // DEV=1: guardian = keeper, DevSwapRouter
        address weth; // the chain's WETH (a local WETH9 here)
        address usdQuote; // the USD quote (USDG on Robinhood; a local 6-dp token here)
        PoolKey usdQuotePool; // its hookless ETH pool
        address positionManager; // the chain's v4 PositionManager (a local one here), for the LiquidityKeeper
    }

    struct Out {
        address router;
        address flipper;
        address house;
        address module;
        address randomness;
        address dice;
        address lens;
        address v4;
        address vault;
        address policy;
        address converter;
        address partners;
        address wethWrapper;
        address principalLock;
        address devSwap;
        address liquidityKeeper;
        PoolKey flipperKey;
        PoolKey wethKey;
        uint256 openingBuyEth;
        uint256 bought;
        uint160 sqrtPriceX96;
    }
}

interface ISimDeployer {
    function deploy(SimTypes.Cfg calldata c) external payable returns (SimTypes.Out memory o);
    /// @notice act as the deployer (owner of every contract, unlocker, the PrincipalLock's creator)
    function exec(address target, bytes calldata data) external payable returns (bytes memory);
}
