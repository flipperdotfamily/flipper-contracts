// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {FlipperHouseBase, IPartnerRegistry} from "./house/FlipperHouseBase.sol";
import {IRandomnessAdapter, IRandomnessConsumer} from "./interfaces/IRandomness.sol";
import {IRouteAdapter} from "./interfaces/IRouteAdapter.sol";
import {IRevenueRouter} from "./interfaces/IRevenueRouter.sol";

/// @title FlipperHouse
/// @notice Coin-flip any listed Uniswap v4 token against a bankroll held in $FLIPPER, settled by verifiable
///         randomness (Dice, a Pyth Entropy v2 fork, on Robinhood Chain; any Pyth Entropy v2 or Chainlink VRF v2.5
///         deployment elsewhere) behind an adapter.
///
/// Lifecycle
///   1. `flip` escrows the stake, prices it onchain in $FLIPPER in both directions (S = what selling the stake
///      yields, B = what buying the same amount costs), derives the win chance and the house's maximum
///      liability, reserves that liability out of the bankroll and requests randomness (the player pays the
///      randomness fee in ETH in the same transaction).
///   2. The randomness callback settles atomically:
///        loss → the stake is sold for $FLIPPER into the bankroll (if the sale can't clear the slippage floor the
///               house keeps the tokens as inventory; the player's loss stands either way);
///        win  → the house buys exactly `amount` more of the token (paying at most 1.05·B) and returns
///               2x the stake; if that purchase can't be done the player gets the stake back plus a $FLIPPER
///               fallback of min(B, settle-time value)·1.05.
///   3. Nothing in the callback can revert on an outcome-dependent path: every swap, quote and transfer is a
///      gas-capped `try`. There is therefore no way to learn the outcome and then void a losing flip.
///   4. A delivery whose timing may be chosen by someone who already knows the outcome (a provider retry after a
///      failed first attempt, or a delivery nested inside one of our own external calls) settles in *safe mode*:
///      no swaps, no pushes — losses become inventory, wins return the stake and are resolved later by anyone.
///
/// Pricing rules (all bps, per unit of the stake's mid value M = (S + B) / 2)
///   routeCost h = (B - S) / (B + S)            one-way route cost: LP fees + hook fees + price impact
///   house edge  = 1 - h - 2·winChance          expected profit after ALL swap costs (the house sponsors them)
///   winChance   = min(base, (1 - h - minHouseEdge) / 2)
///                 the chance-based fee: odds only shift once the route is so expensive that sponsoring it
///                 would take the house below its guaranteed profit floor (≈8% one-way at 45% / 2% floor)
///   liability   = 1.05 · B                     worst-case $FLIPPER outflow (capped buy or fallback);
///                 (payout − 1) · stake on a $FLIPPER flip
///   liability  <= min(maxBet, kelly · f*) · (treasury - reserved)   f*: the flip's own Kelly fraction (`_betCap`)
///   profit share: every flip's expected profit is split rewardsShare → $FLIPPER holders, the rest
///                 → bankroll; the holder share is paid out of lost stakes, scaled by 1 / P(loss)
///
/// Upgradeability: deployed behind a TransparentUpgradeableProxy. Storage is append-only (see
/// test/StorageLayout.t.sol); `flipper`, `randomness` and the PoolManager are immutables of the implementation.
///
/// Layout: this contract is the hot path (flip, pricing, randomness callback, settlement, claims, bankroll). The cold
/// paths (initialisation, cancellation, listing, upkeep, admin, partner claims) live in `HouseModule` and run by
/// delegatecall through one-line stubs below, so the ABI is complete here; both share `FlipperHouseBase` storage.
contract FlipperHouse is FlipperHouseBase, IRandomnessConsumer {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice the HouseModule the cold-path stubs delegate to
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable module;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(IPoolManager _poolManager, IERC20 _flipper, IRandomnessAdapter _randomness, address _module)
        FlipperHouseBase(_poolManager, _flipper, _randomness)
    {
        if (_module.code.length == 0) revert InvalidAddress();
        module = _module;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Player entry points
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Flip `amount` of `token`. `msg.value` must cover the randomness fee (see `randomnessFeeFor`); any
    ///         excess is refunded. Reverts with `FlipRejected(code)` when the flip can't be accepted.
    /// @param minWinChanceBps protects against the chance-based fee moving between quote and inclusion
    function flip(address token, uint256 amount, uint16 minWinChanceBps, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 flipId)
    {
        if (block.timestamp > deadline) revert Expired();
        Preview memory pv = _evaluate(token, amount, false);
        if (pv.code == OK && pv.winChanceBps < minWinChanceBps) pv.code = REJECT_WIN_CHANCE;
        if (pv.code != OK) revert FlipRejected(pv.code);
        // ERC-8021 attribution suffix after the four static arguments → partner odds and share
        PartnerTag memory tag;
        uint256 cutBps;
        uint256 discountBps;
        uint256 bonus;
        if (msg.data.length > 132) (tag, cutBps, discountBps, bonus) = _applyPartner(token, pv, 132);
        _capBet(token, pv, tag.shareBps);
        if (pv.code != OK) revert FlipRejected(pv.code);

        _pullExact(token, amount);
        openFlips[msg.sender] += 1;
        reserved += pv.liability;
        escrowed[token] += amount;

        uint32 cbGas = _callbackGas(token);
        uint256 fee = randomness.fee(cbGas);
        if (msg.value < fee) revert InsufficientFee(msg.value, fee);
        uint256 requestId = randomness.request{value: fee}(cbGas);
        if (flipIdByRequest[requestId] != 0) revert DuplicateRequest();

        flipId = nextFlipId++;
        flips[flipId] = Flip({
            player: msg.sender,
            createdAt: uint40(block.timestamp),
            winChanceBps: uint16(pv.winChanceBps),
            roll: 0,
            status: Status.Pending,
            token: token,
            amount: amount.toUint128(),
            liability: pv.liability.toUint128(),
            sellQuote: pv.sellQuote.toUint128(),
            buyQuote: pv.buyQuote.toUint128(),
            requestId: requestId,
            payoutBps: uint16(_flipperPayout())
        });
        flipIdByRequest[requestId] = flipId;
        if (tag.partnerId != 0) {
            flipPartner[flipId] = tag;
            emit FlipPartner(flipId, tag.partnerId, cutBps, discountBps, bonus, tag.shareBps);
        }

        emit FlipRequested(
            flipId,
            msg.sender,
            token,
            amount,
            pv.winChanceBps,
            pv.sellQuote,
            pv.buyQuote,
            pv.liability,
            requestId,
            fee
        );

        if (msg.value > fee) {
            // a sender that can't take the excess back (a contract without `receive`) doesn't lose the flip: the
            // excess becomes a claimable ETH balance (`claim(address(0))`)
            uint256 excess = msg.value - fee;
            (bool sent,) = msg.sender.call{value: excess}("");
            if (!sent) _credit(msg.sender, address(0), excess);
        }
    }

    /// @dev Resolve the flip's ERC-8021 suffix through the partner registry (gas-capped, bounded returndata: a failing
    ///      or hostile registry means no partner) and price it in: the partner's tier cut C of the flip's expected
    ///      profit E is capped so that E − C stays at the house-edge floor; the discount D = C·discount goes back to
    ///      the player as win chance (+D/2 on token flips, +D/payout on $FLIPPER flips); the partner keeps C − D.
    /// @param tailOffset where the calldata tail starts (after the function's static arguments)
    function _applyPartner(address token, Preview memory pv, uint256 tailOffset)
        internal
        view
        returns (PartnerTag memory tag, uint256 cut, uint256 disc, uint256 bonus)
    {
        address reg = partnerRegistry;
        if (reg == address(0)) return (tag, 0, 0, 0);
        // the lookup's failure is swallowed: make sure it gets its full gas cap
        if (gasleft() < PARTNER_GAS * 64 / 63 + 20_000) revert InsufficientGas();
        bytes memory q = abi.encodeCall(IPartnerRegistry.resolve, (msg.sender, msg.data[tailOffset:]));
        bool ok;
        uint256 id;
        uint256 gasCap = PARTNER_GAS;
        assembly ("memory-safe") {
            // at most 96 bytes of returndata are copied, to free memory (not the scratch space: 0x40 is the free
            // memory pointer)
            let out := mload(0x40)
            ok := staticcall(gasCap, reg, add(q, 0x20), mload(q), out, 0x60)
            ok := and(ok, eq(returndatasize(), 0x60))
            if ok {
                id := mload(out)
                cut := mload(add(out, 0x20))
                disc := mload(add(out, 0x40))
            }
        }
        if (!ok || id == 0 || id > type(uint32).max || cut > BPS || disc > BPS) return (tag, 0, 0, 0);
        Params memory p = _params;
        bool isFlipper = token == address(flipper);
        uint256 winPayout = isFlipper ? _flipperPayout() : 2 * BPS;
        // expected profit (bps of value) at the flip's odds, before the partner
        uint256 e = isFlipper
            ? BPS - Math.mulDiv(pv.winChanceBps, winPayout, BPS, Math.Rounding.Ceil)
            : BPS - pv.routeCostBps - 2 * pv.winChanceBps;
        if (e <= p.minHouseEdgeBps) return (tag, 0, 0, 0);
        uint256 c = e * cut / BPS;
        if (c > e - p.minHouseEdgeBps) c = e - p.minHouseEdgeBps;
        bonus = c * disc / BPS * BPS / winPayout;
        uint256 given = Math.mulDiv(bonus, winPayout, BPS, Math.Rounding.Ceil);
        pv.winChanceBps += bonus;
        tag = PartnerTag(uint32(id), uint16(c > given ? c - given : 0));
    }

    /// @notice Price a prospective flip exactly as `flip` would. Not a view (quotes simulate swaps); call it
    ///         with eth_call. With the same ERC-8021 suffix appended (and `from` = the player) the win chance includes
    ///         the partner's discount.
    ///         `maxLiability` is this flip's own cap (its Kelly term, under the `maxBetBps` ceiling).
    function previewFlip(address token, uint256 amount) external returns (Preview memory pv) {
        pv = _evaluate(token, amount, true);
        if (pv.code != OK) return pv;
        PartnerTag memory tag;
        if (msg.data.length > 68) (tag,,,) = _applyPartner(token, pv, 68);
        _capBet(token, pv, tag.shareBps);
    }

    /// @dev The bet-size check, once the flip's final odds and partner share are known: its own cap (`_betCap`:
    ///      Kelly under the `maxBetBps` ceiling) and the cap on all pending liabilities (`maxReservedBps`).
    function _capBet(address token, Preview memory pv, uint256 shareBps) internal view {
        pv.maxLiability = _betCap(token == address(flipper), pv.winChanceBps, pv.sellQuote, pv.buyQuote, shareBps);
        uint256 mr = _params.maxReservedBps;
        if (
            pv.liability > pv.maxLiability || pv.liability == 0
                || (mr != 0 && (reserved + pv.liability) * BPS > treasury * mr)
        ) pv.code = REJECT_BET_SIZE;
    }

    /// @notice Withdraw payments that could not be pushed during settlement (`address(0)`: ETH, e.g. a randomness-fee
    ///         excess that couldn't be refunded).
    function claim(address token) external nonReentrant {
        _whenUnlocked();
        uint256 amount = claimable[msg.sender][token];
        if (amount == 0) return;
        claimable[msg.sender][token] = 0;
        claimableTotal[token] -= amount;
        if (token == address(0)) _sendEth(msg.sender, amount);
        else IERC20(token).safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, token, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Randomness callback + settlement
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IRandomnessConsumer
    function onRandomness(uint256 requestId, uint256 randomWord, bool safeMode) external {
        if (msg.sender != address(randomness)) revert OnlyRandomness();
        uint256 flipId = flipIdByRequest[requestId];
        if (flipId == 0) return;
        Flip storage f = flips[flipId];
        if (f.status != Status.Pending) return;
        _closeOpen(f.player);
        uint16 roll = uint16(randomWord % BPS);
        if (locked) {
            // drawdown lock: record the outcome, settle it market-free after unlock (`settleDeferred`); later
            // deliveries of this request are ignored
            _deferredRoll[flipId] = uint256(roll) + 1;
            delete flipIdByRequest[requestId];
            emit SettlementDeferred(flipId);
            return;
        }

        // Delivered from inside one of our own external calls: settle without any external interaction.
        bool nested = _locked();
        if (nested) safeMode = true;
        // a market settlement swallows failed swaps, so a delivery well short of the callback budget would settle
        // degraded: refuse it (providers then retry with the budget, or recover in safe mode; relayers' estimates
        // include it). 15/16: the delivery reaches here through ~3 call frames, each keeping 63/64 of the gas.
        else if (!safeMode && gasleft() < uint256(_callbackGas(f.token)) * 15 / 16) revert InsufficientGas();
        if (!nested) _setLock(true);

        bool won = roll >= BPS - f.winChanceBps; // "rand*100 > 55 wins" at 45%
        f.roll = roll;
        if (safeMode) _settleSafe(flipId, f, won, roll);
        else _settleFlip(flipId, f, won, roll, keccak256(abi.encode(randomWord, flipId, address(this))));
        _checkDrawdown();

        if (!nested) _setLock(false);
    }

    /// @param tag secret for settled quotes, derived from the random word (never visible to token/hook code)
    function _settleFlip(uint256 flipId, Flip storage f, bool won, uint16 roll, bytes32 tag) internal {
        address token = f.token;
        address player = f.player;
        uint256 amount = f.amount;
        uint256 liability = f.liability;
        escrowed[token] -= amount;
        reserved -= liability;

        Status st;
        uint256 tokenPaid;
        uint256 flipperPaid;
        uint256 flipperReceived;
        Params memory p = _params;

        if (token == address(flipper)) {
            if (won) {
                uint256 payout = amount * f.payoutBps / BPS;
                flipperPaid = payout - amount; // net outflow from the bankroll, <= liability
                treasury -= flipperPaid;
                _pay(token, player, payout);
                st = Status.Won;
            } else {
                flipperReceived = amount;
                _creditLoss(flipId, amount, amount, _edgeBps(f), f.winChanceBps);
                st = Status.Lost;
            }
        } else {
            uint256 sellQuote = f.sellQuote;
            uint256 buyQuote = f.buyQuote;
            uint256 mid = (sellQuote + buyQuote) / 2;
            PoolKey[] memory route = _tokens[token].route;
            if (won) {
                (bool ok, uint256 spent, uint256 received) = _buyWinnings(token, amount, liability, route);
                if (ok) {
                    treasury -= spent;
                    flipperPaid = spent;
                    tokenPaid = amount + received;
                    st = Status.Won;
                } else {
                    // The purchase failed (price moved past the cap, liquidity pulled, hook refused, gas grief).
                    // Value the winnings at the lower of the flip-time buy quote and the settle-time sell value
                    // (scaled by the flip-time spread). The settle-time value cannot be flash-manipulated, and it
                    // comes from a *settled* simulation — the stake really moves through the pool and the
                    // $FLIPPER really arrives before the revert — so a token or hook that fails only our buys can
                    // never be valued above what the loss branch would realise. It runs on what the callback
                    // budget has left: if that isn't enough the win is left pending for the keeper.
                    (bool okQ,, uint256 s2) = _tryQuoteSettled(
                        _request(EXACT_IN, route, _c(token), _c(address(flipper)), amount, 0),
                        _attemptGas(p.swapGasLimit),
                        tag
                    );
                    tokenPaid = amount;
                    if (okQ) {
                        uint256 base = Math.min(buyQuote, Math.mulDiv(s2, buyQuote, sellQuote));
                        flipperPaid = Math.mulDiv(base, TOKEN_FALLBACK_BPS, BPS);
                        treasury -= flipperPaid;
                        st = Status.WonFallback;
                    } else {
                        // Pool unusable in both directions: return the stake now, keep the liability
                        // reserved, and let a keeper settle the winnings once a fair price exists.
                        reserved += liability;
                        st = Status.WinPending;
                    }
                }
                if (tokenPaid != 0) _pay(token, player, tokenPaid);
                if (st == Status.WonFallback) _pay(address(flipper), player, flipperPaid);
            } else {
                uint256 minOut = sellQuote * (BPS - p.lossSlippageBps) / BPS;
                (bool ok,, uint256 out) = _trySwap(
                    _request(EXACT_IN, route, _c(token), _c(address(flipper)), amount, minOut),
                    _attemptGas(p.swapGasLimit)
                );
                if (ok) {
                    _bookBuyback(true);
                    flipperReceived = out;
                    _creditLoss(flipId, out, mid, _edgeBps(f), f.winChanceBps);
                    st = Status.Lost;
                } else {
                    inventory[token] += amount;
                    inventoryValue[token] += sellQuote;
                    st = Status.LostInventory;
                }
            }
        }

        f.status = st;
        emit FlipSettled(flipId, player, token, won, roll, st, tokenPaid, flipperPaid, flipperReceived, false);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Pricing and views
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function _evaluate(address token, uint256 amount, bool withFee) internal returns (Preview memory pv) {
        Params memory p = _params;
        (uint256 base, uint256 payout) = _baseTerms();
        pv.maxLiability = maxLiability();
        if (withFee) pv.randomnessFee = randomness.fee(_callbackGas(token));

        if (paused) {
            pv.code = REJECT_PAUSED;
            return pv;
        }
        if (locked) {
            pv.code = REJECT_LOCKED;
            return pv;
        }
        if (amount == 0 || amount > type(uint128).max) {
            pv.code = REJECT_AMOUNT;
            return pv;
        }

        if (token == address(flipper)) {
            pv.sellQuote = amount;
            pv.buyQuote = amount;
            // the edge never below the floor, whatever the schedule's shape between its endpoints
            uint256 maxWin = (BPS - p.minHouseEdgeBps) * BPS / payout;
            pv.winChanceBps = base < maxWin ? base : maxWin;
            pv.liability = Math.mulDiv(amount, payout - BPS, BPS, Math.Rounding.Ceil);
        } else {
            TokenConfig storage tc = _tokens[token];
            if (!tc.enabled) {
                pv.code = REJECT_TOKEN;
                return pv;
            }
            PoolKey[] memory route = tc.route;
            (bool okS,, uint256 s) = _tryQuote(
                _request(EXACT_IN, route, _c(token), _c(address(flipper)), amount, 0), p.swapGasLimit
            );
            (bool okB, uint256 b,) = _tryQuote(
                _request(EXACT_OUT, _reversePath(route), _c(address(flipper)), _c(token), amount, 0), p.swapGasLimit
            );
            if (!okS || !okB || s == 0 || b == 0 || b > type(uint128).max) {
                pv.code = REJECT_QUOTE;
                return pv;
            }
            pv.sellQuote = s;
            pv.buyQuote = b;
            pv.routeCostBps = b > s ? Math.mulDiv(b - s, BPS, b + s, Math.Rounding.Ceil) : 0;
            if (pv.routeCostBps > p.maxRouteCostBps) {
                pv.code = REJECT_ROUTE_COST;
                return pv;
            }
            // the house sponsors route costs until they'd take its expected profit below the floor
            uint256 floorOdds = BPS > pv.routeCostBps + p.minHouseEdgeBps
                ? (BPS - pv.routeCostBps - p.minHouseEdgeBps) / 2
                : 0;
            pv.winChanceBps = Math.min(base, floorOdds);
            pv.liability = Math.mulDiv(b, TOKEN_FALLBACK_BPS, BPS, Math.Rounding.Ceil);
        }

        if (pv.winChanceBps < p.minWinChanceBps) pv.code = REJECT_WIN_CHANCE;
        // dust can't hold a randomness request open; nor can one player hold many (the adapter's cap is global)
        else if (pv.liability < minLiability) pv.code = REJECT_AMOUNT;
        else if (openFlips[msg.sender] >= _maxOpenPerPlayer()) pv.code = REJECT_TOO_MANY_OPEN;
        // the bet size is judged after the partner discount and share are known: `_capBet`
    }

    /// @notice The base win chance now (the edge schedule's, before route costs and partner discounts).
    function currentBaseWinChanceBps() external view returns (uint256 w) {
        (w,) = _baseTerms();
    }

    /// @notice The $FLIPPER payout now (the edge schedule's); a flip keeps the one it was made at.
    function currentFlipperPayoutBps() external view returns (uint256) {
        return _flipperPayout();
    }

    /// @notice The Kelly multiplier now (drawdown-scaled).
    function currentKellyBps() external view returns (uint256) {
        return _kelly();
    }

    function _flipperPayout() internal view returns (uint256 payout) {
        (, payout) = _baseTerms();
    }

    /// @notice For the UIs: the house's net buybacks, their ratcheted high, the schedule's thresholds (ETH wei) and
    ///         the base terms they give now.
    function edgeProgress()
        external
        view
        returns (int256 net, int256 high, uint256 fromEth, uint256 toEth, uint256 winBps, uint256 payoutBps)
    {
        EdgeSchedule memory s = edgeSchedule;
        (winBps, payoutBps) = _baseTerms();
        return (netBuybackEth, buybackHigh, s.fromEth, s.toEth, winBps, payoutBps);
    }

    /// @notice Owner: the edge schedule (`toEth` 0 turns it off). Both ends must keep the win chance within
    ///         [minWinChanceBps, 49%], the $FLIPPER payout within [2×, 2.15×] and the house edge at or above
    ///         `minHouseEdgeBps` on token and $FLIPPER flips; `fromEth` < `toEth`.
    function setEdgeSchedule(EdgeSchedule calldata s) external onlyOwner {
        if (s.toEth != 0) {
            Params memory p = _params;
            if (s.fromEth >= s.toEth) revert InvalidParams();
            _checkTerms(p, s.winStartBps, s.payoutStartBps);
            _checkTerms(p, s.winEndBps, s.payoutEndBps);
        }
        edgeSchedule = s;
        emit EdgeScheduleSet(s);
    }

    function _checkTerms(Params memory p, uint256 w, uint256 pay) internal pure {
        if (w < p.minWinChanceBps || w > 4900 || pay < 2 * BPS || pay > 21_500) revert InvalidParams();
        if (2 * w + p.minHouseEdgeBps > BPS || w * pay > (BPS - p.minHouseEdgeBps) * BPS) revert InvalidParams();
    }

    function setBuybackHigh(int128) external {
        _delegate();
    }

    /// @notice Randomness fee (native ETH) for flipping `token` ($FLIPPER flips use a smaller callback budget).
    function randomnessFeeFor(address token) external view returns (uint256) {
        return randomness.fee(_callbackGas(token));
    }

    function tokenConfig(address token)
        external
        view
        returns (bool enabled, bool blocked, address adapter, PoolKey[] memory route)
    {
        TokenConfig storage tc = _tokens[token];
        return (tc.enabled, tc.blocked, tc.adapter, tc.route);
    }

    function listedTokensLength() external view returns (uint256) {
        return listedTokens.length;
    }

    function params() external view returns (Params memory) {
        return _params;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Bankroll
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Add $FLIPPER to the bankroll. The staking vault's deposits (and the very first seed) are capital: they
    ///         mint bankroll units at the current NAV. Anyone else's (revenue, auction proceeds, donations) is income:
    ///         it raises the NAV per unit.
    function depositTreasury(uint256 amount) external nonReentrant {
        _whenUnlocked();
        _pullExact(address(flipper), amount);
        uint256 t = treasury;
        uint256 u = navUnits;
        if (u == 0) navUnits = uint128(t + amount); // first seed (or a pre-existing bankroll): 1 unit per $FLIPPER
        else if (msg.sender == vault) navUnits = uint128(u + (t == 0 ? amount : Math.mulDiv(amount, u, t)));
        treasury = t + amount;
        emit TreasuryDeposit(msg.sender, amount);
        _checkDrawdown();
    }

    /// @notice Withdraw unreserved bankroll. Reserved liabilities and escrowed stakes are untouchable. The owner may
    ///         withdraw only until a staking vault is set; from then on only the vault can (stakers' funds).
    function withdrawTreasury(address to, uint256 amount) external nonReentrant {
        address v = vault;
        if (msg.sender != (v == address(0) ? owner() : v)) revert Unauthorized();
        _whenUnlocked();
        uint256 t = treasury;
        if (amount > _withdrawable(t, reserved)) revert ExceedsAvailable();
        // capital leaving: burn units at the current NAV (rounded up), so the NAV per unit doesn't move
        uint256 u = navUnits;
        if (u != 0) navUnits = uint128(u - Math.min(u, Math.mulDiv(amount, u, t, Math.Rounding.Ceil)));
        treasury = t - amount;
        flipper.safeTransfer(to, amount);
        emit TreasuryWithdrawal(to, amount);
    }

    /// @notice How much bankroll can leave now: never the pending flips' reserved liabilities, and never so much that
    ///         what stays falls under their `maxReservedBps` cap (an exit can't leave pending flips oversized for the
    ///         bankroll that remains). The vault's withdrawals and `maxWithdrawable` use it.
    function withdrawable() external view returns (uint256) {
        return _withdrawable(treasury, reserved);
    }

    function _withdrawable(uint256 t, uint256 r) internal view returns (uint256 w) {
        if (t <= r) return 0;
        w = t - r;
        uint256 mr = _params.maxReservedBps;
        if (mr != 0) {
            // keep ≥ r / maxReserved: reserved × BPS ≤ (treasury − amount) × maxReservedBps
            uint256 keep = Math.mulDiv(r, BPS, mr, Math.Rounding.Ceil);
            uint256 w2 = t > keep ? t - keep : 0;
            if (w2 < w) w = w2;
        }
    }

    /// @notice Total seconds the drawdown lock has held, the current lock included: the revenue auction subtracts it
    ///         from its lots' clocks, so a lock doesn't decay prices nobody may take.
    function lockedTime() external view returns (uint256) {
        uint256 at = _lockedAt;
        return _lockedSeconds + (locked && at != 0 ? block.timestamp - at : 0);
    }

    /// @notice Push skimmed rewards profit to the revenue router (which converts it to launchpad tokens).
    function flushRewards() external nonReentrant {
        _whenUnlocked();
        address router = revenueRouter;
        uint256 amount = rewardsAccrued;
        if (router == address(0) || amount == 0) return;
        rewardsAccrued = 0;
        flipper.safeTransfer(router, amount);
        IRevenueRouter(router).onHouseRewards(amount);
        emit RewardsFlushed(router, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Cold paths: delegated to the HouseModule (see there for documentation)
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function initialize(address, Params calldata) external {
        _delegate();
    }

    function cancelFlip(uint256) external {
        _delegate();
    }

    function listToken(address, IRouteAdapter) external {
        _delegate();
    }

    function setTokenRoute(address, PoolKey[] calldata) external {
        _delegate();
    }

    function setTokenEnabled(address, bool) external {
        _delegate();
    }

    function resolvePendingWin(uint256) external {
        _delegate();
    }

    function sweepInventory(address, uint256) external {
        _delegate();
    }

    function writeOffInventory(address) external {
        _delegate();
    }

    function setParams(Params calldata) external {
        _delegate();
    }

    function setGuardian(address) external {
        _delegate();
    }

    function setConverter(address) external {
        _delegate();
    }

    function setRouteAdapter(address, bool) external {
        _delegate();
    }

    function setRevenueRouter(address) external {
        _delegate();
    }

    function setVault(address) external {
        _delegate();
    }

    function setPaused(bool) external {
        _delegate();
    }

    function claimPartner(uint256) external returns (uint256) {
        _delegate();
    }

    function setPartnerRegistry(address) external {
        _delegate();
    }

    function settleDeferred(uint256) external {
        _delegate();
    }

    function checkDrawdown() external {
        _delegate();
    }

    function unlock(bool) external {
        _delegate();
    }

    function transferUnlocker(address) external {
        _delegate();
    }

    function acceptUnlocker() external {
        _delegate();
    }

    function setUnlocker(address) external {
        _delegate();
    }

    function setLockMinTreasury(uint128) external {
        _delegate();
    }

    function resetNavAth(uint256) external {
        _delegate();
    }

    function setFlipLimits(uint16, uint128) external {
        _delegate();
    }

    function setKellySchedule(uint16, uint16, uint16, uint16) external {
        _delegate();
    }

    /// @dev forward this call to the module in this contract's context and return (or revert) with its result
    function _delegate() private {
        address m = module;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), m, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}
