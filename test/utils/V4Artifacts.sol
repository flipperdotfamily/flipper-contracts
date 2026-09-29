// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Compiles v4-core's PoolManager in its own job (with v4-core's optimizer settings) so tests can deploy it via
// `deployCode` without pulling our contracts into that compilation profile.
import {PoolManager} from "v4-core/PoolManager.sol";
