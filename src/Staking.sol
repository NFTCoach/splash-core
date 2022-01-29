// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "oz-contracts/access/Ownable.sol";
import "oz-contracts/token/ERC20/ERC20.sol";

import "./utils/ABDKMath64x64.sol";

interface ILockable {
  function lockVeteranBatch(address user, uint256[] calldata ids) external;
  function lockRetiredBatch(address user, uint256[] calldata ids) external;
  function unlockVeteranBatch(address user, uint256[] calldata ids) external;
  function unlockRetiredBatch(address user, uint256[] calldata ids) external;
} 

interface IPlayerStatus {
  // 0.Doesn't exist, 1. Rookie, 2. Veteran, 3. Retired 
  function getPlayerStatus(uint256 user) external view returns(uint256 playerStatus);  
}

abstract contract IPlayer {}
abstract contract IManagement is IPlayerStatus, ILockable {}
abstract contract ISplash20 is ERC20 {}

enum StakeStatus { NONE, ENTERED, EXITED }
enum Pass { NONE, BRONZE, SILVER, GOLD }

/**
  @notice Holds pass requirements
  @dev Used while calculating coefficients
*/
struct PassRequirement {
  uint8 veteranCount;
  uint8 retiredCount;
  uint48 stakeTime;
  uint256 stakeAmount;
}

/**
 @notice Holds stake information
*/
struct StakeInfo {
  StakeStatus status;
  Pass pass;
  uint48 exitTimestamp;
  uint48 lastClaim;
  uint48 enteredAt;
  uint48 exitedAt;
  uint256 stakedAmount;
  uint256 claimedAmount;
  uint256[] veteranList;
  uint256[] retiredList;
}

