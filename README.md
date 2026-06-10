# sors

**On-chain repo for tokenized fixed income.** Sors is a securities-financing venue where lenders supply stablecoin cash against tokenized-Treasury collateral and borrowers draw that cash on demand. Custody, haircuts, collateralization, and settlement are enforced by smart contracts; matching, pricing, and risk run off-chain. Funding is secured atomically — collateral and cash move in the same transaction, with no settlement window and no dealer in the middle.

## Why it exists

Tokenized U.S. Treasuries are the largest real-world-asset category on-chain — roughly **$14–15B** in assets as of 2026, led by BlackRock's BUIDL, Hashnote/Circle's USYC, Ondo's OUSG, and Franklin Templeton's BENJI — inside a wider ~$34B tokenized-RWA market. These instruments are yield-bearing, low-risk, and already accepted as collateral, but their biggest unlock is **collateral mobility**: a tokenized T-bill can be posted, recalled, and financed in seconds rather than settling T+1 through legacy plumbing.

That is exactly the gap Sors fills. The $12T+ repo market — the short-term funding layer beneath the entire financial system — is moving onto public chains, with J.P. Morgan (Kinexys), Banque de France, Société Générale, and UBS already running live on-chain repo and tokenized-collateral settlement. Intraday, on-chain repo can halve funding costs and free up capital that today sits idle in overnight buffers.

**Sors is repo infrastructure for that world.** It lets a holder of tokenized Treasuries turn them into instant working cash without selling the position, and lets cash lenders deploy against high-quality, over-collateralized security — with custody, margin, and solvency enforced in code rather than by a back office.

### Who it's for

- **Tokenized-fund holders & trading desks** that want intraday liquidity against BUIDL/USYC/OUSG-style collateral without unwinding their yield.
- **Stablecoin treasuries & market makers** seeking a secured, short-duration place to deploy cash against high-quality collateral.
- **Institutions modernizing collateral & liquidity management** that need programmable haircuts, real-time margining, and atomic delivery-versus-payment.

## How it works

A repo on Sors is a collateralized cash loan with three moving parts:

| Layer | Component | Role |
|---|---|---|
| Collateral | Treasury collateral token | Tokenized fixed-income asset posted as security (mBUIDL/mUSYC/mOUSG — decimals match real assets). |
| Cash | Stablecoin cash token | Dollar leg lenders supply and borrowers draw (mUSDC — 6 decimals to match real USDC). |
| Venue | `RepoVault` | Escrows collateral, holds the cash pool, and enforces how much can be borrowed. |

The economics the vault enforces:

- **Lenders** fund the vault's cash pool that borrowers draw against, secured at all times by collateral worth more than the cash lent. Lenders earn interest paid by borrowers pro-rata to their pool share.
- **Borrowers** post collateral and draw cash up to a haircut-adjusted limit: `maxBorrow = collateralValue × (1 − haircut)`. Collateral is valued at its posted NAV, so available cash tracks the real worth of the Treasuries.
- **Solvency is continuous.** Every borrow and every collateral withdrawal is checked against the position's health (`debt ≤ maxBorrow`); anything that would leave a position under-collateralized reverts.
- **Margin & liquidation.** If a position falls below maintenance margin, the keeper triggers a margin call. If the borrower does not cure within the grace period, the keeper liquidates — collateral is seized, debt cleared, lenders made whole.

The chain is the settlement and custody layer (where trust and money live); matching, pricing, NAV, and risk are computed off-chain and pushed in. A Rust keeper signs and submits margin and expiry transactions automatically.

## Live deployment (Ethereum Sepolia)

