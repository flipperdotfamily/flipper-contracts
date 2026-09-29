// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The staking vault as the token sees it: its depositors' claim on the bankroll, in $FLIPPER, net of the
///         not-yet-crystallised performance fee (protocol-owned shares excluded).
interface IRewardVault {
    function depositorAssets() external view returns (uint256);
}

/// @title FlipperRewardToken
/// @notice $FLIPPER with holder rewards built in. Every eligible balance earns the $FLIPPER streamed in through
///         `distribute`, pro rata to balance × time. There is no staking, no snapshot, no keeper and no owner.
///
///   Accounting (exact; constant gas per transfer). A global reward-per-token accumulator (`rewardPerToken`,
///   magnified by 2^96) and a signed correction per account make an account's lifetime earnings
///   `rewardPerToken × eligibleBalance + correction`, whatever its balance history. A transfer moves
///   `rewardPerToken × value` of correction along with the tokens, so accrued rewards never move: transfers,
///   self-transfers and churn create nothing, and a balance held for an instant earns an instant's worth. Flash
///   loans and snapshot sniping earn ~0.
///
///   Streaming. `distribute(amount)` (anyone; pulls from the caller) adds `amount` to the stream without ever slowing
///   it: the rate becomes the larger of the current rate and (everything not yet streamed) / `STREAM` (7 days), and
///   the stream runs until it is all paid. A small amount therefore just extends the end at the current rate; a large
///   one speeds the stream up and ends it 7 days out. `distribute(0)` only checkpoints and syncs the vault. So nobody
///   can stretch rewards already on their way (re-spreading them over a fresh 7 days on every call would). Rewards
///   sit in this contract's own balance (the reserve) until claimed with `claim()`. Pull only: nothing is ever pushed
///   into balances, so a third-party contract (an AMM pair, a lending market) never sees its balance change behind
///   its back.
///
///   Eligibility. Every address earns holder rewards except a fixed set (`rewardExempt`): this contract (the reserve),
///   the dead address and the PoolManager (v4 liquidity earns swap fees instead), fixed in the constructor, plus the
///   protocol contracts (house, router, converter) named once by the deployer in `seal` before the first distribution.
///   After that the set can never change. Reward exemption only concerns holder rewards: transfers carry no fee, tax,
///   reflection or restriction for anyone. The staking vault earns on a virtual balance, its depositors' assets in the bankroll,
///   synced by `syncVault()` (anyone; the vault calls it on every deposit, withdrawal, request, crystallisation
///   and claim, and `distribute` does too). Its real balance (claimed rewards held for stakers) earns nothing.
///
///   Rewards accrued by an address that never calls `claim` (a contract that can't) stay in the reserve forever:
///   never re-streamed and never double counted, like a burn.
contract FlipperRewardToken is ERC20, ERC20Burnable {
    using SafeCast for uint256;

    uint256 internal constant MAGNITUDE = 2 ** 96;
    /// below this much eligible supply, streamed rewards wait (`carry`) instead of inflating the accumulator
    uint256 internal constant MIN_ELIGIBLE = 1e18;
    uint256 public constant STREAM = 7 days;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice the one-time sealer (the deployer); cleared by `seal`
    address public sealer;
    /// @notice the staking vault (virtual balance); set once by `seal`
    IRewardVault public vault;
    /// @notice the house: while its drawdown circuit breaker is tripped, reward `claim` and `distribute` wait (token
    ///         transfers are never affected); set once by `seal`
    address public rewardsBreaker;

    /// @notice accounts that don't earn holder rewards (the reserve, the pool's liquidity, protocol contracts); fixed
    ///         once `seal` has run. It has no effect on transfers.
    mapping(address => bool) public rewardExempt;
    /// @notice sum of eligible balances, the vault's virtual balance included
    uint256 public eligibleSupply;
    /// @notice the vault's virtual eligible balance as of the last sync
    uint256 public vaultBalance;

    uint256 internal _rpt;
    mapping(address => int256) internal _corrections;
    /// @notice rewards each account has claimed
    mapping(address => uint256) public claimed;

    /// @notice current stream rate, magnified (× 2^96) $FLIPPER per second
    uint256 public rewardRate;
    uint64 public periodFinish;
    uint64 public lastUpdate;
    /// @notice streamed while (almost) nothing was eligible: joins the next distribution
    uint256 public carry;
    uint256 public totalDistributed;
    uint256 public totalClaimed;

    event Distributed(address indexed from, uint256 amount, uint256 streaming, uint256 periodFinish);
    event Claimed(address indexed account, uint256 amount);
    event Sealed(address vault, address[] rewardExempt);
    event VaultSynced(uint256 balance);

    error NotSealer();
    error ProtocolLocked();
    error AlreadyDistributed();

    /// @param to receives the whole fixed supply
    /// @param poolManager the Uniswap v4 PoolManager (its balance is pool liquidity: never eligible)
    constructor(string memory name_, string memory symbol_, uint256 supply, address to, address poolManager)
        ERC20(name_, symbol_)
    {
        sealer = msg.sender;
        rewardExempt[address(this)] = true;
        rewardExempt[DEAD] = true;
        rewardExempt[poolManager] = true;
        _mint(to, supply);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Rewards
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Add `amount` $FLIPPER, pulled from the caller, to the stream (anyone). The stream never slows: its rate
    ///         becomes max(current rate, everything unstreamed / 7 days) and it runs until all of it is paid, so the end
    ///         moves at most 7 days out. `distribute(0)` only checkpoints and syncs the vault.
    function distribute(uint256 amount) external {
        _whenBreakerClear();
        _syncVault();
        _checkpoint();
        if (amount == 0) return;
        _transfer(msg.sender, address(this), amount);
        uint256 total = amount + _unstreamed() + carry;
        carry = 0;
        // the current rate if still streaming; the new stream must never pay out slower than it
        uint256 r = block.timestamp < periodFinish ? rewardRate : 0;
        uint256 duration = r == 0 ? STREAM : Math.min(STREAM, total * MAGNITUDE / r);
        if (duration == 0) duration = 1;
        rewardRate = total * MAGNITUDE / duration; // ≥ r: rounding never pays out more than `total`
        uint256 finish = block.timestamp + duration;
        periodFinish = uint64(finish);
        lastUpdate = uint64(block.timestamp);
        totalDistributed += amount;
        emit Distributed(msg.sender, amount, total, finish);
    }

    /// @notice Pay the caller's accrued rewards.
    function claim() external returns (uint256 amount) {
        _whenBreakerClear();
        amount = claimable(msg.sender);
        if (amount == 0) return 0;
        claimed[msg.sender] += amount;
        totalClaimed += amount;
        _transfer(address(this), msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// @notice Re-read the vault's depositor assets as its eligible balance (anyone may call).
    function syncVault() external {
        _syncVault();
    }

    /// @notice Rewards `account` can claim now.
    function claimable(address account) public view returns (uint256) {
        uint256 a = accrued(account);
        uint256 c = claimed[account];
        return a > c ? a - c : 0;
    }

    /// @notice Everything `account` has earned so far, claimed included.
    function accrued(address account) public view returns (uint256) {
        int256 a = (rewardPerToken() * eligibleBalanceOf(account)).toInt256() + _corrections[account];
        return a > 0 ? uint256(a) / MAGNITUDE : 0;
    }

    /// @notice The reward-per-token accumulator (× 2^96), streamed up to now.
    function rewardPerToken() public view returns (uint256 rpt) {
        (rpt,) = _current();
    }

    /// @notice The balance `account` earns on: its balance, 0 if reward-exempt, the synced virtual balance for the vault.
    function eligibleBalanceOf(address account) public view returns (uint256) {
        if (account == address(vault) && account != address(0)) return vaultBalance;
        return rewardExempt[account] ? 0 : balanceOf(account);
    }

    /// @notice $FLIPPER of the current distribution still to stream.
    function pendingStream() external view returns (uint256) {
        return _unstreamed();
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Reward exemptions (fixed after `seal`)
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice One time, before any distribution: exempt the protocol's contracts from holder rewards, name the
    ///         staking vault and the house whose drawdown breaker holds reward claims back.
    function seal(address[] calldata exempt, IRewardVault v, address house) external {
        if (msg.sender != sealer) revert NotSealer();
        if (totalDistributed != 0) revert AlreadyDistributed();
        sealer = address(0);
        for (uint256 i; i < exempt.length; ++i) {
            _exempt(exempt[i]);
        }
        if (address(v) != address(0)) {
            _exempt(address(v)); // its real balance never earns
            vault = v;
        }
        rewardsBreaker = house;
        emit Sealed(address(v), exempt);
        _syncVault();
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function _whenBreakerClear() internal view {
        address h = rewardsBreaker;
        if (h == address(0)) return;
        (bool ok, bytes memory r) = h.staticcall(abi.encodeWithSignature("locked()"));
        if (ok && r.length == 32 && abi.decode(r, (bool))) revert ProtocolLocked();
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        bool fromEligible = from != address(0) && !rewardExempt[from];
        bool toEligible = to != address(0) && !rewardExempt[to];
        if (!fromEligible && !toEligible) return;
        uint256 rpt;
        if (fromEligible != toEligible) {
            // the eligible supply changes: settle the stream at the old supply first
            _checkpoint();
            rpt = _rpt;
            if (toEligible) eligibleSupply += value;
            else eligibleSupply -= value;
        } else {
            (rpt,) = _current();
        }
        int256 c = (rpt * value).toInt256();
        if (fromEligible) _corrections[from] += c;
        if (toEligible) _corrections[to] -= c;
    }

    function _exempt(address a) internal {
        if (rewardExempt[a]) return;
        _checkpoint();
        uint256 bal = balanceOf(a);
        if (bal != 0) {
            _corrections[a] += (_rpt * bal).toInt256(); // what it earned so far stays claimable
            eligibleSupply -= bal;
        }
        rewardExempt[a] = true;
    }

    function _syncVault() internal {
        IRewardVault v = vault;
        if (address(v) == address(0)) return;
        uint256 nb = v.depositorAssets();
        uint256 ob = vaultBalance;
        if (nb == ob) return;
        _checkpoint();
        int256 c = (_rpt * (nb > ob ? nb - ob : ob - nb)).toInt256();
        if (nb > ob) {
            _corrections[address(v)] -= c;
            eligibleSupply += nb - ob;
        } else {
            _corrections[address(v)] += c;
            eligibleSupply -= ob - nb;
        }
        vaultBalance = nb;
        emit VaultSynced(nb);
    }

    /// @dev fold the stream into the accumulator up to now
    function _checkpoint() internal {
        (uint256 rpt, uint256 waiting) = _current();
        _rpt = rpt;
        if (waiting != 0) carry += waiting;
        uint256 finish = periodFinish;
        uint256 t = block.timestamp < finish ? block.timestamp : finish;
        if (t > lastUpdate) lastUpdate = uint64(t);
    }

    /// @return rpt the accumulator streamed up to now
    /// @return waiting $FLIPPER streamed since the last checkpoint while (almost) nothing was eligible
    function _current() internal view returns (uint256 rpt, uint256 waiting) {
        rpt = _rpt;
        uint256 finish = periodFinish;
        uint256 t = block.timestamp < finish ? block.timestamp : finish;
        uint256 last = lastUpdate;
        if (t <= last) return (rpt, 0);
        uint256 streamed = (t - last) * rewardRate; // magnified
        uint256 supply = eligibleSupply;
        if (supply < MIN_ELIGIBLE) return (rpt, streamed / MAGNITUDE);
        rpt += streamed / supply;
    }

    function _unstreamed() internal view returns (uint256) {
        uint256 finish = periodFinish;
        return block.timestamp < finish ? (finish - block.timestamp) * rewardRate / MAGNITUDE : 0;
    }
}
