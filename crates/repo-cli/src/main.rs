use std::env;
use alloy::primitives::{Address, U256};
use alloy::providers::ProviderBuilder;
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use eyre::Result;

sol! {
    #[sol(rpc)]
    contract IERC20 {
        function approve(address spender, uint256 amount) external returns (bool);
        function balanceOf(address account) external view returns (uint256);
        function mint(address to, uint256 amount) external;
    }
}

sol! {
    #[sol(rpc)]
    contract RepoVault {
        function deposit(uint256 amount) external;
        function withdraw(uint256 amount) external;
        function open(address token, uint256 collateralAmt, uint256 cashAmt, uint256 rateBps, uint256 termSeconds) external;
        function repay(uint256 amount) external;
        function withdrawCollateral(address token, uint256 amount) external;
        function collateralOf(address borrower, address token) external view returns (uint256);
        function totalDebt(address borrower) external view returns (uint256);
        function interestOwed(address borrower) external view returns (uint256);
        function totalCollateralValue(address borrower) external view returns (uint256);
        function maxBorrow(address borrower) external view returns (uint256);
        function isAboveInitialMargin(address borrower) external view returns (bool);
        function lenderClaim(address lender) external view returns (uint256);
        function freeCash() external view returns (uint256);
        function poolValue() external view returns (uint256);
        function collateralTokenCount() external view returns (uint256);
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    dotenvy::dotenv().ok();
    let rpc_url       = env::var("SEPOLIA_RPC_URL")?;
    let lender_key    = env::var("LENDER_PRIVATE_KEY")?;
    let borrower_key  = env::var("BORROWER_PRIVATE_KEY")?;
    let buidl_address: Address = env::var("MOCK_BUIDL_ADDRESS")?.parse()?;
    let usdc_address:  Address = env::var("MOCK_USDC_ADDRESS")?.parse()?;
    let vault_address: Address = env::var("REPO_VAULT_ADDRESS")?.parse()?;

    let lender:   PrivateKeySigner = lender_key.parse()?;
    let borrower: PrivateKeySigner = borrower_key.parse()?;
    let lender_addr   = lender.address();
    let borrower_addr = borrower.address();

    // Two providers — each signs with its own key.
    let lender_provider   = ProviderBuilder::new().wallet(lender).connect_http(rpc_url.parse()?);
    let borrower_provider = ProviderBuilder::new().wallet(borrower).connect_http(rpc_url.clone().parse()?);

    let usdc_lender   = IERC20::new(usdc_address,  lender_provider.clone());
    let buidl_owner   = IERC20::new(buidl_address, lender_provider.clone()); // owner mints
    let vault_lender  = RepoVault::new(vault_address, lender_provider.clone());

    let buidl_borrower = IERC20::new(buidl_address, borrower_provider.clone());
    let usdc_borrower  = IERC20::new(usdc_address,  borrower_provider.clone());
    let vault_borrower = RepoVault::new(vault_address, borrower_provider.clone());

    let buidl_scale = U256::from(10).pow(U256::from(18)); // mBUIDL: 18 decimals
    let usdc_scale  = U256::from(10).pow(U256::from(6));  // mUSDC:   6 decimals

    let fund_amount       = U256::from(1_000u64) * usdc_scale;
    let collateral_amount = U256::from(100u64)   * buidl_scale;
    let borrow_amount     = U256::from(98u64)    * usdc_scale;
    let rate_bps    = U256::from(0u64);               // 0% p.a. for this demo
    let term_secs   = U256::from(30u64 * 24 * 3600);  // 30-day term



    println!("registered collateral tokens: {}",
        vault_lender.collateralTokenCount().call().await?);

    // setup: owner mints 100 mBUIDL to borrower
    println!("\n[setup] mint 100 mBUIDL -> borrower");
    buidl_owner.mint(borrower_addr, collateral_amount).send().await?.get_receipt().await?;

    // --- Lender: seed the cash pool ---
    println!("[1/6] lender approve mUSDC -> vault");
    usdc_lender.approve(vault_address, U256::MAX).send().await?.get_receipt().await?;
    println!("[2/6] lender deposit 1,000 mUSDC");
    vault_lender.deposit(fund_amount).send().await?.get_receipt().await?;

    // --- Borrower: post collateral and draw cash ---
    println!("[3/5] borrower approve mBUIDL -> vault");
    buidl_borrower.approve(vault_address, U256::MAX).send().await?.get_receipt().await?;
    
    println!("[4/5] borrower open: post 100 mBUIDL, draw 98 mUSDC");
    vault_borrower
        .open(buidl_address, collateral_amount, borrow_amount, rate_bps, term_secs)
        .send().await?.get_receipt().await?;
    

    println!("\n=== after open ===");
    println!("freeCash              : {}", vault_lender.freeCash().call().await? / usdc_scale);
    println!("poolValue             : {}", vault_lender.poolValue().call().await? / usdc_scale);
    println!("lenderClaim           : {}", vault_lender.lenderClaim(lender_addr).call().await? / usdc_scale);
    println!("totalCollateralValue  : {}", vault_borrower.totalCollateralValue(borrower_addr).call().await? / usdc_scale);
    println!("maxBorrow             : {}", vault_borrower.maxBorrow(borrower_addr).call().await? / usdc_scale);
    println!("totalDebt             : {}", vault_borrower.totalDebt(borrower_addr).call().await? / usdc_scale);
    println!("interestOwed          : {}", vault_borrower.interestOwed(borrower_addr).call().await? / usdc_scale);
    println!("isAboveInitialMargin  : {}", vault_borrower.isAboveInitialMargin(borrower_addr).call().await?);
    println!("borrower mUSDC        : {}", usdc_borrower.balanceOf(borrower_addr).call().await? / usdc_scale);

    // --- Close out ---
    println!("\n[6/6] borrower approve mUSDC + repay + withdraw");
    usdc_borrower.approve(vault_address, U256::MAX).send().await?.get_receipt().await?;
    vault_borrower.repay(borrow_amount).send().await?.get_receipt().await?;
    vault_borrower.withdrawCollateral(buidl_address, collateral_amount).send().await?.get_receipt().await?;

    println!("\n=== final ===");
    println!("collateralOf(mBUIDL)  : {}", vault_borrower.collateralOf(borrower_addr, buidl_address).call().await? / buidl_scale);
    println!("totalDebt             : {}", vault_borrower.totalDebt(borrower_addr).call().await? / usdc_scale);
    println!("isAboveInitialMargin  : {}", vault_borrower.isAboveInitialMargin(borrower_addr).call().await?);
    println!("lenderClaim (final)   : {}", vault_lender.lenderClaim(lender_addr).call().await? / usdc_scale);

    Ok(())
}
