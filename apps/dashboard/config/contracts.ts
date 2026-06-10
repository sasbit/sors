export const VAULT_ADDRESS = "0x9Aa1913b7ECfA45CB957f223571fc671b12a64E7" as const
export const CHAIN_ID = 11155111 // Sepolia

export const VAULT_ABI = [
  // pool state
  { name: "poolValue",           type: "function", stateMutability: "view", inputs: [],                              outputs: [{ type: "uint256" }] },
  { name: "freeCash",            type: "function", stateMutability: "view", inputs: [],                              outputs: [{ type: "uint256" }] },
  { name: "utilization",         type: "function", stateMutability: "view", inputs: [],                              outputs: [{ type: "uint256" }] },
  { name: "collateralTokenCount",type: "function", stateMutability: "view", inputs: [],                              outputs: [{ type: "uint256" }] },
  // per-borrower
  { name: "totalDebt",           type: "function", stateMutability: "view", inputs: [{ name: "borrower", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "totalCollateralValue",type: "function", stateMutability: "view", inputs: [{ name: "borrower", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "isAboveMaintenanceMargin", type: "function", stateMutability: "view", inputs: [{ name: "borrower", type: "address" }], outputs: [{ type: "bool" }] },
  { name: "positions",           type: "function", stateMutability: "view", inputs: [{ name: "borrower", type: "address" }],
    outputs: [{ type: "tuple", components: [
      { name: "principal",       type: "uint256" },
      { name: "rateBps",         type: "uint256" },
      { name: "startTimestamp",  type: "uint256" },
      { name: "interestAccrued", type: "uint256" },
      { name: "maturity",        type: "uint256" },
      { name: "terminationAt",   type: "uint256" },
      { name: "marginCallAt",    type: "uint256" },
      { name: "earlyTermProposed", type: "bool"  },
    ]}]
  },
  // events
  { name: "Opened",         type: "event", inputs: [{ name: "borrower",  type: "address", indexed: true  }, { name: "token",       type: "address", indexed: true  }, { name: "collateralAmt", type: "uint256", indexed: false }, { name: "cashAmt",       type: "uint256", indexed: false }, { name: "rateBps",       type: "uint256", indexed: false }, { name: "maturity",      type: "uint256", indexed: false }] },
  { name: "Repaid",         type: "event", inputs: [{ name: "borrower",  type: "address", indexed: true  }, { name: "principalPaid", type: "uint256", indexed: false }, { name: "interestPaid", type: "uint256", indexed: false }] },
  { name: "MarginCall",     type: "event", inputs: [{ name: "borrower",  type: "address", indexed: true  }] },
  { name: "Liquidated",     type: "event", inputs: [{ name: "borrower",  type: "address", indexed: true  }, { name: "debtCleared",  type: "uint256", indexed: false }] },
  { name: "PositionExpired",type: "event", inputs: [{ name: "borrower",  type: "address", indexed: true  }, { name: "debtCleared",  type: "uint256", indexed: false }] },
] as const

export const KNOWN_BORROWERS: `0x${string}`[] = [
  "0xc06479E86e43B200464f5582Ce77fAD38860D4e7",
]

export const MUSDC_ADDRESS  = "0x062db38c83b4a9bb719a6e8f3a4fd6c748313c02" as const
export const MBUIDL_ADDRESS = "0x64100b083e85886baa77334b32d1568d7ea8e855" as const
export const MUSYC_ADDRESS  = "0x5dddb22bd74d931c7a823a759a4eba493cbb3d63" as const
export const MOUSG_ADDRESS  = "0xe88862403c198e227f17232cbbb6c638714dbee8" as const

export const COLLATERAL_TOKENS = [
  { label: "mBUIDL", address: MBUIDL_ADDRESS},
  { label: "mUSYC",  address: MUSYC_ADDRESS  },
  { label: "mOUSG",  address: MOUSG_ADDRESS  },
] as const

export const ERC20_ABI = [
  { name: "approve",  type: "function", stateMutability: "nonpayable", inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }], outputs: [{ type: "bool" }] },
  { name: "balanceOf",type: "function", stateMutability: "view",       inputs: [{ name: "account", type: "address" }],                                     outputs: [{ type: "uint256" }] },
  { name: "mint",     type: "function", stateMutability: "nonpayable", inputs: [{ name: "to", type: "address" }, { name: "amount", type: "uint256" }],     outputs: [] },
] as const

export const VAULT_WRITE_ABI = [
  { name: "deposit",          type: "function", stateMutability: "nonpayable", inputs: [{ name: "cashAmt", type: "uint256" }], outputs: [] },
  { name: "withdraw",         type: "function", stateMutability: "nonpayable", inputs: [{ name: "shares",  type: "uint256" }], outputs: [] },
  { name: "repay",            type: "function", stateMutability: "nonpayable", inputs: [{ name: "amount",  type: "uint256" }], outputs: [] },
  { name: "triggerMarginCall",type: "function", stateMutability: "nonpayable", inputs: [{ name: "borrower", type: "address" }], outputs: [] },
  { name: "liquidate",        type: "function", stateMutability: "nonpayable", inputs: [{ name: "borrower", type: "address" }], outputs: [] },
  { name: "open", type: "function", stateMutability: "nonpayable", inputs: [
    { name: "token",         type: "address" },
    { name: "collateralAmt", type: "uint256" },
    { name: "cashAmt",       type: "uint256" },
    { name: "rateBps",       type: "uint256" },
    { name: "termSeconds",   type: "uint256" },
  ], outputs: [] },
] as const

// lenderClaim needs to be read per-address — add to VAULT_ABI reads
export const VAULT_READ_EXTRA_ABI = [
  { name: "lenderClaim", type: "function", stateMutability: "view", inputs: [{ name: "lender", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "lenderShares", type: "function", stateMutability: "view", inputs: [{ name: "lender", type: "address" }], outputs: [{ type: "uint256" }] },
] as const