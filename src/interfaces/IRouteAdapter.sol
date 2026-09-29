// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice A route adapter vouches for a family of tokens (e.g. everything launched by one launchpad) and
///         derives their canonical Uniswap v4 route to $FLIPPER. Approved adapters enable permissionless listing.
interface IRouteAdapter {
    /// @return route pools in trade order from `token` to `flipper`; MUST revert if `token` is not eligible
    function routeFor(address token, address flipper) external view returns (PoolKey[] memory route);
}
