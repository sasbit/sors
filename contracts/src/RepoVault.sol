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

    event AdapterSet(address indexed token, address indexed adapter);
    event CashFunded(address indexed from, uint256 amount);
    event CollateralDeposited(address indexed borrower, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed borrower, address indexed token, uint256 amount);
    event Borrowed(address indexed borrower, uint256 amount);
    event Repaid(address indexed borrower, uint256 amount);

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

    // ── Lender ────────────────────────────────────────────────────────────────

    function fundCash(uint256 amount) external {
        cashToken.safeTransferFrom(msg.sender, address(this), amount);
        emit CashFunded(msg.sender, amount);
    }

    // ── Borrower ──────────────────────────────────────────────────────────────

    function depositCollateral(address token, uint256 amount) external {
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

    function borrow(uint256 amount) external {
        require(amount > 0, "zero amount");
        debtOf[msg.sender] += amount;
        require(debtOf[msg.sender] <= maxBorrow(msg.sender), "exceeds max borrow");
        cashToken.safeTransfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        uint256 debt    = debtOf[msg.sender];
        uint256 payment = amount > debt ? debt : amount; // clamp: never overpay
        cashToken.safeTransferFrom(msg.sender, address(this), payment);
        debtOf[msg.sender] = debt - payment;
        emit Repaid(msg.sender, payment);
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
        return debtOf[borrower] <= maxBorrow(borrower);
    }

    function collateralTokenCount() external view returns (uint256) {
        return collateralTokens.length;
    }
}
