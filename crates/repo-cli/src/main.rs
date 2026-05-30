use std::env;
use alloy::primitives::{Address, U256};
use alloy::providers::ProviderBuilder;
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use eyre::Result;

sol! {
    #[sol(rpc)]
    contract MockBUIDL {
        function transfer(address to, uint256 amount) external returns (bool);
        function balanceOf(address account) external view returns (uint256);
    }
}

//tokio for Rust async operations 
#[tokio::main]
async fn main() -> Result<()> {
    //loading env variables
    let rpc_url = env::var("SEPOLIA_RPC_URL")?;
    let private_key = env::var("PRIVATE_KEY")?;
    let contract_address: Address = env::var("CONTRACT_ADDRESS")?.parse()?;
    let recipient: Address = env::var("RECIPIENT")?.parse()?;

    //setting up provider and signer
    let signer: PrivateKeySigner = private_key.parse()?;
    let sender = signer.address();
    let provider = ProviderBuilder::new().wallet(signer).connect_http(rpc_url.parse()?);

    //contract handle
    let contract = MockBUIDL::new(contract_address, provider);

    let scale = U256::from(10).pow(U256::from(18));

    //reading two balances
    let before_sender = contract.balanceOf(sender).call().await?;
    let before_recipient = contract.balanceOf(recipient).call().await?;
    println!("---before---");
    println!("sender: {} : {} mBUIDL", sender, before_sender / scale);
    println!("recipient: {} : {} mBUIDL", recipient, before_recipient / scale);

    //sending transaction
    let amount = U256::from(100u64) * scale;
    println!("\n--- sending 100 mBUIDL ---");
    let pending= contract.transfer(recipient, amount).send().await?;
    let tx_hash = *pending.tx_hash();
    println!("  tx hash  : {}", tx_hash);
    println!("  etherscan: https://sepolia.etherscan.io/tx/{}", tx_hash);
    println!("  waiting for confirmation...");
    
    //waiting for receipt
    let receipt = pending.get_receipt().await?;
    println!(" confirmed in block {}\n", receipt.block_number.unwrap_or_default());

    //reading two balances
    let after_sender = contract.balanceOf(sender).call().await?;
    let after_recipient = contract.balanceOf(recipient).call().await?;
    println!("---after---");
    println!("sender: {} : {} mBUIDL", sender, after_sender / scale);
    println!("recipient: {} : {} mBUIDL", recipient, after_recipient / scale);

    Ok(())
}
