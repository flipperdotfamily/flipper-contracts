// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Subset of hookit.fun's Master-rail LaunchFactory (v1 0xAB6e…afdd, v2 0x2851…322F on Ink).
interface IHookitLaunchFactory {
    struct LaunchParams {
        string name;
        string symbol;
        string metadataURI;
        uint256 totalSupply;
        address quote; // address(0) = native ETH
        int24 tickSpacing; // 0 → 60
        int24 startingTick; // ignored: start price is a $5k FDV
        uint256 bitmask; // module config (frozen at launch)
        address customHook; // must be 0 (master hook)
        uint256 devBuyQuoteIn; // ≤ 2.5% of the $5k FDV in quote
        uint256 minDevBuyTokensOut;
        uint256 vestPacked;
    }

    function launch(LaunchParams calldata params)
        external
        payable
        returns (uint256 launchId, address token, bytes32 poolId);

    function launchFee() external view returns (uint256);
    function masterHook() external view returns (address);
    function tokenLaunchId(address token) external view returns (uint256);
    function poolKeyOf(uint256 launchId) external view returns (PoolKey memory key);
}

/// @notice Subset of hookit.fun's MasterLaunchHook.
interface IHookitMasterHook {
    struct LaunchState {
        address creator;
        address token;
        address quote;
        uint64 launchTimestamp;
        int24 tickLower;
        int24 tickUpper;
        uint128 seedLiquidity;
        bool tokenIsCurrency0;
        bool initialized;
    }

    function launchState(bytes32 poolId) external view returns (LaunchState memory);
    function factory() external view returns (address);
    /// @notice module bitmask, written once in `prepareLaunch` (AlreadyPrepared guard): fixed for the pool's life
    function configs(bytes32 poolId) external view returns (uint256);
}

/// @notice hookit.fun LaunchToken (solmate ERC20; no owner, pause, blacklist or tax). `holderTracker` (immutable) is
///         called on every transfer when the holder-airdrop module is on.
interface IHookitLaunchToken {
    function holderTracker() external view returns (address);
}

/// @notice hookit.fun FeeEscrow (creator fees; claimed by the creator = `msg.sender` of `launch`).
interface IHookitFeeEscrow {
    function claim(address currency) external;
    function balanceOf(address account, address currency) external view returns (uint256);
}
