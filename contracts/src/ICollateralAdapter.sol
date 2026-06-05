// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICollateralAdapter {
    /// @return The ERC-20 collateral token this adapter prices.
    function token() external view returns (address);

    /// @return Cash units (6 dp) per 1 whole collateral token (i.e. per 10**decimals() raw units).
    function nav() external view returns (uint256);

    /// @return Haircut in basis points (e.g. 200 = 2%).
    function haircutBps() external view returns (uint256);

    /// @return Raw decimal count of the collateral token.
    function decimals() external view returns (uint8);
}
