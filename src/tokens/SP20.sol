// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "oz-contracts/access/Ownable.sol";
import "oz-contracts/token/ERC20/ERC20.sol";
import "oz-contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract Splash is ERC20, ERC20Burnable, Ownable {
  constructor() ERC20("SPLASH", "SPLASH") {
    _mint(msg.sender, 21000000 * 10**decimals());
  }

  function mint(address to, uint256 amount) public onlyOwner {
    _mint(to, amount);
  }
}