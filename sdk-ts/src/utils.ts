import { keccak256, encodeAbiParameters } from "viem";
import type { OpenAuth, Hex } from "./types.js";

/** Build the EIP-712 domain for a deployed CrucibleMarket. */
export function buildDomain(marketAddress: Hex, chainId: number) {
  return {
    name: "Crucible",
    version: "1",
    chainId,
    verifyingContract: marketAddress,
  } as const;
}

/** EIP-712 type definition for OpenAuth. */
export const OPEN_AUTH_TYPES = {
  OpenAuth: [
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
} as const;

/** Deterministic market id matching the on-chain `_marketId(service, agent, nonce)`. */
export function computeMarketId(service: Hex, agent: Hex, nonce: bigint): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "address" }, { type: "uint256" }],
      [service, agent, nonce]
    )
  );
}

/** Random 128-bit nonce that fits in uint256. */
export function randomNonce(): bigint {
  const buf = new Uint8Array(16);
  crypto.getRandomValues(buf);
  let n = 0n;
  for (const b of buf) n = (n << 8n) | BigInt(b);
  return n;
}

/** Helper: compute commitment hash for code-gen use case. Off-chain convention. */
export function codeGenCommitment(opts: {
  input: string;
  testcases: string;
  expectedOutputHash: Hex;
}): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "string" }, { type: "string" }, { type: "bytes32" }],
      [opts.input, opts.testcases, opts.expectedOutputHash]
    )
  );
}
