import { createConfig, http } from "wagmi"
import { sepolia } from "wagmi/chains"
import { injected, walletConnect } from "wagmi/connectors"

export const wagmiConfig = createConfig({
  chains: [sepolia],
  connectors: [
    injected(),
    walletConnect({
      projectId: process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID!,
    }),
  ],
  transports: {
    [sepolia.id]: http(process.env.NEXT_PUBLIC_ALCHEMY_URL),
  },
})
    