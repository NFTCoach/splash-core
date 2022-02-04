// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "oz-contracts/access/Ownable.sol";

import "./MatchMaker.sol";
import "../interfaces/IRegistry.sol";
import "../utils/ABDKMath64x64.sol";

// TODO: add checks to elim fraudulent entries

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
  uint48 lastEntry;
  uint64 tournamentCount;
  uint128 lastId;
  uint256 prizePool;
}

struct UserRegistry {
  bool registered;
  Pass pass;
  uint48 entry;
}

contract WeeklyTournament is Ownable, MatchMaker {
  using ABDKMath64x64 for int128;
  /* IRegistry registry from MatchMaker */

  uint48 constant TOURNAMENT_INTERVAL = 0 seconds;
  uint256 constant TIME_CAP = 4 weeks;

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

  // ############## TOURNAMENT CREATION ############## //
  
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


  function enterTournamentQueue(Pass pass) external checkStarters {

    TournamentRegistry storage tReg = passToRegistry[pass];

    require(tReg.active, "Registration is not started yet");
    require(!userToRegistry[msg.sender].registered, "Player already registered");
    require(pass != Pass.NONE, "Invalid pass");
    require(_now() <= tReg.deadline, "Late for entering queue");

    Pass currentPass = registry.staking().getPass(msg.sender);
    require(pass == currentPass, "User doesn't have the right pass");

    userToRegistry[msg.sender] = UserRegistry(true, pass, _now());
    passToQueue[pass][tReg.playerCount++] = msg.sender;

    uint256 playerLimit = 2 ** tReg.matchCount;
    if(tReg.playerCount % playerLimit == playerLimit - 1) {
      tReg.tournamentCount++;
      tReg.lastEntry = _now();
    }
    
    // This will revert if starters aren't ready
    registry.management().checkStarters(msg.sender, tReg.matchCount, tReg.deadline + (tReg.matchCount * TOURNAMENT_INTERVAL));
    registry.management().lockDefaultFive(msg.sender);
  }
  
  // TODO: leave tournament queue

  function requestTournamentRandomness() external onlyCore {
    registry.rng().requestBlockRandom(msg.sender);
  }


  function assignTournamentUsers(Pass pass) external {

    TournamentRegistry storage tReg = passToRegistry[pass];
    require(tReg.active, "Registration is not started yet");
    require(tReg.tournamentCount > 0, "Not enough players to assign");
    require(registry.core(msg.sender), "Not core");

    tReg.active = false;

    // Generate the random
    registry.rng().checkBlockRandom(msg.sender);
    // It'll revert if there's no random number
    uint256 tournamentRandomness = registry.rng().getBlockRandom(msg.sender);

    // Divide the player pool into individual tournaments
    // TODO: randomize
    uint256 tournamentCount = tReg.tournamentCount;
    uint256 playerLimit = 2**tReg.matchCount;
    for (uint256 i = 0; i < tournamentCount; i++) {
      _tournamentNonce++;

      // Register the tournament
      idToTournament[_tournamentNonce] = Tournament({
        matchCount: tReg.matchCount,
        j: 0,
        k: uint16(playerLimit),
        start: tReg.deadline,
        interval: TOURNAMENT_INTERVAL,
        prizePool: tReg.prizePool / tournamentCount
      });

      for (uint16 j = 0; j < 2**playerLimit; j++) {
        tournamentToPlayers[_tournamentNonce][j] = 
          passToQueue[pass][uint16(i*playerLimit + j)];
      }

      emit TournamentCreated(_tournamentNonce, pass);
    }
  }

  // We're agnostic to which tier this tournament is in
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

    uint256 winnerPrize = (firstCoeff.mulu(7) * totalPrize) / 
      (firstCoeff.mulu(7) + secondCoeff.mulu(3));

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