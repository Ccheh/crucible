import { keccak256, encodeAbiParameters } from "viem";
import type { Hex } from "../types.js";

/** EIP-712 domain for CrucibleMarketV6. Note: version "6". */
export function buildDomainV6(marketAddress: Hex, chainId: number) {
  return {
    name: "Crucible",
    version: "6",
    chainId,
    verifyingContract: marketAddress,
  } as const;
}

/** EIP-712 type definition for the v0.6 OpenAuth struct. */
export const OPEN_AUTH_V6_TYPES = {
  OpenAuth: [
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
} as const;

/** v0.6 OpenAuth struct. */
export interface OpenAuthV6 {
  service: Hex;
  agent: Hex;
  resolver: Hex;
  amount: bigint;
  bondLockAmount: bigint;
  disputeBondBps: number;
  commitmentHash: Hex;
  disputeWindow: bigint;
  nonce: bigint;
  authExpiry: bigint;
}

export interface SignedOpenAuthV6 {
  auth: OpenAuthV6;
  signature: Hex;
}

/** Deterministic market id. Same as v0/v0.5: keccak256(service, agent, nonce). */
export function computeMarketIdV6(service: Hex, agent: Hex, nonce: bigint): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "address" }, { type: "uint256" }],
      [service, agent, nonce]
    )
  );
}

/**
 * Compute the commit-reveal vote hash matching TestcaseResolverV5.computeVoteHash:
 *   keccak256(abi.encode(scoreBps, salt, marketId, voter))
 */
export function computeVoteHash(opts: {
  scoreBps: number;
  salt: Hex;
  marketId: Hex;
  voter: Hex;
}): Hex {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "uint16" },
        { type: "bytes32" },
        { type: "bytes32" },
        { type: "address" },
      ],
      [opts.scoreBps, opts.salt, opts.marketId, opts.voter]
    )
  );
}

/** Generate a fresh 256-bit random salt (Hex). */
export function randomSalt(): Hex {
  const buf = new Uint8Array(32);
  crypto.getRandomValues(buf);
  return ("0x" + Array.from(buf, (b) => b.toString(16).padStart(2, "0")).join("")) as Hex;
}

export function randomNonceV6(): bigint {
  const buf = new Uint8Array(16);
  crypto.getRandomValues(buf);
  let n = 0n;
  for (const b of buf) n = (n << 8n) | BigInt(b);
  return n;
}
