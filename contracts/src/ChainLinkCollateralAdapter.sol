// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Chainlink-backed adapter: nav() reads a live price feed instead of admin-set storage.
// Swap SimpleCollateralAdapter for this once a feed exists for the token.

import "./ICollateralAdapter.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";


contract ChainLinkCollateralAdapter is ICollateralAdapter, Ownable {
    address public immutable override token;
    uint8   public immutable override decimals;
    uint256 public override haircutBps;

    AggregatorV3Interface public immutable priceFeed;
    uint8 private immutable feedDecimals;
    uint256 public immutable maxStaleness; //seconds

    event HaircutUpdated(uint256 oldHaircutBps, uint256 newHaircutBps);

    constructor(
        address token_,
        uint8 decimals_,
        address priceFeed_,
        uint256 maxStaleness_,
        uint256 haircutBps_,
        address initialOwner_
    ) Ownable(initialOwner_) {
        require(token_ != address(0), "zero token");
        require(priceFeed_ !=address(0), "zero feed");
        require(maxStaleness_ > 0, "zero staleness");
        require(haircutBps_ <= 10_000, "haircut > 100%");
        
        token        = token_;
        decimals     = decimals_;
        priceFeed    = AggregatorV3Interface(priceFeed_);
        feedDecimals = AggregatorV3Interface(priceFeed_).decimals();
        maxStaleness = maxStaleness_;
        haircutBps   = haircutBps_;
    }

    function nav() external view override returns (uint256) {
        (, int256 answer, , uint256 updatedAt,) = priceFeed.latestRoundData();
        require(answer > 0, "invalid price");
        require(block.timestamp - updatedAt <= maxStaleness, "stale price");
        // scale from feedDecimals to 6 dp (USDC)
        return uint256(answer) * 1e6 / (10 ** feedDecimals);
    }

    function setHaircut(uint256 newHaircutBps) external onlyOwner {
        require(newHaircutBps <= 10_000, "haircut > 100%");
        emit HaircutUpdated(haircutBps, newHaircutBps);
        haircutBps = newHaircutBps;
    }
}