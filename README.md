# Splash (Formerly COACH) Contracts

Written using Solidity 0.8.10 with optimizer enable @ runs 1000
<br>
Uses [Foundry](https://github.com/gakonst/foundry)

Dependencies:
* OpenZeppelin Contracts
* Chainlink Contracts

In order to run tests:
`forge test`

In order to compile
`forge compile`

Contracts that are in the scope of audit:
* `PaidTournaments.sol`: Holds tournaments where users enter by burning ERC1155 tickets and receives
  ERC20/721/1155 rewards depending on the type of the tournament
* `Staking.sol`: Staking contract that yields Splash token. Users get a certain pass depending on the
  time and amount they stake so it has an interface for getting tournament passes.
* `WeeklyTournaments.sol`: Holds tournaments where users get Splash tokens. Instead of burning tickets
  these tournaments requires a "tournament pass" that is earned by staking.
  Core accounts are trusted to create these tournaments in a weekly intervals.
* `Marketplace.sol`: A marketplace where ERC721 assets can be sold/rented and ERC1155 assets are sold.
  We added a new function where the owner can set a sale price for an ERC1155 asset and an another 
  function where a user can buy these cards (of any amount for now).

<br>

## File Structure

```
src
├── gameplay
│   ├── MatchMaker.sol
│   ├── PaidTournaments.sol
│   ├── TrainingMatches.sol
│   └── WeeklyTournaments.sol
├── interfaces
│   ├── IManagement.sol
│   ├── IRNG.sol
│   ├── IRegistry.sol
│   ├── ISP1155.sol
│   ├── ISP20.sol
│   ├── ISP721.sol
│   └── IStaking.sol
├── management
│   └── Management.sol
├── marketplace
│   └── Marketplace.sol
├── mock
│   ├── MockManagement.sol
│   └── MockRNG.sol
├── registry
│   └── Registry.sol
├── staking
│   └── Staking.sol
├── test
│   ├── PaidTournament.t.sol
│   ├── Player.t.sol
│   ├── Stake.t.sol
│   ├── WeeklyTournament.t.sol
│   └── helpers
│       ├── CheatCodes.sol
│       └── Helpers.sol
├── tokens
│   ├── SP1155.sol
│   ├── SP20.sol
│   └── SP721.sol
└── utils
    ├── ABDKMath64x64.sol
    ├── Errors.sol
    └── RNG.sol
```