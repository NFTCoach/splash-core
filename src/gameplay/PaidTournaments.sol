// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "oz-contracts/access/Ownable.sol";

// Token wrappers 
import "oz-contracts/token/ERC20/ERC20.sol";
import "oz-contracts/token/ERC721/ERC721.sol";
import "oz-contracts/token/ERC1155/ERC1155.sol";

import "./MatchMaker.sol";
import "../interfaces/IRegistry.sol";

enum Reward { ERC20, ERC721, ERC1155 }

struct TournamentDetails {
  Reward  rewardType;
  uint8   matchCount;
  address rewardAddress;
  uint256 rewardId;
  uint256 rewardAmount;
}

struct Tournament {
  bool   active;
  uint16 j;
  uint16 k;
  uint48 start;
  uint48 interval;
  TournamentDetails details;
}

struct TournamentRegistration {
  bool   active;
  uint8  cost;
  uint16 playerCount;
  uint16 tournamentCount;
  uint16 maxTournamentCount;
  uint48 entryDeadline;
  uint48 lastEntry;
  TournamentDetails details;
}

struct UserRegistration {
  bool registered;
  uint48 entryTimestamp;
}

/**
  @title Paid Tournament
  @notice Ticket based tournaments which can have ERC20/ERC721/ERC1155 prizes
  @author Hamza Karabag
*/
contract PaidTournaments is Ownable, MatchMaker {
  /* IRegistry registry from MatchMaker */

  uint48 constant TOURNAMENT_INTERVAL = 0 seconds;
  uint256 constant TIME_CAP = 4 weeks;

  uint128 private _tournamentTypeNonce;
  uint128 private _tournamentNonce;

  event NewTournament           (uint128 tournamentType);
  event TournamentRegistered    (address user, uint128 tournamentType);
  event TournamentFull          (uint128 tournamentType);
  event TournamentCreated       (uint128 tournamentId, uint128 tournamentType);
  event TournamentFinished      (uint128 tournamentId);

  mapping(uint128 => TournamentRegistration)      public  typeToRegistry;
  mapping(uint128 => Tournament)                  public  idToTournament;
  mapping(uint128 => mapping(uint16 => address))  public  tournamentToPlayers;
  mapping(uint128 => mapping(uint16 => address))  public  typeToQueue;
  mapping(address => UserRegistration)            private userToRegistry;

  modifier onlyCore() {
    require(registry.core(msg.sender), "Core only");
    _;
  }

  modifier checkStarters() {
    // This will revert if starters are not ready
    registry.management().checkStarters(msg.sender);
    _;
  }

  constructor(IRegistry registryAddress) MatchMaker(registryAddress) { }

  // Register

  function startTournamentRegistration(
    TournamentDetails memory details,
    uint48 deadline, 
    uint16 maxTournamentCount
  ) external onlyCore {

    _tournamentTypeNonce++;
    TournamentRegistration storage tReg = typeToRegistry[_tournamentTypeNonce];
    
    require(!tReg.active, "Registration is already started");
    require(deadline > _now(), "Invalid deadline");
    
    tReg.active = true;
    tReg.details = details;
    tReg.entryDeadline = deadline;
    tReg.maxTournamentCount = maxTournamentCount;

    emit NewTournament(_tournamentTypeNonce);
  }

  function register(uint128 tournamentType) external {

    TournamentRegistration storage tReg = typeToRegistry[tournamentType];

    require(tReg.active, "Registration is not active");
    require(tReg.tournamentCount > tReg.maxTournamentCount, "Tournament limit reached");
    require(tReg.entryDeadline >= _now(), "Late for entering queue");
    require(!userToRegistry[msg.sender].registered, "Player already registered");
    

    userToRegistry[msg.sender] = UserRegistration(true, _now());
    typeToQueue[tournamentType][tReg.playerCount++] = msg.sender;

    uint256 playerLimit = 2 ** tReg.details.matchCount;
    if(tReg.playerCount % playerLimit == playerLimit - 1) {
      tReg.tournamentCount++;
      tReg.lastEntry = _now();

      emit TournamentFull(tournamentType);
    }

    // Burn the tickets necessary to play
    registry.sp1155().burn(msg.sender, 11, tReg.cost);

    // This will revert if starters aren't ready
    registry.management().checkStarters(
      msg.sender, 
      tReg.details.matchCount, 
      tReg.entryDeadline + (tReg.details.matchCount * TOURNAMENT_INTERVAL)
    );
    registry.management().lockDefaultFive(msg.sender);
  }

  function requestTournamentRandomness() external onlyCore {
    registry.rng().requestBlockRandom(msg.sender);
  }

  // This function will be a gas guzzler
  function assignTournamentUsers(uint128 tournamentType) external onlyCore {
    
    TournamentRegistration storage tReg = typeToRegistry[tournamentType];
    require(tReg.active, "Registration is not started yet");
    require(tReg.tournamentCount > 0, "Not enough players to assign");
    require(registry.core(msg.sender), "Not core");

    tReg.active = false;

    uint256 tournamentCount = tReg.tournamentCount;
    uint256 playerLimit = 2**tReg.details.matchCount;

    for (uint256 i = 0; i < tournamentCount; i++) {
      _tournamentNonce++;

      // Register the tournament
      idToTournament[_tournamentNonce] = Tournament({
        active:     true,
        j:          0,
        k:          uint16(playerLimit),
        start:      tReg.entryDeadline,
        interval:   TOURNAMENT_INTERVAL,
        details:    tReg.details
      });

      for (uint16 j = 0; j < 2**playerLimit; j++) {
        tournamentToPlayers[_tournamentNonce][j] = 
          typeToQueue[tournamentType][uint16(i*playerLimit + j)];
      }

      emit TournamentCreated(_tournamentNonce, tournamentType);
    }
  }


  function playTournamentRound(uint128 tournamentId) external onlyCore {

    Tournament memory tournament = idToTournament[tournamentId];
    require(_now() > tournament.start, "Next match not ready");

    registry.rng().checkBlockRandom(msg.sender);
    // Reverts if no random
    uint256 tournamentRandomness = registry.rng().getBlockRandom(msg.sender);

    uint256 remainingMatches = (tournament.k - tournament.j) / 2;
    for (uint256 i = 0; i < remainingMatches; i++) {
      tournament = idToTournament[tournamentId];

      (uint8 score, , ) = matchMaker({
        enableMorale: false,
        playerOne: tournamentToPlayers[tournamentId][tournament.j],
        playerTwo: tournamentToPlayers[tournamentId][tournament.j + 1],
        randomness: tournamentRandomness
      });

      uint8 gameOffset = score >= 4 ? 1 : 0;

      registry.management().afterTournamentRound({
        userOne: tournamentToPlayers[tournamentId][tournament.j],
        userTwo: tournamentToPlayers[tournamentId][tournament.j + 1]
      });
            
      // Set next tour's player
      tournamentToPlayers[tournamentId][tournament.k] = tournamentToPlayers[tournamentId][
        tournament.j + gameOffset
      ];

      idToTournament[tournamentId].k += 1;
      idToTournament[tournamentId].j += 2;
    }

    // Use idToTournament[...]. to access mutated fields
    // Use tournament to access unchanged fields
    // TODO: gas golf
    if (idToTournament[tournamentId].k != (2**tournament.details.matchCount) * 2 - 1) {
      idToTournament[tournamentId].start += tournament.interval;
    } 
    else {
      emit TournamentFinished(tournamentId);
    }

    registry.rng().resetBlockRandom(msg.sender);
  }


  function finishTournament(uint128 tournamentId) external onlyCore {
    
    Tournament memory tournament = idToTournament[tournamentId];

    require(tournament.k == (2**tournament.details.matchCount) * 2 - 1, "Tournament not finished");

    uint16 winnerIdx = uint16(2**tournament.details.matchCount) * 2 - 2;
    address first = tournamentToPlayers[tournamentId][winnerIdx];

    registry.management().unlockDefaultFive(first);
  
    address rewardAddress = tournament.details.rewardAddress;
    Reward rewardType = tournament.details.rewardType;

    if(rewardType == Reward.ERC20) {
      require(ERC20(rewardAddress).approve({
        spender: first, 
        amount: tournament.details.rewardAmount
      }), "");
    }
    else if(rewardType == Reward.ERC721) {
      ERC721(rewardAddress).safeTransferFrom({
        from: address(this), 
        to: first, 
        tokenId: tournament.details.rewardId
      });
    }
    else if(rewardType == Reward.ERC1155) {
      ERC1155(rewardAddress).safeTransferFrom({
        from: address(this), 
        to: first, 
        id: tournament.details.rewardId, 
        amount: tournament.details.rewardAmount, 
        data: ""
      });
    }

    delete idToTournament[tournamentId].details;
    delete idToTournament[tournamentId];
  }

  function _now() private view returns(uint48) {
    return uint48(block.timestamp);
  }
}