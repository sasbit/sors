// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/MockBUIDL.sol";
import "../src/MockUSDC.sol";
import "../src/SimpleCollateralAdapter.sol";
import "../src/RepoVault.sol";

contract DeployRepo is Script {
    // All three tokenized-treasury tokens price near $1; 1e6 = par in 6-dp cash units.
    uint256 internal constant NAV_BUIDL = 1e6; // 1 mBUIDL = 1 mUSDC
    uint256 internal constant NAV_USYC  = 1e6; // 1 mUSYC  = 1 mUSDC
    uint256 internal constant NAV_OUSG  = 1e6; // 1 mOUSG  = 1 mUSDC

    uint256 internal constant HAIRCUT_BUIDL = 200; // 2%
    uint256 internal constant HAIRCUT_USYC  = 200; // 2%
    uint256 internal constant HAIRCUT_OUSG  = 300; // 3% — slightly less liquid

    function run() external {
        uint256 deployerKey = vm.envUint("LENDER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // ── Tokens ───────────────────────────────────────────────────────────
        MockBUIDL buidl = new MockBUIDL(deployer); // 18 decimals
        MockUSDC  usdc  = new MockUSDC(deployer);  //  6 decimals (cash leg)

        // Mocks for USYC (6 dp) and OUSG (18 dp).
        // In production replace with the real on-chain addresses.
        MockUSDC  usyc = new MockUSDC(deployer);   // proxy for USYC (6 dp)
        MockBUIDL ousg = new MockBUIDL(deployer);  // proxy for OUSG (18 dp)

        // ── Vault ────────────────────────────────────────────────────────────
        RepoVault vault = new RepoVault(address(usdc), deployer);

        // ── Adapters ─────────────────────────────────────────────────────────
        SimpleCollateralAdapter buidlAdapter = new SimpleCollateralAdapter(
            address(buidl), 18, NAV_BUIDL, HAIRCUT_BUIDL, deployer
        );
        SimpleCollateralAdapter usycAdapter = new SimpleCollateralAdapter(
            address(usyc), 6, NAV_USYC, HAIRCUT_USYC, deployer
        );
        SimpleCollateralAdapter ousgAdapter = new SimpleCollateralAdapter(
            address(ousg), 18, NAV_OUSG, HAIRCUT_OUSG, deployer
        );

        // ── Register ─────────────────────────────────────────────────────────
        vault.setAdapter(address(buidl), address(buidlAdapter));
        vault.setAdapter(address(usyc),  address(usycAdapter));
        vault.setAdapter(address(ousg),  address(ousgAdapter));

        vm.stopBroadcast();

        console.log("MockBUIDL   :", address(buidl));
        console.log("MockUSYC    :", address(usyc));
        console.log("MockOUSG    :", address(ousg));
        console.log("MockUSDC    :", address(usdc));
        console.log("RepoVault   :", address(vault));
        console.log("BUIDLAdapter:", address(buidlAdapter));
        console.log("USYCAdapter :", address(usycAdapter));
        console.log("OUSGAdapter :", address(ousgAdapter));
    }
}
