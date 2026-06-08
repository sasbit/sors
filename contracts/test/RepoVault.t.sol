// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/MockBUIDL.sol";
import "../src/MockUSDC.sol";
import "../src/SimpleCollateralAdapter.sol";
import "../src/RepoVault.sol";
import "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";
import "../src/ChainLinkCollateralAdapter.sol";

contract RepoVaultTest is Test {
    MockBUIDL               internal buidl;
    MockBUIDL               internal ousg;  // reuses MockBUIDL (18 dp) as a second collateral
    MockUSDC                internal usdc;
    SimpleCollateralAdapter internal buidlAdapter;
    SimpleCollateralAdapter internal ousgAdapter;
    RepoVault               internal vault;

    address internal borrower;

    uint256 internal constant NAV     = 1e6;  // par: 1 whole token = 1 mUSDC
    uint256 internal constant HAIRCUT = 200;  // 2%

    function setUp() public {
        buidl = new MockBUIDL(address(this));
        ousg  = new MockBUIDL(address(this)); // second 18-dp collateral
        usdc  = new MockUSDC(address(this));

        vault = new RepoVault(address(usdc), address(this));

        buidlAdapter = new SimpleCollateralAdapter(address(buidl), 18, NAV, HAIRCUT, address(this));
        ousgAdapter  = new SimpleCollateralAdapter(address(ousg),  18, NAV, HAIRCUT, address(this));

        vault.setAdapter(address(buidl), address(buidlAdapter));
        vault.setAdapter(address(ousg),  address(ousgAdapter));

        // seed vault with cash liquidity
        usdc.approve(address(vault), type(uint256).max);
        vault.fundCash(100_000e6);

        // give borrower 100 mBUIDL and 100 mOUSG
        borrower = makeAddr("borrower");
        vault.setWhiteListed(borrower, true); // KYC onboarding required by deposit/borrow
        buidl.transfer(borrower, 100e18);
        ousg.transfer(borrower,  100e18);

        vm.startPrank(borrower);
        buidl.approve(address(vault), type(uint256).max);
        ousg.approve(address(vault),  type(uint256).max);
        usdc.approve(address(vault),  type(uint256).max);
        vm.stopPrank();
    }

    // ── Single-token tests (mirrors original suite) ───────────────────────────

    function test_DepositAndBorrow() public {
        vm.startPrank(borrower);
        vault.depositCollateral(address(buidl), 100e18);
        vault.borrow(98e6);
        vm.stopPrank();

        assertEq(vault.collateralOf(borrower, address(buidl)), 100e18);
        assertEq(vault.debtOf(borrower), 98e6);
        assertEq(usdc.balanceOf(borrower), 98e6);
        assertEq(vault.maxBorrow(borrower), 98e6);
        assertTrue(vault.isHealthy(borrower));
    }

    function test_RevertWhen_BorrowExceedsMax() public {
        vm.startPrank(borrower);
        vault.depositCollateral(address(buidl), 100e18);
        vm.expectRevert(bytes("exceeds max borrow"));
        vault.borrow(98e6 + 1);
        vm.stopPrank();
    }

    function test_RepayReducesDebt() public {
        vm.startPrank(borrower);
        vault.depositCollateral(address(buidl), 100e18);
        vault.borrow(98e6);
        vault.repay(50e6);
        vm.stopPrank();

        assertEq(vault.debtOf(borrower), 48e6);
    }

    function test_WithdrawAfterFullRepay() public {
        vm.startPrank(borrower);
        vault.depositCollateral(address(buidl), 100e18);
        vault.borrow(98e6);
        vault.repay(98e6);
        vault.withdrawCollateral(address(buidl), 100e18);
        vm.stopPrank();

        assertEq(vault.collateralOf(borrower, address(buidl)), 0);
        assertEq(vault.debtOf(borrower), 0);
        assertEq(buidl.balanceOf(borrower), 100e18);
    }

    function test_RevertWhen_WithdrawBreaksHealth() public {
        vm.startPrank(borrower);
        vault.depositCollateral(address(buidl), 100e18);
        vault.borrow(98e6);
        vm.expectRevert(bytes("would undercollateralize"));
        vault.withdrawCollateral(address(buidl), 100e18);
        vm.stopPrank();
    }

    // ── Multi-token tests ─────────────────────────────────────────────────────

    // Borrower posts two different tokens; maxBorrow reflects the combined value.
    function test_MultiTokenCollateral_CombinedValue() public {
        vm.startPrank(borrower);
        vault.depositCollateral(address(buidl), 100e18); // worth 100 mUSDC, cap 98
        vault.depositCollateral(address(ousg),  100e18); // worth 100 mUSDC, cap 98
        vm.stopPrank();

        // total collateral value = 200 mUSDC, maxBorrow = 200 * 98% = 196 mUSDC
        assertEq(vault.totalCollateralValue(borrower), 200e6);
        assertEq(vault.maxBorrow(borrower), 196e6);
    }

    function test_MultiTokenCollateral_BorrowUpToAggregateMax() public {
        vm.startPrank(borrower);
        vault.depositCollateral(address(buidl), 100e18);
        vault.depositCollateral(address(ousg),  100e18);
        vault.borrow(196e6); // exactly at the combined ceiling
        vm.stopPrank();

        assertTrue(vault.isHealthy(borrower));
        assertEq(vault.debtOf(borrower), 196e6);
    }

    function test_MultiTokenCollateral_PerTokenHaircutApplied() public {
        // register a third token with a 10% haircut
        MockBUIDL highRisk = new MockBUIDL(address(this));
        SimpleCollateralAdapter highRiskAdapter = new SimpleCollateralAdapter(
            address(highRisk), 18, NAV, 1_000, address(this) // 10% haircut
        );
        vault.setAdapter(address(highRisk), address(highRiskAdapter));
        highRisk.transfer(borrower, 100e18);

        vm.startPrank(borrower);
        highRisk.approve(address(vault), type(uint256).max);
        vault.depositCollateral(address(highRisk), 100e18);
        vm.stopPrank();

        // 100 mUSDC at 10% haircut = 90 mUSDC borrow capacity
        assertEq(vault.tokenCollateralValue(address(highRisk), borrower), 100e6);
        assertEq(vault.maxBorrow(borrower), 90e6);
    }

    // ── Adapter management ────────────────────────────────────────────────────

    function test_RevertWhen_DepositUnregisteredToken() public {
        MockBUIDL unknown = new MockBUIDL(address(this));
        unknown.transfer(borrower, 10e18);

        vm.startPrank(borrower);
        unknown.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("token not registered"));
        vault.depositCollateral(address(unknown), 10e18);
        vm.stopPrank();
    }

    function test_AdapterReplacement_NewNavTakesEffect() public {
        vm.startPrank(borrower);
        vault.depositCollateral(address(buidl), 100e18);
        vm.stopPrank();

        assertEq(vault.maxBorrow(borrower), 98e6); // original: nav=1e6, haircut=2%

        // deploy a new adapter with nav = 2e6 (collateral doubled in value)
        SimpleCollateralAdapter newAdapter = new SimpleCollateralAdapter(
            address(buidl), 18, 2e6, HAIRCUT, address(this)
        );
        vault.setAdapter(address(buidl), address(newAdapter));

        assertEq(vault.maxBorrow(borrower), 196e6); // 200 * 98%
    }

    function test_CollateralTokenCount() public {
        assertEq(vault.collateralTokenCount(), 2); // buidl + ousg registered in setUp
    }

    function test_ChainlinkAdapter_NavFromFeed() public {
    MockV3Aggregator feed = new MockV3Aggregator(8, 1_05_000_000); // $1.05, 8 dp
    ChainLinkCollateralAdapter clAdapter = new ChainLinkCollateralAdapter(
        address(buidl), 18, address(feed), 26 hours, 200, address(this)
    );
    vault.setAdapter(address(buidl), address(clAdapter));

    vm.prank(borrower);
    vault.depositCollateral(address(buidl), 100e18);

    // 100 tokens * $1.05 = $105 collateral value; maxBorrow = $105 * 98% = $102.9
    assertEq(vault.tokenCollateralValue(address(buidl), borrower), 105e6);
    assertEq(vault.maxBorrow(borrower), 102_900_000);
}

    function test_ChainlinkAdapter_RevertWhen_Stale() public {
        MockV3Aggregator feed = new MockV3Aggregator(8, 1_00_000_000);
        ChainLinkCollateralAdapter clAdapter = new ChainLinkCollateralAdapter(
            address(buidl), 18, address(feed), 26 hours, 200, address(this)
        );
        vault.setAdapter(address(buidl), address(clAdapter));

        vm.warp(block.timestamp + 27 hours); // past the staleness threshold

        vm.prank(borrower);
        vault.depositCollateral(address(buidl), 100e18); // deposit still works

        vm.expectRevert(bytes("stale price"));
        vault.maxBorrow(borrower); // price read reverts
    }

    function test_RevertWhen_NotWhitelisted() public {
        address stranger = makeAddr("stranger");

        vm.startPrank(stranger);
        buidl.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("not whitelisted"));
        vault.depositCollateral(address(buidl), 1e18);
        vm.stopPrank();
    }

    function test_Liquidate_UnhealthyPosition() public {
        vm.startPrank(borrower);
        vault.depositCollateral(address(buidl), 100e18);
        vault.borrow(98e6); // borrow at the 98% ceiling
        vm.stopPrank();

        // drop NAV so collateralValue falls below debt: 100 * 0.97 * 98% = 95.06 < 98
        SimpleCollateralAdapter lowNavAdapter = new SimpleCollateralAdapter(
            address(buidl), 18, 0.97e6, HAIRCUT, address(this)
        );
        vault.setAdapter(address(buidl), address(lowNavAdapter));
        assertFalse(vault.isHealthy(borrower));

        uint256 ownerBuidlBefore = buidl.balanceOf(address(this));
        vault.liquidate(borrower);

        assertEq(vault.debtOf(borrower), 0);
        assertEq(vault.collateralOf(borrower, address(buidl)), 0);
        assertEq(buidl.balanceOf(address(this)), ownerBuidlBefore + 100e18);
    }

    function test_RevertWhen_Liquidate_HealthyPosition() public {
        vm.startPrank(borrower);
        vault.depositCollateral(address(buidl), 100e18);
        vault.borrow(50e6); // well under the ceiling
        vm.stopPrank();

        vm.expectRevert(bytes("position is healthy"));
        vault.liquidate(borrower);
    }

}


