// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

/// @notice The part of FlipperHouse the vault uses.
interface IVaultHouse {
    function flipper() external view returns (IERC20);
    function treasury() external view returns (uint256);
    function reserved() external view returns (uint256);
    function depositTreasury(uint256 amount) external;
    function withdrawTreasury(address to, uint256 amount) external;
}

/// @title TreasuryVault
/// @notice Stake $FLIPPER into the house bankroll for a non-transferable receipt, sFLIPPER.
///
///   Accounting (ERC-4626-style, but with two classes of owner)
///     A = totalAssets()  = house.treasury(): the whole bankroll, `reserved` included (pending flips are unrealized)
///     S = totalShares()  = totalSupply() (depositor sFLIPPER) + protocolShares (protocol-owned liquidity, POL)
///     pps = A / S, scaled by PPS_SCALE (1e27). Flip PnL, router deposits and donations all move A and the pps.
///
///   Bootstrap: whenever S == 0 while A > 0, the whole bankroll becomes POL at 1:1 (protocolShares = A). The
///   deployment's seeded bankroll and any donations therefore start protocol-owned, and there is always a large
///   share base, which rules out the first-depositor inflation attack. With A == 0 and S == 0 the first deposit
///   mints 1:1; with A == 0 but S > 0 (the bankroll wiped out) deposits revert until something is donated.
///
///   Performance fee with a high-water mark (`crystallize`, run at the start of every state change): when the
///   pps is above `hwm`, `performanceFeeBps` (80%) of the depositors' gain above the mark becomes protocol-owned
///   by minting protocol shares, so depositors keep 20% of their pro-rata gain. The mark then moves to the new
///   pps. Below the mark nothing is charged: after a drawdown, recovery up to the previous high is fee-free.
///   Fees crystallize continuously, so a fee taken at a peak is not refunded if the bankroll then falls. The mark
///   is global: a deposit made while the pps is below it also recovers fee-free up to it.
///
///   Exits: deposits lock the depositor's shares for `lockDuration`; afterwards `requestWithdraw` starts a
///   `withdrawCooldown`, then `withdraw` pays the pending shares at the pps of that moment, out of the free
///   (unreserved) bankroll. Pending shares stay staked: they keep earning, keep bearing losses and keep counting
///   for holder rewards.
///
///   sFLIPPER cannot be transferred or approved (mint and burn only), so locks can't be bypassed.
///
///   Holder rewards (reward-bearing $FLIPPER, `FlipperRewardToken`): the token credits this vault with a virtual
///   balance equal to its depositors' assets (`depositorAssets`: depositor shares × the post-crystallisation pps,
///   so net of the not-yet-crystallised fee; protocol-owned shares never earn). The vault claims what that
///   balance earned and passes it through to depositors pro rata to shares (a reward-per-share accumulator with
///   per-account corrections, exact across deposits and withdrawals); stakers `claimRewards()`. Lazy sync: every
///   deposit, request, withdrawal, crystallisation and claim first pulls the vault's rewards (before shares
///   change) and afterwards re-syncs its virtual balance on the token. With a plain $FLIPPER these calls are
///   no-ops.
///
///   Upgradeability: deployed behind a TransparentUpgradeableProxy; storage is append-only.
contract TreasuryVault is ERC20Upgradeable, Ownable2StepUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct PendingWithdrawal {
        uint256 shares;
        uint256 readyAt;
    }

    /// @dev one pass of fee accrual, computed without writing state (shared by the views and `_crystallize`)
    struct Accrual {
        uint256 assets;
        uint256 shares; // total shares after bootstrap / fee
        uint256 protocolShares;
        uint256 pps;
        uint256 hwm;
        uint256 feeAssets;
        uint256 feeShares;
        bool bootstrap;
        bool crystallized;
    }

    uint256 public constant PPS_SCALE = 1e27;
    uint256 internal constant REWARD_MAGNITUDE = 2 ** 96;
    /// @dev gas the swallowed reward-token calls (`claim`, `syncVault`) must be able to get; below it the whole
    ///      transaction reverts, so gas estimates always include it and the lazy sync never gets skipped
    uint256 internal constant REWARD_CALL_GAS = 300_000;
    uint256 public constant MAX_FEE_BPS = 9500;
    uint256 public constant MAX_LOCK = 365 days;
    uint256 public constant MAX_COOLDOWN = 30 days;
    uint256 internal constant BPS = 10_000;

    IVaultHouse public house;
    IERC20 public flipper;
    /// @notice protocol-owned shares (not an ERC-20 balance). They can never be withdrawn: there is no function that
    ///         burns them, so the protocol-owned bankroll stays in the house for good
    uint256 public protocolShares;
    /// @notice high-water mark: assets per share (PPS_SCALE) above which the performance fee is charged
    uint256 public hwm;
    uint16 public performanceFeeBps;
    uint32 public lockDuration;
    uint32 public withdrawCooldown;
    mapping(address user => uint256) public unlockAt;
    mapping(address user => PendingWithdrawal) public pending;

    /// @notice holder rewards passed through to depositors: reward per share, magnified by 2^96
    uint256 public rewardPerShare;
    mapping(address user => int256) internal _rewardCorrections;
    mapping(address user => uint256) public rewardsClaimed;

    event Deposit(address indexed user, uint256 assets, uint256 shares, uint256 unlockAt);
    event WithdrawRequested(address indexed user, uint256 shares, uint256 readyAt);
    event WithdrawCancelled(address indexed user, uint256 shares);
    event Withdraw(address indexed user, uint256 assets, uint256 shares);
    event ParamsUpdated(uint256 performanceFeeBps, uint256 lockDuration, uint256 withdrawCooldown);
    event Crystallized(uint256 assets, uint256 pps, uint256 feeAssets, uint256 feeShares);
    event Bootstrapped(uint256 assets);
    event RewardsPulled(uint256 amount, uint256 rewardPerShare);
    event RewardsClaimed(address indexed user, uint256 amount);

    error ZeroAmount();
    error ZeroShares();
    error Slippage(uint256 amount, uint256 min);
    error NoAssets();
    error Locked(uint256 unlockAt);
    error CoolingDown(uint256 readyAt);
    error NothingPending();
    error ExceedsBalance(uint256 available);
    error InsufficientFreeBankroll(uint256 available);
    error NonTransferable();
    error InvalidParams();
    error InvalidAddress();
    error FeeOnTransfer();
    error InsufficientGas();
    /// the house's drawdown circuit breaker is tripped: deposits, withdrawals and claims are frozen until unlock
    error ProtocolLocked();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IVaultHouse _house,
        IERC20 _flipper,
        address _owner,
        uint16 feeBps,
        uint32 lock,
        uint32 cooldown
    ) external initializer {
        if (
            address(_flipper) == address(0) || address(_house).code.length == 0
                || _house.flipper() != _flipper
        ) {
            revert InvalidAddress();
        }
        __ERC20_init("Staked FLIPPER", "sFLIPPER");
        __Ownable_init(_owner);
        house = _house;
        flipper = _flipper;
        hwm = PPS_SCALE;
        _setParams(feeBps, lock, cooldown);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Staking
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Stake `assets` $FLIPPER into the bankroll. Locks all of the caller's shares until
    ///         max(current unlock, now + lockDuration).
    function deposit(uint256 assets, uint256 minShares) external nonReentrant returns (uint256 shares) {
        _whenUnlocked();
        if (assets == 0) revert ZeroAmount();
        _pullRewards();
        (uint256 a, uint256 s) = _crystallize();
        if (s == 0) shares = assets; // empty vault: 1:1
        else if (a == 0) revert NoAssets(); // bankroll wiped out: existing shares are worth nothing
        else shares = Math.mulDiv(assets, s, a);
        if (shares == 0) revert ZeroShares();
        if (shares < minShares) revert Slippage(shares, minShares);

        IERC20 f = flipper;
        uint256 before = f.balanceOf(address(this));
        f.safeTransferFrom(msg.sender, address(this), assets);
        if (f.balanceOf(address(this)) - before != assets) revert FeeOnTransfer();
        f.forceApprove(address(house), assets);
        house.depositTreasury(assets);

        _mint(msg.sender, shares);
        uint256 until = Math.max(unlockAt[msg.sender], block.timestamp + lockDuration);
        unlockAt[msg.sender] = until;
        emit Deposit(msg.sender, assets, shares, until);
        _syncRewardToken();
    }

    /// @notice Queue `shares` for withdrawal once the lock has expired. Restarts the cooldown for everything
    ///         pending. Pending shares stay staked (exposed to PnL, counted for holder rewards) until withdrawn.
    function requestWithdraw(uint256 shares) external nonReentrant {
        _whenUnlocked();
        _crystallize();
        uint256 until = unlockAt[msg.sender];
        if (block.timestamp < until) revert Locked(until);
        if (shares == 0) revert ZeroAmount();
        PendingWithdrawal storage p = pending[msg.sender];
        uint256 available = balanceOf(msg.sender) - p.shares;
        if (shares > available) revert ExceedsBalance(available);
        p.shares += shares;
        uint256 readyAt = block.timestamp + withdrawCooldown;
        p.readyAt = readyAt;
        emit WithdrawRequested(msg.sender, shares, readyAt);
        _syncRewardToken();
    }

    function cancelWithdraw() external nonReentrant {
        _whenUnlocked();
        uint256 shares = pending[msg.sender].shares;
        if (shares == 0) revert NothingPending();
        delete pending[msg.sender];
        emit WithdrawCancelled(msg.sender, shares);
    }

    /// @notice Burn all pending shares for $FLIPPER at the current (post-crystallization) price. Reverts with
    ///         `InsufficientFreeBankroll` while pending flips reserve too much of the bankroll.
    function withdraw(uint256 minAssets) external nonReentrant returns (uint256 assets) {
        _whenUnlocked();
        PendingWithdrawal memory p = pending[msg.sender];
        if (p.shares == 0) revert NothingPending();
        if (block.timestamp < p.readyAt) revert CoolingDown(p.readyAt);
        _pullRewards();
        (uint256 a, uint256 s) = _crystallize();
        assets = Math.mulDiv(p.shares, a, s);
        uint256 free = _freeBankroll();
        if (assets > free) revert InsufficientFreeBankroll(free);
        if (assets < minAssets) revert Slippage(assets, minAssets);

        delete pending[msg.sender];
        _burn(msg.sender, p.shares);
        if (assets != 0) house.withdrawTreasury(msg.sender, assets);
        emit Withdraw(msg.sender, assets, p.shares);
        _syncRewardToken();
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Performance fee
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Bootstrap POL and/or charge the performance fee on gains above the high-water mark. Anyone may
    ///         call; it also runs at the start of every deposit, withdrawal, request and parameter change.
    function crystallize() external nonReentrant {
        _whenUnlocked();
        _crystallize();
        _syncRewardToken();
    }

    function _crystallize() internal returns (uint256 assets, uint256 shares) {
        Accrual memory a = _accrue();
        if (a.protocolShares != protocolShares) protocolShares = a.protocolShares;
        if (a.hwm != hwm) hwm = a.hwm;
        if (a.bootstrap) emit Bootstrapped(a.assets);
        if (a.crystallized) emit Crystallized(a.assets, a.pps, a.feeAssets, a.feeShares);
        return (a.assets, a.shares);
    }

    function _accrue() internal view returns (Accrual memory a) {
        a.assets = house.treasury();
        a.protocolShares = protocolShares;
        a.hwm = hwm;
        uint256 d = totalSupply();
        a.shares = d + a.protocolShares;
        if (a.shares == 0) {
            // nobody owns the bankroll: all of it (the seed, donations, residue) becomes protocol-owned at 1:1
            a.pps = PPS_SCALE;
            a.hwm = PPS_SCALE;
            if (a.assets != 0) {
                a.protocolShares = a.assets;
                a.shares = a.assets;
                a.bootstrap = true;
            }
            return a;
        }
        a.pps = Math.mulDiv(a.assets, PPS_SCALE, a.shares);
        if (a.pps <= a.hwm) return a;

        a.crystallized = true;
        uint256 feeBps = performanceFeeBps;
        if (d != 0 && feeBps != 0) {
            // Depositors keep (1 − fee) of their gain above the mark, so their price after the fee is
            //   p' = hwm + (pps − hwm)·(1 − fee)
            // and the protocol is minted f shares such that A / (S + f) = p'. Those shares dilute the protocol's
            // own shares too, so this is f = fee·S / (depositorAssets − fee), not the third-party
            // f = fee·S / (A − fee). Solving in price space keeps the rounding (in the protocol's favour) at the
            // price's precision, however small the depositors' position.
            uint256 target = a.hwm + Math.mulDiv(a.pps - a.hwm, BPS - feeBps, BPS);
            uint256 f = Math.mulDiv(a.assets, PPS_SCALE, target, Math.Rounding.Ceil) - a.shares;
            uint256 ppsAfter = Math.mulDiv(a.assets, PPS_SCALE, a.shares + f);
            a.feeAssets = Math.mulDiv(d, a.pps - ppsAfter, PPS_SCALE);
            a.feeShares = f;
            a.protocolShares += f;
            a.shares += f;
            a.pps = ppsAfter;
        }
        // (rounding may leave the post-fee price a hair under the old mark: the mark never moves down)
        if (a.pps > a.hwm) a.hwm = a.pps;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Crystallizes first, so a fee change never applies to gains already made. Lock and cooldown changes
    ///         apply to future deposits and requests (existing `unlockAt` / `readyAt` are kept).
    function setParams(uint16 feeBps, uint32 lock, uint32 cooldown) external onlyOwner nonReentrant {
        _crystallize();
        _setParams(feeBps, lock, cooldown);
        _syncRewardToken();
    }

    function _setParams(uint16 feeBps, uint32 lock, uint32 cooldown) internal {
        if (feeBps > MAX_FEE_BPS || lock > MAX_LOCK || cooldown > MAX_COOLDOWN) revert InvalidParams();
        performanceFeeBps = feeBps;
        lockDuration = lock;
        withdrawCooldown = cooldown;
        emit ParamsUpdated(feeBps, lock, cooldown);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Holder rewards (pass-through)
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Claim the caller's share of the holder rewards the vault's depositor assets earned.
    function claimRewards() external nonReentrant returns (uint256 amount) {
        _whenUnlocked();
        _pullRewards();
        amount = _earned(msg.sender, rewardPerShare) - rewardsClaimed[msg.sender];
        if (amount != 0) {
            rewardsClaimed[msg.sender] += amount;
            flipper.safeTransfer(msg.sender, amount);
            emit RewardsClaimed(msg.sender, amount);
        }
        _syncRewardToken();
    }

    /// @notice Holder rewards `user` can claim now (including what the vault hasn't pulled from the token yet).
    function pendingRewards(address user) external view returns (uint256) {
        uint256 rps = rewardPerShare;
        uint256 s = totalSupply();
        if (s != 0) {
            (bool ok, bytes memory ret) =
                address(flipper).staticcall(abi.encodeWithSignature("claimable(address)", address(this)));
            if (ok && ret.length >= 32) rps += abi.decode(ret, (uint256)) * REWARD_MAGNITUDE / s;
        }
        return _earned(user, rps) - rewardsClaimed[user];
    }

    /// @notice The depositors' claim on the bankroll: depositor shares at the post-crystallisation price. The
    ///         reward-bearing $FLIPPER uses it as the vault's eligible balance.
    function depositorAssets() public view returns (uint256) {
        Accrual memory a = _accrue();
        return a.shares == 0 ? 0 : Math.mulDiv(totalSupply(), a.assets, a.shares);
    }

    /// @dev claim what the vault's virtual balance earned and credit it to the current shares (no-op with a plain
    ///      $FLIPPER)
    function _pullRewards() internal {
        if (gasleft() < REWARD_CALL_GAS) revert InsufficientGas();
        (bool ok, bytes memory ret) = address(flipper).call(abi.encodeWithSignature("claim()"));
        if (!ok || ret.length < 32) return;
        uint256 amount = abi.decode(ret, (uint256));
        uint256 s = totalSupply();
        if (amount == 0 || s == 0) return;
        uint256 rps = rewardPerShare + amount * REWARD_MAGNITUDE / s;
        rewardPerShare = rps;
        emit RewardsPulled(amount, rps);
    }

    /// @dev the house's drawdown lock freezes the vault too (a house without the breaker never locks)
    function _whenUnlocked() internal view {
        (bool ok, bytes memory r) = address(house).staticcall(abi.encodeWithSignature("locked()"));
        if (ok && r.length == 32 && abi.decode(r, (bool))) revert ProtocolLocked();
    }

    /// @dev re-sync the vault's virtual balance on the token (no-op with a plain $FLIPPER)
    function _syncRewardToken() internal {
        if (gasleft() < REWARD_CALL_GAS) revert InsufficientGas();
        (bool ok,) = address(flipper).call(abi.encodeWithSignature("syncVault()"));
        ok;
    }

    function _earned(address user, uint256 rps) internal view returns (uint256) {
        int256 e = SafeCast.toInt256(rps * balanceOf(user)) + _rewardCorrections[user];
        return e > 0 ? uint256(e) / REWARD_MAGNITUDE : 0;
    }

    /// @dev mint / burn only (transfers are disabled): move reward corrections with the shares
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        int256 c = SafeCast.toInt256(rewardPerShare * value);
        if (from != address(0)) _rewardCorrections[from] += c;
        if (to != address(0)) _rewardCorrections[to] -= c;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Views (all at the post-crystallization state, without writing it)
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice The whole bankroll, pending-flip reservations included.
    function totalAssets() public view returns (uint256) {
        return house.treasury();
    }

    /// @notice Depositor shares + protocol-owned shares (as stored; see `stats` for the post-crystallization view).
    function totalShares() public view returns (uint256) {
        return totalSupply() + protocolShares;
    }

    /// @notice Assets per share (PPS_SCALE) after crystallization.
    function previewPricePerShare() external view returns (uint256) {
        return _accrue().pps;
    }

    /// @notice Shares `deposit(assets, …)` would mint now (0 where it would revert).
    function previewDeposit(uint256 assets) external view returns (uint256) {
        Accrual memory a = _accrue();
        if (a.shares == 0) return assets;
        return a.assets == 0 ? 0 : Math.mulDiv(assets, a.shares, a.assets);
    }

    /// @notice Assets `shares` are worth now (before the free-bankroll check).
    function previewRedeem(uint256 shares) external view returns (uint256) {
        Accrual memory a = _accrue();
        return a.shares == 0 ? 0 : Math.mulDiv(shares, a.assets, a.shares);
    }

    function positionOf(address user)
        external
        view
        returns (uint256 shares, uint256 assets, uint256 unlocksAt, uint256 pendingShares, uint256 readyAt)
    {
        Accrual memory a = _accrue();
        shares = balanceOf(user);
        assets = shares == 0 ? 0 : Math.mulDiv(shares, a.assets, a.shares);
        PendingWithdrawal memory p = pending[user];
        return (shares, assets, unlockAt[user], p.shares, p.readyAt);
    }

    /// @notice What `withdraw` would pay `user` right now: the value of their pending shares once the cooldown
    ///         has passed, or 0 (nothing pending, still cooling down, or not enough free bankroll yet).
    function maxWithdrawable(address user) external view returns (uint256) {
        PendingWithdrawal memory p = pending[user];
        if (p.shares == 0 || block.timestamp < p.readyAt) return 0;
        Accrual memory a = _accrue();
        uint256 assets = Math.mulDiv(p.shares, a.assets, a.shares);
        return assets <= _freeBankroll() ? assets : 0;
    }

    function stats()
        external
        view
        returns (
            uint256 assets,
            uint256 depositorShares,
            uint256 polShares,
            uint256 pricePerShare,
            uint256 highWaterMark,
            uint256 protocolOwnedAssets,
            uint256 depositorAssets
        )
    {
        Accrual memory a = _accrue();
        depositorShares = totalSupply();
        if (a.shares != 0) {
            protocolOwnedAssets = Math.mulDiv(a.protocolShares, a.assets, a.shares);
            depositorAssets = Math.mulDiv(depositorShares, a.assets, a.shares);
        }
        return
            (a.assets, depositorShares, a.protocolShares, a.pps, a.hwm, protocolOwnedAssets, depositorAssets);
    }

    /// @notice $FLIPPER that can leave the bankroll now: the house's `withdrawable()` — never the pending flips'
    ///         reserved liabilities, nor so much that what stays falls under their `maxReservedBps` cap. What
    ///         `maxWithdrawable` and `InsufficientFreeBankroll` report.
    function freeBankroll() external view returns (uint256) {
        return _freeBankroll();
    }

    function _freeBankroll() internal view returns (uint256) {
        (bool ok, bytes memory r) = address(house).staticcall(abi.encodeWithSignature("withdrawable()"));
        if (ok && r.length == 32) return abi.decode(r, (uint256));
        return house.treasury() - house.reserved(); // a house without the reserve rule
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Non-transferable receipt
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function transfer(address, uint256) public pure override returns (bool) {
        revert NonTransferable();
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert NonTransferable();
    }

    function approve(address, uint256) public pure override returns (bool) {
        revert NonTransferable();
    }
}
