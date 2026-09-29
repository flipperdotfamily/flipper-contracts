// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Reentrancy lock in transient storage whose state is readable, so a callback can *detect* that it
///         is running inside one of our own external calls (and degrade gracefully) instead of reverting.
abstract contract TransientLock {
    // keccak256("flipper.family.lock") - 1
    bytes32 private constant LOCK_SLOT = 0x5c1b7a8b6b5a3f1b3f0f5b6bb0d3a1f4c0f64a4b3f5c2b1c37a0b7cb4a8d6e21;

    error Reentrancy();

    modifier nonReentrant() {
        if (_locked()) revert Reentrancy();
        _setLock(true);
        _;
        _setLock(false);
    }

    function _locked() internal view returns (bool l) {
        assembly ("memory-safe") {
            l := tload(LOCK_SLOT)
        }
    }

    function _setLock(bool l) internal {
        assembly ("memory-safe") {
            tstore(LOCK_SLOT, l)
        }
    }
}
