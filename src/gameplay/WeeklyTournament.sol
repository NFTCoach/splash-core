// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "oz-contracts/access/Ownable.sol";

import "./MatchMaker.sol";
import "../interfaces/IRegistry.sol";
import "../utils/ABDKMath64x64.sol";

struct Tournament {
  uint8 matchCount;
  uint16 j;
  uint16 k;
  uint48 start;
  uint48 interval;
  uint256 prizePool;
}

struct TournamentRegistry {
  bool active;
  uint8 matchCount;
  uint16 playerCount;
  uint48 deadline;
  uint64 tournamentCount;
  uint128 lastId;
  uint256 prizePool;
}

struct UserRegistry {
  bool registered;
}

/**
  @title WeeklyTournaments

  @author Hamza Karabag
*/
contract WeeklyTournament is Ownable, MatchMaker {
  using ABDKMath64x64 for int128;
  /* IRegistry registry from MatchMaker */

  uint48 constant TOURNAMENT_INTERVAL = 0 seconds;
  uint256 constant TIME_CAP = 4 weeks;

  uint8   private _firstWeight = 7;
  uint8   private _secondWeight = 3;
  uint128 private _tournamentNonce;

  event TournamentRegistration  (address user, Pass pass);
  event TournamentCreated       (uint128 tournamentId, Pass pass);
  event TournamentFinished      (uint128 tournamentId);

  mapping(uint128 => Tournament)                  public idToTournament;
  mapping(uint128 => mapping(uint16 => address))  public tournamentToPlayers;
  mapping(Pass => TournamentRegistry)             public passToRegistry;
  mapping(Pass => mapping(uint16 => address))     public passToQueue;
  mapping(address => UserRegistry)                private userToRegistry;

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

  // ############## SETTERS ############## //

  function setFirstWeight(uint8 newWeight) external onlyOwner {
    _firstWeight = newWeight;
  }

  function setSecondWeight(uint8 newWeight) external onlyOwner {
    _secondWeight = newWeight;
  }

  // ############## TOURNAMENT CREATION ############## //
  
  /**
    == ONLY CORE ==

    @notice Starts tournament registration for a certain pass
    @param pass _
    @param deadline timestamp until when users can register
    @param matchCount of tournament
    @param prizePool of tournament
  */
  function startTournamentRegistration( 
    Pass pass, 
    uint48 deadline, 
    uint8 matchCount, 
    uint256 prizePool
  ) external onlyCore {

    TournamentRegistry storage tReg = passToRegistry[pass];
    
    require(!tReg.active, "Registration is already started");
    require(deadline > _now(), "Invalid deadline");
    
    tReg.active = true;
    tReg.deadline = deadline;
    tReg.matchCount = matchCount;
    tReg.prizePool = prizePool;
  }


  /**
    @notice Enters the queue for a tournament
    @param pass Each tournament has a pass, indicating some of its props

    @dev Management contract checks msg.sender's players to ensure they are eligible
  */
  function enterTournamentQueue(Pass pass) external checkStarters {

    TournamentRegistry storage tReg = passToRegistry[pass];

    require(tReg.active, "Registration is not started yet");
    require(!userToRegistry[msg.sender].registered, "Player already registered");
    require(pass != Pass.NONE, "Invalid pass");
    require(_now() <= tReg.deadline, "Late for entering queue");

    Pass currentPass = registry.staking().getPass(msg.sender);
    require(pass == currentPass, "User doesn't have the right pass");

    userToRegistry[msg.sender] = UserRegistry(true);
    passToQueue[pass][tReg.playerCount++] = msg.sender;

    uint256 playerLimit = 2 ** tReg.matchCount;
    if(tReg.playerCount % playerLimit == playerLimit - 1) {
      tReg.tournamentCount++;
    }
    
    // This will revert if starters aren't ready
    registry.management().checkStarters(msg.sender, tReg.matchCount, tReg.deadline + (tReg.matchCount * TOURNAMENT_INTERVAL));
    registry.management().lockDefaultFive(msg.sender);
  }
  
  /**
    == ONLY CORE ==

    @dev Sets a checkpoint for the RNG algorithm we use
  */
  function requestTournamentRandomness() external onlyCore {
    registry.rng().requestBlockRandom(msg.sender);
  }


  /**
    == ONLY CORE ==

    @notice Creates tournaments after registration
    @param pass Each tournament has a pass, indicating some of its props
    @dev Core user can create tournaments before the deadline is finished
  */
  function createTournaments(Pass pass) external onlyCore {

    TournamentRegistry storage tReg = passToRegistry[pass];
    require(tReg.active, "Registration is not started yet");
    require(tReg.tournamentCount > 0, "Not enough players to assign");

    tReg.active = false;

    // Generate the random
    registry.rng().checkBlockRandom(msg.sender);
    // It'll revert if there's no random number
    uint256 tournamentRandomness = registry.rng().getBlockRandom(msg.sender);
    
    // Divide the player pool into individual tournaments
    uint256 tournamentCount = tReg.tournamentCount;
    uint16 playerLimit = uint16(2**tReg.matchCount);
    for (uint128 i = 0; i < tournamentCount; i++) {
      _tournamentNonce++;

      // Register the tournament
      idToTournament[_tournamentNonce] = Tournament({
        matchCount: tReg.matchCount,
        j: 0,
        k: playerLimit,
        start: tReg.deadline,
        interval: TOURNAMENT_INTERVAL,
        prizePool: tReg.prizePool / tournamentCount
      });

      emit TournamentCreated(_tournamentNonce, pass);


      // Get a list of indexes for each tournament
      // Something like [ 0,1,2,3,4,5,..,15 ]
      uint16[] memory idxList;
      for (uint16 j = 0; j < playerLimit; j++)
        idxList[j] = j;

      // Pick a random index from the list,
      // Assign the next player to this random tournament slot
      // Repeat until index list is empty
      // This should randomize a single tournament's game order
      for (uint16 size = playerLimit; size > 0; size--) {
        uint256 randIdx = tournamentRandomness % size - 1;
        uint16 tSlot = idxList[randIdx];

        tournamentToPlayers[_tournamentNonce][tSlot] = 
          passToQueue[pass][uint16((i+1) * playerLimit - size)]; 
      
        // Remove the index from the list
        delete idxList[randIdx];
      }

      delete idxList; // This might be pointless
    }
  }


  /**
    == ONLY CORE ==

    @notice Plays a single round of a tournament
    @param tournamentId Each tournament has an ID

  */
  function playTournamentRound(uint128 tournamentId) external onlyCore {

    Tournament memory tournament = idToTournament[tournamentId];
    
    require(_now() > tournament.start, "Next match not ready");

    // Requires a new request for random
    registry.rng().checkBlockRandom(msg.sender);
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
    if (idToTournament[tournamentId].k != (2**tournament.matchCount) * 2 - 1) {
      idToTournament[tournamentId].start += tournament.interval;
    } 
    else {
      emit TournamentFinished(tournamentId);
    }

    registry.rng().resetBlockRandom(msg.sender);
  }

  /**
    == ONLY CORE ==

    @notice Ends a tournament
    @param tournamentId _

    @dev Winner prize is calculating using 
      Prize = TotalPrize * m*A / (m*A + n*B) where:
      m: Prize weight of 1st place
      n: Prize weight of 2nd place
      A: Stake coefficient of 1st user
      B: Stake coefficeient of 2nd user

    @dev Second prize is basically (Total prize - Winner prize)
  */
  function finishTournament(uint128 tournamentId) external onlyCore {
    Tournament memory tournament = idToTournament[tournamentId];

    require(tournament.k == (2**tournament.matchCount) * 2 - 1, "Tournament not finished");

    // Set up variables for convenience
    uint256 totalPrize = tournament.prizePool;
    uint16 winnerIdx = uint16(2**tournament.matchCount) * 2 - 2;
    address first = tournamentToPlayers[tournamentId][winnerIdx];
    address second = tournamentToPlayers[tournamentId][winnerIdx - 1];

    int128 firstCoeff = registry.staking().getCoefficient(first);
    int128 secondCoeff = registry.staking().getCoefficient(second);

    uint256 winnerPrize = (firstCoeff.mulu(_firstWeight) * totalPrize) / 
      (firstCoeff.mulu(_firstWeight) + secondCoeff.mulu(_secondWeight));

    assert(winnerPrize < totalPrize);

    registry.management().unlockDefaultFive(first);
    registry.management().unlockDefaultFive(second);

    // Approve prize to the winner
    _approveSplash(first, winnerPrize);
    _approveSplash(second, totalPrize - winnerPrize);
  }

  function _approveSplash(address to, uint256 amount) private {
    require(
      registry.sp20().increaseAllowance(to, amount),
      "Token approve for second failed"
    );
  }

  function _now() private view returns(uint48) {
    return uint48(block.timestamp);
  }
}