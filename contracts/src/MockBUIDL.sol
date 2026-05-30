// SPDX-License-Identifier: MIT

/*
standard functionality inherited through ERC20:
transfer(...)
approve(...)
transferFrom(...)
balanceOf(...)
allowance(...)
totalSupply()
*/

pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockBUIDL is ERC20, Ownable {
    constructor(address initialOwner)
        ERC20("Mock BUIDL", "mBUIDL")
        Ownable(initialOwner)
    {
        _mint(initialOwner, 1_000_000 * 10 ** decimals());
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
