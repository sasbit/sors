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
    MockBUIDL               internal ousg;
    MockUSDC                internal usdc;
    SimpleCollateralAdapter internal buidlAdapter;
    SimpleCollateralAdapter internal ousgAdapter;
    RepoVault               internal vault;

    address internal lender;
    address internal borrower;
    address internal keeper; // liquidator role

    uint256 internal constant NAV          = 1e6;  // 1 whole token = 1 mUSDC
    uint256 internal constant HAIRCUT      = 200;  // 2% initial margin
    uint256 internal constant MAINTENANCE  = 100;  // 1% maintenance margin

    function setUp() public {
        buidl = new MockBUIDL(address(this));
        ousg  = new MockBUIDL(address(this));
        usdc  = new MockUSDC(address(this));

        // test contract is DEFAULT_ADMIN_ROLE
        vault = new RepoVault(address(usdc), address(this), MAINTENANCE);

        buidlAdapter = new SimpleCollateralAdapter(address(buidl), 18, NAV, HAIRCUT, address(this));
        ousgAdapter  = new SimpleCollateralAdapter(address(ousg),  18, NAV, HAIRCUT, address(this));

        vault.approveCollateral(address(buidl), address(buidlAdapter));
        vault.approveCollateral(address(ousg),  address(ousgAdapter));

        lender   = makeAddr("lender");
        borrower = makeAddr("borrower");
        keeper   = makeAddr("keeper");

        vault.approveLender(lender);
        vault.approveBorrower(borrower);
        vault.approveLiquidator(keeper);

        // fund lender and borrower
        usdc.transfer(lender, 100_000e6);
        buidl.transfer(borrower, 200e18);
        ousg.transfer(borrower,  200e18);

        vm.startPrank(lender);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(borrower);
        buidl.approve(address(vault), type(uint256).max);
        ousg.approve(address(vault),  type(uint256).max);
        usdc.approve(address(vault),  type(uint256).max);
        vm.stopPrank();
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _lenderDeposit(uint256 amount) internal {
        vm.prank(lender);
        vault.deposit(amount);
    }

    function _borrowerOpen(uint256 cash, uint256 termSeconds) internal {
        vm.prank(borrower);
        vault.open(address(buidl), 100e18, cash, 0, termSeconds);
    }

    // ── Lender pool ───────────────────────────────────────────────────────────

    function test_LenderDeposit_SharesIssued() public {
        _lenderDeposit(1_000e6);
        assertEq(vault.lenderShares(lender), 1_000e6);
        assertEq(vault.totalShares(), 1_000e6);
        assertEq(vault.poolValue(), 1_000e6);
        assertEq(vault.freeCash(), 1_000e6);
    }

    function test_LenderWithdraw() public {
        _lenderDeposit(1_000e6);
        vm.prank(lender);
        vault.withdraw(500e6);
        assertEq(usdc.balanceOf(lender), 100_000e6 - 500e6); // got 500 back
        assertEq(vault.freeCash(), 500e6);
    }

    function test_LenderWithdrawWithInterest() public {
        _lenderDeposit(1_000e6);
        _borrowerOpen(98e6, 30 days); // borrow at 0% for simplicity

        // simulate interest repaid — transfer 10 mUSDC to vault (represents interest collected)
        usdc.transfer(address(vault), 10e6);

        // lender's claim is now 1000 + 10 = 1010 (but only freeCash = 912 available)
        // freeCash = 1000 deposited - 98 borrowed + 10 interest = 912
        assertEq(vault.freeCash(), 912e6);
        assertTrue(vault.lenderClaim(lender) > 1_000e6); // has grown

        vm.prank(lender);
        vault.withdrawWithInterest();
        // lender withdrew all available free cash
        assertTrue(usdc.balanceOf(lender) > 100_000e6 - 1_000e6 + 912e6 - 1); // got back most
    }

    function test_Utilization() public {
        _lenderDeposit(1_000e6);
        assertEq(vault.utilization(), 0);
        buidl.transfer(borrower, 400e18); // top up so borrower has 600 total
        vm.prank(borrower);
        vault.open(address(buidl), 600e18, 500e6, 0, 30 days); // maxBorrow=588, borrow 500
        // utilization = 500 / (500 free + 500 borrowed) = 50%
        assertEq(vault.utilization(), 0.5e18);
    }

    function test_FreeCash_DecreasesOnBorrow() public {
        _lenderDeposit(1_000e6);
        _borrowerOpen(98e6, 30 days);
        assertEq(vault.freeCash(), 902e6);
    }

    // ── Open / repay ──────────────────────────────────────────────────────────

    function test_Open_And_Repay() public {
        _lenderDeposit(1_000e6);
        vm.prank(borrower);
        vault.open(address(buidl), 100e18, 98e6, 0, 30 days);

        assertEq(vault.positions(borrower).principal, 98e6);
        assertEq(vault.totalDebt(borrower), 98e6);
        assertTrue(vault.isAboveInitialMargin(borrower));

        vm.prank(borrower);
        vault.repay(98e6);

        assertEq(vault.positions(borrower).principal, 0);
        assertEq(vault.totalBorrowed(), 0);
    }

    function test_RevertWhen_OpenBelowInitialMargin() public {
        _lenderDeposit(1_000e6);
        vm.prank(borrower);
        vm.expectRevert(bytes("below initial margin"));
        vault.open(address(buidl), 100e18, 99e6, 0, 30 days); // 99% > 98% max
    }

    function test_PartialRepay() public {
        _lenderDeposit(1_000e6);
        _borrowerOpen(98e6, 30 days);

        vm.prank(borrower);
        vault.repay(50e6);

        assertEq(vault.positions(borrower).principal, 48e6);
        assertEq(vault.totalBorrowed(), 48e6);
    }

    function test_RepayWithInterest() public {
        _lenderDeposit(1_000e6);
        vm.prank(borrower);
        vault.open(address(buidl), 100e18, 98e6, 100, 365 days); // 1% p.a.

        vm.warp(block.timestamp + 365 days);
        assertEq(vault.interestOwed(borrower), 980_000); // 98e6 * 1%

        usdc.transfer(borrower, 980_000); // top up borrower for interest
        vm.prank(borrower);
        vault.repay(98_980_000); // principal + interest

        assertEq(vault.positions(borrower).principal, 0);
        assertEq(vault.interestOwed(borrower), 0);
    }

    // ── Multi-token collateral ────────────────────────────────────────────────

    function test_MultiToken_CombinedValue() public {
        _lenderDeposit(1_000e6);
        vm.prank(borrower);
        vault.open(address(buidl), 100e18, 98e6, 0, 30 days);

        vm.prank(borrower);
        vault.postAdditionalCollateral(address(ousg), 100e18);

        assertEq(vault.totalCollateralValue(borrower), 200e6);
        assertEq(vault.maxBorrow(borrower), 196e6);
    }

    function test_SubstituteCollateral() public {
        _lenderDeposit(1_000e6);
        vm.prank(borrower);
        vault.open(address(buidl), 100e18, 98e6, 0, 30 days);

        // swap 50 buidl for 60 ousg (more than enough to maintain margin)
        vm.prank(borrower);
        vault.substituteCollateral(address(buidl), 50e18, address(ousg), 60e18);

        assertEq(vault.collateralOf(borrower, address(buidl)), 50e18);
        assertEq(vault.collateralOf(borrower, address(ousg)),  60e18);
        assertTrue(vault.isAboveInitialMargin(borrower));
    }

    function test_RevertWhen_SubstituteCollateral_BreachesMargin() public {
        _lenderDeposit(1_000e6);
        vm.prank(borrower);
        vault.open(address(buidl), 100e18, 98e6, 0, 30 days);

        // try to swap 100 buidl for only 1 ousg (insufficient)
        vm.prank(borrower);
        vm.expectRevert(bytes("below initial margin after substitution"));
        vault.substituteCollateral(address(buidl), 100e18, address(ousg), 1e18);
    }

    // ── Margin call & liquidation ─────────────────────────────────────────────

    function test_TriggerMarginCall_WhenBelowMaintenance() public {
        _lenderDeposit(1_000e6);
        _borrowerOpen(98e6, 30 days);

        // drop NAV so collateralValue falls from 100 to 98.5:
        // debt=98, maintenance threshold = 98.5 * 99% = 97.5 < 98 → margin call zone
        SimpleCollateralAdapter lowNavAdapter = new SimpleCollateralAdapter(
            address(buidl), 18, 0.985e6, HAIRCUT, address(this)
        );
        vault.approveCollateral(address(buidl), address(lowNavAdapter));

        assertFalse(vault.isAboveMaintenanceMargin(borrower));

        vm.prank(keeper);
        vault.triggerMarginCall(borrower);

        assertGt(vault.positions(borrower).marginCallAt, 0);
    }

    function test_MarginCallCleared_OnCure() public {
        _lenderDeposit(1_000e6);
        _borrowerOpen(98e6, 30 days);

        SimpleCollateralAdapter lowNavAdapter = new SimpleCollateralAdapter(
            address(buidl), 18, 0.985e6, HAIRCUT, address(this)
        );
        vault.approveCollateral(address(buidl), address(lowNavAdapter));
        vm.prank(keeper);
        vault.triggerMarginCall(borrower);
        assertGt(vault.positions(borrower).marginCallAt, 0);

        // borrower posts enough collateral to cure
        vm.prank(borrower);
        vault.postAdditionalCollateral(address(buidl), 20e18); // pushes value well above maintenance
        assertEq(vault.positions(borrower).marginCallAt, 0); // cleared
    }

    function test_Liquidate_AfterMarginCall() public {
        _lenderDeposit(1_000e6);
        _borrowerOpen(98e6, 30 days);

        SimpleCollateralAdapter lowNavAdapter = new SimpleCollateralAdapter(
            address(buidl), 18, 0.97e6, HAIRCUT, address(this)
        );
        vault.approveCollateral(address(buidl), address(lowNavAdapter));
        vm.prank(keeper);
        vault.triggerMarginCall(borrower);

        uint256 recipientBefore = buidl.balanceOf(address(this));
        vm.prank(keeper);
        vault.liquidate(borrower);

        assertEq(vault.positions(borrower).principal, 0);
        assertEq(buidl.balanceOf(address(this)), recipientBefore + 100e18);
    }

    function test_RevertWhen_TriggerMarginCall_WhenHealthy() public {
        _lenderDeposit(1_000e6);
        _borrowerOpen(98e6, 30 days);
        vm.prank(keeper);
        vm.expectRevert(bytes("above maintenance margin"));
        vault.triggerMarginCall(borrower);
    }

    function test_RevertWhen_Liquidate_WithoutMarginCall() public {
        _lenderDeposit(1_000e6);
        _borrowerOpen(98e6, 30 days);

        SimpleCollateralAdapter lowNavAdapter = new SimpleCollateralAdapter(
            address(buidl), 18, 0.97e6, HAIRCUT, address(this)
        );
        vault.approveCollateral(address(buidl), address(lowNavAdapter));

        vm.prank(keeper);
        vm.expectRevert(bytes("no margin call issued"));
        vault.liquidate(borrower);
    }

    // ── Term repo: expire & rollover ──────────────────────────────────────────

    function test_Expire_AfterMaturity() public {
        _lenderDeposit(1_000e6);
        _borrowerOpen(98e6, 7 days);

        vm.warp(block.timestamp + 7 days + 1);

        uint256 recipientBefore = buidl.balanceOf(address(this));
        vault.expire(borrower);

        assertEq(vault.positions(borrower).principal, 0);
        assertEq(buidl.balanceOf(address(this)), recipientBefore + 100e18);
    }

    function test_RevertWhen_Expire_BeforeMaturity() public {
        _lenderDeposit(1_000e6);
        _borrowerOpen(98e6, 7 days);
        vm.warp(block.timestamp + 6 days);
        vm.expectRevert(bytes("not yet expirable"));
        vault.expire(borrower);
    }

    function test_EarlyTermination_Flow() public {
        _lenderDeposit(1_000e6);
        _borrowerOpen(98e6, 30 days);

        vm.prank(borrower);
        vault.proposeEarlyTermination();
        assertTrue(vault.positions(borrower).earlyTermProposed);

        vault.acceptEarlyTermination(borrower);
        assertFalse(vault.positions(borrower).earlyTermProposed);
        assertEq(vault.positions(borrower).maturity, block.timestamp + 24 hours);
    }

    function test_Rollover_TermToTerm() public {
        _lenderDeposit(1_000e6);
        _borrowerOpen(98e6, 7 days);

        vault.offerRollover(borrower, 200, 30 days, 1 days);
        vm.prank(borrower);
        vault.acceptRollover();

        assertEq(vault.positions(borrower).rateBps, 200);
        assertEq(vault.positions(borrower).maturity, block.timestamp + 30 days);
    }

    function test_Rollover_TermToOpen() public {
        _lenderDeposit(1_000e6);
        _borrowerOpen(98e6, 7 days);

        vault.offerRollover(borrower, 150, 0, 1 days); // 0 = open repo
        vm.prank(borrower);
        vault.acceptRollover();

        assertTrue(vault.isOpenRepo(borrower));
        assertEq(vault.positions(borrower).maturity, 0);
    }

    function test_RevertWhen_AcceptExpiredOffer() public {
        _lenderDeposit(1_000e6);
        _borrowerOpen(98e6, 7 days);
        vault.offerRollover(borrower, 200, 30 days, 1 days);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(borrower);
        vm.expectRevert(bytes("offer expired"));
        vault.acceptRollover();
    }

    // ── Open repo: termination ────────────────────────────────────────────────

    function test_OpenRepo_LenderTermination() public {
        _lenderDeposit(1_000e6);
        vm.prank(borrower);
        vault.open(address(buidl), 100e18, 98e6, 0, 0); // open repo

        vault.notifyTermination(borrower, 1 days);
        vm.warp(block.timestamp + 1 days + 1);

        uint256 recipientBefore = buidl.balanceOf(address(this));
        vault.expire(borrower);
        assertEq(buidl.balanceOf(address(this)), recipientBefore + 100e18);
    }

    function test_OpenRepo_BorrowerTermination() public {
        _lenderDeposit(1_000e6);
        vm.prank(borrower);
        vault.open(address(buidl), 100e18, 98e6, 0, 0);

        vm.prank(borrower);
        vault.giveTerminationNotice(1 days);

        vm.warp(block.timestamp + 1 days + 1);
        vault.expire(borrower);
        assertEq(vault.positions(borrower).principal, 0);
    }

    function test_OpenRepo_UpdateRepoRate() public {
        _lenderDeposit(1_000e6);
        vm.prank(borrower);
        vault.open(address(buidl), 100e18, 98e6, 100, 0); // 1% p.a., open repo

        vm.warp(block.timestamp + 180 days);
        vault.updateRepoRate(borrower, 200); // 2% p.a. going forward

        // interest before rate change is snapshotted correctly
        uint256 interestAt180 = vault.positions(borrower).interestAccrued;
        assertGt(interestAt180, 0);
        assertEq(vault.positions(borrower).rateBps, 200);
        assertEq(vault.positions(borrower).startTimestamp, block.timestamp);
    }

    // ── Access control ────────────────────────────────────────────────────────

    function test_RevertWhen_UnauthorisedDeposit() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert();
        vault.deposit(100e6);
    }

    function test_RevertWhen_UnauthorisedOpen() public {
        _lenderDeposit(1_000e6);
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert();
        vault.open(address(buidl), 100e18, 98e6, 0, 30 days);
    }

    function test_Pause_BlocksDeposit() public {
        vault.pause();
        vm.prank(lender);
        vm.expectRevert();
        vault.deposit(100e6);
    }

    function test_Unpause_RestoresDeposit() public {
        vault.pause();
        vault.unpause();
        _lenderDeposit(1_000e6);
        assertEq(vault.freeCash(), 1_000e6);
    }

    // ── Chainlink adapter ─────────────────────────────────────────────────────

    function test_ChainlinkAdapter_NavFromFeed() public {
        _lenderDeposit(1_000e6);
        MockV3Aggregator feed = new MockV3Aggregator(8, 1_05_000_000); // $1.05
        ChainLinkCollateralAdapter clAdapter = new ChainLinkCollateralAdapter(
            address(buidl), 18, address(feed), 26 hours, HAIRCUT, address(this)
        );
        vault.approveCollateral(address(buidl), address(clAdapter));

        vm.prank(borrower);
        vault.open(address(buidl), 100e18, 100e6, 0, 30 days); // 100 * 1.05 * 98% = 102.9 max

        assertEq(vault.totalCollateralValue(borrower), 105e6);
        assertTrue(vault.isAboveInitialMargin(borrower));
    }

    function test_ChainlinkAdapter_RevertWhen_Stale() public {
        _lenderDeposit(1_000e6);
        MockV3Aggregator feed = new MockV3Aggregator(8, 1_00_000_000);
        ChainLinkCollateralAdapter clAdapter = new ChainLinkCollateralAdapter(
            address(buidl), 18, address(feed), 26 hours, HAIRCUT, address(this)
        );
        vault.approveCollateral(address(buidl), address(clAdapter));
        vm.prank(borrower);
        vault.open(address(buidl), 100e18, 98e6, 0, 30 days);

        vm.warp(block.timestamp + 27 hours);
        vm.expectRevert(bytes("stale price"));
        vault.totalCollateralValue(borrower);
    }

    // ── Adapter management ────────────────────────────────────────────────────

    function test_RevokeCollateral_BlocksNewDeposits() public {
        vault.revokeCollateral(address(buidl));
        _lenderDeposit(1_000e6);
        vm.prank(borrower);
        vm.expectRevert(bytes("token not approved"));
        vault.open(address(buidl), 100e18, 98e6, 0, 30 days);
    }

    function test_AdapterReplacement_NewNavTakesEffect() public {
        _lenderDeposit(1_000e6);
        _borrowerOpen(98e6, 30 days);
        assertEq(vault.maxBorrow(borrower), 98e6);

        SimpleCollateralAdapter newAdapter = new SimpleCollateralAdapter(
            address(buidl), 18, 2e6, HAIRCUT, address(this) // NAV doubled
        );
        vault.approveCollateral(address(buidl), address(newAdapter));
        assertEq(vault.maxBorrow(borrower), 196e6);
    }

    // ── E2E test: full lifecycle ───────────────────────────────────────────────

    function test_E2E_FullLifecycle() public {
        // 1. Lender deposits 10,000 mUSDC into the pool
        _lenderDeposit(10_000e6);
        assertEq(vault.poolValue(), 10_000e6);
        assertEq(vault.utilization(), 0);

        // 2. Borrower opens a 30-day term repo: posts 1000 mBUIDL, draws 980 mUSDC at 2% p.a.
        buidl.transfer(borrower, 900e18); // give borrower more collateral
        vm.prank(borrower);
        vault.open(address(buidl), 1_000e18, 980e6, 200, 30 days);

        assertEq(vault.positions(borrower).principal, 980e6);
        assertEq(vault.totalBorrowed(), 980e6);
        assertApproxEqAbs(vault.utilization(), 0.098e18, 0.001e18); // ~9.8%
        assertTrue(vault.isAboveInitialMargin(borrower));
        assertEq(vault.freeCash(), 9_020e6);

        // 3. Time passes — 15 days. Check interest.
        vm.warp(block.timestamp + 15 days);
        uint256 interest15d = vault.interestOwed(borrower);
        // 980 * 2% * 15/365 ≈ 805,479 μUSDC
        assertGt(interest15d, 0);
        assertLt(interest15d, 1e6); // less than 1 mUSDC for 15 days at 2% on 980

        // 4. NAV dips slightly — position enters maintenance margin zone
        SimpleCollateralAdapter lowNavAdapter = new SimpleCollateralAdapter(
            address(buidl), 18, 0.985e6, HAIRCUT, address(this) // 1000 * 0.985 * 98% = 964.3 < 980
        );
        vault.approveCollateral(address(buidl), address(lowNavAdapter));
        assertFalse(vault.isAboveMaintenanceMargin(borrower));

        // 5. Keeper triggers margin call
        vm.prank(keeper);
        vault.triggerMarginCall(borrower);
        assertGt(vault.positions(borrower).marginCallAt, 0);

        // 6. Borrower cures by posting 50 more mBUIDL
        vm.prank(borrower);
        vault.postAdditionalCollateral(address(buidl), 50e18);
        assertEq(vault.positions(borrower).marginCallAt, 0); // cleared

        // 7. NAV recovers. Lender offers a 60-day rollover at 1.5% p.a.
        vm.warp(block.timestamp + 15 days); // at original 30-day maturity
        vault.approveCollateral(address(buidl), address(buidlAdapter)); // reset to NAV=1
        vault.offerRollover(borrower, 150, 60 days, 1 days);

        vm.prank(borrower);
        vault.acceptRollover();
        assertEq(vault.positions(borrower).rateBps, 150);
        assertEq(vault.positions(borrower).maturity, block.timestamp + 60 days);
        assertGt(vault.positions(borrower).interestAccrued, 0); // 30 days of interest snapshotted

        // 8. 60 days pass, borrower repays in full (principal + total interest)
        vm.warp(block.timestamp + 60 days);
        uint256 finalDebt = vault.totalDebt(borrower);
        assertGt(finalDebt, 980e6); // interest on top
        usdc.transfer(borrower, finalDebt - 980e6); // top up borrower with interest amount
        vm.prank(borrower);
        vault.repay(finalDebt);

        assertEq(vault.positions(borrower).principal, 0);
        assertEq(vault.totalBorrowed(), 0);

        // 9. Lender withdraws with interest — pool value > 10,000 (interest collected)
        assertTrue(vault.poolValue() > 10_000e6);
        assertTrue(vault.lenderClaim(lender) > 10_000e6);
        vm.prank(lender);
        vault.withdrawWithInterest();
        assertTrue(usdc.balanceOf(lender) > 100_000e6 - 10_000e6); // recovered more than principal
    }

    function test_PartialRepay_InterestCarriedForward() public {
        _lenderDeposit(1_000e6);
        vm.prank(borrower);
        vault.open(address(buidl), 100e18, 98e6, 100, 365 days); // 1% p.a.

        // after 1 year: interest = 98e6 * 1% = 980_000
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.interestOwed(borrower), 980_000);

        // partial repay 49e6 principal — this resets the clock
        vm.prank(borrower);
        vault.repay(49e6);
        assertEq(vault.positions(borrower).principal, 49e6);

        // interestAccrued checkpoint must hold the 980_000 already earned
        assertEq(vault.positions(borrower).interestAccrued, 980_000);

        // another year on the remaining 49e6 at 1%: +490_000
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.interestOwed(borrower), 980_000 + 490_000);

        // full close: pay remaining 49e6 principal + 1_470_000 total interest
        usdc.transfer(borrower, 980_000 + 490_000);
        vm.prank(borrower);
        vault.repay(49e6 + 980_000 + 490_000);

        assertEq(vault.positions(borrower).principal, 0);
        assertEq(vault.interestOwed(borrower), 0);
    }

    function test_RepayWorksWhenPaused() public {
    _lenderDeposit(1_000e6);
    _borrowerOpen(98e6, 30 days);

    vault.pause();

    // repay must still work
    vm.prank(borrower);
    vault.repay(98e6); // should NOT revert
    assertEq(vault.positions(borrower).principal, 0);
}

    function test_PostCollateralWorksWhenPaused() public {
        _lenderDeposit(1_000e6);
        _borrowerOpen(98e6, 30 days);

        SimpleCollateralAdapter lowNav = new SimpleCollateralAdapter(
            address(buidl), 18, 0.985e6, HAIRCUT, address(this)
        );
        vault.approveCollateral(address(buidl), address(lowNav));
        vm.prank(keeper);
        vault.triggerMarginCall(borrower);

        vault.pause();

        // borrower must still be able to cure
        vm.prank(borrower);
        vault.postAdditionalCollateral(address(buidl), 50e18); // should NOT revert
    }

    function test_TwoLenders_ProportionalInterest() public {
        address lender2 = makeAddr("lender2");
        vault.approveLender(lender2);
        usdc.transfer(lender2, 1_000e6);
        vm.prank(lender2);
        usdc.approve(address(vault), type(uint256).max);

        // lender1 deposits 1000, lender2 deposits 1000
        _lenderDeposit(1_000e6);
        vm.prank(lender2);
        vault.deposit(1_000e6);

        // borrower opens and repays with 100e6 interest
        vm.prank(borrower);
        vault.open(address(buidl), 100e18, 98e6, 0, 30 days);
        usdc.transfer(address(vault), 100e6); // simulate interest landing in vault

        // both should have equal claims (deposited equally)
        assertApproxEqAbs(vault.lenderClaim(lender), vault.lenderClaim(lender2), 1);

        // each should have claim > their original 1000 deposit
        assertTrue(vault.lenderClaim(lender) > 1_000e6);
    }

    function test_LenderCannotWithdrawBorrowedCash() public {
        _lenderDeposit(1_000e6);
        _borrowerOpen(98e6, 30 days); // 98 of 1000 is now borrowed

        // lender tries to withdraw 1000 — only 902 is free
        vm.prank(lender);
        vm.expectRevert(bytes("insufficient free cash"));
        vault.withdraw(1_000e6);

        // 902 should succeed
        vm.prank(lender);
        vault.withdraw(902e6);
    }

    function test_RevertWhen_PoolDry() public {
        _lenderDeposit(100e6); // only 100 in pool

        vm.prank(borrower);
        vm.expectRevert(bytes("insufficient pool liquidity"));
        vault.open(address(buidl), 100e18, 101e6, 0, 30 days); // trying to borrow 101
    }

    function test_ExpireRespects24hGraceAfterEarlyTerm() public {
        _lenderDeposit(1_000e6);
        _borrowerOpen(98e6, 30 days);

        vm.prank(borrower);
        vault.proposeEarlyTermination();
        vault.acceptEarlyTermination(borrower);

        // immediately after acceptance: should NOT be expirable
        vm.expectRevert(bytes("not yet expirable"));
        vault.expire(borrower);

        // after 24h: expirable
        vm.warp(block.timestamp + 24 hours + 1);
        vault.expire(borrower); // should succeed
    }

    function test_RevertWhen_RateExceedsCap() public {
        _lenderDeposit(1_000e6);
        vm.prank(borrower);
        vault.open(address(buidl), 100e18, 98e6, 0, 0); // open repo

        vm.expectRevert(bytes("rate exceeds cap"));
        vault.updateRepoRate(borrower, 5_001); // 50.01% p.a.
    }
}
