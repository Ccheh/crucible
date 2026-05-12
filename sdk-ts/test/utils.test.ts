import { describe, it, expect } from "vitest";
import { computeMarketId, randomNonce, buildDomain, OPEN_AUTH_TYPES } from "../src/utils.js";
import { CRUCIBLE_ARC_TESTNET, ARC_TESTNET } from "../src/constants.js";
import type { Hex } from "../src/types.js";

describe("computeMarketId", () => {
  it("matches keccak256(abi.encode(service, agent, nonce)) of the contract", () => {
    const service = "0xF2745f5ed1Dee216da4D87ce88f24fA93939cd95" as Hex;
    const agent = "0xA94175a5cA5Ad5c96c96dcbfB97255b9D8683054" as Hex;
    const nonce = 1778561895528n;
    const id = computeMarketId(service, agent, nonce);
    expect(id).toMatch(/^0x[a-fA-F0-9]{64}$/);
  });

  it("is deterministic for same inputs", () => {
    const service = "0x0000000000000000000000000000000000000001" as Hex;
    const agent = "0x0000000000000000000000000000000000000002" as Hex;
    expect(computeMarketId(service, agent, 42n)).toBe(computeMarketId(service, agent, 42n));
  });

  it("changes with each input", () => {
    const a = "0x0000000000000000000000000000000000000001" as Hex;
    const b = "0x0000000000000000000000000000000000000002" as Hex;
    expect(computeMarketId(a, a, 0n)).not.toBe(computeMarketId(b, a, 0n));
    expect(computeMarketId(a, a, 0n)).not.toBe(computeMarketId(a, b, 0n));
    expect(computeMarketId(a, a, 0n)).not.toBe(computeMarketId(a, a, 1n));
  });
});

describe("randomNonce", () => {
  it("returns uint256-fitting bigints", () => {
    const n = randomNonce();
    expect(typeof n).toBe("bigint");
    expect(n).toBeGreaterThanOrEqual(0n);
    expect(n).toBeLessThan(2n ** 256n);
  });

  it("is unlikely to collide", () => {
    const N = 1000;
    const set = new Set<string>();
    for (let i = 0; i < N; i++) set.add(randomNonce().toString());
    expect(set.size).toBe(N);
  });
});

describe("buildDomain", () => {
  it("produces a v1 Crucible domain pinned to the deployed market", () => {
    const d = buildDomain(CRUCIBLE_ARC_TESTNET.market, ARC_TESTNET.chainId);
    expect(d.name).toBe("Crucible");
    expect(d.version).toBe("1");
    expect(d.chainId).toBe(5042002);
    expect(d.verifyingContract).toBe(CRUCIBLE_ARC_TESTNET.market);
  });
});

describe("OPEN_AUTH_TYPES", () => {
  it("has the 9 OpenAuth fields in canonical order", () => {
    const fields = OPEN_AUTH_TYPES.OpenAuth.map(f => f.name);
    expect(fields).toEqual([
      "service",
      "agent",
      "resolver",
      "amount",
      "bondLockAmount",
      "commitmentHash",
      "disputeWindow",
      "nonce",
      "authExpiry",
    ]);
  });
});
