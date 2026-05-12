import type { Hex } from "../types.js";

/** Canonical Crucible v0.6 deployments on Arc Testnet. */
export const CRUCIBLE_V6_ARC_TESTNET = {
  market: "0x6535a3cbb4235746b732ab5d55c6b0988f381a20" as Hex,
  resolver: "0x51cc924fe83dc5221150f5752454a37121be3957" as Hex,
} as const;

/** Subset of CrucibleMarketV6 ABI covering all SDK-used functions. */
export const CRUCIBLE_MARKET_V6_ABI = [
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
    type: "function", name: "requiredDisputeBond", stateMutability: "view",
    inputs: [{ name: "marketId", type: "bytes32" }],
    outputs: [{ type: "uint256" }],
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
          { name: "disputeBondBps", type: "uint16" },
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
    type: "function", name: "dispute", stateMutability: "payable",
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
    type: "function", name: "forceResolveStale", stateMutability: "nonpayable",
    inputs: [{ name: "marketId", type: "bytes32" }], outputs: [],
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
      { name: "disputeBond", type: "uint256" },
      { name: "disputeBondBps", type: "uint16" },
      { name: "commitmentHash", type: "bytes32" },
      { name: "disputeDeadline", type: "uint64" },
      { name: "disputedAt", type: "uint64" },
      { name: "scoreBps", type: "uint16" },
      { name: "status", type: "uint8" },
    ],
  },
] as const;

/** Subset of TestcaseResolverV5 ABI covering all SDK-used functions. */
export const TESTCASE_RESOLVER_V5_ABI = [
  { type: "function", name: "stake", stateMutability: "payable", inputs: [], outputs: [] },
  {
    type: "function", name: "requestUnstake", stateMutability: "nonpayable",
    inputs: [{ name: "amount", type: "uint256" }], outputs: [],
  },
  { type: "function", name: "completeUnstake", stateMutability: "nonpayable", inputs: [], outputs: [] },
  {
    type: "function", name: "commitVote", stateMutability: "nonpayable",
    inputs: [
      { name: "marketId", type: "bytes32" },
      { name: "voteHash", type: "bytes32" },
    ], outputs: [],
  },
  {
    type: "function", name: "revealVote", stateMutability: "nonpayable",
    inputs: [
      { name: "marketId", type: "bytes32" },
      { name: "scoreBps", type: "uint16" },
      { name: "salt", type: "bytes32" },
    ], outputs: [],
  },
  {
    type: "function", name: "computeVoteHash", stateMutability: "pure",
    inputs: [
      { name: "scoreBps", type: "uint16" },
      { name: "salt", type: "bytes32" },
      { name: "marketId", type: "bytes32" },
      { name: "voter", type: "address" },
    ],
    outputs: [{ type: "bytes32" }],
  },
  { type: "function", name: "claimRewards", stateMutability: "nonpayable", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "claimSubscription", stateMutability: "nonpayable", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function", name: "earnedSubscription", stateMutability: "view",
    inputs: [{ type: "address" }], outputs: [{ type: "uint256" }],
  },
  {
    type: "function", name: "pendingReward", stateMutability: "view",
    inputs: [{ type: "address" }], outputs: [{ type: "uint256" }],
  },
  {
    type: "function", name: "validatorStake", stateMutability: "view",
    inputs: [{ type: "address" }], outputs: [{ type: "uint256" }],
  },
  { type: "function", name: "totalStake", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "MIN_STAKE", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function", name: "getMarket", stateMutability: "view",
    inputs: [{ type: "bytes32" }],
    outputs: [
      { name: "commitDeadline", type: "uint64" },
      { name: "revealDeadline", type: "uint64" },
      { name: "finalScoreBps", type: "uint16" },
      { name: "resolved", type: "bool" },
      { name: "voterCount", type: "uint256" },
      { name: "feePool", type: "uint256" },
    ],
  },
  { type: "function", name: "name", stateMutability: "pure", inputs: [], outputs: [{ type: "string" }] },
] as const;
