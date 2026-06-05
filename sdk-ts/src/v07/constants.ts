import type { Hex } from "../types.js";

/** Canonical Crucible v0.7 (graded-resolution layer) deployments on Arc Testnet
 *  (chain 5042002). See docs/repositioning-v0.7.md. */
export const CRUCIBLE_V7_ARC_TESTNET = {
  market: "0x9934bAF33bcF0dfD14040f8ddd5DdF18eCfEFb59" as Hex,
  resolver: "0x85b332122371f3c08253844B6170e8daC0c8c2fB" as Hex,
  erc8183Adapter: "0x44A0a6DEFE24F8CA84a3E5390Ab3f656Db306CaB" as Hex,
} as const;

/** Dispute lens declared by the agent on `dispute(marketId, kind)`. Must not be
 *  Unspecified (0). */
export enum DisputeKind {
  Unspecified = 0,
  Objective = 1,
  Intersubjective = 2,
}

/** EIP-712 domain for CrucibleMarketV7. Note: version "7". */
export function crucibleV7Domain(marketAddress: Hex, chainId: number) {
  return {
    name: "Crucible",
    version: "7",
    chainId,
    verifyingContract: marketAddress,
  } as const;
}

/** EIP-712 `OpenAuth` struct types for viem `signTypedData`. v0.7 adds
 *  `criteriaHash` (the pre-committed resolution rubric) after `commitmentHash`. */
export const OPEN_AUTH_TYPES_V7 = {
  OpenAuth: [
    { name: "service", type: "address" },
    { name: "agent", type: "address" },
    { name: "resolver", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "bondLockAmount", type: "uint256" },
    { name: "disputeBondBps", type: "uint16" },
    { name: "commitmentHash", type: "bytes32" },
    { name: "criteriaHash", type: "bytes32" },
    { name: "disputeWindow", type: "uint64" },
    { name: "nonce", type: "uint256" },
    { name: "authExpiry", type: "uint256" },
  ],
} as const;

/** Subset of CrucibleMarketV7 ABI covering all SDK-used functions. */
export const CRUCIBLE_MARKET_V7_ABI = [
  { type: "function", name: "depositBond", stateMutability: "payable", inputs: [], outputs: [] },
  { type: "function", name: "withdrawBond", stateMutability: "nonpayable", inputs: [{ name: "amount", type: "uint256" }], outputs: [] },
  {
    type: "function", name: "setResolverAllowed", stateMutability: "nonpayable",
    inputs: [{ name: "resolver", type: "address" }, { name: "allowed", type: "bool" }], outputs: [],
  },
  { type: "function", name: "bondAvailable", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "requiredDisputeBond", stateMutability: "view", inputs: [{ name: "marketId", type: "bytes32" }], outputs: [{ type: "uint256" }] },
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
          { name: "criteriaHash", type: "bytes32" }, // v0.7
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
    // v0.7: dispute now takes a typed DisputeKind.
    type: "function", name: "dispute", stateMutability: "payable",
    inputs: [{ name: "marketId", type: "bytes32" }, { name: "kind", type: "uint8" }], outputs: [],
  },
  { type: "function", name: "collectAfterWindow", stateMutability: "nonpayable", inputs: [{ name: "marketId", type: "bytes32" }], outputs: [] },
  { type: "function", name: "resolveDisputed", stateMutability: "nonpayable", inputs: [{ name: "marketId", type: "bytes32" }, { name: "resolverData", type: "bytes" }], outputs: [] },
  { type: "function", name: "forceResolveStale", stateMutability: "nonpayable", inputs: [{ name: "marketId", type: "bytes32" }], outputs: [] },
  { type: "function", name: "marketIdOf", stateMutability: "pure", inputs: [{ type: "address" }, { type: "address" }, { type: "uint256" }], outputs: [{ type: "bytes32" }] },
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
      { name: "criteriaHash", type: "bytes32" },     // v0.7
      { name: "disputeDeadline", type: "uint64" },
      { name: "disputedAt", type: "uint64" },
      { name: "scoreBps", type: "uint16" },
      { name: "status", type: "uint8" },
      { name: "disputeKind", type: "uint8" },         // v0.7
      { name: "decouplingActive", type: "bool" },     // v0.7
    ],
  },
] as const;

/** Subset of ScalarResolverV7 ABI. Validator-facing funcs match v0.5; v0.7 adds
 *  `onDispute` (market-only), `conflicted`, and `AUTHORIZED_MARKET`. */
export const SCALAR_RESOLVER_V7_ABI = [
  { type: "function", name: "stake", stateMutability: "payable", inputs: [], outputs: [] },
  { type: "function", name: "requestUnstake", stateMutability: "nonpayable", inputs: [{ name: "amount", type: "uint256" }], outputs: [] },
  { type: "function", name: "completeUnstake", stateMutability: "nonpayable", inputs: [], outputs: [] },
  { type: "function", name: "commitVote", stateMutability: "nonpayable", inputs: [{ name: "marketId", type: "bytes32" }, { name: "voteHash", type: "bytes32" }], outputs: [] },
  { type: "function", name: "revealVote", stateMutability: "nonpayable", inputs: [{ name: "marketId", type: "bytes32" }, { name: "scoreBps", type: "uint16" }, { name: "salt", type: "bytes32" }], outputs: [] },
  {
    type: "function", name: "computeVoteHash", stateMutability: "pure",
    inputs: [{ name: "scoreBps", type: "uint16" }, { name: "salt", type: "bytes32" }, { name: "marketId", type: "bytes32" }, { name: "voter", type: "address" }],
    outputs: [{ type: "bytes32" }],
  },
  { type: "function", name: "claimRewards", stateMutability: "nonpayable", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "claimSubscription", stateMutability: "nonpayable", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "earnedSubscription", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "validatorStake", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "MIN_STAKE", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "AUTHORIZED_MARKET", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "conflicted", stateMutability: "view", inputs: [{ type: "bytes32" }, { type: "address" }], outputs: [{ type: "bool" }] },
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
] as const;

/** Subset of Erc8183ProportionalAdapter ABI. */
export const ERC8183_ADAPTER_ABI = [
  {
    type: "function", name: "register", stateMutability: "payable",
    inputs: [{ name: "id", type: "bytes32" }, { name: "payer", type: "address" }, { name: "payee", type: "address" }, { name: "marketId", type: "bytes32" }],
    outputs: [],
  },
  { type: "function", name: "settle", stateMutability: "nonpayable", inputs: [{ name: "id", type: "bytes32" }], outputs: [] },
  {
    type: "function", name: "previewSplit", stateMutability: "pure",
    inputs: [{ name: "amount", type: "uint256" }, { name: "scoreBps", type: "uint16" }],
    outputs: [{ name: "toPayee", type: "uint256" }, { name: "toPayer", type: "uint256" }],
  },
] as const;
