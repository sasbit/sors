// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// On-chain settlement venue — escrows tokenized treasury collateral and lets a borrower
// draw cash against it, capped by a per-token haircut. Supports multiple collateral tokens
// via an ICollateralAdapter registry. Matching/pricing stays off-chain; the vault enforces
// custody + collateralisation.

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./ICollateralAdapter.sol";

contract RepoVault is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable cashToken; // 6-decimal stablecoin (mUSDC / USDC)

    // token address → adapter; zero address means the token is not registered
    mapping(address => ICollateralAdapter) public adapterOf;
    // enumerable list used for collateral-value loops
    address[] public collateralTokens;

    // borrower → token → escrowed amount (native token units)
    mapping(address => mapping(address => uint256)) public collateralOf;
    // borrower → cash drawn (6 dp)
    mapping(address => uint256) public debtOf;
    // KYC allowlist
    mapping(address => bool) public whitelisted;
    // interest rate maps
    mapping(address => uint256) public borrowTimestamp; //when position was opened
    mapping(address => uint256) public borrowRateBps; //rate per annum
    mapping(address => uint256) public interestAccrued; //checkpointed interest before last clock reset

    event AdapterSet(address indexed token, address indexed adapter);
    event CashFunded(address indexed from, uint256 amount);
    event CollateralDeposited(address indexed borrower, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed borrower, address indexed token, uint256 amount);
    event Borrowed(address indexed borrower, uint256 amount);
    event Repaid(address indexed borrower, uint256 amount);
    event Whitelisted(address indexed account, bool status);
    event Liquidated(address indexed borrower, uint256 debt);
    
    
    constructor(address cashToken_, address initialOwner) Ownable(initialOwner) {
        require(cashToken_ != address(0), "zero cash token");
        cashToken = IERC20(cashToken_);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    // Register a new collateral token or replace an existing adapter (e.g. to upgrade
    // from admin-NAV to an oracle-backed version). Cannot set adapter to zero — existing
    // positions must always have a valid pricer. To retire a token, deploy an adapter
    // with haircutBps = 10_000 (zero borrowing capacity).
    function setAdapter(address token, address adapter) external onlyOwner {
        require(token   != address(0), "zero token");
        require(adapter != address(0), "zero adapter");
        require(ICollateralAdapter(adapter).token() == token, "adapter/token mismatch");
        if (address(adapterOf[token]) == address(0)) {
            collateralTokens.push(token); // first registration — add to enumerable list
        }
        adapterOf[token] = ICollateralAdapter(adapter);
        emit AdapterSet(token, adapter);
    }

    function setWhiteListed(address account, bool status) external onlyOwner {
        whitelisted[account] = status;
        emit Whitelisted(account, status);
    }

    // ── Lender ────────────────────────────────────────────────────────────────

    function fundCash(uint256 amount) external {
        cashToken.safeTransferFrom(msg.sender, address(this), amount);
        emit CashFunded(msg.sender, amount);
    }

    // ── Borrower ──────────────────────────────────────────────────────────────
    function depositCollateral(address token, uint256 amount) external {
        require(whitelisted[msg.sender], "not whitelisted");
        require(address(adapterOf[token]) != address(0), "token not registered");
        require(amount > 0, "zero amount");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        collateralOf[msg.sender][token] += amount;
        emit CollateralDeposited(msg.sender, token, amount);
    }

    function withdrawCollateral(address token, uint256 amount) external {
        require(collateralOf[msg.sender][token] >= amount, "insufficient collateral");
        collateralOf[msg.sender][token] -= amount;
        require(debtOf[msg.sender] <= maxBorrow(msg.sender), "would undercollateralize");
        IERC20(token).safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, token, amount);
    }

    function borrow(uint256 amount, uint256 rateBps) external {
        require(whitelisted[msg.sender], "not whitelisted");
        require(amount > 0, "zero amount");
        if (debtOf[msg.sender] == 0) {
            borrowTimestamp[msg.sender] = block.timestamp;
            borrowRateBps[msg.sender] = rateBps;
        } else {
            require(rateBps == borrowRateBps[msg.sender], "rate mismatch");
        }
        debtOf[msg.sender] += amount;
        require(debtOf[msg.sender] <= maxBorrow(msg.sender), "exceeds max borrow");
        cashToken.safeTransfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        uint256 principal        = debtOf[msg.sender];
        uint256 principalPayment = amount > principal ? principal : amount;
        uint256 newPrincipal     = principal - principalPayment;

        uint256 interestPayment = 0;
        if (newPrincipal == 0) {
            interestPayment             = interestOwed(msg.sender); // read before zeroing debtOf
            interestAccrued[msg.sender] = 0;
            borrowTimestamp[msg.sender] = 0;
            borrowRateBps[msg.sender]   = 0;
        }

        debtOf[msg.sender] = newPrincipal;
        cashToken.safeTransferFrom(msg.sender, address(this), principalPayment + interestPayment);
        emit Repaid(msg.sender, principalPayment + interestPayment);
    }

    // ── View ──────────────────────────────────────────────────────────────────

    // Cash value (6 dp) of a single token position for a borrower.
    function tokenCollateralValue(address token, address borrower) public view returns (uint256) {
        ICollateralAdapter adapter = adapterOf[token];
        if (address(adapter) == address(0)) return 0;
        uint256 amount = collateralOf[borrower][token];
        if (amount == 0) return 0;
        return amount * adapter.nav() / (10 ** adapter.decimals());
    }

    // Total cash value (6 dp) of all collateral across every registered token.
    function totalCollateralValue(address borrower) public view returns (uint256) {
        uint256 total;
        uint256 len = collateralTokens.length;
        for (uint256 i; i < len; ++i) {
            total += tokenCollateralValue(collateralTokens[i], borrower);
        }
        return total;
    }

    // Maximum cash borrowable. Each token's contribution is haircutted by its own rate,
    // so mixed collateral baskets are priced correctly.
    function maxBorrow(address borrower) public view returns (uint256) {
        uint256 total;
        uint256 len = collateralTokens.length;
        for (uint256 i; i < len; ++i) {
            address token = collateralTokens[i];
            ICollateralAdapter adapter = adapterOf[token];
            if (address(adapter) == address(0)) continue;
            uint256 value = tokenCollateralValue(token, borrower);
            total += value * (10_000 - adapter.haircutBps()) / 10_000;
        }
        return total;
    }

    function isHealthy(address borrower) public view returns (bool) {
        return debtOf[borrower] + interestOwed(borrower)<= maxBorrow(borrower);
    }

    function interestOwed(address borrower) public view returns (uint256) {
        if (debtOf[borrower]  == 0) return 0;
        uint256 elapsed = block.timestamp - borrowTimestamp[borrower];
        uint256 accruing = debtOf[borrower] * borrowRateBps[borrower] * elapsed / (365 days * 10_000);
        return interestAccrued[borrower] + accruing;
    }

    function collateralTokenCount() external view returns (uint256) {
        return collateralTokens.length;
    }

    function liquidate(address borrower) external onlyOwner {
        require(!isHealthy(borrower), "position is healthy");
        uint256 debt = debtOf[borrower];
        debtOf[borrower] = 0;
        uint256 len = collateralTokens.length;
        for (uint256 i; i < len; ++i) {
            address token = collateralTokens[i];
            uint256 amount = collateralOf[borrower][token];
            if (amount == 0) continue;
            collateralOf[borrower][token] = 0;
            IERC20(token).safeTransfer(msg.sender, amount);
        }
        emit Liquidated(borrower, debt);
    }
}
