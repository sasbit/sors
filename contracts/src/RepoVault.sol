// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// On-chain settlement venue for institutional repo.
// Lenders deposit into a shared cash pool and receive pro-rata interest.
// Borrowers post approved collateral and draw cash against it.
// Supports term repo (fixed maturity) and open repo (notice-based termination).
// Matching / pricing stay off-chain; the vault enforces custody, collateralisation,
// margin, and access control.

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./ICollateralAdapter.sol";

contract RepoVault is AccessControl, Pausable {
    using SafeERC20 for IERC20;

    // ── Roles ─────────────────────────────────────────────────────────────────
    bytes32 public constant LENDER_ROLE     = keccak256("LENDER_ROLE");
    bytes32 public constant BORROWER_ROLE   = keccak256("BORROWER_ROLE");
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");

    // ── Collateral registry ───────────────────────────────────────────────────
    IERC20 public immutable cashToken;
    mapping(address => ICollateralAdapter) public adapterOf;
    mapping(address => bool) public collateralApproved; // gates new deposits; adapter stays for valuation
    address[] public collateralTokens;

    // ── Lending pool ──────────────────────────────────────────────────────────
    mapping(address => uint256) public lenderShares;
    uint256 public totalShares;
    uint256 public totalBorrowed; // principal outstanding, excludes accrued interest

    // ── Positions ─────────────────────────────────────────────────────────────
    struct Position {
        uint256 principal;
        uint256 rateBps;            // per-annum rate in basis points
        uint256 startTimestamp;     // when rate was last set / position opened
        uint256 interestAccrued;    // checkpointed before repricing or partial repay
        uint256 maturity;           // 0 = open repo; >0 = term repo expiry timestamp
        uint256 terminationAt;      // open repo: timestamp after which expire() callable
        uint256 marginCallAt;       // 0 = no active margin call
        bool    earlyTermProposed;  // borrower proposed early exit on a term repo
    }
    mapping(address => Position) private _positions;
    mapping(address => mapping(address => uint256)) public collateralOf;

    // ── Rollover offers (lender → borrower) ───────────────────────────────────
    struct RolloverOffer {
        uint256 newRateBps;
        uint256 newTermSeconds; // 0 = roll into open repo
        uint256 offerExpiry;
    }
    mapping(address => RolloverOffer) public pendingRollover;

    // ── Margin config ─────────────────────────────────────────────────────────
    // maintenanceMarginBps: collateral must cover at least (1 - bps/10000) of debt.
    // Must be lower than adapter haircutBps (initial margin). Example:
    //   haircutBps = 200 → can borrow up to 98% of collateral (initial margin = 102%)
    //   maintenanceMarginBps = 100 → called when debt > 99% of collateral (maintenance = 101%)
    uint256 public maintenanceMarginBps;

    // Where seized collateral is sent on liquidation or expiry.
    // IMPORTANT: collateral is not returned to the lending pool automatically.
    // The admin must sell seized collateral and call deposit() to return proceeds
    // to the pool, otherwise lenders absorb the loss from the reduced poolValue.
    address public collateralRecipient;

    uint256 public constant MAX_RATE_BPS          = 5_000; // 50% p.a. hard cap on repo rate
    uint256 public constant EARLY_TERM_GRACE      = 24 hours;
    uint256 public constant MAX_NOTICE_PERIOD     = 30 days; // cap on self-notice to prevent blocking admin
    uint256 public constant MAX_MAINTENANCE_BPS   = 9_999;   // must stay below 100% or every position is liquidatable

    // ── Events ────────────────────────────────────────────────────────────────
    event Deposited(address indexed lender, uint256 amount, uint256 shares);
    event Withdrawn(address indexed lender, uint256 amount, uint256 shares);
    event Opened(address indexed borrower, address indexed token, uint256 collateralAmt, uint256 cashAmt, uint256 rateBps, uint256 maturity);
    event CollateralPosted(address indexed borrower, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed borrower, address indexed token, uint256 amount);
    event CollateralSubstituted(address indexed borrower, address oldToken, uint256 oldAmt, address newToken, uint256 newAmt);
    event Repaid(address indexed borrower, uint256 principalPaid, uint256 interestPaid);
    event EarlyTerminationProposed(address indexed borrower);
    event EarlyTerminationAccepted(address indexed borrower);
    event TerminationNoticed(address indexed borrower, address indexed noticingParty, uint256 terminatesAt);
    event MarginCall(address indexed borrower);
    event MarginCallCleared(address indexed borrower);
    event Liquidated(address indexed borrower, uint256 debtCleared);
    event PositionExpired(address indexed borrower, uint256 debtCleared);
    event RolloverOffered(address indexed borrower, uint256 newRateBps, uint256 newTermSeconds, uint256 offerExpiry);
    event RolloverAccepted(address indexed borrower, uint256 newRateBps, uint256 newMaturity);
    event AdapterSet(address indexed token, address indexed adapter);
    event CollateralRevoked(address indexed token);
    event RepoRateUpdated(address indexed borrower, uint256 newRateBps);
    event CollateralRecipientUpdated(address indexed newRecipient);
    event MaintenanceMarginUpdated(uint256 newBps);

    constructor(
        address cashToken_,
        address admin_,
        uint256 maintenanceMarginBps_
    ) {
        require(cashToken_ != address(0), "zero cash token");
        require(admin_     != address(0), "zero admin");
        cashToken             = IERC20(cashToken_);
        maintenanceMarginBps  = maintenanceMarginBps_;
        collateralRecipient   = admin_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function approveLender(address a)     external onlyRole(DEFAULT_ADMIN_ROLE) { _grantRole(LENDER_ROLE, a); }
    function revokeLender(address a)      external onlyRole(DEFAULT_ADMIN_ROLE) { _revokeRole(LENDER_ROLE, a); }
    function approveBorrower(address a)   external onlyRole(DEFAULT_ADMIN_ROLE) { _grantRole(BORROWER_ROLE, a); }
    function revokeBorrower(address a)    external onlyRole(DEFAULT_ADMIN_ROLE) { _revokeRole(BORROWER_ROLE, a); }
    function approveLiquidator(address a) external onlyRole(DEFAULT_ADMIN_ROLE) { _grantRole(LIQUIDATOR_ROLE, a); }
    function revokeLiquidator(address a)  external onlyRole(DEFAULT_ADMIN_ROLE) { _revokeRole(LIQUIDATOR_ROLE, a); }

    function approveCollateral(address token, address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token   != address(0), "zero token");
        require(adapter != address(0), "zero adapter");
        require(ICollateralAdapter(adapter).token() == token, "adapter/token mismatch");
        if (address(adapterOf[token]) == address(0)) {
            collateralTokens.push(token);
        }
        adapterOf[token]        = ICollateralAdapter(adapter);
        collateralApproved[token] = true;
        emit AdapterSet(token, adapter);
    }

    // Revoke stops new deposits but keeps the adapter so existing positions remain valued.
    function revokeCollateral(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(collateralApproved[token], "not approved");
        collateralApproved[token] = false;
        emit CollateralRevoked(token);
    }

    // Open repos only: admin updates rate directly without borrower acceptance.
    function updateRepoRate(address borrower, uint256 newRateBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRateBps <= MAX_RATE_BPS, "rate exceeds cap");
        Position storage p = _positions[borrower];
        require(p.principal > 0, "no open position");
        require(p.maturity == 0, "not an open repo");
        p.interestAccrued = _interestOwed(borrower);
        p.startTimestamp  = block.timestamp;
        p.rateBps         = newRateBps;
        emit RepoRateUpdated(borrower, newRateBps);
    }

    function setMaintenanceMargin(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newBps <= MAX_MAINTENANCE_BPS, "maintenance margin too high");
        maintenanceMarginBps = newBps;
        emit MaintenanceMarginUpdated(newBps);
    }

    function setCollateralRecipient(address r) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(r != address(0), "zero address");
        collateralRecipient = r;
        emit CollateralRecipientUpdated(r);
    }

    function pause()   external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    // ── Lender ────────────────────────────────────────────────────────────────

    function deposit(uint256 amount) external onlyRole(LENDER_ROLE) whenNotPaused {
        require(amount > 0, "zero amount");
        uint256 pv = poolValue();
        uint256 sharesToMint = (totalShares == 0 || pv == 0)
            ? amount
            : amount * totalShares / pv;
        cashToken.safeTransferFrom(msg.sender, address(this), amount);
        lenderShares[msg.sender] += sharesToMint;
        totalShares              += sharesToMint;
        emit Deposited(msg.sender, amount, sharesToMint);
    }

    function withdraw(uint256 amount) external onlyRole(LENDER_ROLE) whenNotPaused {
        _withdrawCash(msg.sender, amount);
    }

    // Withdraw full entitlement (principal + share of accrued interest), up to freeCash.
    function withdrawWithInterest() external onlyRole(LENDER_ROLE) whenNotPaused {
        uint256 claim      = lenderClaim(msg.sender);
        uint256 withdrawable = claim < freeCash() ? claim : freeCash();
        require(withdrawable > 0, "nothing to withdraw");
        _withdrawCash(msg.sender, withdrawable);
    }

    // ── Borrower ──────────────────────────────────────────────────────────────

    // Atomically deposit collateral and open a position.
    // termSeconds == 0 → open repo. termSeconds > 0 → term repo.
    function open(
        address token,
        uint256 collateralAmt,
        uint256 cashAmt,
        uint256 rateBps,
        uint256 termSeconds
    ) external onlyRole(BORROWER_ROLE) whenNotPaused {
        require(collateralApproved[token], "token not approved");
        require(collateralAmt > 0, "zero collateral");
        require(cashAmt > 0, "zero cash");
        require(cashAmt <= freeCash(), "insufficient pool liquidity");
        require(rateBps <= MAX_RATE_BPS, "rate exceeds cap");
        require(_positions[msg.sender].principal == 0, "position already open");

        IERC20(token).safeTransferFrom(msg.sender, address(this), collateralAmt);
        collateralOf[msg.sender][token] += collateralAmt;

        Position storage p = _positions[msg.sender];
        p.principal      = cashAmt;
        p.rateBps        = rateBps;
        p.startTimestamp = block.timestamp;
        p.maturity       = termSeconds == 0 ? 0 : block.timestamp + termSeconds;

        require(isAboveInitialMargin(msg.sender), "below initial margin");
        totalBorrowed += cashAmt;
        cashToken.safeTransfer(msg.sender, cashAmt);
        emit Opened(msg.sender, token, collateralAmt, cashAmt, rateBps, p.maturity);
    }

    // Post additional collateral to an existing position (e.g. to cure a margin call).
    function postAdditionalCollateral(address token, uint256 amount) external onlyRole(BORROWER_ROLE) {
        require(collateralApproved[token], "token not approved");
        require(amount > 0, "zero amount");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        collateralOf[msg.sender][token] += amount;
        // clear margin call if now cured
        if (_positions[msg.sender].marginCallAt > 0 && isAboveMaintenanceMargin(msg.sender)) {
            _positions[msg.sender].marginCallAt = 0;
            emit MarginCallCleared(msg.sender);
        }
        emit CollateralPosted(msg.sender, token, amount);
    }

    // Atomically swap one collateral token for another without breaking collateralisation.
    function substituteCollateral(
        address oldToken,
        uint256 oldAmt,
        address newToken,
        uint256 newAmt
    ) external onlyRole(BORROWER_ROLE) whenNotPaused {
        require(collateralApproved[newToken], "new token not approved");
        require(collateralOf[msg.sender][oldToken] >= oldAmt, "insufficient old collateral");

        IERC20(newToken).safeTransferFrom(msg.sender, address(this), newAmt);
        collateralOf[msg.sender][newToken] += newAmt;
        collateralOf[msg.sender][oldToken] -= oldAmt;

        require(isAboveInitialMargin(msg.sender), "below initial margin after substitution");
        IERC20(oldToken).safeTransfer(msg.sender, oldAmt);
        emit CollateralSubstituted(msg.sender, oldToken, oldAmt, newToken, newAmt);
    }

    function repay(uint256 amount) external onlyRole(BORROWER_ROLE) {
        Position storage p = _positions[msg.sender];
        uint256 principal  = p.principal;
        require(principal > 0, "no open position");

        uint256 principalPayment = amount > principal ? principal : amount;
        uint256 newPrincipal     = principal - principalPayment;
        uint256 interestPayment  = 0;

        if (newPrincipal == 0) {
            interestPayment = _interestOwed(msg.sender);
            totalBorrowed  -= principal;
            _clearPosition(msg.sender);
        } else {
            // snapshot interest before reducing principal so the portion accrued
            // on the repaid amount is not forgiven at final close
            p.interestAccrued = _interestOwed(msg.sender);
            p.startTimestamp  = block.timestamp;
            p.principal       = newPrincipal;
            totalBorrowed    -= principalPayment;
        }

        cashToken.safeTransferFrom(msg.sender, address(this), principalPayment + interestPayment);
        emit Repaid(msg.sender, principalPayment, interestPayment);
    }

    // Withdraw excess collateral. Not allowed if it would breach initial margin.
    function withdrawCollateral(address token, uint256 amount) external onlyRole(BORROWER_ROLE) {
        require(collateralOf[msg.sender][token] >= amount, "insufficient collateral");
        collateralOf[msg.sender][token] -= amount;
        require(isAboveInitialMargin(msg.sender), "would breach initial margin");
        IERC20(token).safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, token, amount);
    }

    // Term repo only: borrower requests early exit. Lender must call acceptEarlyTermination.
    function proposeEarlyTermination() external onlyRole(BORROWER_ROLE) whenNotPaused {
        Position storage p = _positions[msg.sender];
        require(p.principal > 0, "no open position");
        require(p.maturity > 0, "use giveTerminationNotice for open repo");
        require(!p.earlyTermProposed, "already proposed");
        p.earlyTermProposed = true;
        emit EarlyTerminationProposed(msg.sender);
    }

    // Open repo only: borrower gives formal notice of intent to repay.
    function giveTerminationNotice(uint256 noticePeriodSeconds) external onlyRole(BORROWER_ROLE) whenNotPaused {
        require(noticePeriodSeconds <= MAX_NOTICE_PERIOD, "notice period too long");
        Position storage p = _positions[msg.sender];
        require(p.principal > 0, "no open position");
        require(p.maturity == 0, "not an open repo");
        require(p.terminationAt == 0, "notice already given");
        uint256 t = block.timestamp + noticePeriodSeconds;
        p.terminationAt = t;
        emit TerminationNoticed(msg.sender, msg.sender, t);
    }

    // Accept the lender's rollover offer.
    function acceptRollover() external onlyRole(BORROWER_ROLE) whenNotPaused {
        RolloverOffer memory offer = pendingRollover[msg.sender];
        require(offer.offerExpiry > 0, "no pending offer");
        require(block.timestamp <= offer.offerExpiry, "offer expired");
        Position storage p        = _positions[msg.sender];
        p.interestAccrued         = _interestOwed(msg.sender);
        p.startTimestamp          = block.timestamp;
        p.rateBps                 = offer.newRateBps;
        p.maturity                = offer.newTermSeconds == 0 ? 0 : block.timestamp + offer.newTermSeconds;
        p.terminationAt           = 0;
        // only clear margin call if the rolled position is now above maintenance margin
        if (p.marginCallAt > 0 && isAboveMaintenanceMargin(msg.sender)) {
            p.marginCallAt = 0;
        }
        p.earlyTermProposed       = false;
        delete pendingRollover[msg.sender];
        emit RolloverAccepted(msg.sender, offer.newRateBps, p.maturity);
    }

    // ── Admin: repo lifecycle ─────────────────────────────────────────────────

    // Offer new terms to any borrower (term or open repo).
    // newTermSeconds == 0 rolls into open repo.
    function offerRollover(
        address borrower,
        uint256 newRateBps,
        uint256 newTermSeconds,
        uint256 offerWindowSeconds
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_positions[borrower].principal > 0, "no open position");
        require(newRateBps <= MAX_RATE_BPS, "rate exceeds cap");
        uint256 expiry = block.timestamp + offerWindowSeconds;
        pendingRollover[borrower] = RolloverOffer(newRateBps, newTermSeconds, expiry);
        emit RolloverOffered(borrower, newRateBps, newTermSeconds, expiry);
    }

    // Accept borrower's early termination proposal. Sets maturity to now so repay closes cleanly.
    function acceptEarlyTermination(address borrower) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Position storage p = _positions[borrower];
        require(p.principal > 0, "no open position");
        require(p.earlyTermProposed, "no pending proposal");
        p.earlyTermProposed = false;
        p.maturity          = block.timestamp + EARLY_TERM_GRACE; // 24h for borrower to repay before expire() is callable
        emit EarlyTerminationAccepted(borrower);
    }

    // Open repo: lender gives formal termination notice.
    function notifyTermination(address borrower, uint256 noticePeriodSeconds) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Position storage p = _positions[borrower];
        require(p.principal > 0, "no open position");
        require(p.maturity == 0, "not an open repo");
        require(p.terminationAt == 0, "notice already given");
        uint256 t = block.timestamp + noticePeriodSeconds;
        p.terminationAt = t;
        emit TerminationNoticed(borrower, msg.sender, t);
    }

    // Expire a term repo past maturity, or an open repo past its termination notice.
    // Collateral is seized and sent to collateralRecipient.
    function expire(address borrower) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Position storage p = _positions[borrower];
        bool termExpired = p.maturity > 0 && block.timestamp >= p.maturity;
        bool openExpired = p.maturity == 0 && p.terminationAt > 0 && block.timestamp >= p.terminationAt;
        require(termExpired || openExpired, "not yet expirable");
        require(p.principal > 0, "no open position");
        uint256 debt = p.principal;
        totalBorrowed -= debt;
        _seizeCollateral(borrower);
        _clearPosition(borrower);
        emit PositionExpired(borrower, debt);
    }

    // ── Keeper ────────────────────────────────────────────────────────────────

    // Issue a margin call when position falls below maintenance margin.
    // Borrower should call postAdditionalCollateral to cure.
    function triggerMarginCall(address borrower) external onlyRole(LIQUIDATOR_ROLE) {
        require(!isAboveMaintenanceMargin(borrower), "above maintenance margin");
        Position storage p = _positions[borrower];
        require(p.marginCallAt == 0, "margin call already active");
        p.marginCallAt = block.timestamp;
        emit MarginCall(borrower);
    }

    // Liquidate a position that has an active margin call and is still underwater.
    function liquidate(address borrower) external onlyRole(LIQUIDATOR_ROLE) {
        require(_positions[borrower].marginCallAt > 0, "no margin call issued");
        require(!isAboveMaintenanceMargin(borrower), "position cured");
        uint256 debt = _positions[borrower].principal;
        totalBorrowed -= debt;
        _seizeCollateral(borrower);
        _clearPosition(borrower);
        emit Liquidated(borrower, debt);
    }

    // ── View ──────────────────────────────────────────────────────────────────

    // Total pool value: cash on hand + principal outstanding (interest increases pool when repaid).
    function poolValue() public view returns (uint256) {
        return cashToken.balanceOf(address(this)) + totalBorrowed;
    }

    function freeCash() public view returns (uint256) {
        return cashToken.balanceOf(address(this));
    }

    // Utilization: principal outstanding / total pool value (18 dp).
    function utilization() public view returns (uint256) {
        uint256 pv = poolValue();
        if (pv == 0) return 0;
        return totalBorrowed * 1e18 / pv;
    }

    function lenderClaim(address lender) public view returns (uint256) {
        if (totalShares == 0) return 0;
        return lenderShares[lender] * poolValue() / totalShares;
    }

    function lenderDeposits(address lender) external view returns (uint256) {
        return lenderClaim(lender);
    }

    function lenderShare(address lender) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return lenderShares[lender] * 1e18 / totalShares;
    }

    function totalDebt(address borrower) public view returns (uint256) {
        return _positions[borrower].principal + _interestOwed(borrower);
    }

    function interestOwed(address borrower) public view returns (uint256) {
        return _interestOwed(borrower);
    }

    // Cash value of an arbitrary amount of a token (useful for keepers checking margin).
    function collateralValueInCash(address token, uint256 amount) public view returns (uint256) {
        ICollateralAdapter adapter = adapterOf[token];
        if (address(adapter) == address(0)) return 0;
        return amount * adapter.nav() / (10 ** adapter.decimals());
    }

    function tokenCollateralValue(address token, address borrower) public view returns (uint256) {
        return collateralValueInCash(token, collateralOf[borrower][token]);
    }

    function totalCollateralValue(address borrower) public view returns (uint256) {
        uint256 total;
        uint256 len = collateralTokens.length;
        for (uint256 i; i < len; ++i) {
            total += tokenCollateralValue(collateralTokens[i], borrower);
        }
        return total;
    }

    // Max cash borrowable against current collateral at initial margin (per-token haircut).
    function maxBorrow(address borrower) public view returns (uint256) {
        uint256 total;
        uint256 len = collateralTokens.length;
        for (uint256 i; i < len; ++i) {
            address tok = collateralTokens[i];
            ICollateralAdapter adapter = adapterOf[tok];
            if (address(adapter) == address(0)) continue;
            uint256 value = tokenCollateralValue(tok, borrower);
            total += value * (10_000 - adapter.haircutBps()) / 10_000;
        }
        return total;
    }

    function isAboveInitialMargin(address borrower) public view returns (bool) {
        return totalDebt(borrower) <= maxBorrow(borrower);
    }

    function isAboveMaintenanceMargin(address borrower) public view returns (bool) {
        uint256 debt = totalDebt(borrower);
        if (debt == 0) return true;
        return totalCollateralValue(borrower) * (10_000 - maintenanceMarginBps) / 10_000 >= debt;
    }

    function isOpenRepo(address borrower) public view returns (bool) {
        return _positions[borrower].principal > 0 && _positions[borrower].maturity == 0;
    }

    function positions(address borrower) external view returns (Position memory) {
        return _positions[borrower];
    }

    function collateralTokenCount() external view returns (uint256) {
        return collateralTokens.length;
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    function _interestOwed(address borrower) internal view returns (uint256) {
        Position storage p = _positions[borrower];
        if (p.principal == 0) return 0;
        uint256 elapsed  = block.timestamp - p.startTimestamp;
        uint256 accruing = p.principal * p.rateBps * elapsed / (365 days * 10_000);
        return p.interestAccrued + accruing;
    }

    function _withdrawCash(address lender, uint256 amount) internal {
        require(amount > 0, "zero amount");
        require(amount <= freeCash(), "insufficient free cash");
        uint256 pv           = poolValue();
        uint256 sharesToBurn = amount * totalShares / pv;
        require(lenderShares[lender] >= sharesToBurn, "insufficient shares");
        lenderShares[lender] -= sharesToBurn;
        totalShares          -= sharesToBurn;
        cashToken.safeTransfer(lender, amount);
        emit Withdrawn(lender, amount, sharesToBurn);
    }

    function _seizeCollateral(address borrower) internal {
        uint256 len = collateralTokens.length;
        for (uint256 i; i < len; ++i) {
            address token  = collateralTokens[i];
            uint256 amount = collateralOf[borrower][token];
            if (amount == 0) continue;
            collateralOf[borrower][token] = 0;
            IERC20(token).safeTransfer(collateralRecipient, amount);
        }
    }

    function _clearPosition(address borrower) internal {
        delete _positions[borrower];
    }
}
