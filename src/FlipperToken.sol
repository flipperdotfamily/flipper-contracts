// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @notice $FLIPPER for the self-launched (no launchpad) path: a plain fixed-supply ERC20 with no owner, no mint, no
///         pause and no transfer hooks.
contract FlipperToken is ERC20, ERC20Burnable {
    constructor(string memory name_, string memory symbol_, uint256 supply, address to) ERC20(name_, symbol_) {
        _mint(to, supply);
    }
}
