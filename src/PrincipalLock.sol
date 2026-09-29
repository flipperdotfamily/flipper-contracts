// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice The TreasuryVault as the lock uses it.
interface IStakingVault {
    function flipper() external view returns (IERC20);
    function deposit(uint256 assets, uint256 minShares) external returns (uint256 shares);
    function requestWithdraw(uint256 shares) external;
    function cancelWithdraw() external;
    function withdraw(uint256 minAssets) external returns (uint256 assets);
    function claimRewards() external returns (uint256 amount);
    function balanceOf(address user) external view returns (uint256);
    function pending(address user) external view returns (uint256 shares, uint256 readyAt);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function pendingRewards(address user) external view returns (uint256);
    function freeBankroll() external view returns (uint256);
}

/// @notice The reward-bearing $FLIPPER's claim side (absent on a plain token).
interface IHolderRewards {
    function claim() external returns (uint256);
    function claimable(address account) external view returns (uint256);
}

/// @title PrincipalLock
/// @notice Stakes $FLIPPER in the TreasuryVault once, for good: the principal can never come out, only what it earns
///         on top, and that only ever goes to `devAddress`. Not upgradeable, and no admin withdrawal: the owner can only
///         choose which address `devAddress` is.
///
///   - Its creator stakes once (`stake(amount)`); that amount is the principal P.
///   - `devAddress` (the dev claim wallet: an everyday key, so the owner's cold key isn't needed to claim) may take out
///     only the excess, value − P: the stake's share of treasury gains after the vault's performance fee, through the
///     vault's own request → cooldown → withdraw flow. A request must be worth no more than the excess when made; a
///     withdrawal that would leave the position worth less than P (the price fell during the cooldown) reverts: cancel
///     it and request less. Under water, nothing is withdrawable. Only `devAddress` can request or withdraw, so nobody
///     else can force the bankroll to shrink.
///   - The owner (Ownable2Step, a cold key) may point `devAddress` at another wallet at any time (`setDevAddress`); a
///     withdrawal already queued is then paid to the new address. Ownership can be handed over but never renounced,
///     so `devAddress` can always be replaced.
///   - Rewards: holder rewards on staked $FLIPPER accrue to the vault's virtual balance on the token and reach the
///     lock through the vault's pass-through (`vault.claimRewards`, the "vault rewards"); the token itself also
///     accrues holder rewards on the lock's own wallet balance (in practice ~0: the lock holds no $FLIPPER between
///     transactions). `sweepVaultRewards`, `sweepHolderRewards` and `sweepRewards` claim them and pay `devAddress`;
///     anyone may call them. Every request and withdrawal sweeps both as well.
///   - While the house's drawdown breaker is tripped, the vault and the token refuse (`ProtocolLocked`), and so does
///     every call here: requests, withdrawals and sweeps all revert.
///
///   If the claim wallet's key is lost or compromised, the owner replaces it; either way only the excess and rewards
///   were ever exposed, never the principal. If the owner's key is compromised, the same holds: it can redirect
///   earnings, not the principal.
///   Trust boundary: the lock is exactly as strong as the vault. The TreasuryVault is upgradeable; an upgrade by its
///   proxy admin could change what the lock's shares are worth or how they exit. Put the vault's proxy admin behind a
///   timelock or multisig.
contract PrincipalLock is Ownable2Step {
    using SafeERC20 for IERC20;

    /// @dev gas a holder-reward claim must be able to get (its failure without data means "no such function")
    uint256 internal constant CLAIM_GAS = 150_000;

    IStakingVault public immutable vault;
    IERC20 public immutable flipper;
    address internal immutable creator;
    /// @notice the only address earnings are ever paid to, and the only one that may request or withdraw them (the
    ///         owner can change it)
    address public devAddress;

    /// @notice $FLIPPER staked through this lock, never withdrawable (set once by `stake`)
    uint256 public principal;

    event Staked(uint256 amount, uint256 shares);
    event ExcessRequested(uint256 shares, uint256 value);
    event ExcessCancelled();
    event ExcessWithdrawn(uint256 amount);
    event RewardsSwept(uint256 vaultRewards, uint256 holderRewards);
    event DevAddressSet(address indexed previous, address indexed devAddress);

    error Unauthorized();
    error AlreadyStaked();
    error ExceedsExcess(uint256 value, uint256 excess);
    error PrincipalBreach(uint256 value, uint256 principal);
    error InvalidAddress();
    error InsufficientGas();

    modifier onlyDev() {
        if (msg.sender != devAddress) revert Unauthorized();
        _;
    }

    /// @param _owner may change `devAddress` (a cold key; Ownable2Step)
    constructor(IStakingVault _vault, address _devAddress, address _owner) Ownable(_owner) {
        if (address(_vault) == address(0) || _devAddress == address(0)) revert InvalidAddress();
        vault = _vault;
        flipper = _vault.flipper();
        devAddress = _devAddress;
        creator = msg.sender;
        emit DevAddressSet(address(0), _devAddress);
    }

    // ── owner ────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Owner: pay earnings to, and let request and withdraw, `next` from now on (a queued withdrawal included).
    function setDevAddress(address next) external onlyOwner {
        if (next == address(0)) revert InvalidAddress();
        emit DevAddressSet(devAddress, next);
        devAddress = next;
    }

    /// @notice Disabled: without an owner the claim wallet could never be replaced.
    function renounceOwnership() public pure override {
        revert Unauthorized();
    }

    /// @notice One time, by the creator: pull `amount` $FLIPPER from the caller and stake it; it is the principal.
    function stake(uint256 amount) external returns (uint256 shares) {
        if (msg.sender != creator) revert Unauthorized();
        if (principal != 0) revert AlreadyStaked();
        flipper.safeTransferFrom(msg.sender, address(this), amount);
        flipper.forceApprove(address(vault), amount);
        shares = vault.deposit(amount, 1);
        principal = amount;
        emit Staked(amount, shares);
    }

    // ── earnings (devAddress only) ───────────────────────────────────────────────────────────────────────

    /// @notice Queue `amount` $FLIPPER of the excess for withdrawal (type(uint256).max: all of it not yet queued).
    ///         Everything queued must be worth no more than the excess now. Sweeps the rewards too.
    function requestExcess(uint256 amount) external onlyDev {
        (uint256 queued,) = vault.pending(address(this));
        uint256 excess = withdrawableExcess();
        if (amount == type(uint256).max) {
            uint256 q = vault.previewRedeem(queued);
            amount = excess > q ? excess - q : 0;
        }
        uint256 shares = vault.previewDeposit(amount);
        uint256 v = vault.previewRedeem(queued + shares);
        if (v > excess) revert ExceedsExcess(v, excess);
        vault.requestWithdraw(shares);
        emit ExcessRequested(shares, v);
        _sweep();
    }

    function cancelExcess() external onlyDev {
        vault.cancelWithdraw();
        emit ExcessCancelled();
    }

    /// @notice Withdraw the queued excess once the vault's cooldown has passed, sweep both reward sources, and pay
    ///         it all to `devAddress`. Reverts if what stays staked would be worth less than the principal.
    function withdrawExcess() external onlyDev returns (uint256 assets) {
        assets = vault.withdraw(0);
        uint256 v = value();
        if (v < principal) revert PrincipalBreach(v, principal);
        emit ExcessWithdrawn(assets);
        _sweep();
    }

    // ── rewards (anyone; always paid to devAddress) ──────────────────────────────────────────────────────

    /// @notice Claim both reward sources and pay them (and any other $FLIPPER in the lock) to `devAddress`.
    function sweepRewards() external returns (uint256 vaultRewards, uint256 holderRewards) {
        return _sweep();
    }

    /// @notice Claim the holder rewards the lock's vault shares earned (the vault's pass-through).
    function sweepVaultRewards() external returns (uint256 amount) {
        amount = vault.claimRewards();
        emit RewardsSwept(amount, 0);
        _payOut();
    }

    /// @notice Claim the holder rewards the token credited to the lock's own wallet balance.
    function sweepHolderRewards() external returns (uint256 amount) {
        amount = _claimHolder();
        emit RewardsSwept(0, amount);
        _payOut();
    }

    function _sweep() internal returns (uint256 vaultRewards, uint256 holderRewards) {
        vaultRewards = vault.claimRewards();
        holderRewards = _claimHolder();
        emit RewardsSwept(vaultRewards, holderRewards);
        _payOut();
    }

    /// @dev the token's `claim()`; 0 on a plain token (no such function: an empty revert), bubbled otherwise
    function _claimHolder() internal returns (uint256 amount) {
        if (gasleft() < CLAIM_GAS) revert InsufficientGas();
        try IHolderRewards(address(flipper)).claim() returns (uint256 a) {
            amount = a;
        } catch (bytes memory reason) {
            if (reason.length != 0) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }
    }

    /// @dev everything the lock holds in its wallet is earnings (the principal is always in the vault)
    function _payOut() internal {
        uint256 bal = flipper.balanceOf(address(this));
        if (bal != 0) flipper.safeTransfer(devAddress, bal);
    }

    // ── views ────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice What the lock's vault shares (queued ones included) are worth now, in $FLIPPER.
    function value() public view returns (uint256) {
        return vault.previewRedeem(vault.balanceOf(address(this)));
    }

    /// @notice What may be taken out now: max(0, value − principal), queued shares included, but no more than can
    ///         leave the bankroll now (`vault.freeBankroll()`: pending flips' reserves and their cap stay).
    function withdrawableExcess() public view returns (uint256) {
        uint256 excess = _excess();
        uint256 free = vault.freeBankroll();
        return excess < free ? excess : free;
    }

    /// @dev max(0, value − principal)
    function _excess() internal view returns (uint256) {
        uint256 v = value();
        uint256 p = principal;
        return v > p ? v - p : 0;
    }

    /// @notice The queued withdrawal: its shares, their $FLIPPER value now and when it can be withdrawn.
    function pendingWithdrawal() external view returns (uint256 shares, uint256 assets, uint256 readyAt) {
        (shares, readyAt) = vault.pending(address(this));
        assets = vault.previewRedeem(shares);
    }

    /// @notice Holder rewards claimable through the vault now.
    function pendingVaultRewards() external view returns (uint256) {
        return vault.pendingRewards(address(this));
    }

    /// @notice Holder rewards the token credits to the lock's own wallet balance (0 on a plain token).
    function pendingHolderRewards() external view returns (uint256) {
        (bool ok, bytes memory r) =
            address(flipper).staticcall(abi.encodeCall(IHolderRewards.claimable, (address(this))));
        return ok && r.length == 32 ? abi.decode(r, (uint256)) : 0;
    }
}
