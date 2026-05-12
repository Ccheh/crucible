export type Hex = `0x${string}`;

/** The EIP-712 OpenAuth message signed by a service to authorize a market opening. */
export interface OpenAuth {
  service: Hex;
  agent: Hex;
  resolver: Hex;
  amount: bigint;
  bondLockAmount: bigint;
  commitmentHash: Hex;
  disputeWindow: bigint;     // seconds
  nonce: bigint;
  authExpiry: bigint;        // unix seconds
}

export interface SignedOpenAuth {
  auth: OpenAuth;
  signature: Hex;
}

export interface MarketState {
  service: Hex;
  agent: Hex;
  resolver: Hex;
  agentEscrow: bigint;
  bondLocked: bigint;
  commitmentHash: Hex;
  disputeDeadline: bigint;
  scoreBps: number;
  status: number;            // 0=None, 1=Open, 2=Disputed, 3=Resolved
}

export interface ValidatorMarketState {
  votingDeadline: bigint;
  finalScore: number;
  resolved: boolean;
  voterCount: bigint;
}
