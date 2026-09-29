// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/// @title V4SwapEngine
/// @notice Minimal, self-contained Uniswap v4 multi-hop swap + quote engine.
///
///         - Executes exact-input and exact-output multi-hop swaps inside a single `unlock`, netting the
///           intermediate currencies through flash accounting (only the two endpoints ever move).
///         - Quotes the same swaps by running them and reverting with the result (the V4Quoter pattern), so
///           quotes and executions share one code path and can never disagree on routing or hook behaviour.
///         - Every call into the PoolManager is made through `try` with an explicit gas cap. Callers get a
///           boolean instead of a revert, which is what lets the VRF callback treat "the pool is broken or
///           griefed" as an ordinary, outcome-independent branch instead of an unrecoverable failure.
///
///         Strict delta checks: every hop must consume exactly the amount requested and produce exactly the
///         amount expected; partial fills (liquidity exhausted) or hooks that alter the caller's specified
///         amount make the whole swap revert (and therefore return `ok = false`).
abstract contract V4SwapEngine is IUnlockCallback {
    using SafeERC20 for IERC20;

    uint256 internal constant MAX_HOPS = 4;

    uint8 internal constant EXACT_IN = 1;
    uint8 internal constant EXACT_OUT = 2;

    uint8 internal constant OP_SWAP = 0;

    uint8 internal constant MODE_EXECUTE = 0;
    uint8 internal constant MODE_QUOTE = 1; // swap only, revert with the amounts
    uint8 internal constant MODE_QUOTE_SETTLED = 2; // swap + settle + take (real token transfers), then revert


    IPoolManager public immutable poolManager;

    /// @dev Revert channel for quotes. Only our own unlockCallback can raise it at the top level of an
    ///      `unlock` frame: hook reverts are wrapped by the PoolManager (`WrappedError`) and quotes never
    ///      transfer tokens, so no third-party code can spoof this selector.
    error QuoteResult(uint256 amountIn, uint256 amountOut);
    /// @dev Settled quotes run token code (transfers, balanceOf) that can revert with arbitrary data, so their
    ///      result carries a caller-chosen secret `tag` that token code cannot know.
    error SettledQuoteResult(bytes32 tag, uint256 amountIn, uint256 amountOut);
    error NotPoolManager();
    error InvalidPath();
    error PartialFill();
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error ExcessiveInput(uint256 amountIn, uint256 maxAmountIn);

    /// @param kind EXACT_IN or EXACT_OUT
    /// @param mode MODE_EXECUTE, MODE_QUOTE or MODE_QUOTE_SETTLED
    /// @param tag secret echoed by MODE_QUOTE_SETTLED
    /// @param currencyIn first currency of `path`
    /// @param currencyOut last currency of `path`
    /// @param amount exact input (EXACT_IN) or exact output (EXACT_OUT)
    /// @param limit min output (EXACT_IN) or max input (EXACT_OUT); ignored for quotes
    /// @param path pools in trade order, from currencyIn to currencyOut
    struct SwapRequest {
        uint8 kind;
        uint8 mode;
        bytes32 tag;
        Currency currencyIn;
        Currency currencyOut;
        uint256 amount;
        uint256 limit;
        PoolKey[] path;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Internal API
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Execute a swap. Never reverts: failures (slippage, partial fill, hook revert, out-of-gas)
    ///         return ok = false with no state change.
    function _trySwap(SwapRequest memory r, uint256 gasCap)
        internal
        returns (bool ok, uint256 amountIn, uint256 amountOut)
    {
        r.mode = MODE_EXECUTE;
        try poolManager.unlock{gas: _gasCap(gasCap)}(abi.encode(OP_SWAP, abi.encode(r))) returns (bytes memory res) {
            if (res.length != 64) return (false, 0, 0);
            (amountIn, amountOut) = abi.decode(res, (uint256, uint256));
            ok = true;
        } catch {
            return (false, 0, 0);
        }
    }

    /// @notice Simulate a swap and return its amounts. Never reverts.
    function _tryQuote(SwapRequest memory r, uint256 gasCap)
        internal
        returns (bool ok, uint256 amountIn, uint256 amountOut)
    {
        r.mode = MODE_QUOTE;
        try poolManager.unlock{gas: _gasCap(gasCap)}(abi.encode(OP_SWAP, abi.encode(r))) {
            // unreachable: a quote always reverts
            return (false, 0, 0);
        } catch (bytes memory reason) {
            if (reason.length != 68 || bytes4(reason) != QuoteResult.selector) return (false, 0, 0);
            assembly ("memory-safe") {
                amountIn := mload(add(reason, 36))
                amountOut := mload(add(reason, 68))
            }
            ok = true;
        }
    }

    /// @notice Simulate a swap *including* settlement: the input really leaves this contract and the output really
    ///         arrives, then everything is reverted. Proves the path is executable end to end (token transfers,
    ///         blocklists, transfer taxes), not just priceable. Never reverts.
    function _tryQuoteSettled(SwapRequest memory r, uint256 gasCap, bytes32 tag)
        internal
        returns (bool ok, uint256 amountIn, uint256 amountOut)
    {
        r.mode = MODE_QUOTE_SETTLED;
        r.tag = tag;
        try poolManager.unlock{gas: _gasCap(gasCap)}(abi.encode(OP_SWAP, abi.encode(r))) {
            return (false, 0, 0);
        } catch {
            // Read only the 100 bytes a result has, straight from returndata: token code runs inside this call and
            // can revert with an arbitrarily large payload, whose copy would be paid outside the gas cap.
            bytes4 sel = SettledQuoteResult.selector;
            assembly ("memory-safe") {
                if eq(returndatasize(), 100) {
                    let m := mload(0x40)
                    returndatacopy(m, 0, 100)
                    ok := and(eq(and(mload(m), shl(224, 0xffffffff)), sel), eq(mload(add(m, 4)), tag))
                    amountIn := mload(add(m, 36))
                    amountOut := mload(add(m, 68))
                }
            }
            if (!ok) return (false, 0, 0);
        }
    }

    function _request(uint8 kind, PoolKey[] memory path, Currency cIn, Currency cOut, uint256 amount, uint256 limit)
        internal
        pure
        returns (SwapRequest memory r)
    {
        r.kind = kind;
        r.currencyIn = cIn;
        r.currencyOut = cOut;
        r.amount = amount;
        r.limit = limit;
        r.path = path;
    }

    /// @dev Never forward more than 63/64 of what we hold minus a small reserve, so the caller always keeps
    ///      enough gas to handle a failed sub-call.
    /// @dev Called by every executed or simulated swap with the native ETH it moved through its end hop: an exact-input
    ///      swap's ETH into its last hop, an exact-output swap's ETH out of its first hop (0 if that hop isn't ETH-paired).
    ///      Real hop amounts from the PoolManager's deltas. A no-op unless overridden (the house records it).
    function _onEthHop(uint256 eth) internal virtual {}

    /// @dev whether this contract records `_onEthHop` (a compile-time constant: the engine's other users skip the work)
    function _tracksEthHop() internal pure virtual returns (bool) {
        return false;
    }

    function _gasCap(uint256 cap) private view returns (uint256) {
        uint256 left = gasleft();
        uint256 usable = left > 40_000 ? left - 40_000 : 0;
        usable -= usable / 64;
        return cap < usable ? cap : usable;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Unlock callback
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint8 op, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (op != OP_SWAP) return _customUnlock(op, payload);
        SwapRequest memory r = abi.decode(payload, (SwapRequest));

        // An exact input is paid before swapping when the swap really moves tokens, so the PoolManager holds it
        // while the pools run: pools that pay out of the PoolManager mid-swap (the v3 bridge hook) can, and flash
        // accounting nets the same either way. Exact outputs pay after, once the input is known; pure quotes never.
        // Step 0 pays, step 1 swaps, step 2 pays: one settle site keeps FlipperHouse under EIP-170.
        bool payFirst = r.kind == EXACT_IN && r.mode != MODE_QUOTE;
        uint256 amountIn = r.amount;
        uint256 amountOut;
        for (uint256 step = payFirst ? 0 : 1; step < 3; ++step) {
            if (step != 1) {
                _settleCurrency(r.currencyIn, amountIn);
                continue;
            }
            (amountIn, amountOut) = r.kind == EXACT_IN ? _swapExactIn(r) : _swapExactOut(r);

            if (r.mode == MODE_QUOTE) revert QuoteResult(amountIn, amountOut);

            if (r.mode == MODE_EXECUTE) {
                if (r.kind == EXACT_IN) {
                    if (amountOut < r.limit) revert InsufficientOutput(amountOut, r.limit);
                } else if (amountIn > r.limit) {
                    revert ExcessiveInput(amountIn, r.limit);
                }
            }
            if (payFirst) break;
        }

        poolManager.take(r.currencyOut, address(this), amountOut);
        if (r.mode == MODE_QUOTE_SETTLED) revert SettledQuoteResult(r.tag, amountIn, amountOut);
        return abi.encode(amountIn, amountOut);
    }

    /// @dev Derived contracts may run their own PoolManager actions (e.g. liquidity) inside `unlock`.
    function _customUnlock(uint8, bytes memory) internal virtual returns (bytes memory) {
        revert InvalidPath();
    }

    function _swapExactIn(SwapRequest memory r) private returns (uint256, uint256) {
        uint256 n = r.path.length;
        if (n == 0 || n > MAX_HOPS || r.amount == 0 || r.amount > uint256(type(int256).max)) revert InvalidPath();

        Currency cur = r.currencyIn;
        uint256 amt = r.amount;
        uint256 ethHop;
        for (uint256 i; i < n; ++i) {
            PoolKey memory key = r.path[i];
            bool zeroForOne;
            if (cur == key.currency0) zeroForOne = true;
            else if (!(cur == key.currency1)) revert InvalidPath();
            if (_tracksEthHop() && i == n - 1 && cur.isAddressZero()) ethHop = amt; // ETH into the last hop

            BalanceDelta d = poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amt),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            (int128 dIn, int128 dOut) = zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
            // must have paid exactly `amt` and received something
            if (dIn >= 0 || uint256(-int256(dIn)) != amt || dOut <= 0) revert PartialFill();
            amt = uint256(int256(dOut));
            cur = zeroForOne ? key.currency1 : key.currency0;
        }
        if (!(cur == r.currencyOut)) revert InvalidPath();
        if (_tracksEthHop()) _onEthHop(ethHop);
        return (r.amount, amt);
    }

    function _swapExactOut(SwapRequest memory r) private returns (uint256, uint256) {
        uint256 n = r.path.length;
        if (n == 0 || n > MAX_HOPS || r.amount == 0 || r.amount > uint256(type(int256).max)) revert InvalidPath();

        // walk the path backwards: each hop must produce exactly what the next hop consumes
        Currency cur = r.currencyOut;
        uint256 amt = r.amount;
        uint256 ethHop;
        for (uint256 i = n; i > 0; --i) {
            PoolKey memory key = r.path[i - 1];
            bool zeroForOne; // true when currency0 is the input of this hop, i.e. `cur` is currency1
            if (cur == key.currency1) zeroForOne = true;
            else if (!(cur == key.currency0)) revert InvalidPath();
            if (_tracksEthHop() && i == 1 && cur.isAddressZero()) ethHop = amt; // ETH out of the first hop

            BalanceDelta d = poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: int256(amt),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            (int128 dIn, int128 dOut) = zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
            if (dOut <= 0 || uint256(int256(dOut)) != amt || dIn >= 0) revert PartialFill();
            amt = uint256(-int256(dIn));
            cur = zeroForOne ? key.currency0 : key.currency1;
        }
        if (!(cur == r.currencyIn)) revert InvalidPath();
        if (_tracksEthHop()) _onEthHop(ethHop);
        return (amt, r.amount);
    }

    function _settleCurrency(Currency currency, uint256 amount) internal {
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Path helpers
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev Walks `path` from `from` and returns the currency it ends on; reverts if any hop is disconnected,
    ///      the path is too long, or a pool appears twice.
    function _pathEnd(PoolKey[] memory path, Currency from) internal pure returns (Currency cur) {
        uint256 n = path.length;
        if (n == 0 || n > MAX_HOPS) revert InvalidPath();
        cur = from;
        for (uint256 i; i < n; ++i) {
            PoolKey memory key = path[i];
            if (cur == key.currency0) cur = key.currency1;
            else if (cur == key.currency1) cur = key.currency0;
            else revert InvalidPath();
            for (uint256 j; j < i; ++j) {
                if (keccak256(abi.encode(path[j])) == keccak256(abi.encode(key))) revert InvalidPath();
            }
        }
    }

    function _reversePath(PoolKey[] memory path) internal pure returns (PoolKey[] memory rev) {
        uint256 n = path.length;
        rev = new PoolKey[](n);
        for (uint256 i; i < n; ++i) {
            rev[i] = path[n - 1 - i];
        }
    }
}
