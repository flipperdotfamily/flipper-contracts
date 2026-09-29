// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FlipperHouse} from "../FlipperHouse.sol";
import {FlipperHouseBase} from "../house/FlipperHouseBase.sol";
import {TreasuryVault} from "../TreasuryVault.sol";

/// @title FlipperLens
/// @notice Read helpers for the frontend and SDK. Several functions simulate swaps through the house, so they are
///         not `view`; call them with eth_call.
contract FlipperLens {
    struct HouseView {
        address flipper;
        uint256 treasury;
        uint256 reserved;
        uint256 maxLiability;
        uint256 rewardsAccrued;
        uint256 randomnessFee;
        bool paused;
        uint256 listedTokens;
        uint256 nextFlipId;
        FlipperHouseBase.Params params;
    }

    struct TokenView {
        address token;
        string name;
        string symbol;
        uint8 decimals;
        bool enabled;
        bool blocked;
        address adapter;
        uint256 hops;
    }

    struct FlipView {
        uint256 id;
        address player;
        uint40 createdAt;
        uint16 winChanceBps;
        uint16 roll;
        FlipperHouseBase.Status status;
        address token;
        uint128 amount;
        uint128 liability;
        uint128 sellQuote;
        uint128 buyQuote;
        uint256 requestId;
        uint16 payoutBps;
    }

    struct VaultView {
        address vault;
        uint256 totalAssets; // whole bankroll (house.treasury), reserved included
        uint256 freeAssets; // treasury - reserved: the most that can be withdrawn right now
        uint256 depositorShares;
        uint256 protocolShares;
        uint256 pricePerShare; // post-crystallization, TreasuryVault.PPS_SCALE
        uint256 highWaterMark;
        uint256 protocolOwnedAssets;
        uint256 depositorAssets;
        uint16 performanceFeeBps;
        uint32 lockDuration;
        uint32 withdrawCooldown;
    }

    struct VaultPositionView {
        uint256 shares;
        uint256 assets; // at the post-crystallization price
        uint256 unlockAt;
        uint256 pendingShares;
        uint256 readyAt;
        uint256 maxWithdrawable; // what `withdraw` would pay right now
        uint256 flipperBalance;
        uint256 flipperAllowance; // granted to the vault
    }

    function house(FlipperHouse h) external view returns (HouseView memory v) {
        v.flipper = address(h.flipper());
        v.treasury = h.treasury();
        v.reserved = h.reserved();
        v.maxLiability = h.maxLiability();
        v.rewardsAccrued = h.rewardsAccrued();
        v.randomnessFee = h.randomnessFeeFor(address(0)); // token-flip fee
        v.paused = h.paused();
        v.listedTokens = h.listedTokensLength();
        v.nextFlipId = h.nextFlipId();
        v.params = h.params();
    }

    /// @notice Staking vault totals and `user`'s position (pass address(0) for totals only).
    function vault(TreasuryVault tv, address user)
        external
        view
        returns (VaultView memory v, VaultPositionView memory p)
    {
        FlipperHouse h = FlipperHouse(payable(address(tv.house())));
        v.vault = address(tv);
        v.freeAssets = h.treasury() - h.reserved();
        (
            v.totalAssets,
            v.depositorShares,
            v.protocolShares,
            v.pricePerShare,
            v.highWaterMark,
            v.protocolOwnedAssets,
            v.depositorAssets
        ) = tv.stats();
        v.performanceFeeBps = tv.performanceFeeBps();
        v.lockDuration = tv.lockDuration();
        v.withdrawCooldown = tv.withdrawCooldown();
        if (user == address(0)) return (v, p);
        (p.shares, p.assets, p.unlockAt, p.pendingShares, p.readyAt) = tv.positionOf(user);
        p.maxWithdrawable = tv.maxWithdrawable(user);
        IERC20 f = tv.flipper();
        p.flipperBalance = f.balanceOf(user);
        p.flipperAllowance = f.allowance(user, address(tv));
    }

    function tokens(FlipperHouse h, uint256 offset, uint256 limit) external view returns (TokenView[] memory out) {
        uint256 n = h.listedTokensLength();
        if (offset >= n) return out;
        uint256 end = offset + limit > n ? n : offset + limit;
        out = new TokenView[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            out[i - offset] = tokenView(h, h.listedTokens(i));
        }
    }

    function tokenView(FlipperHouse h, address token) public view returns (TokenView memory v) {
        (bool enabled, bool blocked, address adapter, PoolKey[] memory route) = h.tokenConfig(token);
        v.token = token;
        v.enabled = enabled;
        v.blocked = blocked;
        v.adapter = adapter;
        v.hops = route.length;
        (v.name, v.symbol, v.decimals) = _meta(token);
    }

    function flipsById(FlipperHouse h, uint256[] calldata ids) external view returns (FlipView[] memory out) {
        out = new FlipView[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            out[i] = _flip(h, ids[i]);
        }
    }

    /// @notice Flips in ids [fromId, toId) that are WinPending, of `player` (address(0): anyone's). Each can be paid by
    ///         anyone through `house.resolvePendingWin(id)`: simulate that call (eth_call) to see whether the buy
    ///         executes now; from `createdAt + params.pendingTimeout` it always succeeds (liability paid in $FLIPPER).
    function pendingWins(FlipperHouse h, address player, uint256 fromId, uint256 toId)
        external
        view
        returns (FlipView[] memory out)
    {
        uint256 next = h.nextFlipId();
        if (toId > next) toId = next;
        if (fromId == 0) fromId = 1;
        uint256[] memory hits = new uint256[](toId > fromId ? toId - fromId : 0);
        uint256 n;
        for (uint256 id = fromId; id < toId; ++id) {
            (address p,,,, FlipperHouseBase.Status st,,,,,,,) = h.flips(id);
            if (st == FlipperHouseBase.Status.WinPending && (player == address(0) || p == player)) hits[n++] = id;
        }
        out = new FlipView[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = _flip(h, hits[i]);
        }
    }

    function _flip(FlipperHouse h, uint256 id) internal view returns (FlipView memory f) {
        f.id = id;
        (
            f.player,
            f.createdAt,
            f.winChanceBps,
            f.roll,
            f.status,
            f.token,
            f.amount,
            f.liability,
            f.sellQuote,
            f.buyQuote,
            f.requestId,
            f.payoutBps
        ) = h.flips(id);
    }

    function claimables(FlipperHouse h, address user, address[] calldata tokenList)
        external
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](tokenList.length);
        for (uint256 i; i < tokenList.length; ++i) {
            amounts[i] = h.claimable(user, tokenList[i]);
        }
    }

    /// @notice The house's balance of `token` less everything it owes in it: 0 when the books are exact (the house
    ///         runs with no buffer), negative if a claim could fail. $FLIPPER owes the treasury (reserved included),
    ///         the holders' accrual, escrowed stakes, deferred payments and partner accruals; any other token owes
    ///         escrowed stakes, inventory and deferred payments; `address(0)`, ETH owed (unrefundable fee excess). For
    ///         monitoring (alarm on anything but 0).
    function surplus(FlipperHouse h, address token) external view returns (int256) {
        uint256 owed = h.escrowed(token) + h.claimableTotal(token);
        owed += token == address(h.flipper())
            ? h.treasury() + h.rewardsAccrued() + h.partnerAccruedTotal()
            : h.inventory(token);
        uint256 bal = token == address(0) ? address(h).balance : IERC20(token).balanceOf(address(h));
        return int256(bal) - int256(owed);
    }

    /// @notice Batch previews (one per amount) — used to draw the odds/size curve in the UI.
    function previews(FlipperHouse h, address token, uint256[] calldata amounts)
        external
        returns (FlipperHouseBase.Preview[] memory out)
    {
        out = new FlipperHouseBase.Preview[](amounts.length);
        for (uint256 i; i < amounts.length; ++i) {
            out[i] = h.previewFlip(token, amounts[i]);
        }
    }

    /// @notice Largest stake in (0, hi] the house accepts (0 if none). With `baseOdds`, also require that no
    ///         chance-based fee applies (route cost within the allowance). Binary search: the accepted stakes are one
    ///         window [min, max] — below it a stake is refused as too small (code 2, under `minLiability`), above it as
    ///         too big — so a too-small midpoint raises the lower bound like an accepted one.
    function maxStake(FlipperHouse h, address token, uint256 hi, bool baseOdds)
        external
        returns (uint256 amount, FlipperHouseBase.Preview memory pv)
    {
        uint256 base = h.currentBaseWinChanceBps(); // the edge schedule's, now
        FlipperHouseBase.Preview memory top = h.previewFlip(token, hi);
        if (_ok(top, base, baseOdds)) return (hi, top);
        uint256 lo = 0; // never too big: accepted (then `amount == lo`) or too small
        for (uint256 i; i < 256 && hi - lo > 1; ++i) {
            uint256 mid = lo + (hi - lo) / 2;
            FlipperHouseBase.Preview memory p = h.previewFlip(token, mid);
            if (_ok(p, base, baseOdds)) {
                lo = mid;
                amount = mid;
                pv = p;
                // stop once within 0.1%: plenty for a UI "max" button
                if ((hi - lo) * 1000 < lo) break;
            } else if (p.code == 2 && mid <= type(uint128).max && amount == 0) {
                lo = mid; // too small: the window, if any, is above
            } else {
                hi = mid;
            }
        }
    }

    function _ok(FlipperHouseBase.Preview memory p, uint256 base, bool baseOdds) internal pure returns (bool) {
        return p.code == 0 && (!baseOdds || p.winChanceBps == base);
    }

    function _meta(address token) internal view returns (string memory name, string memory symbol, uint8 dec) {
        try IERC20Metadata(token).name() returns (string memory n) {
            name = n;
        } catch {}
        try IERC20Metadata(token).symbol() returns (string memory s) {
            symbol = s;
        } catch {}
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            dec = d;
        } catch {
            dec = 18;
        }
    }
}
