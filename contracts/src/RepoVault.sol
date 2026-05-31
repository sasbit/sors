//on-chain settlement venue - escrows tokenized treasurey collateral (mBUIDL) and lets a borrower draw cash (mUSDC) against it, capped by a threshhold. Matching/pricing stays off-chain, the vaul enforces custody + collateralization
//SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

//ERC20 interface is all we need (transfer(), transferFrom(), balanceOf())
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract RepoVault is Ownable {
    using SafeERC20 for IERC20;
    
    IERC20 public immutable collateralToken; 
    IERC20 public immutable cashToken;

    uint256 public haircutBps; //200 = 2% haircut
    uint256 public nav; //cash units(6dp) per 1 whole collateral token

    mapping(address => uint256) public collateralOf; //escrowed collateral per borrower
    mapping(address => uint256) public debtOf; //cash drawn per borrower nav = Net Asset Value

    event CashFunded(address indexed from, uint256 amount);
    event CollateralDeposited(address indexed borrower, uint256 amount);
    event CollateralWithdrawn(address indexed borrower, uint256 amount);
    event Borrowed(address indexed borrower, uint256 amount);
    event Repaid(address indexed borrower, uint256 amount);
    event NavUpdated(uint256 oldNav, uint256 newNav);
    event HaircutUpdated(uint256 oldHaircutBps, uint256 newHaircutBps);
    
    constructor (
        address collateralToken_,
        address cashToken_,
        uint256 haircutBps_,
        uint256 nav_,
        address initialOwner
    ) Ownable(initialOwner) {
        require(collateralToken_ != address(0) && cashToken_ != address(0), "zero token");
        require(haircutBps_ <= 10_000, "haircut > 100%");
        collateralToken = IERC20(collateralToken_);
        cashToken = IERC20(cashToken_);
        haircutBps = haircutBps_;
        nav = nav_;
    }

    //Admin sets the nav to be posted
    function setNav(uint256 newNav) external onlyOwner {
        emit NavUpdated(nav, newNav);
        nav = newNav;
    }

    function setHaircut(uint256 newHaircutBps) external onlyOwner {
        require(newHaircutBps <= 10_000, "haircut > 100%");
        emit HaircutUpdated(haircutBps, newHaircutBps);
        haircutBps = newHaircutBps;
    }

    //lender side: funds cash into the vault so the borrower has something to draw from
    //safeTransferFrom pulls amount from the caller into the vault which requries the caller to have falled cashToken.approve(vault, amount) first (standard ERC20 allowance flow)
    function fundCash(uint256 amount) external {
        cashToken.safeTransferFrom(msg.sender, address(this), amount);
        emit CashFunded(msg.sender, amount);
    }

    //borrower side: deposit collateral pulls collateral from the borrower into the vault (again, needs prior approve)
    function depositCollateral(uint256 amount) external {
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        // then credits the borrower's ledger entry
        collateralOf[msg.sender] += amount;
        emit CollateralDeposited(msg.sender, amount);
    }

    //borrowing cash
    function borrow(uint256 amount) external {
        require(amount > 0, "zero amount");
        debtOf[msg.sender] += amount;
        require(debtOf[msg.sender] <= maxBorrow(msg.sender), "exceeds max borrow limit");
        cashToken.safeTransfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    //repaying the loan
    function repay(uint256 amount) external {
        uint256 debt = debtOf[msg.sender];
        uint256 payment = amount > debt ? debt : amount; //clamp: never overpay
        cashToken.safeTransferFrom(msg.sender, address(this), payment);
        debtOf[msg.sender] = debt - payment;
        emit Repaid(msg.sender, payment);
    }

    //withdrawing collateral
    function withdrawCollateral(uint256 amount)  external {
        require(collateralOf[msg.sender] >= amount, "insufficient collateral");
        collateralOf[msg.sender] -= amount;
        require(debtOf[msg.sender] <= maxBorrow(msg.sender), "would be undercollateralized");
        collateralToken.safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, amount);
    }

    function collateralValue(address borrower) public view returns (uint256) {
        return collateralOf[borrower] * nav / 1e18;
    }
    function maxBorrow(address borrower) public view returns (uint256) {
        return collateralValue(borrower) * (10_000 - haircutBps) / 10_000;
    }
    function isHealthy(address borrower) public view returns (bool) {
        return debtOf[borrower] <= maxBorrow(borrower);
    }

}
