// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ILaunchpadVerifier} from "../interfaces/ILaunchpadVerifier.sol";
import {IPonsV2Factory} from "../interfaces/IPons.sol";
import {CodeTemplate} from "../libraries/CodeTemplate.sol";

/// @title PonsVerifier
/// @notice ListingPolicy verifier for pons v2 launches (Robinhood Chain). Immutable: no owner, no settings. Built for
///         the Robinhood config; not attached by default.
///
///   Approves a token on its canonical graduated pool when
///     - the pons v2 factory's registry has it (`getLaunchedToken(token).exists`, `.token == token`) and it has
///       graduated into its v4 pool (phase PoolCreated);
///     - its runtime code is the audited `PonsV2LauncherToken` template (OpenZeppelin ERC20 + ERC20Burnable: no
///       owner, pause, blacklist, tax or transfer hook; immutables masked). This also guards against the pons Safe
///       swapping the factory's token deployer (`setLaunchDeployer`) for one that emits different code;
///     - `key` is the canonical pool: (token, pair token or native ETH), the launch's frozen fee and tick spacing,
///       and the pons meme hook, whose runtime code is still the audited one. The meme hook's fees are frozen per
///       pool at registration; it has no pause, allowlist or upgrade path.
contract PonsVerifier is ILaunchpadVerifier {
    bytes32 public constant LAUNCHPAD_ID = "pons";
    uint8 internal constant PHASE_POOL_CREATED = 2;

    uint8 public constant NOT_A_LAUNCH = 1;
    uint8 public constant NOT_GRADUATED = 2;
    uint8 public constant TOKEN_CODE = 3;
    uint8 public constant NOT_CANONICAL_POOL = 4;
    uint8 public constant HOOK_CODE_CHANGED = 5;

    IPonsV2Factory public immutable factory;
    address public immutable memeHook;
    bytes32 public immutable memeHookCodehash;
    bytes32 public immutable tokenTemplate;
    uint256 public immutable tokenSize;
    uint256 public immutable tokenImmutables;

    constructor(
        IPonsV2Factory _factory,
        address _memeHook,
        bytes32 _memeHookCodehash,
        bytes32 _tokenTemplate,
        uint256 _tokenSize,
        uint256 _tokenImmutables
    ) {
        factory = _factory;
        memeHook = _memeHook;
        memeHookCodehash = _memeHookCodehash;
        tokenTemplate = _tokenTemplate;
        tokenSize = _tokenSize;
        tokenImmutables = _tokenImmutables;
    }

    function verify(address token, PoolKey calldata key) external view returns (bool, uint8, bytes32) {
        uint8 reason = _verify(token, key);
        return (reason == 0, reason, LAUNCHPAD_ID);
    }

    function _verify(address token, PoolKey calldata key) internal view returns (uint8) {
        IPonsV2Factory.LaunchedToken memory l = factory.getLaunchedToken(token);
        if (!l.exists || l.token != token) return NOT_A_LAUNCH;
        if (l.phase != PHASE_POOL_CREATED) return NOT_GRADUATED;
        if (CodeTemplate.maskedHash(token, tokenSize, tokenImmutables) != tokenTemplate) return TOKEN_CODE;
        (address c0, address c1) = token < l.pairToken ? (token, l.pairToken) : (l.pairToken, token);
        if (
            Currency.unwrap(key.currency0) != c0 || Currency.unwrap(key.currency1) != c1 || key.fee != l.poolFee
                || key.tickSpacing != l.tickSpacing || address(key.hooks) != memeHook
        ) return NOT_CANONICAL_POOL;
        if (memeHook.codehash != memeHookCodehash) return HOOK_CODE_CHANGED;
        return 0;
    }
}
