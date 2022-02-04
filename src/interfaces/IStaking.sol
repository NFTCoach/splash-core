// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

enum Pass { NONE, BRONZE, SILVER, GOLD }

interface IStaking {
  function getPass(address user) external view returns(Pass);
  function getCoefficient(address user) external view returns(int128);
}