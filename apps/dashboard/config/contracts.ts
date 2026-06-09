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