/*
  TODOs:
  * Make an emergency strat
*/
contract Staking is Ownable {
  using ABDKMath64x64 for int128;
  using ABDKMath64x64 for uint256;

  ISplash20 splash20Contract;
  IManagement managementContract;
  IPlayer playerContract;

  /// @dev Abbreviated as "RPS" throughout the contract
  uint256 public rewardPerSecond;
  // Max Stake Rate: 1.4
  int128 public maxStakeRate = uint256(7).divu(5);
  // Max Time Rate: 2.2
  int128 public maxTimeRate = uint256(11).divu(5);

  event RewardChanged(uint256 newRPS);
  event MaxStakeRateChanged(int128 newStakeRate);
  event MaxTimeRateChanged(int128 newTimeRate);

  mapping(Pass => PassRequirement) public passRequirements;
  mapping(address => StakeInfo) public userToStakeInfo;

  constructor(
    IPlayer playerAddress,
    IManagement managementAddress,
    ISplash20 splash20Address,
    uint256 initRPS,
    PassRequirement[] memory initReqs
  ) {
    require(initReqs.length == 3, "Invalid number of requirements");
    
    splash20Contract = ISplash20(splash20Address);
    managementContract = IManagement(managementAddress);
    playerContract = IPlayer(playerAddress);

    rewardPerSecond = initRPS;
    for (uint256 i = 0; i <= initReqs.length; i++) {
      passRequirements[Pass(i + 1)] = initReqs[i];
    }
  }

  // #################### SETTERS #################### //

  function setRewardsPerSeconds(uint256 newRPS) external onlyOwner {
    rewardPerSecond = newRPS;
    emit RewardChanged(newRPS);
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
    @dev This is used in reward calculations
    @return int128 ABDK64x64 coefficient
  */
  function getCoefficient(address user) external view returns(int128) {
    StakeInfo memory stakeInfo = userToStakeInfo[user];

    if(userToStakeInfo[user].status != StakeStatus.ENTERED)
      return 0;

    PassRequirement memory requirement = passRequirements[stakeInfo.pass];
    
    int128 stakeRate = stakeInfo.stakedAmount.divu(requirement.stakeAmount);
    int128 timeRate = uint256(stakeInfo.exitTimestamp - stakeInfo.enteredAt)
      .divu(uint256(requirement.stakeTime));

    if(stakeRate > maxStakeRate)
      stakeRate = maxStakeRate;
    
    if(timeRate > maxTimeRate)
      timeRate = maxTimeRate;

    return stakeRate.mul(timeRate);
  }

  // #################### STAKING #################### //

  function enterStake(
    Pass pass, 
    uint256 stakeAmount, 
    uint48 stakeTime,
    uint256[] memory veteranList,
    uint256[] memory retiredList
  ) external {
    require(userToStakeInfo[msg.sender].status == StakeStatus.NONE, "Wrong status");

    PassRequirement memory requirement = passRequirements[pass];
    require(stakeAmount >= requirement.stakeAmount, "Invalid stake amount");
    require(stakeTime >= requirement.stakeTime, "Invalid stake time");
  
    userToStakeInfo[msg.sender] = StakeInfo({
      status: StakeStatus.ENTERED,
      pass: pass,
      exitTimestamp: uint48(block.timestamp + stakeTime),
      lastClaim: uint48(block.timestamp),
      enteredAt: uint48(block.timestamp),
      exitedAt: 0,
      stakedAmount: stakeAmount,
      claimedAmount: 0,
      veteranList: veteranList,
      retiredList: retiredList
    });

    // These two call must revert if the player status is incorrect, or owner doesn't match
    managementContract.lockVeteranBatch(msg.sender, veteranList);
    managementContract.lockRetiredBatch(msg.sender, retiredList);
     
    // Transfer token to contract
    require(splash20Contract.transferFrom(msg.sender, address(this), stakeAmount), "Token checkout failed");
  }

  function exitStake() external {
    StakeInfo memory info = userToStakeInfo[msg.sender];

    require(info.status == StakeStatus.ENTERED, "Wrong status");

    managementContract.lockVeteranBatch(msg.sender, info.veteranList);
    managementContract.lockRetiredBatch(msg.sender, info.retiredList);

    // Approve all stake directly if exiting at right time
    if(block.timestamp >= userToStakeInfo[msg.sender].exitTimestamp) {
      require(splash20Contract.increaseAllowance(msg.sender, info.stakedAmount), "Token approve failed");      
      delete userToStakeInfo[msg.sender];
      
      return;
    }

    StakeInfo storage infoStorage = userToStakeInfo[msg.sender];
    infoStorage.status = StakeStatus.EXITED;
    infoStorage.exitTimestamp = 0;
    infoStorage.lastClaim = uint48(block.timestamp);
    infoStorage.exitedAt = uint48(block.timestamp);
  }

  /**
    @notice Claims staked amount after early exit
  */
  function claimPendingStake() external {
    StakeInfo memory info = userToStakeInfo[msg.sender];
    require(info.status == StakeStatus.EXITED, "Wrong status");
    require(block.timestamp - info.lastClaim > 15 minutes, "Too early to claim again");

    assert(info.exitedAt > 0);
    assert(info.exitTimestamp > info.exitedAt);
    assert(block.timestamp > info.exitedAt);
    
    uint256 claimableAmount;
    uint256 releaseTime = uint256(info.exitTimestamp - info.exitedAt);
    uint256 waitedTime = uint256(block.timestamp - info.exitedAt);
    
    // If waiting period is over, approve the remaining 
    // amount and delete the stake position
    if(waitedTime >= releaseTime) {
      claimableAmount = info.stakedAmount;
    }
    else {
      claimableAmount = (info.stakedAmount * waitedTime) / releaseTime;
    }

    require(splash20Contract.increaseAllowance(msg.sender, claimableAmount - info.claimedAmount),
      "Token approve failed");
    
    userToStakeInfo[msg.sender].claimedAmount = claimableAmount;
    userToStakeInfo[msg.sender].lastClaim = uint48(block.timestamp);
  }

  function claimStakingReward() external {


  }
}
