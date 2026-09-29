// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title HolderRewards
/// @notice Pays the launchpad token (HKT on Ink) to $FLIPPER holders, pro rata to their time-weighted average
///         balance (TWAB) over each epoch. Protocol contracts are reward-exempt.
///
///   Why roots: $FLIPPER is a plain hookit launch token (no checkpoints or transfer hooks), so holder balances over
///   time can only be reconstructed from its Transfer log. A keeper recomputes every epoch deterministically from
///   public data (scripts/keeper → rewards snapshotter) and posts a Merkle root of (account, amount); anyone can
///   recompute and check it. A root only becomes claimable after `challengeDelay`, during which the guardian can
///   veto it, and it can never allocate more than the epoch's pot.
///
///   Reward exemptions: `rewardExempt` is the on-chain source of truth the snapshotter must honour — the house vault
///   (bankroll), the revenue router, the rewards contracts, the Uniswap v4 PoolManager (pool liquidity), hookit fee
///   escrow / vaults, and burn addresses. Exempt balances are removed from both the numerator and the
///   denominator, so they neither earn nor dilute.
///
///   Leaves use OpenZeppelin's standard double-hashed encoding: keccak256(bytes.concat(keccak256(abi.encode(
///   account, amount)))), compatible with the OpenZeppelin merkle-tree JS library.
///
///   Deployed behind a TransparentUpgradeableProxy; storage is append-only.
contract HolderRewards is Ownable2StepUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct Epoch {
        uint128 pot; // reward tokens deposited during the epoch
        uint128 claimed;
        bytes32 root;
        uint128 allocated; // sum of leaf amounts declared by the poster (<= pot)
        uint64 postedAt;
        bool vetoed;
    }

    IERC20 public rewardToken;
    IERC20 public holdingToken; // $FLIPPER
    uint256 public genesis;
    uint256 public epochLength;
    uint256 public challengeDelay;
    address public rootPoster;
    address public guardian;

    mapping(uint256 epoch => Epoch) public epochs;
    mapping(uint256 epoch => mapping(address => bool)) public claimed;
    mapping(address => bool) public rewardExempt;
    address[] internal _rewardExempt;

    event RewardNotified(uint256 indexed epoch, address indexed from, uint256 amount);
    event RootPosted(uint256 indexed epoch, bytes32 root, uint256 allocated);
    event RootVetoed(uint256 indexed epoch);
    event Claimed(uint256 indexed epoch, address indexed account, uint256 amount);
    event RolledOver(uint256 indexed fromEpoch, uint256 indexed toEpoch, uint256 amount);
    event RewardExemptSet(address indexed account, bool exempt);
    event RolesUpdated(address rootPoster, address guardian, uint256 challengeDelay);

    error Unauthorized();
    error EpochNotOver();
    error RootExists();
    error OverAllocated();
    error NotClaimable();
    error AlreadyClaimed();
    error InvalidProof();
    error FeeOnTransfer();
    error NothingToRoll();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IERC20 _rewardToken,
        IERC20 _holdingToken,
        uint256 _epochLength,
        uint256 _challengeDelay,
        address _rootPoster,
        address _owner
    ) external initializer {
        require(address(_rewardToken) != address(0) && _epochLength >= 10 minutes, "config");
        __Ownable_init(_owner);
        rewardToken = _rewardToken;
        holdingToken = _holdingToken;
        epochLength = _epochLength;
        challengeDelay = _challengeDelay;
        rootPoster = _rootPoster;
        guardian = _owner;
        genesis = block.timestamp;
        _setRewardExempt(address(0), true);
        _setRewardExempt(0x000000000000000000000000000000000000dEaD, true);
        _setRewardExempt(address(this), true);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Epochs
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - genesis) / epochLength;
    }

    function epochStart(uint256 epoch) public view returns (uint256) {
        return genesis + epoch * epochLength;
    }

    function epochEnd(uint256 epoch) public view returns (uint256) {
        return genesis + (epoch + 1) * epochLength;
    }

    /// @notice Deposit rewards into the current epoch's pot (anyone; the RevenueRouter in practice).
    function notifyReward(uint256 amount) external nonReentrant {
        uint256 before = rewardToken.balanceOf(address(this));
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        if (rewardToken.balanceOf(address(this)) - before != amount) revert FeeOnTransfer();
        uint256 e = currentEpoch();
        epochs[e].pot += uint128(amount);
        emit RewardNotified(e, msg.sender, amount);
    }

    /// @notice Post the distribution root of a finished epoch. `allocated` must not exceed the pot; any
    ///         remainder (rounding, exempt balances) can be rolled forward once the root is final.
    function postRoot(uint256 epoch, bytes32 root, uint256 allocated) external {
        if (msg.sender != rootPoster && msg.sender != owner()) revert Unauthorized();
        if (epoch >= currentEpoch()) revert EpochNotOver();
        Epoch storage ep = epochs[epoch];
        if (ep.root != bytes32(0) && !ep.vetoed) revert RootExists();
        if (allocated > ep.pot) revert OverAllocated();
        ep.root = root;
        ep.allocated = uint128(allocated);
        ep.postedAt = uint64(block.timestamp);
        ep.vetoed = false;
        emit RootPosted(epoch, root, allocated);
    }

    /// @notice Guardian veto during the challenge window; the poster may then post a corrected root.
    function vetoRoot(uint256 epoch) external {
        if (msg.sender != guardian && msg.sender != owner()) revert Unauthorized();
        Epoch storage ep = epochs[epoch];
        if (ep.root == bytes32(0) || isClaimable(epoch)) revert NotClaimable();
        ep.vetoed = true;
        emit RootVetoed(epoch);
    }

    function isClaimable(uint256 epoch) public view returns (bool) {
        Epoch storage ep = epochs[epoch];
        return ep.root != bytes32(0) && !ep.vetoed && block.timestamp >= uint256(ep.postedAt) + challengeDelay;
    }

    function claim(uint256 epoch, uint256 amount, bytes32[] calldata proof) public nonReentrant {
        _claim(epoch, msg.sender, amount, proof);
        rewardToken.safeTransfer(msg.sender, amount);
    }

    function claimMany(uint256[] calldata epochList, uint256[] calldata amounts, bytes32[][] calldata proofs)
        external
        nonReentrant
        returns (uint256 total)
    {
        for (uint256 i; i < epochList.length; ++i) {
            _claim(epochList[i], msg.sender, amounts[i], proofs[i]);
            total += amounts[i];
        }
        if (total != 0) rewardToken.safeTransfer(msg.sender, total);
    }

    function _claim(uint256 epoch, address account, uint256 amount, bytes32[] calldata proof) internal {
        if (!isClaimable(epoch)) revert NotClaimable();
        if (claimed[epoch][account]) revert AlreadyClaimed();
        Epoch storage ep = epochs[epoch];
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
        if (!MerkleProof.verifyCalldata(proof, ep.root, leaf)) revert InvalidProof();
        claimed[epoch][account] = true;
        ep.claimed += uint128(amount);
        if (ep.claimed > ep.allocated) revert OverAllocated();
        emit Claimed(epoch, account, amount);
    }

    /// @notice Roll a finished epoch's unallocated remainder (or a whole epoch that had no eligible holders)
    ///         into the current epoch. Allocated-but-unclaimed rewards stay claimable forever.
    function rollover(uint256 epoch) external {
        uint256 e = currentEpoch();
        if (epoch >= e) revert EpochNotOver();
        Epoch storage ep = epochs[epoch];
        if (ep.root != bytes32(0) && !isClaimable(epoch)) revert NotClaimable();
        uint256 amount = ep.pot - ep.allocated;
        if (amount == 0) revert NothingToRoll();
        ep.pot = ep.allocated;
        epochs[e].pot += uint128(amount);
        emit RolledOver(epoch, e, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Reward exemptions / admin
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function setRewardExempt(address[] calldata accounts, bool exempt) external onlyOwner {
        for (uint256 i; i < accounts.length; ++i) {
            _setRewardExempt(accounts[i], exempt);
        }
    }

    function rewardExemptList() external view returns (address[] memory) {
        return _rewardExempt;
    }

    function setRoles(address _rootPoster, address _guardian, uint256 _challengeDelay) external onlyOwner {
        rootPoster = _rootPoster;
        guardian = _guardian;
        challengeDelay = _challengeDelay;
        emit RolesUpdated(_rootPoster, _guardian, _challengeDelay);
    }

    function _setRewardExempt(address account, bool exempt) internal {
        if (rewardExempt[account] == exempt) return;
        rewardExempt[account] = exempt;
        if (exempt) {
            _rewardExempt.push(account);
        } else {
            for (uint256 i; i < _rewardExempt.length; ++i) {
                if (_rewardExempt[i] == account) {
                    _rewardExempt[i] = _rewardExempt[_rewardExempt.length - 1];
                    _rewardExempt.pop();
                    break;
                }
            }
        }
        emit RewardExemptSet(account, exempt);
    }
}
