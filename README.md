# Sors

> Working name — trivially renameable. Placeholder for the on-chain repo / securities-financing venue.

On-chain **repo (securities financing) for tokenized fixed income**. Lenders supply
stablecoins against tokenized-Treasury collateral (BUIDL, USYC, OUSG, …); borrowers
post collateral and draw cash. Settlement, haircuts, margin, and liquidation are
enforced by smart contracts; matching, pricing, risk, and indexing run off-chain.

This repository is the V0: mock collateral + a repo vault on an Ethereum testnet,
driven by a Rust off-chain stack.

## Layout

```
sors/
├── contracts/          # Foundry project (Solidity) — on-chain layer
│   ├── src/            # MockBUIDL, (next) MockUSDC, RepoVault, NAVOracle, LiquidationEngine
│   ├── test/           # Foundry tests
│   ├── script/         # deploy scripts
│   └── lib/            # git submodules: openzeppelin-contracts, forge-std
└── crates/             # Cargo workspace (Rust) — off-chain layer
    └── repo-cli/       # CLI client: signs + sends txs, reads on-chain state
        # (next) oracle, indexer, matching-engine, risk
```

- **`contracts/`** and **`crates/`** are siblings because Foundry and Cargo are
  separate toolchains; keeping them apart keeps each build system clean.
- The Rust side is a **Cargo workspace** so every service shares one lockfile,
  one `target/`, and unified dependency versions.

## Prerequisites

- [Rust](https://rustup.rs) (stable, 1.90+)
- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`)

## Setup

```bash
# Clone with submodules (OpenZeppelin + forge-std live in contracts/lib)
git clone --recurse-submodules <repo-url>
cd sors

# If you already cloned without --recurse-submodules:
git submodule update --init --recursive
```

## Build

```bash
# Solidity
cd contracts && forge build

# Rust (from repo root)
cargo build
```

## Run the CLI demo

Requires a Sepolia RPC URL, a funded testnet key, the deployed contract address,
and a recipient. Provide them via environment variables (never commit real keys):

```bash
export SEPOLIA_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/<key>"
export PRIVATE_KEY="0x..."          # testnet only
export CONTRACT_ADDRESS="0x..."     # deployed MockBUIDL
export RECIPIENT="0x..."

cargo run -p repo-cli
```

## Status

- [x] `MockBUIDL` ERC-20 deployed to Sepolia
- [x] Rust CLI signs + sends a transfer, confirms on-chain, reads back balances
- [ ] `MockUSDC` (cash leg)
- [ ] `RepoVault` (collateral escrow + borrow/repay)
- [ ] `NAVOracle` (price feed) + Rust oracle pusher
- [ ] `LiquidationEngine` + Rust risk watcher
- [ ] Two-party (lender/borrower) end-to-end repo demo
