//SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Mock cash leg for the repo venue. Mirrors real USDC at 6 decimals
///         (not the ERC20 default of 18) so off-chain accounting matches mainnet.

contract MockUSDC is ERC20, Ownable {
    constructor(address initialOwner)
        ERC20("Mock USDC", "mUSDC")
        Ownable(initialOwner)

    {
        _mint(initialOwner, 1_000_000 * 10 ** decimals());
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}