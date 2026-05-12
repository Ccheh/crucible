import type { Hex } from "./types.js";

export interface ArcChain {
  chainId: number;
  rpc: string;
  explorer: string;
}

export const ARC_TESTNET: ArcChain = {
  chainId: 5042002,
  rpc: "https://rpc.testnet.arc.network",
  explorer: "https://testnet.arcscan.app",
};

/** Canonical Crucible v0 deployments on Arc Testnet. */
export const CRUCIBLE_ARC_TESTNET = {
  market: "0x61996d505d6510a339f39c9923519b2f5350f61c" as Hex,
  testcaseResolver: "0xa12874e9f77be35efb9e3aeb19eb547b9f224195" as Hex,
  mockResolver: "0x76696e3c541eb32c81cfc1cbfb3e5e5ef1c4d35f" as Hex,
} as const;

export const CRUCIBLE_MARKET_ABI = [
  { type: "function", name: "depositBond", stateMutability: "payable", inputs: [], outputs: [] },
  {
    type: "function", name: "withdrawBond", stateMutability: "nonpayable",
    inputs: [{ name: "amount", type: "uint256" }], outputs: [],
  },
  {
    type: "function", name: "setResolverAllowed", stateMutability: "nonpayable",
    inputs: [
      { name: "resolver", type: "address" },
      { name: "allowed", type: "bool" },
    ], outputs: [],
  },
  {
    type: "function", name: "bondPool", stateMutability: "view",
    inputs: [{ type: "address" }], outputs: [{ type: "uint256" }],
  },
  {
    type: "function", name: "bondLocked", stateMutability: "view",
    inputs: [{ type: "address" }], outputs: [{ type: "uint256" }],
  },
  {
    type: "function", name: "bondAvailable", stateMutability: "view",
    inputs: [{ type: "address" }], outputs: [{ type: "uint256" }],
  },
  {
    type: "function", name: "openMarket", stateMutability: "payable",
    inputs: [
      {
        name: "auth", type: "tuple",
        components: [
          { name: "service", type: "address" },
          { name: "agent", type: "address" },
          { name: "resolver", type: "address" },
          { name: "amount", type: "uint256" },
          { name: "bondLockAmount", type: "uint256" },
          { name: "commitmentHash", type: "bytes32" },
          { name: "disputeWindow", type: "uint64" },
          { name: "nonce", type: "uint256" },
          { name: "authExpiry", type: "uint256" },
        ],
      },
      { name: "signature", type: "bytes" },
    ],
    outputs: [{ name: "marketId", type: "bytes32" }],
  },
  {
    type: "function", name: "dispute", stateMutability: "nonpayable",
    inputs: [{ name: "marketId", type: "bytes32" }], outputs: [],
  },
  {
    type: "function", name: "collectAfterWindow", stateMutability: "nonpayable",
    inputs: [{ name: "marketId", type: "bytes32" }], outputs: [],
  },
  {
    type: "function", name: "resolveDisputed", stateMutability: "nonpayable",
    inputs: [
      { name: "marketId", type: "bytes32" },
      { name: "resolverData", type: "bytes" },
    ], outputs: [],
  },
  {
    type: "function", name: "marketIdOf", stateMutability: "pure",
    inputs: [
      { type: "address" },
      { type: "address" },
      { type: "uint256" },
    ],
    outputs: [{ type: "bytes32" }],
  },
  {
    type: "function", name: "markets", stateMutability: "view",
    inputs: [{ type: "bytes32" }],
    outputs: [
      { name: "service", type: "address" },
      { name: "agent", type: "address" },
      { name: "resolver", type: "address" },
      { name: "agentEscrow", type: "uint256" },
      { name: "bondLocked", type: "uint256" },
      { name: "commitmentHash", type: "bytes32" },
      { name: "disputeDeadline", type: "uint64" },
      { name: "scoreBps", type: "uint16" },
      { name: "status", type: "uint8" },
    ],
  },
] as const;

export const TESTCASE_RESOLVER_ABI = [
  { type: "function", name: "stake", stateMutability: "payable", inputs: [], outputs: [] },
  {
    type: "function", name: "requestUnstake", stateMutability: "nonpayable",
    inputs: [{ name: "amount", type: "uint256" }], outputs: [],
  },
  { type: "function", name: "completeUnstake", stateMutability: "nonpayable", inputs: [], outputs: [] },
  {
    type: "function", name: "vote", stateMutability: "nonpayable",
    inputs: [
      { name: "marketId", type: "bytes32" },
      { name: "scoreBps", type: "uint16" },
    ], outputs: [],
  },
  {
    type: "function", name: "validatorStake", stateMutability: "view",
    inputs: [{ type: "address" }], outputs: [{ type: "uint256" }],
  },
  { type: "function", name: "totalStake", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function", name: "getMarket", stateMutability: "view",
    inputs: [{ type: "bytes32" }],
    outputs: [
      { name: "votingDeadline", type: "uint64" },
      { name: "finalScore", type: "uint16" },
      { name: "resolved", type: "bool" },
      { name: "voterCount", type: "uint256" },
    ],
  },
  { type: "function", name: "name", stateMutability: "pure", inputs: [], outputs: [{ type: "string" }] },
] as const;

/** Market status values matching the Solidity enum. */
export const MarketStatus = {
  None: 0,
  Open: 1,
  Disputed: 2,
  Resolved: 3,
} as const;
