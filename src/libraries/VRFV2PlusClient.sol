// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Mirror of Chainlink's VRFV2PlusClient extra-args encoding.
library VRFV2PlusClient {
    // bytes4(keccak256("VRF ExtraArgsV1"))
    bytes4 internal constant EXTRA_ARGS_V1_TAG = hex"92fd1338";

    struct ExtraArgsV1 {
        bool nativePayment;
    }

    function _argsToBytes(ExtraArgsV1 memory extraArgs) internal pure returns (bytes memory bts) {
        return abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, extraArgs);
    }
}
