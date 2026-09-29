// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Identifies contracts deployed from one audited source whose runtime code differs only in its immutables:
///         the runtime code is hashed with the 32-byte immutable words zeroed.
library CodeTemplate {
    /// @param size the template's runtime size (anything else can't match)
    /// @param offsets up to 16 byte offsets of immutable words, 16 bits each, low bits first; 0 ends the list
    /// @return h keccak256 of `a`'s masked runtime code, or 0 when its size differs
    function maskedHash(address a, uint256 size, uint256 offsets) internal view returns (bytes32 h) {
        if (a.code.length != size) return bytes32(0);
        assembly ("memory-safe") {
            let m := mload(0x40)
            extcodecopy(a, m, 0, size)
            for {} offsets {} {
                let o := and(offsets, 0xffff)
                if iszero(o) { break }
                if gt(add(o, 32), size) { break }
                mstore(add(m, o), 0)
                offsets := shr(16, offsets)
            }
            h := keccak256(m, size)
        }
    }

    /// @notice Pack byte offsets for `maskedHash`.
    function pack(uint16[] memory offsets) internal pure returns (uint256 packed) {
        require(offsets.length <= 16, "CodeTemplate: too many offsets");
        for (uint256 i; i < offsets.length; ++i) {
            packed |= uint256(offsets[i]) << (16 * i);
        }
    }
}
