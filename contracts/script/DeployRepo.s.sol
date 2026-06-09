// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/MockBUIDL.sol";
import "../src/MockUSDC.sol";
import "../src/SimpleCollateralAdapter.sol";
import "../src/RepoVault.sol";

contract DeployRepo is Script {
    uint256 internal constant NAV_BUIDL = 1e6;
    uint256 internal constant NAV_USYC  = 1e6;
    uint256 internal constant NAV_OUSG  = 1e6;

    uint256 internal constant HAIRCUT_BUIDL = 200; // 2% initial margin
    uint256 internal constant HAIRCUT_USYC  = 200;
    uint256 internal constant HAIRCUT_OUSG  = 300; // 3% — slightly less liquid

    uint256 internal constant MAINTENANCE_MARGIN = 100;

    function run() external {
        uint256 deployerKey = vm.envUint("LENDER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // ── Tokens ───────────────────────────────────────────────────────────
        MockBUIDL buidl = new MockBUIDL(deployer);
        MockUSDC  usdc  = new MockUSDC(deployer);
        MockUSDC  usyc  = new MockUSDC(deployer);  // proxy for USYC (6 dp)
        MockBUIDL ousg  = new MockBUIDL(deployer); // proxy for OUSG (18 dp)

        // ── Vault ────────────────────────────────────────────────────────────
        RepoVault vault = new RepoVault(address(usdc), deployer, MAINTENANCE_MARGIN);

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

        // ── Register collateral ───────────────────────────────────────────────
        vault.approveCollateral(address(buidl), address(buidlAdapter));
        vault.approveCollateral(address(usyc),  address(usycAdapter));
        vault.approveCollateral(address(ousg),  address(ousgAdapter));

        // ── Grant roles to deployer for initial testing ───────────────────────
        vault.approveLender(deployer);
        vault.approveBorrower(deployer);
        vault.approveLiquidator(deployer);

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
