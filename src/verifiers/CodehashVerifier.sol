// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ILaunchpadVerifier} from "../interfaces/ILaunchpadVerifier.sol";

/// @title CodehashVerifier
/// @notice ListingPolicy verifier for one trusted issuer's tokens, identified by exact runtime codehash, on hookless
///         pools (or v3 pools through our bridge). Immutable. Built for the Robinhood config; not attached by default.
///
///   Robinhood Stock Tokens: every one is an OpenZeppelin BeaconProxy whose runtime embeds Robinhood's beacon
///   (0xe10b…1b00), so all share one codehash. Behind it, `Stock` takes roles, pause and the blocklist from an
///   access-control registry fixed in the implementation, and `initialize` only sets uid / name / symbol: a copycat
///   proxy on the same beacon is governed by Robinhood exactly like a real one and can't be minted by anyone else.
///   The issuer can pause, block, burn or upgrade: the trusted-issuer class.
contract CodehashVerifier is ILaunchpadVerifier {
    uint8 public constant TOKEN_CODE = 1;
    uint8 public constant HOOKED_POOL = 2;

    bytes32 public immutable codehash;
    bytes32 public immutable launchpadId;
    /// the v3 bridge hook (pools it bridges are fine), or address(0)
    address public immutable bridge;

    constructor(bytes32 _codehash, bytes32 _launchpadId, address _bridge) {
        codehash = _codehash;
        launchpadId = _launchpadId;
        bridge = _bridge;
    }

    function verify(address token, PoolKey calldata key) external view returns (bool, uint8, bytes32) {
        if (token.code.length == 0 || token.codehash != codehash) return (false, TOKEN_CODE, launchpadId);
        address hook = address(key.hooks);
        if (hook != address(0) && hook != bridge) return (false, HOOKED_POOL, launchpadId);
        return (true, 0, launchpadId);
    }
}
