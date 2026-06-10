"use client"

import { useState } from "react"
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from "wagmi"
import { parseUnits } from "viem"
import { useRouter } from "next/navigation"
import {
  VAULT_ADDRESS, VAULT_WRITE_ABI,
  MUSDC_ADDRESS, MUSYC_ADDRESS, ERC20_ABI,
  COLLATERAL_TOKENS,
} from "@/config/contracts"

type Tab = "mint" | "lend" | "borrow" | "repay" | "admin"

function useTx() {
  const router = useRouter()
  const { writeContract, data: hash, isPending } = useWriteContract()
  const { isLoading: waiting, isSuccess } = useWaitForTransactionReceipt({ hash })
  if (isSuccess) router.refresh()
  return { writeContract, isPending, waiting, isSuccess }
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-1">
      <p className="text-[10px] text-zinc-600 tracking-widest">{label}</p>
      {children}
    </div>
  )
}

function Input({ placeholder, value, onChange }: { placeholder: string; value: string; onChange: (v: string) => void }) {
  return (
    <input type="number" placeholder={placeholder} value={value} onChange={(e) => onChange(e.target.value)}
      className="w-full bg-zinc-950 border border-zinc-800 text-zinc-100 text-xs font-mono px-3 py-2 focus:outline-none focus:border-amber-700" />
  )
}

function TxButton({ onClick, disabled, pending, waiting, success, label, pendingLabel, successLabel }: {
  onClick: () => void; disabled: boolean; pending: boolean; waiting: boolean; success: boolean;
  label: string; pendingLabel: string; successLabel: string;
}) {
  return (
    <button onClick={onClick} disabled={disabled || pending || waiting}
      className="flex-1 text-xs font-mono py-2 border border-zinc-700 text-zinc-300 hover:border-amber-700 hover:text-amber-400 disabled:opacity-30 disabled:cursor-not-allowed transition-colors">
      {pending || waiting ? pendingLabel : success ? successLabel : label}
    </button>
  )
}

// ── MINT ─────────────────────────────────────────────────────────────────────
function MintTab() {
  const { address } = useAccount()
  const [token, setToken] = useState<string>(MUSDC_ADDRESS)
  const [to, setTo] = useState("")
  const [amount, setAmount] = useState("")
  const decimals = token === MUSYC_ADDRESS || token === MUSDC_ADDRESS ? 6 : 18
  const { writeContract, isPending, waiting, isSuccess } = useTx()

  if (!address) return <p className="text-xs text-zinc-600 tracking-widest">CONNECT WALLET TO TRANSACT</p>

  return (
    <div className="space-y-3">
      <p className="text-[10px] text-zinc-600 tracking-widest">Deployer wallet only — mints test tokens</p>
      <Row label="TOKEN">
        <select value={token} onChange={(e) => setToken(e.target.value)}
          className="w-full bg-zinc-950 border border-zinc-800 text-zinc-100 text-xs font-mono px-3 py-2 focus:outline-none focus:border-amber-700">
          <option value={MUSDC_ADDRESS}>mUSDC (cash)</option>
          {COLLATERAL_TOKENS.map(t => <option key={t.address} value={t.address}>{t.label}</option>)}
        </select>
      </Row>
      <Row label="RECIPIENT"><Input placeholder="0x… (leave blank for self)" value={to} onChange={setTo} /></Row>
      <Row label="AMOUNT"><Input placeholder="Amount" value={amount} onChange={setAmount} /></Row>
      <TxButton
        onClick={() => writeContract({
          address: token as `0x${string}`,
          abi: ERC20_ABI,
          functionName: "mint",
          args: [((to || address) as `0x${string}`), parseUnits(amount || "0", decimals)],
        })}
        disabled={!amount}
        pending={isPending} waiting={waiting} success={isSuccess}
        label="MINT" pendingLabel="MINTING…" successLabel="✓ MINTED"
      />
    </div>
  )
}

