// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";

/// @notice The part of Uniswap's v4 PositionManager the keeper uses.
interface IV4PositionManager {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function ownerOf(uint256 tokenId) external view returns (address);
    function approve(address spender, uint256 tokenId) external;
    function permit2() external view returns (address);
}

/// @notice Permit2's allowance entry point.
interface IPermit2Approve {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice The part of UNCX's v4 liquidity locker (`UniV4LiquidityLockerV3`) the keeper uses.
interface IUNCXV4Locker {
    struct LockInfo {
        uint256 lockId;
        address owner;
        uint256 tokenId;
        PoolKey poolKey;
        uint256 amount;
        uint256 unlockTime;
        address collectAddress;
        bool isNFTized;
        uint256 ucf;
    }

    function flatFee() external view returns (uint256);
    function lpFee() external view returns (uint256);
    function collectFee() external view returns (uint256);
    function whitelistedForFreeLock(address) external view returns (bool);
    function lockNFTPosition(uint256 tokenId, uint256 unlockTime, bool mintLockNFT) external payable returns (uint256);
    function setCollectAddress(uint256 lockId, address collectAddress) external;
    function collect(uint256 lockId, address recipient)
        external
        returns (uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1);
    function getLockInfo(uint256 lockId) external view returns (LockInfo memory);
}

/// @title LiquidityKeeper
/// @notice Holds the protocol-owned $FLIPPER/ETH launch position, for good. Not upgradeable, no owner, no admin: once
///         `launch` has run, nothing — the router's owner, a router upgrade, anyone — can decrease the position, move
///         its NFT or take its liquidity. Its only action is `collect()`: anyone may send the position's fees to the
///         RevenueRouter (an immutable address), where they are protocol revenue.
///
///   - `launch` (the router, once, inside its launch transaction): initialises the pool at the start price and mints
///     the router's single-sided $FLIPPER range as a Uniswap v4 PositionManager NFT owned by this contract.
///   - Optional UNCX lock (constructor `locker` ≠ 0): `launch` also locks the NFT in UNCX's v4 locker forever
///     (`ETERNAL_LOCK`), after checking UNCX's fees against the caps fixed at deployment, and points the lock's
///     collect address at the router. This contract then owns the lock; it has no function that migrates, relocks,
///     unlocks or transfers it.
contract LiquidityKeeper {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    // PositionManager actions (v4-periphery `Actions`)
    uint8 internal constant DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant MINT_POSITION = 0x02;
    uint8 internal constant SETTLE_PAIR = 0x0d;
    uint8 internal constant TAKE_PAIR = 0x11;
    uint256 internal constant ETERNAL_LOCK = type(uint256).max;

    IPoolManager public immutable poolManager;
    IV4PositionManager public immutable positionManager;
    /// @notice the only caller of `launch`, and where fees go
    address public immutable router;
    /// @notice UNCX's v4 locker when the position is locked there (0 = held here unlocked)
    IUNCXV4Locker public immutable locker;
    /// @notice the most UNCX may charge at lock time: flat fee (wei), LP fee and collect fee (bps)
    uint256 public immutable maxFlatFee;
    uint256 public immutable maxLpFeeBps;
    uint256 public immutable maxCollectFeeBps;

    PoolKey internal _key;
    int24 public tickLower;
    int24 public tickUpper;
    uint256 public tokenId;
    uint256 public lockId;
    bool public launched;

    event Launched(bytes32 indexed poolId, uint256 tokenId, uint128 liquidity, uint256 lockId);
    event Collected(uint256 amount0, uint256 amount1);

    error Unauthorized();
    error AlreadyLaunched();
    error NotLaunched();
    error UncxFeeTooHigh();
    error PoolPreInitialized();
    error EthTransferFailed();

    constructor(
        IPoolManager _poolManager,
        IV4PositionManager _positionManager,
        address _router,
        IUNCXV4Locker _locker,
        uint256 _maxFlatFee,
        uint256 _maxLpFeeBps,
        uint256 _maxCollectFeeBps
    ) {
        poolManager = _poolManager;
        positionManager = _positionManager;
        router = _router;
        locker = _locker;
        maxFlatFee = _maxFlatFee;
        maxLpFeeBps = _maxLpFeeBps;
        maxCollectFeeBps = _maxCollectFeeBps;
    }

    receive() external payable {}

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Launch (the router, once)
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Initialise `key` at `sqrtPriceX96` and mint `liquidity` over [lower, upper] from the $FLIPPER (currency1)
    ///         the router transferred here, as a PositionManager NFT owned by this contract; lock it in UNCX when so
    ///         configured (`msg.value` pays UNCX's flat fee). Anything left over goes back to the router.
    function launch(PoolKey calldata key, uint160 sqrtPriceX96, int24 lower, int24 upper, uint128 liquidity)
        external
        payable
        returns (uint256 id)
    {
        if (msg.sender != router) revert Unauthorized();
        if (launched) revert AlreadyLaunched();
        launched = true;
        _key = key;
        (tickLower, tickUpper) = (lower, upper);
        // someone may have initialised the pool first (the token address is public once deployed): at or above the
        // start price that is harmless (the range still sits below the price; the opening buy walks the price down
        // through the empty ticks into it), below it the single-sided range would need ETH, so that reverts
        (uint160 current,,,) = poolManager.getSlot0(PoolId.wrap(keccak256(abi.encode(key))));
        if (current == 0) poolManager.initialize(key, sqrtPriceX96);
        else if (current < sqrtPriceX96) revert PoolPreInitialized();

        IERC20 t1 = IERC20(Currency.unwrap(key.currency1));
        uint256 bal = t1.balanceOf(address(this));
        address permit2 = positionManager.permit2();
        t1.forceApprove(permit2, bal);
        IPermit2Approve(permit2).approve(address(t1), address(positionManager), uint160(bal), uint48(block.timestamp));

        id = positionManager.nextTokenId();
        bytes memory actions = abi.encodePacked(MINT_POSITION, SETTLE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, lower, upper, uint256(liquidity), uint128(0), uint128(bal), address(this), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        t1.forceApprove(permit2, 0);

        uint256 lid;
        if (address(locker) != address(0)) (lid, id) = _lock(id);
        (tokenId, lockId) = (id, lid);

        // dust and unused ETH back to the router
        uint256 left = t1.balanceOf(address(this));
        if (left != 0) t1.safeTransfer(router, left);
        _sendEth(router, address(this).balance);
        emit Launched(PoolId.unwrap(_poolId()), id, liquidity, lid);
    }

    /// @dev lock the NFT in UNCX forever, within the fee caps, with the router as the collect address; returns the
    ///      lock and the position NFT it holds (UNCX takes its LP fee out of the liquidity)
    function _lock(uint256 id) internal returns (uint256 lid, uint256 lockedId) {
        IUNCXV4Locker l = locker;
        uint256 fee;
        if (!l.whitelistedForFreeLock(address(this))) {
            fee = l.flatFee();
            if (fee > maxFlatFee || l.lpFee() > maxLpFeeBps || l.collectFee() > maxCollectFeeBps) revert UncxFeeTooHigh();
        } else if (l.collectFee() > maxCollectFeeBps) {
            revert UncxFeeTooHigh();
        }
        positionManager.approve(address(l), id);
        lid = l.lockNFTPosition{value: fee}(id, ETERNAL_LOCK, true);
        l.setCollectAddress(lid, router);
        lockedId = l.getLockInfo(lid).tokenId;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Fees (anyone)
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Send the position's accrued fees (ETH and $FLIPPER) to the RevenueRouter. Anyone may call.
    function collect() external returns (uint256 amount0, uint256 amount1) {
        if (!launched) revert NotLaunched();
        if (address(locker) != address(0)) {
            (amount0, amount1,,) = locker.collect(lockId, router); // UNCX keeps its collect fee
        } else {
            PoolKey memory key = _key;
            address to = router;
            IERC20 t1 = IERC20(Currency.unwrap(key.currency1));
            (uint256 e0, uint256 b0) = (to.balance, t1.balanceOf(to));
            bytes memory actions = abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR);
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
            params[1] = abi.encode(key.currency0, key.currency1, to);
            positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
            (amount0, amount1) = (to.balance - e0, t1.balanceOf(to) - b0);
        }
        // anything that reached this contract some other way (e.g. fees UNCX paid out at lock time) goes along too
        IERC20 f = IERC20(Currency.unwrap(_key.currency1));
        uint256 stray = f.balanceOf(address(this));
        if (stray != 0) f.safeTransfer(router, stray);
        _sendEth(router, address(this).balance);
        emit Collected(amount0, amount1);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice The position: its pool, NFT id, range and liquidity.
    function position()
        external
        view
        returns (bytes32 poolId, uint256 id, int24 lower, int24 upper, uint128 liquidity)
    {
        poolId = PoolId.unwrap(_poolId());
        id = tokenId;
        (lower, upper) = (tickLower, tickUpper);
        if (launched) liquidity = positionManager.getPositionLiquidity(id);
    }

    /// @notice What the position holds now at the pool's current price: amount0 ETH, amount1 $FLIPPER (fees excluded).
    function positionAmounts() external view returns (uint256 amount0, uint256 amount1) {
        if (!launched) return (0, 0);
        uint128 l = positionManager.getPositionLiquidity(tokenId);
        (uint160 sp,,,) = poolManager.getSlot0(_poolId());
        uint160 sa = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sb = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sp <= sa) {
            amount0 = SqrtPriceMath.getAmount0Delta(sa, sb, l, false);
        } else if (sp < sb) {
            amount0 = SqrtPriceMath.getAmount0Delta(sp, sb, l, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sa, sp, l, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sa, sb, l, false);
        }
    }

    /// @notice The pool key of the position.
    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    function _poolId() internal view returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(_key)));
    }

    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
