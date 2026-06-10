"use client"

import { useEffect, useState } from "react"
import { useAccount, useConnect, useDisconnect, useConfig } from "wagmi"

export function WalletButton() {
  const [mounted, setMounted] = useState(false)
  useEffect(() => setMounted(true), [])

  const { address, isConnected } = useAccount()
  const { connect } = useConnect()
  const { disconnect } = useDisconnect()
  const { connectors } = useConfig()

  if (!mounted) return null

  if (isConnected && address) {
    return (
      <button
        onClick={() => disconnect()}
        className="text-xs font-mono text-amber-400 border border-amber-900 px-3 py-1 hover:bg-amber-950 transition-colors"
      >
        {address.slice(0, 6)}…{address.slice(-4)} · disconnect
      </button>
    )
  }

  return (
    <div className="flex gap-2">
      {connectors.map((connector) => (
        <button
          key={connector.uid}
          onClick={() => connect({ connector })}
          className="text-xs font-mono text-zinc-400 border border-zinc-800 px-3 py-1 hover:border-amber-900 hover:text-amber-400 transition-colors"
        >
          {connector.name}
        </button>
      ))}
    </div>
  )
}
