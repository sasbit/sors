// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Script.sol";
import "../src/MockBUIDL.sol";
import "../src/MockUSDC.sol";
import "../src/RepoVault.sol";

contract DeployRepo is Script {
    uint256 internal constant HAIRCUT = 200;   // 2%
    uint256 internal constant NAV     = 1e6;    // par: 1 mBUIDL = 1 mUSDC

    //run() is the conventional entrypoint for forge script calls
    function run() external {
        //load the deployer key from the environment
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        MockBUIDL buidl = new MockBUIDL(deployer);
        MockUSDC usdc = new MockUSDC(deployer);
        RepoVault vault = new RepoVault(
            address(buidl),
            address(usdc),
            HAIRCUT,
            NAV,
            deployer
        );

        vm.stopBroadcast();

        console.log("MockBUIDL :", address(buidl));
        console.log("MockUSDC :", address(usdc));
        console.log("RepoVault :", address(vault));
    }
}