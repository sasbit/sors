use std::{
    collections::HashSet,
    env,
    fs,
    time::Duration,
};
use alloy::{
    primitives::{Address, U256},
    providers::{Provider, ProviderBuilder},
    rpc::types::Filter,
    signers::local::PrivateKeySigner,
    sol,
    sol_types::SolEvent,
};
use eyre::Result;

sol! {
    struct Position {
        uint256 principal;
        uint256 rateBps;
        uint256 startTimestamp;
        uint256 interestAccrued;
        uint256 maturity;
        uint256 terminationAt;
        uint256 marginCallAt;
        bool earlyTermProposed;
    }

    #[sol(rpc)]
    contract RepoVault {
        //reads
        function positions(address borrower) external view returns(Position memory);
        function isAboveMaintenanceMargin(address borrower) external view returns (bool);

        //keeper actions
        function triggerMarginCall(address borrower) external;
        function liquidate(address borrower) external;
        function expire(address borrower) external;

        //events - used to discvoer which address have ever openend a position
        event Opened(address indexed borrower, address indexed token, uint256 collateralAmt, uint256 cashAmt, uint256 rateBps, uint256 maturity);
        event PositionExpired(address indexed borrower, uint256 debtCleared);
        event Liquidated(address indexed borrower, uint256 debtCleared);
        event Repaid(address indexed borrower, uint256 principalPaid, uint256 interestPaid);
    }
}


struct Config {
    rpc_url: String,
    keeper_key: String,
    vault: Address,
    poll_secs: u64,
    state_file: String,
}

impl  Config {
    fn from_env() -> Result<Self> {
        Ok(Self {
            rpc_url: env::var("SEPOLIA_RPC_URL")?,
            keeper_key: env::var("KEEPER_PRIVATE_KEY")?,
            vault: env::var("REPO_VAULT_ADDRESS")?.parse()?,
            poll_secs: env::var("KEEPER_POLL_SECS").unwrap_or_else(|_| "30".into()).parse()?,
            state_file: env::var("KEEPER_STATE_FILE").unwrap_or_else(|_| "keeper_state.json".into()),
        })
    }
}

fn load_borrowers(path: &str) -> HashSet<Address> {
    fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str::<Vec<String>>(&s).ok())
        .map(|v| v.iter().filter_map(|a| a.parse().ok()).collect())
        .unwrap_or_default()
}

fn save_borrowers(path: &str, borrowers: &HashSet<Address>) {
    let v: Vec<String> = borrowers.iter().map(|a| a.to_string()).collect();
    if let Ok(json) = serde_json::to_string_pretty(&v) {
        let _ = fs::write(path, json);
    }
}

async fn sync_borrowers<P>(
    provider: &P,
    vault_addr: Address,
    from_block: u64,
    to_block:   u64,
    known:      &mut HashSet<Address>,
) -> Result<()>
where
    P: alloy::providers::Provider<alloy::network::Ethereum> + Clone,
{
    const CHUNK: u64 = 9; // Alchemy free tier caps eth_getLogs at 10 blocks per request

    let mut cur = from_block;
    while cur <= to_block {
        let end = (cur + CHUNK - 1).min(to_block);
        let filter = Filter::new()
            .address(vault_addr)
            .from_block(cur)
            .to_block(end);

        let logs = provider.get_logs(&filter).await?;

        for log in &logs {
            if let Ok(e) = RepoVault::Opened::decode_log(log.as_ref()) {
                known.insert(e.borrower);
            }
            if let Ok(e) = RepoVault::PositionExpired::decode_log(log.as_ref()) {
                known.remove(&e.borrower);
            }
            if let Ok(e) = RepoVault::Liquidated::decode_log(log.as_ref()) {
                known.remove(&e.borrower);
            }
        }

        cur = end + 1;
        tokio::time::sleep(Duration::from_millis(200)).await; // respect free-tier rate limit
    }

    Ok(())
}

async fn check_and_act<P>(
    vault:    &RepoVault::RepoVaultInstance<P, alloy::network::Ethereum>,
    borrower: Address,
) -> Result<bool>
where
    P: alloy::providers::Provider<alloy::network::Ethereum> + Clone,
{ // returns true if position is still open
    let pos = vault.positions(borrower).call().await?;

    // no open position — caller should remove from set
    if pos.principal == U256::ZERO {
        return Ok(false);
    }

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs();

    // ── Expiry check ─────────────────────────────────────────────────────────
    let term_expired = pos.maturity > U256::ZERO
        && now >= pos.maturity.to::<u64>();
    let open_expired = pos.maturity == U256::ZERO
        && pos.terminationAt > U256::ZERO
        && now >= pos.terminationAt.to::<u64>();

    if term_expired || open_expired {
        println!("  → expire({borrower})");
        vault.expire(borrower).send().await?.get_receipt().await?;
        return Ok(false);
    }

    // ── Margin check ─────────────────────────────────────────────────────────
    let healthy = vault.isAboveMaintenanceMargin(borrower).call().await?;

    if !healthy {
        if pos.marginCallAt == U256::ZERO {
            println!("  → triggerMarginCall({borrower})");
            vault.triggerMarginCall(borrower).send().await?.get_receipt().await?;
        } else {
            println!("  → liquidate({borrower}) (margin call was at {})", pos.marginCallAt);
            vault.liquidate(borrower).send().await?.get_receipt().await?;
            return Ok(false);
        }
    }

    Ok(true)
}

#[tokio::main]
async fn main() -> Result<()> {
    dotenvy::dotenv().ok();
    let cfg = Config::from_env()?;

    let signer: PrivateKeySigner = cfg.keeper_key.parse()?;
    let provider = ProviderBuilder::new()
        .wallet(signer)
        .connect_http(cfg.rpc_url.parse()?);

    let vault = RepoVault::new(cfg.vault, provider.clone());

    let mut known = load_borrowers(&cfg.state_file);
    let mut last_block: u64 = 0;
    let mut interval = tokio::time::interval(Duration::from_secs(cfg.poll_secs));

    println!("keeper started — vault {} — polling every {}s", cfg.vault, cfg.poll_secs);

    loop {
        interval.tick().await;

        // get current block
        let head = match provider.get_block_number().await {
            Ok(b)  => b,
            Err(e) => { eprintln!("rpc error: {e}"); continue; }
        };

        if head <= last_block {
            continue;
        }

        // discover new borrowers from events since last scan
        let from = if last_block == 0 { head.saturating_sub(500) } else { last_block + 1 };
        println!("scanning blocks {from}..{head}");

        if let Err(e) = sync_borrowers(&provider, cfg.vault, from, head, &mut known).await {
            eprintln!("sync error: {e}");
        }

        last_block = head;

        // check every known position
        let mut to_remove = vec![];
        for &borrower in &known {
            print!("checking {borrower} … ");
            match check_and_act(&vault, borrower).await {
                Ok(true)  => println!("healthy"),
                Ok(false) => { println!("closed"); to_remove.push(borrower); }
                Err(e)    => eprintln!("error: {e}"),
            }
        }

        for addr in to_remove {
            known.remove(&addr);
        }

        save_borrowers(&cfg.state_file, &known);
    }
}
