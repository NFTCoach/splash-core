// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "oz-contracts/access/Ownable.sol";
import "oz-contracts/token/ERC20/ERC20.sol";

// Floating number library
import "../utils/ABDKMath64x64.sol";

import "../interfaces/IRegistry.sol";

enum StakeStatus { NONE, ENTERED, EXITED }

struct PassRequirement {
  uint8 veteranCount;
  uint8 retiredCount;
  uint48 stakeTime;
  uint256 stakeAmount;
}

struct StakeInfo {
  StakeStatus status;
  Pass pass;
  uint48 stakeTime;
  uint48 enteredAt;
  uint48 exitedAt;
  uint48 lateClaimedAt;
  uint256 stakeAmount;
  uint256 lateClaimAmount;
  uint256 lastStakeReward;
  uint256 pendingStakeRewards;
  uint256[] veteranList;
  uint256[] retiredList;
}

/**
  @title  Staking
  @notice Synthetix-inspired staking and pass management
  @dev    Passes are used to enter tournaments w/o tickets
  @author Hamza Karabag
*/
contract Staking is Ownable {
  using ABDKMath64x64 for int128;
  using ABDKMath64x64 for uint256;

  IRegistry private registry;

  uint256 private _rewardPerToken;
  uint256 public rewardRate;
  uint256 public totalStaked;
  uint256 public lastUpdateTime;

  // Max Stake Rate: 1.4
  int128 public maxStakeRate = uint256(7).divu(5);
  // Max Time Rate: 2.2
  int128 public maxTimeRate = uint256(11).divu(5);

  event RewardChanged(uint256 newRewardRate);
  event MaxStakeRateChanged(int128 newStakeRate);
  event MaxTimeRateChanged(int128 newTimeRate);

  mapping(Pass => PassRequirement)  public passRequirements;
  mapping(address => StakeInfo)     public userToStakeInfo;

  constructor(
    IRegistry registryAddress, 
    uint256 initialRewardRate, 
    PassRequirement[] memory initialRequirements 
  ) {
    require(initialRequirements.length == 3, "Invalid number of requirements");
      
    registry = IRegistry(registryAddress);

    rewardRate = initialRewardRate;
    for (uint256 i = 0; i <= initialRequirements.length; i++) {
      passRequirements[Pass(i + 1)] = initialRequirements[i];
    }
  }

  // #################### SETTERS #################### //

  function setRewardRate(uint256 newRewardRate) external onlyOwner {
    rewardRate = newRewardRate;
    emit RewardChanged(newRewardRate);
  }

  function setMaxStakeRate(int128 newRate) external onlyOwner{
    maxStakeRate = newRate;
    emit MaxStakeRateChanged(newRate);
  }

  function setMaxTimeRate(int128 newRate) external onlyOwner {
    maxTimeRate = newRate;
    emit MaxStakeRateChanged(newRate);
  }

  // #################### COEFFICENT #################### //

  /**
    @notice Returns player's coefficient based on their staking stats
    @dev This is used in reward calculations in pass-only tournaments
    @return int128 ABDK64x64 coefficient
  */
  function getCoefficient(address user) external view returns(int128) {
    StakeInfo memory info = userToStakeInfo[user];

    if(info.status != StakeStatus.ENTERED)
      return 0;

    PassRequirement memory requirement = passRequirements[info.pass];
    
    int128 stakeRate = info.stakeAmount.divu(requirement.stakeAmount);
    int128 timeRate = uint256(info.stakeTime).divu(uint256(requirement.stakeTime));

    if(stakeRate > maxStakeRate)
      stakeRate = maxStakeRate;
    
    if(timeRate > maxTimeRate)
      timeRate = maxTimeRate;

    return stakeRate.mul(timeRate);
  }

  // #################### PASS #################### //

  function getPass(address user) external view returns(Pass) {
    return userToStakeInfo[user].pass;
  }

  // #################### STAKING #################### //

  /**
    @notice Returns new amount of rewards per each staked token
    @dev New reward per token is calculated as:
      RPT = Previous RPT + (totalReward / totalStake)
      where totalReward is elapsedTime * rewardRate
  */
  function rewardPerToken() public view returns(uint256) {
    if(totalStaked == 0)
      return 0;
    
    return _rewardPerToken +
      ((block.timestamp - lastUpdateTime) * rewardRate * 1e18) 
      / totalStaked; 
  }

  function pendingRewards(address account) public view returns(uint256) {
    StakeInfo memory info = userToStakeInfo[account];
    
    return info.pendingStakeRewards + 
      (info.stakeAmount * (rewardPerToken() - info.lastStakeReward)) / 1e18; 
  }

  function _updateRewards() private {
    _rewardPerToken = rewardPerToken();
    lastUpdateTime = block.timestamp;
    
    userToStakeInfo[msg.sender].pendingStakeRewards = pendingRewards(msg.sender);
    userToStakeInfo[msg.sender].lastStakeReward = _rewardPerToken;
  }

  function _approveSplash(address to, uint256 amount) private {
    require(registry.sp20().increaseAllowance(to, amount), "Token approve failed");
  } 

  function enterStake(
    Pass pass, 
    uint256 stakeAmount, 
    uint48 stakeTime,
    uint256[] memory veteranList,
    uint256[] memory retiredList
  ) external {
    _updateRewards();

    StakeInfo storage info = userToStakeInfo[msg.sender];
    require(info.status == StakeStatus.NONE, "Wrong status");

    PassRequirement memory requirement = passRequirements[pass];
    require(stakeAmount >= requirement.stakeAmount, "Invalid stake amount");
    require(stakeTime >= requirement.stakeTime, "Invalid stake time");

    // Register stake
    info.status = StakeStatus.ENTERED;
    info.pass = pass;
    info.stakeTime = stakeTime;
    info.stakeAmount = stakeAmount;
    info.veteranList = veteranList;
    info.retiredList = retiredList;
    info.enteredAt = uint48(block.timestamp);
  
    totalStaked += stakeAmount;

    IManagement management = registry.management();
    management.lockVeteranBatch(msg.sender, veteranList);
    management.lockRetiredBatch(msg.sender, retiredList);
  }

  function exitStake() external {
    _updateRewards();

    StakeInfo storage info = userToStakeInfo[msg.sender];
    require(info.status == StakeStatus.ENTERED, "Wrong status");

    uint256 pendingStakeRewards = info.pendingStakeRewards;
    
    // Approve all stake directly if exiting at right time
    if(block.timestamp >= (info.enteredAt + info.stakeTime)) {
      uint256 stakedAmount = info.stakeAmount;

      totalStaked -= stakedAmount;
      delete userToStakeInfo[msg.sender];

      _approveSplash(msg.sender, stakedAmount + pendingStakeRewards);
      return;
    }

    // Update stake info
    info.status = StakeStatus.EXITED;
    info.exitedAt = uint48(block.timestamp);
    info.lateClaimedAt = uint48(block.timestamp);
    info.lateClaimAmount = 0;
    info.pendingStakeRewards = 0;

    // Unlock staked players
    IManagement management = registry.management();
    management.unlockVeteranBatch(msg.sender, info.veteranList);
    management.unlockRetiredBatch(msg.sender, info.retiredList);

    // Approve stake rewards
    _approveSplash(msg.sender, pendingStakeRewards);
  }

  function lateClaimStake() external {
    _updateRewards();

    StakeInfo storage info = userToStakeInfo[msg.sender];
    require(info.status == StakeStatus.EXITED, "Wrong status");

    uint256 claimableAmount;
    uint256 releaseTime = uint256(info.enteredAt + info.stakeTime - info.exitedAt);
    uint256 waitedTime = uint256(block.timestamp - info.exitedAt);

    if(waitedTime >= releaseTime) {
      claimableAmount = info.stakeAmount - info.lateClaimAmount;
      
      delete userToStakeInfo[msg.sender];
    }
    else {
      claimableAmount = (info.stakeAmount * waitedTime) / releaseTime - info.lateClaimAmount;
      
      info.lateClaimAmount = claimableAmount;
      info.lateClaimedAt = uint48(block.timestamp);
    }

    totalStaked -= claimableAmount;

    _approveSplash(msg.sender, claimableAmount);
  }

  function claimPendingRewards() external {
    _updateRewards();

    StakeInfo storage info = userToStakeInfo[msg.sender];
    require(info.status == StakeStatus.ENTERED, "Wrong status");
  
    uint256 reward = info.pendingStakeRewards;
    info.pendingStakeRewards = 0;

    _approveSplash(msg.sender, reward);
  }
}