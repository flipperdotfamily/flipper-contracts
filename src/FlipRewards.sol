// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IFlipRewards} from "./interfaces/IFlipRewards.sol";

/// @title FlipRewards
/// @notice Distributes the launchpad token (e.g. $HOOKIT) to flippers, pro rata to settled flip volume.
///
///         Time is cut into fixed epochs. The house records each settled flip's volume (valued in $FLIPPER at
///         settlement, so it can't be flash-inflated) against the current epoch; every reward deposited during
///         an epoch belongs to that epoch's flippers. Once an epoch ends its share is fixed and claimable forever.
///         Epochs that saw deposits but no volume can be rolled forward by anyone.
///
///         Wash-flipping to farm rewards is strictly unprofitable: rewards are funded by a slice of the house
///         edge, so every unit of volume costs the flipper more in expected losses than it earns back.
///
///         Deployed behind a TransparentUpgradeableProxy; storage is append-only.
contract FlipRewards is IFlipRewards, Ownable2StepUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IERC20 public rewardToken;
    uint256 public genesis;
    uint256 public epochLength;

    mapping(address => bool) public isRecorder;
    mapping(uint256 epoch => uint256) public epochRewards;
    mapping(uint256 epoch => uint256) public epochPoints;
    mapping(uint256 epoch => mapping(address => uint256)) public userPoints;
    mapping(uint256 epoch => mapping(address => bool)) public claimed;

    event RecorderUpdated(address recorder, bool allowed);
    event VolumeRecorded(uint256 indexed epoch, address indexed player, uint256 points);
    event RewardNotified(uint256 indexed epoch, address indexed from, uint256 amount);
    event RewardClaimed(uint256 indexed epoch, address indexed player, uint256 amount);
    event RolledOver(uint256 indexed fromEpoch, uint256 indexed toEpoch, uint256 amount);

    error NotRecorder();
    error EpochNotOver();
    error EpochHasVolume();
    error FeeOnTransfer();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20 _rewardToken, uint256 _epochLength, address _owner) external initializer {
        require(address(_rewardToken) != address(0) && _epochLength >= 1 hours, "config");
        __Ownable_init(_owner);
        rewardToken = _rewardToken;
        epochLength = _epochLength;
        genesis = block.timestamp;
    }

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - genesis) / epochLength;
    }

    function epochEnd(uint256 epoch) external view returns (uint256) {
        return genesis + (epoch + 1) * epochLength;
    }

    function setRecorder(address recorder, bool allowed) external onlyOwner {
        isRecorder[recorder] = allowed;
        emit RecorderUpdated(recorder, allowed);
    }

    /// @inheritdoc IFlipRewards
    function recordVolume(address player, uint256 points) external {
        if (!isRecorder[msg.sender]) revert NotRecorder();
        uint256 e = currentEpoch();
        userPoints[e][player] += points;
        epochPoints[e] += points;
        emit VolumeRecorded(e, player, points);
    }

    /// @notice Deposit rewards for the current epoch (anyone may top up).
    function notifyReward(uint256 amount) external nonReentrant {
        uint256 before = rewardToken.balanceOf(address(this));
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        if (rewardToken.balanceOf(address(this)) - before != amount) revert FeeOnTransfer();
        uint256 e = currentEpoch();
        epochRewards[e] += amount;
        emit RewardNotified(e, msg.sender, amount);
    }

    /// @notice Move the rewards of a finished epoch with zero volume into the current epoch.
    function rollover(uint256 epoch) external {
        uint256 e = currentEpoch();
        if (epoch >= e) revert EpochNotOver();
        if (epochPoints[epoch] != 0) revert EpochHasVolume();
        uint256 amount = epochRewards[epoch];
        epochRewards[epoch] = 0;
        epochRewards[e] += amount;
        emit RolledOver(epoch, e, amount);
    }

    function claimableFor(address player, uint256 epoch) public view returns (uint256) {
        if (epoch >= currentEpoch() || claimed[epoch][player]) return 0;
        uint256 total = epochPoints[epoch];
        if (total == 0) return 0;
        return epochRewards[epoch] * userPoints[epoch][player] / total;
    }

    /// @notice Claim finished epochs. Unfinished, already-claimed or empty epochs are skipped.
    function claim(uint256[] calldata epochs) external nonReentrant returns (uint256 total) {
        for (uint256 i; i < epochs.length; ++i) {
            uint256 e = epochs[i];
            uint256 amount = claimableFor(msg.sender, e);
            if (amount == 0) continue;
            claimed[e][msg.sender] = true;
            total += amount;
            emit RewardClaimed(e, msg.sender, amount);
        }
        if (total != 0) rewardToken.safeTransfer(msg.sender, total);
    }
}
