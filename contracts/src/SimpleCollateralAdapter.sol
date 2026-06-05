// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Minimal adapter: NAV and haircut are set by the owner (e.g. an operator posting a daily
// fixing). Swap this contract for a Chainlink-backed version later without touching the vault.

import "./ICollateralAdapter.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SimpleCollateralAdapter is ICollateralAdapter, Ownable {
    address public immutable override token;
    uint8   public immutable override decimals;
    uint256 public override nav;
    uint256 public override haircutBps;

    event NavUpdated(uint256 oldNav, uint256 newNav);
    event HaircutUpdated(uint256 oldHaircutBps, uint256 newHaircutBps);

    constructor(
        address token_,
        uint8   decimals_,
        uint256 nav_,
        uint256 haircutBps_,
        address initialOwner
    ) Ownable(initialOwner) {
        require(token_ != address(0), "zero token");
        require(nav_ > 0, "zero nav");
        require(haircutBps_ <= 10_000, "haircut > 100%");
        token      = token_;
        decimals   = decimals_;
        nav        = nav_;
        haircutBps = haircutBps_;
    }

    function setNav(uint256 newNav) external onlyOwner {
        require(newNav > 0, "zero nav");
        emit NavUpdated(nav, newNav);
        nav = newNav;
    }

    function setHaircut(uint256 newHaircutBps) external onlyOwner {
        require(newHaircutBps <= 10_000, "haircut > 100%");
        emit HaircutUpdated(haircutBps, newHaircutBps);
        haircutBps = newHaircutBps;
    }
}
