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
    let private_key = env::var("PRIVATE_KEY")?;
    let buidl_address : Address = env::var("MOCK_BUIDL_ADDRESS")?.parse()?;
    let usdc_address:  Address = env::var("MOCK_USDC_ADDRESS")?.parse()?;
    let vault_address: Address = env::var("REPO_VAULT_ADDRESS")?.parse()?;

    let signer: PrivateKeySigner = private_key.parse()?;
    let me = signer.address();
    let provider = ProviderBuilder::new().wallet(signer).connect_http(rpc_url.parse()?);

    let buidl = IERC20::new(buidl_address, provider.clone());
    let usdc  = IERC20::new(usdc_address,  provider.clone());
    let vault = RepoVault::new(vault_address, provider.clone());

    let buidl_scale = U256::from(10).pow(U256::from(18)); // mBUIDL: 18 decimals
    let usdc_scale  = U256::from(10).pow(U256::from(6));  // mUSDC:  6 decimals

    let fund_amount       = U256::from(1_000u64) * usdc_scale;  // lender seeds 1,000 mUSDC
    let collateral_amount = U256::from(100u64)   * buidl_scale; // borrower posts 100 mBUIDL
    let borrow_amount     = U256::from(98u64)    * usdc_scale;  // draw 98 mUSDC (the 2% haircut ceiling)

    println!("=== initial ===");
    println!("my mBUIDL : {}", buidl.balanceOf(me).call().await? / buidl_scale);
    println!("my mUSDC  : {}", usdc.balanceOf(me).call().await? / usdc_scale);
    println!("vault mUSDC: {}", usdc.balanceOf(vault_address).call().await? / usdc_scale);
    println!("collateralOf(me): {}", vault.collateralOf(me).call().await? / buidl_scale);
    println!("debtOf(me)      : {}", vault.debtOf(me).call().await? / usdc_scale);

    // --- Lender side: approve + fund the vault's cash pool ---
    println!("\n[1/6] approve mUSDC -> vault");
    usdc.approve(vault_address, U256::MAX).send().await?.get_receipt().await?;

    println!("[2/6] fundCash 1,000 mUSDC");
    vault.fundCash(fund_amount).send().await?.get_receipt().await?;

    // --- Borrower side: approve + post collateral ---
    println!("[3/6] approve mBUIDL -> vault");
    buidl.approve(vault_address, U256::MAX).send().await?.get_receipt().await?;

    println!("[4/6] depositCollateral 100 mBUIDL");
    vault.depositCollateral(collateral_amount).send().await?.get_receipt().await?;

    // --- Draw cash against the collateral ---
    println!("[5/6] borrow 98 mUSDC");
    vault.borrow(borrow_amount).send().await?.get_receipt().await?;

    println!("\n=== after borrow ===");
    println!("maxBorrow(me)   : {}", vault.maxBorrow(me).call().await? / usdc_scale);
    println!("debtOf(me)      : {}", vault.debtOf(me).call().await? / usdc_scale);
    println!("isHealthy(me)   : {}", vault.isHealthy(me).call().await?);
    println!("my mUSDC        : {}", usdc.balanceOf(me).call().await? / usdc_scale);

    // --- Close out: repay debt, reclaim collateral ---
    println!("\n[6/6] repay 98 mUSDC + withdraw 100 mBUIDL");
    vault.repay(borrow_amount).send().await?.get_receipt().await?;
    vault.withdrawCollateral(collateral_amount).send().await?.get_receipt().await?;

    println!("\n=== final ===");
    println!("collateralOf(me): {}", vault.collateralOf(me).call().await? / buidl_scale);
    println!("debtOf(me)      : {}", vault.debtOf(me).call().await? / usdc_scale);
    println!("isHealthy(me)   : {}", vault.isHealthy(me).call().await?);

    Ok(())
}
