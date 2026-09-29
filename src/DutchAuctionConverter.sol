// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IBankroll {
    function depositTreasury(uint256 amount) external;
}

/// @title DutchAuctionConverter
/// @notice Turns protocol-held assets into $FLIPPER without a keeper, an oracle or a discretionary `minOut`: every lot
///         is sold by descending-price (Dutch) auction to whoever takes it first.
///
///   - Lots are kicked by the house (inventory from losses whose sale failed, with its flip-time $FLIPPER value as
///     the reference) and the RevenueRouter (ETH revenue, no reference). The asset is transferred in first; `kick`
///     records the lot.
///   - Price, in $FLIPPER per 1e18 units of the lot asset, starts at `startMultiple` × the best reference known — the
///     lot's recorded reference (e.g. the flip-time sell quote of the inventory), this asset's last clearing price, or
///     the owner's one-time seed for an asset that has never cleared (`seedPrice`, e.g. ETH at launch) — or at
///     `defaultStart` when none exists. It halves every `halfLife` (linear within each half-life).
///   - Floor: a lot with a reference never sells below half of it at first; that floor itself halves every
///     `FLOOR_HALF_LIFE` (1 day). A thin market with nobody watching therefore can't clear a lot far below the last
///     clearing price in one quick descent, while a real drop in the asset's price only delays the sale by days.
///     The price never stops falling, so any lot eventually clears at the market.
///   - The clock stops while the house's drawdown lock holds (nobody may take then): a lot's elapsed time excludes
///     the house's `lockedTime()` since its kick. And one take can lower an asset's `lastPrice` by at most half, so a
///     single cheap sale can't collapse the next lots' reference.
///   - Anyone takes any part of a lot at the current price (`take`), paying $FLIPPER. Proceeds of house lots are
///     deposited straight into the bankroll (`depositTreasury`); other kickers' proceeds go to the kicker.
///   - The owner only manages who may kick; it cannot move lots or proceeds.
contract DutchAuctionConverter is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct Lot {
        address asset; // address(0) = native ETH
        uint128 remaining;
        uint64 startedAt;
        uint64 lockedAtKick; // the house's `lockedTime()` at kick: time spent locked since then doesn't count
        address kicker;
        uint256 startPrice; // $FLIPPER per 1e18 units of `asset`
        uint256 floorPrice; // at kick: half the lot's reference (0 without one); halves every FLOOR_HALF_LIFE
    }

    uint256 internal constant ONE = 1e18;
    /// @notice a lot's floor starts at this share of its reference ...
    uint256 public constant FLOOR_BPS = 5000;
    /// @notice ... and halves every this long
    uint256 public constant FLOOR_HALF_LIFE = 1 days;

    IERC20 public immutable flipper;
    /// the house: its lots' proceeds are deposited into the bankroll
    address public immutable house;
    uint256 public immutable halfLife;
    uint256 public immutable startMultiple;
    /// start price when no reference exists ($FLIPPER per 1e18 units): high enough for any asset
    uint256 public immutable defaultStart;

    mapping(address => bool) public isKicker;
    Lot[] internal _lots;
    /// @notice last clearing price per asset ($FLIPPER per 1e18 units)
    mapping(address asset => uint256) public lastPrice;

    event Kicked(uint256 indexed lotId, address indexed asset, uint256 amount, uint256 startPrice, address kicker);
    event Taken(uint256 indexed lotId, address indexed taker, uint256 amount, uint256 price, uint256 paid);
    event KickerSet(address kicker, bool allowed);
    event PriceSeeded(address indexed asset, uint256 price);

    error Unauthorized();
    error BadLot();
    error PriceAboveMax(uint256 price, uint256 maxPrice);
    error EthTransferFailed();
    error AlreadyPriced();
    /// the house's drawdown circuit breaker is tripped: lots neither start nor clear until unlock
    error ProtocolLocked();

    constructor(
        IERC20 _flipper,
        address _house,
        address _owner,
        uint256 _halfLife,
        uint256 _startMultiple,
        uint256 _defaultStart
    ) Ownable(_owner) {
        flipper = _flipper;
        house = _house;
        halfLife = _halfLife;
        startMultiple = _startMultiple;
        defaultStart = _defaultStart;
    }

    receive() external payable {}

    function setKicker(address kicker, bool allowed) external onlyOwner {
        isKicker[kicker] = allowed;
        emit KickerSet(kicker, allowed);
    }

    /// @notice Owner, once per asset and only before its first sale: a reference price for an asset with no clearing
    ///         history (e.g. ETH, at the launch price), so its first lot has a start and a floor. Can't overwrite market
    ///         history.
    function seedPrice(address asset, uint256 price) external onlyOwner {
        if (lastPrice[asset] != 0) revert AlreadyPriced();
        lastPrice[asset] = price;
        emit PriceSeeded(asset, price);
    }

    /// @notice Start a lot for `amount` of `asset` already transferred here (ETH: sent with the call).
    /// @param refValue a reference value of the whole lot in $FLIPPER (0 if unknown)
    function kick(address asset, uint256 amount, uint256 refValue) external payable returns (uint256 lotId) {
        if (!isKicker[msg.sender]) revert Unauthorized();
        _whenUnlocked();
        if (amount == 0 || amount > type(uint128).max || (asset == address(0) && msg.value != amount)) revert BadLot();
        uint256 refPrice = Math.mulDiv(refValue, ONE, amount);
        uint256 ref = refPrice > lastPrice[asset] ? refPrice : lastPrice[asset];
        uint256 start = ref == 0 ? defaultStart : ref * startMultiple;
        lotId = _lots.length;
        _lots.push(
            Lot(
                asset,
                uint128(amount),
                uint64(block.timestamp),
                uint64(_lockedTime()),
                msg.sender,
                start,
                ref * FLOOR_BPS / 10_000
            )
        );
        emit Kicked(lotId, asset, amount, start, msg.sender);
    }

    /// @notice Buy `amount` of lot `lotId` at the current price (at most `maxPrice` $FLIPPER per 1e18 units).
    /// @return paid $FLIPPER pulled from the caller
    function take(uint256 lotId, uint256 amount, uint256 maxPrice) external nonReentrant returns (uint256 paid) {
        _whenUnlocked();
        Lot storage l = _lots[lotId];
        if (amount == 0 || amount > l.remaining) revert BadLot();
        uint256 p = priceOf(lotId);
        if (p > maxPrice) revert PriceAboveMax(p, maxPrice);
        paid = Math.mulDiv(amount, p, ONE, Math.Rounding.Ceil);
        l.remaining -= uint128(amount);
        uint256 last = lastPrice[l.asset];
        lastPrice[l.asset] = p >= last / 2 ? p : last / 2;
        address kicker = l.kicker;
        if (kicker == house) {
            flipper.safeTransferFrom(msg.sender, address(this), paid);
            flipper.forceApprove(house, paid);
            IBankroll(house).depositTreasury(paid);
        } else {
            flipper.safeTransferFrom(msg.sender, kicker, paid);
        }
        if (l.asset == address(0)) {
            (bool ok,) = msg.sender.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(l.asset).safeTransfer(msg.sender, amount);
        }
        emit Taken(lotId, msg.sender, amount, p, paid);
    }

    /// @dev the house's total drawdown-lock time (0 for a house without the clock)
    function _lockedTime() internal view returns (uint256) {
        (bool ok, bytes memory r) = house.staticcall(abi.encodeWithSignature("lockedTime()"));
        return ok && r.length == 32 ? abi.decode(r, (uint256)) : 0;
    }

    function _whenUnlocked() internal view {
        (bool ok, bytes memory r) = house.staticcall(abi.encodeWithSignature("locked()"));
        if (ok && r.length == 32 && abi.decode(r, (bool))) revert ProtocolLocked();
    }

    /// @notice Current price of a lot: `startPrice` halving every `halfLife` (linear within each half-life), but not
    ///         below its floor (half its reference, halving every `FLOOR_HALF_LIFE`).
    function priceOf(uint256 lotId) public view returns (uint256) {
        Lot storage l = _lots[lotId];
        uint256 elapsed = block.timestamp - l.startedAt;
        uint256 lt = _lockedTime();
        uint256 paused = lt > l.lockedAtKick ? lt - l.lockedAtKick : 0;
        elapsed = elapsed > paused ? elapsed - paused : 0;
        uint256 f = elapsed / FLOOR_HALF_LIFE;
        uint256 floor = f >= 255 ? 0 : l.floorPrice >> f;
        uint256 k = elapsed / halfLife;
        if (k >= 255) return floor;
        uint256 hi = l.startPrice >> k;
        uint256 p = hi - (hi >> 1) * (elapsed % halfLife) / halfLife;
        return p > floor ? p : floor;
    }

    function lot(uint256 lotId) external view returns (Lot memory) {
        return _lots[lotId];
    }

    function lotsLength() external view returns (uint256) {
        return _lots.length;
    }
}