| Contract | Address |
|---|---|
| `RepoVault` | [`0x9Aa1913b7ECfA45CB957f223571fc671b12a64E7`](https://sepolia.etherscan.io/address/0x9Aa1913b7ECfA45CB957f223571fc671b12a64E7#code) |
| `MockUSDC` (cash) | [`0x062db38c83b4a9bb719a6e8f3a4fd6c748313c02`](https://sepolia.etherscan.io/address/0x062db38c83b4a9bb719a6e8f3a4fd6c748313c02) |
| `MockBUIDL` (collateral) | [`0x64100b083e85886baa77334b32d1568d7ea8e855`](https://sepolia.etherscan.io/address/0x64100b083e85886baa77334b32d1568d7ea8e855) |
| `MockUSYC` (collateral) | [`0x5dddb22bd74d931c7a823a759a4eba493cbb3d63`](https://sepolia.etherscan.io/address/0x5dddb22bd74d931c7a823a759a4eba493cbb3d63) |
| `MockOUSG` (collateral) | [`0xe88862403c198e227f17232cbbb6c638714dbee8`](https://sepolia.etherscan.io/address/0xe88862403c198e227f17232cbbb6c638714dbee8) |

## Architecture

```
sors/
├── contracts/                  # Foundry (Solidity) — on-chain settlement & custody
│   ├── src/
│   │   ├── RepoVault.sol               # core venue: pool, positions, margin, liquidation
│   │   ├── SimpleCollateralAdapter.sol # haircut + NAV adapter for mock tokens
│   │   ├── ChainLinkCollateralAdapter.sol  # Chainlink oracle adapter (production path)
│   │   ├── ICollateralAdapter.sol      # adapter interface
│   │   ├── MockBUIDL.sol               # ERC-20 collateral token (18 dec)
│   │   └── MockUSDC.sol                # ERC-20 cash token (6 dec)
│   ├── test/                   # Foundry lifecycle tests
│   ├── script/
│   │   └── DeployRepo.s.sol            # one-shot deployment of the full venue
│   └── lib/                    # git submodules: openzeppelin-contracts, forge-std
│
├── crates/                     # Cargo workspace (Rust) — off-chain stack
│   ├── keeper/                 # automated margin monitor & liquidator
│   │   └── src/main.rs         # polls every N seconds, triggers margin calls + liquidations
│   └── repo-cli/               # end-to-end lifecycle script for dev/demo
│       └── src/main.rs         # mint → lend → borrow → print position state
│
└── apps/
    └── dashboard/              # Next.js 16 App Router — live read + transaction UI
        ├── app/                # server components (chain reads) + client components (wallet)
        ├── components/ui/      # WalletButton, ActionPanel (MINT/LEND/BORROW/REPAY/ADMIN tabs)
        └── config/             # wagmi config, contract addresses + ABIs
```

## Prerequisites

- [Rust](https://rustup.rs) (stable, 1.80+)
- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`)
- [Node.js](https://nodejs.org) 20+ with npm (for the dashboard)

## Setup

```bash
git clone --recurse-submodules <repo-url>
cd sors

# If already cloned without --recurse-submodules:
git submodule update --init --recursive
```

## Configuration

All Rust components read from `contracts/.env` (git-ignored). Copy the example and fill in real values:

```bash
cp contracts/.env.example contracts/.env
```

Required variables:

```bash
# RPC
SEPOLIA_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/<key>"

# Signing keys (testnet only — never commit real keys)
PRIVATE_KEY="0x..."            # deployer / owner (for forge scripts)
LENDER_PRIVATE_KEY="0x..."     # lender account (repo-cli)
BORROWER_PRIVATE_KEY="0x..."   # borrower account (repo-cli)
KEEPER_PRIVATE_KEY="0x..."     # keeper account — must hold LIQUIDATOR_ROLE on the vault

# Deployed addresses (already set for the current Sepolia deployment)
REPO_VAULT_ADDRESS="0x9Aa1913b7ECfA45CB957f223571fc671b12a64E7"
MOCK_USDC_ADDRESS="0x062db38c83b4a9bb719a6e8f3a4fd6c748313c02"
MOCK_BUIDL_ADDRESS="0x64100b083e85886baa77334b32d1568d7ea8e855"

# Keeper tuning (optional — defaults shown)
KEEPER_POLL_SECS=30
KEEPER_STATE_FILE=keeper_state.json
```

The dashboard reads from `apps/dashboard/.env.local`:

```bash
NEXT_PUBLIC_ALCHEMY_URL="https://eth-sepolia.g.alchemy.com/v2/<key>"
NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID="<wc-project-id>"
```

## Build & test

```bash
# Solidity — build and run the full lifecycle test suite
cd contracts
forge build
forge test -vvv

# Rust (from repo root)
cargo build
```

## Deploy

Deploy all contracts in one script:

```bash
cd contracts

# Dry run (no broadcast, no gas)
forge script script/DeployRepo.s.sol:DeployRepo --rpc-url "$SEPOLIA_RPC_URL"

# Broadcast (requires funded account at PRIVATE_KEY)
forge script script/DeployRepo.s.sol:DeployRepo --rpc-url "$SEPOLIA_RPC_URL" --broadcast
```

## Run the keeper

The keeper monitors every open position on-chain. It discovers borrowers by scanning `Opened` events from the vault, then every poll interval it checks each position and:

1. Calls `expire()` on positions past maturity
2. Calls `triggerMarginCall()` on positions below maintenance margin
3. Calls `liquidate()` on positions already under a margin call

```bash
# from repo root, with contracts/.env populated
cargo run -p keeper
```

Example output:

```
keeper started — vault 0x9Aa1...64E7 — polling every 30s
scanning blocks 8120000..8120042
checking 0xc064…D4e7 … healthy
```

## Run the lifecycle demo script

`repo-cli` executes the full lend → borrow flow programmatically and prints position state. Useful for verifying contract behavior end-to-end without the UI:

```bash
cargo run -p repo-cli
```

Example output:

```
[setup] mint 100 mBUIDL -> borrower
[1/6] lender approve mUSDC -> vault
[2/6] lender deposit 1,000 mUSDC
[3/5] borrower approve mBUIDL -> vault
[4/5] borrower open: post 100 mBUIDL, draw 98 mUSDC

=== after open ===
freeCash              : 902
poolValue             : 1000
lenderClaim           : 1000
totalCollateralValue  : 100
maxBorrow             : 98
totalDebt             : 98
isAboveInitialMargin  : true
borrower mUSDC        : 98
```

## Run the dashboard

```bash
cd apps/dashboard
npm install
npm run dev
# → http://localhost:3000
```

The main page is a server component that reads live chain state on every request via viem. The wallet interaction layer (connect, approve, deposit, borrow, repay, admin) runs client-side via wagmi v3 + WalletConnect.

## Known limitations (Sepolia V1)

| Limitation | Current State | Production Path |
|---|---|---|
| Test tokens | mUSDC, mBUIDL/mUSYC/mOUSG (mocks) | Real BUIDL/USYC/OUSG require whitelist onboarding with issuer |
| Admin key | Single EOA with all roles | Gnosis Safe multisig |
| Oracle | Admin-set NAV via SimpleCollateralAdapter | ChainlinkCollateralAdapter already built |
| Network | Sepolia testnet | Mainnet after audit |
| KYC | AccessControl whitelist | SumSub or Jumio integration |
| Audit | Not audited | Required before any real capital |