// ── LEND ─────────────────────────────────────────────────────────────────────
function LendTab() {
  const { address } = useAccount()
  const [amount, setAmount] = useState("")
  const rawAmount = parseUnits(amount || "0", 6)

  const approve = useTx()
  const deposit = useTx()

  if (!address) return <p className="text-xs text-zinc-600 tracking-widest">CONNECT WALLET TO TRANSACT</p>

  return (
    <div className="space-y-3">
      <Row label="USDC AMOUNT"><Input placeholder="Amount to deposit" value={amount} onChange={setAmount} /></Row>
      <div className="flex gap-2">
        <TxButton
          onClick={() => approve.writeContract({ address: MUSDC_ADDRESS, abi: ERC20_ABI, functionName: "approve", args: [VAULT_ADDRESS, rawAmount] })}
          disabled={!amount} pending={approve.isPending} waiting={approve.waiting} success={approve.isSuccess}
          label="1. APPROVE" pendingLabel="APPROVING…" successLabel="✓ APPROVED"
        />
        <TxButton
          onClick={() => deposit.writeContract({ address: VAULT_ADDRESS, abi: VAULT_WRITE_ABI, functionName: "deposit", args: [rawAmount] })}
          disabled={!approve.isSuccess} pending={deposit.isPending} waiting={deposit.waiting} success={deposit.isSuccess}
          label="2. DEPOSIT" pendingLabel="DEPOSITING…" successLabel="✓ DEPOSITED"
        />
      </div>
    </div>
  )
}

// ── BORROW ────────────────────────────────────────────────────────────────────
function BorrowTab() {
  const { address } = useAccount()
  const [token, setToken] = useState<`0x${string}`>(COLLATERAL_TOKENS[0].address)
  const [collateralAmt, setCollateralAmt] = useState("")
  const [cashAmt, setCashAmt] = useState("")
  const [rateBps, setRateBps] = useState("")
  const [termDays, setTermDays] = useState("")

  const tokenDecimals = token === MUSYC_ADDRESS ? 6 : 18
  const rawCollateral = parseUnits(collateralAmt || "0", tokenDecimals)
  const rawCash = parseUnits(cashAmt || "0", 6)
  const termSeconds = BigInt(Math.floor(Number(termDays || "0") * 86400))

  const approve = useTx()
  const open = useTx()

  if (!address) return <p className="text-xs text-zinc-600 tracking-widest">CONNECT WALLET TO TRANSACT</p>

  return (
    <div className="space-y-3">
      <Row label="COLLATERAL TOKEN">
        <select value={token} onChange={(e) => setToken(e.target.value as `0x${string}`)}
          className="w-full bg-zinc-950 border border-zinc-800 text-zinc-100 text-xs font-mono px-3 py-2 focus:outline-none focus:border-amber-700">
          {COLLATERAL_TOKENS.map(t => <option key={t.address} value={t.address}>{t.label}</option>)}
        </select>
      </Row>
      <div className="grid grid-cols-2 gap-2">
        <Row label="COLLATERAL AMOUNT"><Input placeholder="e.g. 100" value={collateralAmt} onChange={setCollateralAmt} /></Row>
        <Row label="CASH TO DRAW (USDC)"><Input placeholder="e.g. 98" value={cashAmt} onChange={setCashAmt} /></Row>
        <Row label="RATE (BPS)"><Input placeholder="e.g. 50 = 0.5%" value={rateBps} onChange={setRateBps} /></Row>
        <Row label="TERM (DAYS, 0 = OPEN)"><Input placeholder="e.g. 30" value={termDays} onChange={setTermDays} /></Row>
      </div>
      <div className="flex gap-2">
        <TxButton
          onClick={() => approve.writeContract({ address: token, abi: ERC20_ABI, functionName: "approve", args: [VAULT_ADDRESS, rawCollateral] })}
          disabled={!collateralAmt} pending={approve.isPending} waiting={approve.waiting} success={approve.isSuccess}
          label="1. APPROVE" pendingLabel="APPROVING…" successLabel="✓ APPROVED"
        />
        <TxButton
          onClick={() => open.writeContract({ address: VAULT_ADDRESS, abi: VAULT_WRITE_ABI, functionName: "open", args: [token, rawCollateral, rawCash, BigInt(rateBps || "0"), termSeconds] })}
          disabled={!approve.isSuccess} pending={open.isPending} waiting={open.waiting} success={open.isSuccess}
          label="2. OPEN REPO" pendingLabel="OPENING…" successLabel="✓ OPENED"
        />
      </div>
    </div>
  )
}

