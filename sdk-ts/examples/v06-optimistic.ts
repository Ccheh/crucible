/**
 * Crucible v0.6 — optimistic-path lifecycle demo, driven entirely through the SDK.
 *
 * Steps:
 *   1. Service deposits a small bond and whitelists the v0.6 testcase resolver.
 *   2. Service signs a v0.6 OpenAuth (includes disputeBondBps).
 *   3. Agent opens the market with the signed auth.
 *   4. Agent does NOT dispute — testcases pass off-chain (this demo never
 *      actually calls the LLM; the point is to exercise the SDK).
 *   5. After the 60-second dispute window expires, anyone calls
 *      `collectAfterWindow`. Market resolves at scoreBps=10000:
 *        - Service receives `escrow - validatorSubscription`
 *        - Validator subscription pool grows by 10 bps of escrow
 *
 * Run with:
 *   npx tsx examples/v06-optimistic.ts
 *
 * Requires `D:\\桌面\\arc\\.env` to provide PRIVATE_KEY and SERVICE_PRIVATE_KEY.
 */

import { keccak256, toBytes, parseEther } from "viem";
import {
  ServiceClientV6,
  AgentClientV6,
  CRUCIBLE_V6_ARC_TESTNET,
} from "../src/v06/index.js";
import type { Hex } from "../src/types.js";

import * as fs from "node:fs";
import * as path from "node:path";

// ---------- load shared .env ----------
const envPath = "D:\\桌面\\arc\\.env";
const env: Record<string, string> = {};
if (fs.existsSync(envPath)) {
  const text = fs.readFileSync(envPath, "utf8");
  for (const line of text.split("\n")) {
    const m = line.match(/^\s*([A-Z_][A-Z_0-9]*)\s*=\s*(.*)\s*$/);
    if (m) env[m[1]] = m[2].replace(/^"(.*)"$/, "$1");
  }
}

const AGENT_PK = (env.PRIVATE_KEY ?? "") as Hex;
const SERVICE_PK = (env.SERVICE_PRIVATE_KEY ?? "") as Hex;
if (!AGENT_PK || !SERVICE_PK) {
  throw new Error("PRIVATE_KEY and SERVICE_PRIVATE_KEY must be set in arc/.env");
}

async function main() {
  const market = CRUCIBLE_V6_ARC_TESTNET.market;
  const resolver = CRUCIBLE_V6_ARC_TESTNET.resolver;

  const service = new ServiceClientV6({ privateKey: SERVICE_PK, marketAddress: market });
  const agent = new AgentClientV6({ privateKey: AGENT_PK, marketAddress: market });

  console.log("Service: %s", service.address);
  console.log("Agent:   %s", agent.address);
  console.log("Market:  %s", market);
  console.log("Resolver:%s", resolver);

  // 1. Ensure service has bond pool + whitelisted resolver.
  const bondAvailable = await service.bondAvailable();
  console.log("Service bondAvailable: %s", bondAvailable.toString());
  if (bondAvailable < parseEther("0.05")) {
    console.log("Depositing 0.05 USDC bond...");
    const dHash = await service.depositBond(parseEther("0.05"));
    console.log("  deposit tx: %s", dHash);
    const wHash = await service.setResolverAllowed(resolver, true);
    console.log("  whitelist tx: %s", wHash);
  }

  // 2. Service signs a v0.6 OpenAuth (with 5% dispute bond rate).
  const commitmentHash = keccak256(toBytes("crucible-v06-demo"));
  const signed = await service.signOpenAuth({
    agent: agent.address,
    resolver,
    amount: parseEther("0.001"),       // 0.001 USDC escrow
    bondLockAmount: parseEther("0.005"),
    disputeBondBps: 500,                // 5% — agent's bond if they dispute
    commitmentHash,
    disputeWindow: 60,                  // 60 seconds for fast demo
    expirySeconds: 600,
  });
  console.log("Signed OpenAuth nonce: %s", signed.auth.nonce.toString());

  // 3. Agent opens the market.
  const { txHash, marketId } = await agent.openMarket(signed);
  console.log("Market opened. tx: %s", txHash);
  console.log("marketId: %s", marketId);

  // 4. Wait 65 seconds for the dispute window to expire.
  console.log("Waiting 65 seconds for dispute window to close...");
  await new Promise((r) => setTimeout(r, 65_000));

  // 5. Collect (retry on flaky RPC).
  let collectHash: Hex | undefined;
  for (let attempt = 1; attempt <= 4; attempt++) {
    try {
      collectHash = await agent.collectAfterWindow(marketId);
      console.log("Collected. tx: %s", collectHash);
      break;
    } catch (err) {
      console.log("Collect attempt %d failed: %s", attempt, (err as Error).message.split("\n")[0]);
      if (attempt === 4) throw err;
      await new Promise((r) => setTimeout(r, 5_000));
    }
  }

  // 6. Inspect the resolved market.
  const m = await agent.getMarket(marketId);
  console.log("Final scoreBps: %s, status: %s", m[10].toString(), m[11].toString());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
