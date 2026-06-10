import { client } from "@/config/client"
import { VAULT_ADDRESS, VAULT_ABI, KNOWN_BORROWERS } from "@/config/contracts"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { WalletButton } from "@/components/ui/wallet-button"
import { ActionPanel } from "@/components/ui/action-panel"


function fmt(value: bigint) {
  return (Number(value) / 1e6).toLocaleString("en-US", { style: "currency", currency: "USD" })
}

function fmtRate(bps: bigint) {
  return (Number(bps) / 100).toFixed(2) + "%"
}

function fmtMaturity(maturity: bigint) {
  if (maturity === 0n) return "OPEN"
  return new Date(Number(maturity) * 1000).toLocaleDateString("en-GB", {
    day: "2-digit", month: "short", year: "numeric",
  }).toUpperCase()
}

function truncate(addr: string) {
  return addr.slice(0, 6) + "…" + addr.slice(-4)
}

async function getPoolState() {
  const [poolValue, freeCash, utilization, collateralTokenCount] = await Promise.all([
    client.readContract({ address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: "poolValue" }),
    client.readContract({ address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: "freeCash" }),
    client.readContract({ address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: "utilization" }),
    client.readContract({ address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: "collateralTokenCount" }),
  ])
  return { poolValue, freeCash, utilization, collateralTokenCount }
}

async function getPositions() {
  const rows = await Promise.all(
    KNOWN_BORROWERS.map(async (borrower) => {
      const [pos, debt, collateralValue, healthy] = await Promise.all([
        client.readContract({ address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: "positions", args: [borrower] }),
        client.readContract({ address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: "totalDebt", args: [borrower] }),
        client.readContract({ address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: "totalCollateralValue", args: [borrower] }),
        client.readContract({ address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: "isAboveMaintenanceMargin", args: [borrower] }),
      ])
      return { borrower, pos, debt, collateralValue, healthy }
    })
  )
  return rows.filter((r) => r.pos.principal > 0n)
}

export default async function Home() {
  const [pool, positions] = await Promise.all([getPoolState(), getPositions()])
  const utilizationPct = (Number(pool.utilization) / 1e16).toFixed(2)
  const borrowed = (pool.poolValue as bigint) - (pool.freeCash as bigint)

  return (
    <main className="min-h-screen bg-black font-mono text-zinc-100">

      {/* Top bar */}
      <div className="border-b-2 border-amber-500 bg-black px-6 py-2 flex items-center justify-between">
        <div className="flex items-center gap-6">
          <span className="text-amber-500 font-bold text-sm tracking-widest">SORS</span>
          <span className="text-zinc-500 text-xs tracking-widest"></span>
          <span className="text-zinc-700 text-xs">|</span>
          <span className="text-zinc-500 text-xs font-mono">{VAULT_ADDRESS}</span>
        </div>
        <div className="flex items-center gap-4">
          <div className="flex items-center gap-2 text-xs text-zinc-500 tracking-widest">
            <span className="relative flex h-1.5 w-1.5">
              <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75" />
              <span className="relative inline-flex rounded-full h-1.5 w-1.5 bg-emerald-500" />
            </span>
            LIVE · SEPOLIA
          </div>
          <WalletButton />
        </div>
      </div>


      {/* Metric strip */}
      <div className="border-b border-zinc-900 grid grid-cols-4 divide-x divide-zinc-900">
        {[
          { label: "POOL VALUE",  value: fmt(pool.poolValue as bigint), highlight: false },
          { label: "FREE CASH",   value: fmt(pool.freeCash as bigint),  highlight: false },
          { label: "DEPLOYED",    value: fmt(borrowed),                 highlight: true  },
          { label: "UTILIZATION", value: utilizationPct + "%",          highlight: true  },
        ].map(({ label, value, highlight }) => (
          <div key={label} className="px-6 py-4">
            <p className="text-[10px] text-zinc-600 tracking-widest mb-1">{label}</p>
            <p className={`text-lg font-bold tabular-nums ${highlight ? "text-amber-400" : "text-zinc-100"}`}>
              {value}
            </p>
          </div>
        ))}
      </div>

      {/* Secondary strip */}
      <div className="border-b border-zinc-900 grid grid-cols-4 divide-x divide-zinc-900 bg-zinc-950">
        {[
          { label: "COLLATERAL TOKENS", value: String(pool.collateralTokenCount) },
          { label: "OPEN POSITIONS",    value: String(positions.length) },
          { label: "NETWORK",           value: "SEPOLIA" },
          { label: "PROTOCOL",          value: "REPO V1" },
        ].map(({ label, value }) => (
          <div key={label} className="px-6 py-2.5">
            <p className="text-[10px] text-zinc-700 tracking-widest mb-0.5">{label}</p>
            <p className="text-xs text-zinc-400 font-bold tracking-wider">{value}</p>
          </div>
        ))}
      </div>

      {/* Positions panel */}
      <div className="px-6 py-5">
        <div className="flex items-center gap-3 mb-4">
          <div className="w-1 h-4 bg-amber-500" />
          <p className="text-[11px] font-bold tracking-widest text-zinc-400">OPEN POSITIONS</p>
        </div>
      
      {/* Action panel */}
      <div className="px-6 pb-8">
        <div className="flex items-center gap-3 mb-4">
          <div className="w-1 h-4 bg-amber-500" />
          <p className="text-[11px] font-bold tracking-widest text-zinc-400">TRANSACT</p>
        </div>
        <ActionPanel />
      </div>

        {positions.length === 0 ? (
          <p className="text-xs text-zinc-700 tracking-widest pl-4">— NO OPEN POSITIONS</p>
        ) : (
          <div className="border border-zinc-900">
            <Table>
              <TableHeader>
                <TableRow className="border-zinc-900 bg-zinc-950 hover:bg-zinc-950">
                  {["BORROWER", "PRINCIPAL", "TOTAL DEBT", "COLLATERAL VALUE", "RATE P.A.", "MATURITY", "STATUS"].map((h) => (
                    <TableHead key={h} className={`text-[10px] tracking-widest text-zinc-600 font-bold py-2.5 ${h !== "BORROWER" ? "text-right" : ""}`}>
                      {h}
                    </TableHead>
                  ))}
                </TableRow>
              </TableHeader>
              <TableBody>
                {positions.map(({ borrower, pos, debt, collateralValue, healthy }) => (
                  <TableRow key={borrower} className="border-zinc-900 hover:bg-zinc-950">
                    <TableCell className="text-xs text-amber-400 py-3">{truncate(borrower)}</TableCell>
                    <TableCell className="text-xs text-zinc-100 text-right tabular-nums">{fmt(pos.principal)}</TableCell>
                    <TableCell className="text-xs text-zinc-100 text-right tabular-nums">{fmt(debt as bigint)}</TableCell>
                    <TableCell className="text-xs text-zinc-100 text-right tabular-nums">{fmt(collateralValue as bigint)}</TableCell>
                    <TableCell className="text-xs text-zinc-100 text-right tabular-nums">{fmtRate(pos.rateBps)}</TableCell>
                    <TableCell className="text-xs text-zinc-100 text-right">{fmtMaturity(pos.maturity)}</TableCell>
                    <TableCell className="text-right">
                      <span className={`text-[10px] font-bold tracking-widest px-2 py-0.5 border ${
                        healthy
                          ? "text-emerald-400 border-emerald-900 bg-emerald-950"
                          : "text-red-400 border-red-900 bg-red-950"
                      }`}>
                        {healthy ? "HEALTHY" : "MARGIN CALL"}
                      </span>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </div>
    </main>
  )
}
