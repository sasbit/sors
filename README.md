# Sors

**On-chain repo for tokenized fixed income.** Sors is a securities-financing venue
where lenders supply stablecoin cash against tokenized-Treasury collateral and
borrowers draw that cash on demand. Custody, haircuts, collateralization, and
settlement are enforced by smart contracts; matching, pricing, and risk run
off-chain. Funding is secured atomically — collateral and cash move in the same
transaction, with no settlement window and no dealer in the middle.

## Why it exists

Tokenized U.S. Treasuries are the largest real-world-asset category on-chain —
roughly **$14–15B** in assets as of 2026, led by BlackRock's BUIDL, Hashnote/Circle's
USYC, Ondo's OUSG, and Franklin Templeton's BENJI — inside a wider ~$34B tokenized-RWA
market. These instruments are yield-bearing, low-risk, and already accepted as
collateral, but their biggest unlock is **collateral mobility**: a tokenized T-bill
can be posted, recalled, and financed in seconds rather than settling T+1 through
legacy plumbing.

That is exactly the gap Sors fills. The $12T+ repo market — the short-term funding
layer beneath the entire financial system — is moving onto public chains, with
J.P. Morgan (Kinexys), Banque de France, Société Générale, and UBS already running
live on-chain repo and tokenized-collateral settlement. Intraday, on-chain repo can
halve funding costs and free up capital that today sits idle in overnight buffers.

**Sors is repo infrastructure for that world.** It lets a holder of tokenized
Treasuries turn them into instant working cash without selling the position, and lets
cash lenders deploy against high-quality, over-collateralized security — with custody,
margin, and solvency enforced in code rather than by a back office.

### Who it's for

- **Tokenized-fund holders & trading desks** that want intraday liquidity against
  BUIDL/USYC/OUSG-style collateral without unwinding their yield.
- **Stablecoin treasuries & market makers** seeking a secured, short-duration place
  to deploy cash against high-quality collateral.
- **Institutions modernizing collateral & liquidity management** that need
  programmable haircuts, real-time margining, and atomic delivery-versus-payment.

## How it works

A repo on Sors is a collateralized cash loan with three moving parts:

| Layer | Component | Role |
| --- | --- | --- |
| Collateral | **Treasury collateral token** | The tokenized fixed-income asset posted as security (modeled here by `MockBUIDL`, 18 decimals). |
| Cash | **Stablecoin cash token** | The dollar leg lenders supply and borrowers draw (modeled by `MockUSDC`, 6 decimals to match real USDC). |
| Venue | **`RepoVault`** | Escrows collateral, holds the cash pool, and enforces how much can be borrowed. |

The economics the vault enforces:

- **Lenders** fund the vault's cash pool that borrowers draw against, secured at all
  times by collateral worth more than the cash lent.
- **Borrowers** post collateral and draw cash up to a **haircut-adjusted** limit of
  its value: `maxBorrow = collateralValue × (1 − haircut)`. Collateral is valued at
  its posted **NAV** (net asset value), so the available cash tracks the real worth of
  the Treasuries, not a fixed peg.
- **Solvency is continuous.** Every borrow and every collateral withdrawal is checked
  against the position's health (`debt ≤ maxBorrow`); anything that would leave a
  position under-collateralized reverts. Healthy positions are distinguishable from
  unhealthy ones on-chain at any moment, which is the signal a margin/liquidation
  process acts on.

Borrowers repay to reduce debt and reclaim their collateral; the full lifecycle —
fund → deposit → borrow → repay → withdraw — settles entirely on-chain.

The split is deliberate: **the chain is the settlement and custody layer** (where
trust and money live), while **matching, pricing, NAV, and risk are computed
off-chain** (where flexibility and speed live) and pushed in. A Rust service signs and
submits transactions and reads venue state.

## Live deployment (Ethereum Sepolia)

| Contract | Address |
| --- | --- |
| `RepoVault` | [`0xF3a45804c853D7829585b1c0f5BC489a0E4ab1c9`](https://sepolia.etherscan.io/address/0xF3a45804c853D7829585b1c0f5BC489a0E4ab1c9) |
| Treasury collateral (`MockBUIDL`) | [`0x477944B6E89D60638BF76A69273348e444C67CB7`](https://sepolia.etherscan.io/address/0x477944B6E89D60638BF76A69273348e444C67CB7) |
| Stablecoin cash (`MockUSDC`) | [`0x7fBc681584FC6898B5812aFf75Cc9A19D53E4Aaf`](https://sepolia.etherscan.io/address/0x7fBc681584FC6898B5812aFf75Cc9A19D53E4Aaf) |

The vault is configured at a **2% haircut** and a par NAV (1 collateral token = 1 cash
dollar). The two tokens are mocks that mirror the decimals and ERC-20 behavior of
real tokenized-Treasury and stablecoin assets, so the venue logic is identical to what
runs against production collateral.

## Architecture

```
sors/
├── contracts/          # Foundry project (Solidity) — on-chain settlement & custody
│   ├── src/            # MockBUIDL (collateral), MockUSDC (cash), RepoVault (venue)
│   ├── test/           # Foundry tests covering the full repo lifecycle
│   ├── script/         # DeployRepo.s.sol — one-shot deployment of the venue
│   └── lib/            # git submodules: openzeppelin-contracts, forge-std
└── crates/             # Cargo workspace (Rust) — off-chain stack
    └── repo-cli/       # signs + submits transactions, reads on-chain venue state
```

`contracts/` and `crates/` are siblings because Foundry and Cargo are separate
toolchains; keeping them apart keeps each build system clean. The Rust side is a Cargo
workspace so every off-chain service shares one lockfile, one `target/`, and unified
dependency versions.

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

## Build & test

```bash
# Solidity — build and run the full lifecycle test suite
cd contracts
forge build
forge test -vvv

# Rust (from repo root)
cargo build
```

The Foundry suite exercises deposit, borrowing up to the haircut limit, the
over-limit and broken-health reverts, debt repayment, and full close-out.

## Configuration

The off-chain client and the deploy script read configuration from `contracts/.env`
(git-ignored — never commit real keys). See `.env.example` for the full list:

```bash
SEPOLIA_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/<key>"
PRIVATE_KEY="0x..."                  # testnet only
MOCK_BUIDL_ADDRESS="0x4779..."       # deployed Treasury collateral
MOCK_USDC_ADDRESS="0x7fBc..."        # deployed stablecoin cash
REPO_VAULT_ADDRESS="0xF3a4..."       # deployed venue
```

## Deploy

Deploy the full venue (both token legs + the vault) with one script. Dry-run first,
then broadcast:

```bash
cd contracts

# simulate locally — sends nothing, costs nothing
forge script script/DeployRepo.s.sol:DeployRepo --rpc-url "$SEPOLIA_RPC_URL"

# deploy for real (requires a funded testnet account)
forge script script/DeployRepo.s.sol:DeployRepo --rpc-url "$SEPOLIA_RPC_URL" --broadcast
```

## Run the client

With `contracts/.env` populated, the Rust client connects with the configured account,
submits signed transactions, and reads venue state back from chain:

```bash
cargo run -p repo-cli
```
