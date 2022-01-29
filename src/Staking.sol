// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "oz-contracts/access/Ownable.sol";
import "oz-contracts/token/ERC20/IERC20.sol";

interface ILockable {
  function lockVeteranBatch(address user, uint256[] calldata ids) external;
  function lockRetiredBatch(address user, uint256[] calldata ids) external;
} 

interface IPlayerStatus {
  // 0.Doesn't exist, 1. Rookie, 2. Veteran, 3. Retired 
  function getPlayerStatus(uint256 user) external view returns(uint256 playerStatus);  
}

abstract contract IPlayer {}
abstract contract IManagement is IPlayerStatus, ILockable {}
abstract contract ISplash20 is IERC20 {}

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
  uint48 exitedAt;
  uint256 stakedAmount;
}

/*
  TODOs:
  * Make an emergency strat
*/
contract Staking is Ownable {
  ISplash20 splash20Contract;
  IManagement managementContract;
  IPlayer playerContract;

  /// @dev Abbreviated as "RPS" throughout the contract
  uint256 public rewardPerSecond;

  event RewardChanged(uint256 newRPS);

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

  // #################### COEFFICENT #################### //

  function getCoefficient(address user) external view returns(uint8) {
    StakeInfo memory stakeInfo = userToStakeInfo[user];

    if(userToStakeInfo[user].status != StakeStatus.ENTERED)
      return 0;
    
    PassRequirement memory requirement = passRequirements[stakeInfo.pass];
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
      exitedAt: 0,
      stakedAmount: stakeAmount
    });

    // These two call must revert if the player status is incorrect, or owner doesn't match
    managementContract.lockVeteranBatch(msg.sender, veteranList);
    managementContract.lockRetiredBatch(msg.sender, retiredList);
     
    // Transfer token to contract
    require(splash20Contract.transferFrom(msg.sender, address(this), stakeAmount), "Coach checkout failed");
  }
}
