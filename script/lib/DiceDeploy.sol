// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DiceEntropyAdapter} from "../../src/randomness/DiceEntropyAdapter.sol";
import {DiceEntropy} from "../../src/mocks/dice/DiceEntropy.sol";
import {IDiceEntropy} from "../../src/interfaces/IDiceEntropy.sol";
import {IRandomnessAdapter} from "../../src/interfaces/IRandomness.sol";
import {FlipperDeploy} from "./FlipperDeploy.sol";
import {RobinhoodAddresses} from "./RobinhoodAddresses.sol";

/// @notice Deployment helpers for Dice Protocol randomness (research/DICE_INTEGRATION.md, "Deploy.s.sol").
///   dice         production: the live DiceEntropy, its default provider (Tyche), L2 blocks from ArbSys
///   dice-mirror  dev on a Robinhood fork: the same live DiceEntropy in the fork's state, its default provider, whose
///                hash chain the dev keeper re-keys (`register-provider`) and reveals from; blocks from `block.number`
///                (anvil has no ArbSys)
///   dice-mock    dev on any chain: a local copy of the verified DiceEntropy (src/mocks/dice), keeper = admin and
///                provider (registered by `register-provider` after the deploy)
library DiceDeploy {
    /// @notice the randomness adapter, behind a TransparentUpgradeableProxy (bound to the house by deployCore)
    function deployAdapter(
        FlipperDeploy.Config memory c,
        IDiceEntropy dice,
        address provider,
        bool arbitrum,
        DiceEntropyAdapter.Config memory cfg
    ) internal returns (IRandomnessAdapter) {
        return IRandomnessAdapter(
            FlipperDeploy.proxy(
                address(new DiceEntropyAdapter()),
                c.proxyAdminOwner,
                abi.encodeCall(DiceEntropyAdapter.initialize, (dice, provider, arbitrum, cfg, c.deployer))
            )
        );
    }

    /// @notice dice-mock: a local DiceEntropy with Robinhood's live fee and refund delay. No provider is registered
    ///         here (Dice registration takes the provider's hash-chain commitment): `admin` registers one with
    ///         `registerFor` — the dev keeper's `register-provider` does, as admin and default provider.
    function deployLocalDice(address admin, address defaultProvider, address vault) internal returns (IDiceEntropy) {
        return IDiceEntropy(
            address(
                new DiceEntropy(
                    admin,
                    uint128(RobinhoodAddresses.DICE_FEE),
                    defaultProvider,
                    false,
                    vault,
                    bytes32(0),
                    0,
                    "",
                    RobinhoodAddresses.DICE_REFUND_DELAY_BLOCKS
                )
            )
        );
    }
}
