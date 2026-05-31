// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/MockBUIDL.sol";
import "../src/MockUSDC.sol";
import "../src/RepoVault.sol";

contract RepoVaultTest is Test {
    MockBUIDL internal buidl;
    MockUSDC internal usdc;
    RepoVault internal vault;
    
    address internal borrower;

    uint256 internal constant HAIRCUT =  200;
    uint256 internal constant NAV = 1e6;

    function setUp() public {
        //test contract is the owner/deployer of everything
        buidl = new MockBUIDL (address(this));
        usdc = new MockUSDC (address(this));
        vault = new RepoVault (address(buidl), address(usdc), HAIRCUT, NAV, address(this));

        //seed the valut with cash liquidity (we hold 1M mUSDC from the mint)
        usdc.approve(address(vault), type(uint256).max);
        vault.fundCash(100_000e6);

        //give the borrower some  collateral to work with: 100 whole mBUIDL
        buidl.transfer(borrower = makeAddr("borrower"), 100e18);

        //borrower pre-approves the vault to pull collateral (deposit) and cash (repay)
        vm.startPrank(borrower);
        buidl.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function test_DepositAndBorrow() public {
        vm.startPrank(borrower);
        vault.depositCollateral(100e18);
        vault.borrow(98e6);
        vm.stopPrank();
        assertEq(vault.collateralOf(borrower), 100e18);
        assertEq(vault.debtOf(borrower), 98e6);
        assertEq(usdc.balanceOf(borrower), 98e6);
        assertEq(vault.maxBorrow(borrower), 98e6);
        assertTrue(vault.isHealthy(borrower));
    }

    function test_RevertWhen_BorrowExceedsMax() public {
        vm.startPrank(borrower);
        vault.depositCollateral(100e18);
        vm.expectRevert(bytes("exceeds max borrow limit"));
        vault.borrow(98e6 + 1);      // one wei over the ceiling
        vm.stopPrank();
    }

    function test_RepayReducesDebt() public {
        vm.startPrank(borrower);
        vault.depositCollateral(100e18);
        vault.borrow(98e6);
        vault.repay(50e6);
        vm.stopPrank();

        assertEq(vault.debtOf(borrower), 48e6);   // 98 - 50
    }

    function test_WithdrawAfterFullRepay() public {
        vm.startPrank(borrower);
        vault.depositCollateral(100e18);
        vault.borrow(98e6);
        vault.repay(98e6);                 // clear the debt
        vault.withdrawCollateral(100e18);  // now allowed
        vm.stopPrank();

        assertEq(vault.collateralOf(borrower), 0);
        assertEq(vault.debtOf(borrower), 0);
        assertEq(buidl.balanceOf(borrower), 100e18);  // collateral returned
    }

    function test_RevertWhen_WithdrawBreaksHealth() public {
        vm.startPrank(borrower);
        vault.depositCollateral(100e18);
        vault.borrow(98e6);
        vm.expectRevert(bytes("would be undercollateralized"));
        vault.withdrawCollateral(100e18);  // debt still outstanding
        vm.stopPrank();
    }



}