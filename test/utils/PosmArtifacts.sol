// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Compiles v4-periphery's PositionManager in its own job (v4-periphery's `posm` settings: via-IR, 500 runs) so tests
// can deploy it via `deployCode` without pulling our contracts into that compilation profile.
import {PositionManager} from "v4-periphery/PositionManager.sol";
