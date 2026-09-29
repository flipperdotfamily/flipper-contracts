// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice A launchpad's (or trusted issuer's) listing analysis, attached to the ListingPolicy. Each verifier carries
///         its own logic — provenance from the launchpad's registry, the token's canonical pool, pinned hook code,
///         token code / immutability, module policy — and approves a token *on a specific pool*.
interface ILaunchpadVerifier {
    /// @param key the pool the token would be listed through (a Uniswap v3 pool arrives as its v4 bridge key)
    /// @return ok the token and this pool pass the verifier's analysis
    /// @return reason a verifier-specific code explaining a refusal (0 when ok)
    /// @return launchpadId which launchpad vouches (e.g. "pons"), recorded with the listing
    function verify(address token, PoolKey calldata key)
        external
        view
        returns (bool ok, uint8 reason, bytes32 launchpadId);
}