// ── REPAY ─────────────────────────────────────────────────────────────────────
function RepayTab() {
  const { address } = useAccount()
  const [amount, setAmount] = useState("")
  const rawAmount = parseUnits(amount || "0", 6)

  const approve = useTx()
  const repay = useTx()

  if (!address) return <p className="text-xs text-zinc-600 tracking-widest">CONNECT WALLET TO TRANSACT</p>

  return (
    <div className="space-y-3">
      <Row label="REPAY AMOUNT (USDC)"><Input placeholder="Amount (principal + interest)" value={amount} onChange={setAmount} /></Row>
      <div className="flex gap-2">
        <TxButton
          onClick={() => approve.writeContract({ address: MUSDC_ADDRESS, abi: ERC20_ABI, functionName: "approve", args: [VAULT_ADDRESS, rawAmount] })}
          disabled={!amount} pending={approve.isPending} waiting={approve.waiting} success={approve.isSuccess}
          label="1. APPROVE" pendingLabel="APPROVING…" successLabel="✓ APPROVED"
        />
        <TxButton
          onClick={() => repay.writeContract({ address: VAULT_ADDRESS, abi: VAULT_WRITE_ABI, functionName: "repay", args: [rawAmount] })}
          disabled={!approve.isSuccess} pending={repay.isPending} waiting={repay.waiting} success={repay.isSuccess}
          label="2. REPAY" pendingLabel="REPAYING…" successLabel="✓ REPAID"
        />
      </div>
    </div>
  )
}

// ── ADMIN ─────────────────────────────────────────────────────────────────────
function AdminTab() {
  const { address } = useAccount()
  const [borrower, setBorrower] = useState("")
  const marginCall = useTx()
  const liquidate = useTx()

  if (!address) return <p className="text-xs text-zinc-600 tracking-widest">CONNECT WALLET TO TRANSACT</p>

  return (
    <div className="space-y-3">
      <p className="text-[10px] text-zinc-600 tracking-widest">Liquidator role required</p>
      <Row label="BORROWER ADDRESS"><Input placeholder="0x…" value={borrower} onChange={setBorrower} /></Row>
      <div className="flex gap-2">
        <TxButton
          onClick={() => marginCall.writeContract({ address: VAULT_ADDRESS, abi: VAULT_WRITE_ABI, functionName: "triggerMarginCall", args: [borrower as `0x${string}`] })}
          disabled={!borrower} pending={marginCall.isPending} waiting={marginCall.waiting} success={marginCall.isSuccess}
          label="MARGIN CALL" pendingLabel="SENDING…" successLabel="✓ TRIGGERED"
        />
        <TxButton
          onClick={() => liquidate.writeContract({ address: VAULT_ADDRESS, abi: VAULT_WRITE_ABI, functionName: "liquidate", args: [borrower as `0x${string}`] })}
          disabled={!borrower || !marginCall.isSuccess} pending={liquidate.isPending} waiting={liquidate.waiting} success={liquidate.isSuccess}
          label="LIQUIDATE" pendingLabel="LIQUIDATING…" successLabel="✓ LIQUIDATED"
        />
      </div>
    </div>
  )
}

// ── WRAPPER ───────────────────────────────────────────────────────────────────
const TABS: { id: Tab; label: string }[] = [
  { id: "mint",   label: "MINT"   },
  { id: "lend",   label: "LEND"   },
  { id: "borrow", label: "BORROW" },
  { id: "repay",  label: "REPAY"  },
  { id: "admin",  label: "ADMIN"  },
]

export function ActionPanel() {
  const [tab, setTab] = useState<Tab>("lend")

  return (
    <div className="border border-zinc-900">
      <div className="flex border-b border-zinc-900">
        {TABS.map((t) => (
          <button key={t.id} onClick={() => setTab(t.id)}
            className={`flex-1 text-[10px] font-bold tracking-widest py-2.5 transition-colors ${
              tab === t.id ? "text-amber-400 border-b-2 border-amber-500 bg-zinc-950" : "text-zinc-600 hover:text-zinc-400"
            }`}>
            {t.label}
          </button>
        ))}
      </div>
      <div className="p-4">
        {tab === "mint"   && <MintTab />}
        {tab === "lend"   && <LendTab />}
        {tab === "borrow" && <BorrowTab />}
        {tab === "repay"  && <RepayTab />}
        {tab === "admin"  && <AdminTab />}
      </div>
    </div>
  )
}
