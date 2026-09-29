// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FlipperHouse} from "../../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../../src/house/FlipperHouseBase.sol";
import {IHookitLaunchFactory} from "../../src/interfaces/IHookit.sol";

/// @notice Ink mainnet (57073) addresses and protocol defaults. Verified on-chain 2026-09-23 (research/).
library InkAddresses {
    address internal constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address internal constant STATE_VIEW = 0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990;
    address internal constant V4_QUOTER = 0x3972C00f7ed4885e145823eb7C655375d275A1C5;
    /// @notice Uniswap v4 PositionManager (`poolManager()` = POOL_MANAGER, `permit2()` = canonical Permit2)
    address internal constant POSITION_MANAGER = 0x1b35d13a2E2528f192637F14B05f0Dc0e7dEB566;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    /// Pyth Entropy v2 proxy (the only verifiable randomness oracle live on Ink; Chainlink VRF is not deployed)
    address internal constant ENTROPY = 0xD458261E832415CFd3BAE5E416FdF3230ce6F134;

    address internal constant CHAINLINK_ETH_USD = 0x963d5d3aD2Dfd3fe759d376fF62A0963176DBdF5;
    address internal constant CHAINLINK_SEQUENCER_UPTIME = 0xFB6acA74A4069b69C4383e8BE8f7D34e4aFeC3Fb;

    // hookit.fun Master rail (factory → masterHook)
    address internal constant HOOKIT_FACTORY_V1 = 0xAB6eaE3092AE574BEF0A16505FDf137072DCafdd; // hook 0xBD7E…aAc8
    address internal constant HOOKIT_FACTORY_V2 = 0x2851Cb70a6784ae69B45E6b7065908A00176322F; // hook 0x7C62…AaC8
    address internal constant HOOKIT_FEE_ESCROW = 0x964D82e82DeB1584942f82d3A23041316f4f5D77;
    address internal constant HKT = 0xcf010BA185Fd6ee6027b141e2C32614D673f8258;
    address internal constant HOOKIT_SWAP_ROUTER = 0xb099176151Ecde2E194CCa23E491413f789D1Cb7;
    address internal constant HOOKIT_HOOK_V1 = 0xBD7E7815C640a67cAbD9a93A15D1f250AAeeaAc8;
    address internal constant HOOKIT_HOOK_V2 = 0x7C629422e9ac982CE72323D48EAD94fCC092AaC8;
    address internal constant HOOKIT_GRADUATED_HOOK = 0xaAC738f140D529bc0662BDDd812964D843362088;
    /// USDC on Ink + its hookless ETH/USDC 0.3% v4 pool (poolId 0x45a5…2583) — quote route for USDC-paired tokens
    address internal constant USDC = 0x2D270e6886d130D724215A266106e6832161EAEd;
    /// Uniswap v3 factory (research/HOOKIT_INK_REPORT.md; v3 pools are bridged into v4 by the V3RouteAdapter)
    address internal constant V3_FACTORY = 0x640887A9ba3A9C53Ed27D0F7e8246A4F933f3424;
    // ── listing policy (VettedListing) ──
    /// hookit LaunchToken runtime (solmate ERC20, no owner/pause/blacklist/tax) with its immutables (creator,
    /// domain separator, holderTracker ×3) zeroed; identical across the v1 and v2 factories (checked 2026-09-25)
    bytes32 internal constant HOOKIT_TOKEN_TEMPLATE = 0xd29aa498df5f42acbaadc7915295267fd3399c2eb777c57e4ae5e0fdb8c04f96;
    uint256 internal constant HOOKIT_TOKEN_SIZE = 3615;
    /// packed 16-bit offsets 1434, 2245, 2563, 2911, 3166
    uint256 internal constant HOOKIT_TOKEN_IMMUTABLES =
        1434 | (2245 << 16) | (2563 << 32) | (2911 << 48) | (3166 << 64);
    /// modules that break settlement: ANTI_MEV (bit 2), MAX_TX (bit 3), HOLDER_AIRDROP (bit 145)
    uint256 internal constant HOOKIT_FORBIDDEN_FLAGS = (1 << 2) | (1 << 3) | (1 << 145);

    /// USD₮0 (Ink's deepest stablecoin; 0.3% v3 pool vs WETH)
    address internal constant USDT0 = 0x0200C29006150606B650577BBE7B6248F58470c1;

    /// @notice Majors allowlisted on the ListingPolicy (listable permissionlessly on hookless / bridged-v3 pools).
    ///         hookit launches come in through the HookitVerifier; HKT runs ANTI_MEV, so the owner lists it directly.
    function trustedTokens() internal pure returns (address[] memory t) {
        t = new address[](3);
        t[0] = WETH;
        t[1] = USDC;
        t[2] = USDT0;
    }

    /// first PoolManager Initialize on Ink (discovery scans start here)
    uint256 internal constant POOL_MANAGER_START_BLOCK = 0;

    function defaultParams() internal pure returns (FlipperHouseBase.Params memory p) {
        p.baseWinChanceBps = 4500; // 45% → "rand*100 > 55 wins"
        p.minWinChanceBps = 4000;
        p.flipperPayoutBps = 21_000; // 2.1x on $FLIPPER; token-flip fallback bonus = 5%
        p.minHouseEdgeBps = 200; // ≥2% expected profit per flip after every swap cost the house sponsors
        p.maxRouteCostBps = 1000;
        p.lossSlippageBps = 500;
        p.maxBetBps = 500; // 5% of the unreserved bankroll (ceiling)
        p.kellyBps = 5000; // half Kelly
        p.rewardsShareBps = 5000; // half of each flip's expected profit → $FLIPPER holders (as HKT)
        p.listingMaxRouteCostBps = 400; // permissionless listing: probe round trip ≤ 4%
        p.listingProbeBps = 2000;
        // hookit hooks run nested fee swaps, and whenever a token's 15-minute HKT-holder drop epoch has elapsed the
        // next swaps on its pool each push a batch of ≤48 transfers inside beforeSwap (466 holders → ~10 swaps per
        // drop), paid by whoever swaps. Pyth bills (budget + 60k) × 0.01 gwei per gas, used or not. Measured on an
        // Ink fork (test/fork/InkFork.t.sol, HKT route [HKT/ETH, ETH/$FLIPPER]): a swap attempt uses 0.62-0.64M
        // (callback ~0.70M) with no drop due; 1.35-1.42M with one batch due; 2.06M with $FLIPPER's first batch to 48
        // fresh recipients (the heaviest single push, 1.35M); 1.93-2.42M with both hops' batches due (2.42M with
        // that fresh one). swapGasLimit covers any one push and every measured two-batch case; every attempt keeps
        // the 350k settlement reserve back, and 4.5M also leaves a win's fallback quote a full 3.0M after a normal
        // first attempt (after a pushed one ~2.0M: a second push there is left WinPending for the keeper).
        // Fee 4.56e13 wei (~$0.12), down from 9.56e13 (~$0.26) at the former 4.5M / 9.5M.
        p.swapGasLimit = 3_000_000;
        p.callbackGasLimit = 4_500_000;
        p.guardianCancelDelay = 1 days;
        p.playerCancelDelay = 7 days;
        p.minListingProbe = 1000 ether;
        p.flipperCallbackGasLimit = 400_000; // $FLIPPER flips settle without swaps (~200k)
        // a WinPending flip whose buy still can't execute after this long is paid its reserved liability in $FLIPPER
        // by whoever calls resolvePendingWin
        p.pendingTimeout = 1 days;
    }

    /// @notice $FLIPPER launch config: ETH-quoted, no hookit modules (bitmask 0).
    /// @dev    Deliberately OFF: ANTI_MEV (one swap per tx.origin per pool per block would block every second
    ///         settlement in a block — all settlements share the randomness keeper as tx.origin and all touch the
    ///         $FLIPPER pool), MAX_TX (caps house payouts), ANTI_SNIPE (would tax the creator's own opening buy —
    ///         snipe protection comes from launching and buying atomically), hook tax / airdrop / burn modules
    ///         (every extra bp and nested swap is paid on every house trade).
    function flipperLaunchParams(uint256 devBuy) internal pure returns (IHookitLaunchFactory.LaunchParams memory p) {
        p.name = "Flipper";
        p.symbol = "FLIPPER";
        p.metadataURI = "";
        p.totalSupply = 1_000_000_000 ether;
        p.quote = address(0);
        p.tickSpacing = 60;
        p.startingTick = 0;
        p.bitmask = 0;
        p.customHook = address(0);
        p.devBuyQuoteIn = devBuy;
        p.minDevBuyTokensOut = 1;
        p.vestPacked = 0;
    }
}
