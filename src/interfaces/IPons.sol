// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Subset of pons v2 on Robinhood Chain (factory 0x7eD598Bc…01EC7e): bonding-curve launch that graduates
///         into a Uniswap v4 pool (native ETH, token, fee 0, tickSpacing 200, meme hook).
interface IPonsV2Factory {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    struct TokenParams {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
        address creatorFeeRecipient; // 0 = msg.sender
        uint16 creatorTaxBps;
        bool buybackEnabled;
        bytes32 expectedEconomics; // 0 = no pin
        bytes32 salt;
    }

    function launchToken(TokenParams calldata params, uint256 launchConfigId, address pairToken)
        external
        payable
        returns (address token, address curve);

    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        uint8 phase; // 0 curve trading, 1 swept (sold out, awaiting pool), 2 graduated (v4 pool seeded)
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
    function launchFee() external view returns (uint256);
    function createGraduatedPool(address token) external returns (uint256 positionId);
    function memeHook() external view returns (address);
}

interface IPonsV2Curve {
    /// @dev clamps to what remains on the curve and refunds the excess to msg.sender
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function readyToGraduate() external view returns (bool);
}
