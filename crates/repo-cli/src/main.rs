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
        function fundCash(uint256 amount) external;
        function depositCollateral(uint256 amount) external;
        function borrow(uint256 amount) external;
        function repay(uint256 amount)  external;
        function withdrawCollateral(uint256 amount) external;
        function collateralOf(address borrower) external view returns (uint256);
        function debtOf(address borrower) external view returns (uint256);
        function maxBorrow(address borrower) external view returns (uint256);
        function isHealthy(address borrower) external view returns (bool);
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let rpc_url = env::var("SEPOLIA_RPC_URL")?;
    let lender_key = env::var("LENDER_PRIVATE_KEY")?;
    let borrower_key = env::var("BORROWER_PRIVATE_KEY")?;
    let buidl_address : Address = env::var("MOCK_BUIDL_ADDRESS")?.parse()?;
    let usdc_address:  Address = env::var("MOCK_USDC_ADDRESS")?.parse()?;
    let vault_address: Address = env::var("REPO_VAULT_ADDRESS")?.parse()?;

    let lender: PrivateKeySigner = lender_key.parse()?;
    let borrower: PrivateKeySigner = borrower_key.parse()?;
    let lender_addr = lender.address();
    let borrower_addr = borrower.address();

    //two providers because one provider signs every transaction it sends with the single wallet baked into it
    let lender_provider = ProviderBuilder::new().wallet(lender).connect_http(rpc_url.parse()?);
    let borrower_provider = ProviderBuilder::new().wallet(borrower).connect_http(rpc_url.parse()?);

    // Lender-controlled (Wallet 1, also the MockBUIDL owner)
    let usdc_lender  = IERC20::new(usdc_address,  lender_provider.clone());
    let buidl_owner  = IERC20::new(buidl_address, lender_provider.clone()); // for mint
    let vault_lender = RepoVault::new(vault_address, lender_provider.clone());

    // Borrower-controlled (Wallet 2)
    let buidl_borrower = IERC20::new(buidl_address, borrower_provider.clone());
    let usdc_borrower  = IERC20::new(usdc_address,  borrower_provider.clone()); // for repay
    let vault_borrower = RepoVault::new(vault_address, borrower_provider.clone());

    let buidl_scale = U256::from(10).pow(U256::from(18)); // mBUIDL: 18 decimals
    let usdc_scale  = U256::from(10).pow(U256::from(6));  // mUSDC:  6 decimals

    let fund_amount       = U256::from(1_000u64) * usdc_scale;
    let collateral_amount = U256::from(100u64)   * buidl_scale;
    let borrow_amount     = U256::from(98u64)    * usdc_scale;

    // setup: lender (owner) mints 100 mBUIDL collateral to the borrower
    println!("[setup] mint 100 mBUIDL -> borrower");
    buidl_owner.mint(borrower_addr, collateral_amount).send().await?.get_receipt().await?;

    // --- Lender: seed the cash pool ---
    println!("[1/6] lender approve mUSDC -> vault");
    usdc_lender.approve(vault_address, U256::MAX).send().await?.get_receipt().await?;
    println!("[2/6] lender fundCash");
    vault_lender.fundCash(fund_amount).send().await?.get_receipt().await?;

    // --- Borrower: post collateral and draw cash ---
    println!("[3/6] borrower approve mBUIDL -> vault");
    buidl_borrower.approve(vault_address, U256::MAX).send().await?.get_receipt().await?;
    println!("[4/6] borrower depositCollateral");
    vault_borrower.depositCollateral(collateral_amount).send().await?.get_receipt().await?;
    println!("[5/6] borrower borrow 98 mUSDC");
    vault_borrower.borrow(borrow_amount).send().await?.get_receipt().await?;

    println!("\n=== after borrow ===");
    println!("borrower debt     : {}", vault_borrower.debtOf(borrower_addr).call().await? / usdc_scale);
    println!("borrower healthy  : {}", vault_borrower.isHealthy(borrower_addr).call().await?);
    println!("borrower mUSDC    : {}", usdc_lender.balanceOf(borrower_addr).call().await? / usdc_scale);
    println!("lender   mUSDC    : {}", usdc_lender.balanceOf(lender_addr).call().await? / usdc_scale);
    println!("vault    mUSDC    : {}", usdc_lender.balanceOf(vault_address).call().await? / usdc_scale);

    // --- Close out (borrower) ---
    println!("\n[6/6] borrower approve mUSDC + repay + withdraw");
    usdc_borrower.approve(vault_address, U256::MAX).send().await?.get_receipt().await?;
    vault_borrower.repay(borrow_amount).send().await?.get_receipt().await?;
    vault_borrower.withdrawCollateral(collateral_amount).send().await?.get_receipt().await?;

    println!("\n=== final ===");
    println!("borrower debt      : {}", vault_borrower.debtOf(borrower_addr).call().await? / usdc_scale);
    println!("borrower collateral: {}", vault_borrower.collateralOf(borrower_addr).call().await? / buidl_scale);

    Ok(())
}
