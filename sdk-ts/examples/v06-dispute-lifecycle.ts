/**
 * Crucible v0.6 — FULL DISPUTE-PATH lifecycle on Arc Testnet.
 *
 * This script does what `v06-codegen-demo.ts` deliberately stops short of:
 * it walks through the complete commit-reveal dispute path on a real chain.
 *
 * Steps and timing:
 *   1. Service deposits bond, whitelists resolver (skipped if already done)
 *   2. Service signs OpenAuth
 *   3. Agent opens market
 *   4. Agent disputes (with bond) — INSTANTLY
 *   5. Validator stakes (if not already)
 *   6. Validator commitVote()                  ← triggers 30-min commit window
 *   7. WAIT 31 minutes                          ← commit window closes
 *   8. Validator revealVote()
 *   9. WAIT 31 minutes                          ← reveal window closes
 *  10. Anyone calls resolveDisputed
 *  11. Validator can call claimRewards + claimSubscription
 *
 * Total wall-clock: ~65 minutes. This is the cost of providing real on-chain
 * evidence of the full dispute path; the protocol's resolver windows are
 * 30-min hard constants in TestcaseResolverV5.
 *
 * Output: prints every tx hash to stdout. README's "Live on-chain evidence"
 * section can be updated by hand with these hashes after a successful run.
 *
 * Run:
 *   npx tsx examples/v06-dispute-lifecycle.ts
 *
 * Recommended: run in background (`> dispute.log 2>&1 &`) and tail the log
 * to see progress without blocking your terminal.
 */

import { keccak256, toBytes, parseEther, encodeAbiParameters } from "viem";
import {
  ServiceClientV6,
  AgentClientV6,
  ValidatorClientV6,
  CRUCIBLE_V6_ARC_TESTNET,
} from "../src/v06/index.js";
import type { Hex } from "../src/types.js";

import * as fs from "node:fs";

// ---------- env ----------
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

// Validator is the agent's main wallet too — has more USDC. (Not great
// game-theoretically, but fine for a single-actor demo on testnet.)
const VALIDATOR_PK = AGENT_PK;

// ---------- helpers ----------
function ts(): string {
  return new Date().toISOString().replace("T", " ").slice(0, 19);
}
function log(...args: unknown[]): void {
  console.log("[" + ts() + "]", ...args);
}

async function retryOnRPC<T>(label: string, fn: () => Promise<T>, attempts = 5): Promise<T> {
  for (let i = 1; i <= attempts; i++) {
    try {
      return await fn();
    } catch (err) {
      const msg = (err as Error).message.split("\n")[0];
      log("  " + label + " attempt " + i + " failed: " + msg);
      if (i === attempts) throw err;
      await new Promise((r) => setTimeout(r, 10_000));
    }
  }
  throw new Error("unreachable");
}

// ---------- main ----------
async function main() {
  const market = CRUCIBLE_V6_ARC_TESTNET.market;
  const resolver = CRUCIBLE_V6_ARC_TESTNET.resolver;
  const service = new ServiceClientV6({ privateKey: SERVICE_PK, marketAddress: market });
  const agent = new AgentClientV6({ privateKey: AGENT_PK, marketAddress: market });
  const validator = new ValidatorClientV6({ privateKey: VALIDATOR_PK, resolverAddress: resolver });

  log("=== Crucible v0.6 — full dispute lifecycle ===");
  log("Service:   " + service.address);
  log("Agent:     " + agent.address);
  log("Validator: " + validator.address);
  log("Market:    " + market);
  log("Resolver:  " + resolver);

  // 1. Ensure bond + whitelist
  const bond = await service.bondAvailable();
  if (bond < parseEther("0.01")) {
    log("[1/11] Service depositing bond + whitelisting resolver");
    await retryOnRPC("deposit", () => service.depositBond(parseEther("0.05")));
    await retryOnRPC("whitelist", () => service.setResolverAllowed(resolver, true));
  } else {
    log("[1/11] Service bond already sufficient (" + bond.toString() + ")");
  }

  // 2. Ensure validator stake
  const stake = await validator.getStake();
  if (stake < parseEther("0.1")) {
    log("[2/11] Validator staking");
    await retryOnRPC("stake", () => validator.stake(parseEther("0.5")));
  } else {
    log("[2/11] Validator stake already sufficient (" + stake.toString() + ")");
  }

  // 3. Service signs OpenAuth
  const commitmentHash = keccak256(toBytes("dispute-lifecycle-demo-" + Date.now()));
  const signed = await service.signOpenAuth({
    agent: agent.address,
    resolver,
    amount: parseEther("0.001"),
    bondLockAmount: parseEther("0.002"),
    disputeBondBps: 500,
    commitmentHash,
    disputeWindow: 60,
  });
  log("[3/11] Service signed OpenAuth, nonce=" + signed.auth.nonce.toString());

  // 4. Agent opens market
  const { txHash: openHash, marketId } = await retryOnRPC("openMarket", () =>
    agent.openMarket(signed)
  );
  log("[4/11] openMarket tx: " + openHash);
  log("       marketId: " + marketId);

  // 5. Agent disputes (with bond)
  const disputeHash = await retryOnRPC("dispute", () => agent.dispute(marketId));
  log("[5/11] dispute tx: " + disputeHash);

  // 6. Validator commitVote
  const SCORE = 7500;
  const { txHash: commitHash, salt } = await retryOnRPC("commitVote", () =>
    validator.commitVote({ marketId, scoreBps: SCORE })
  );
  log("[6/11] commitVote tx: " + commitHash + " (score=" + SCORE + ")");
  log("       salt (must persist for reveal): " + salt);

  // 7. Wait 31 minutes for commit window to close
  log("[7/11] Waiting 31 minutes for commit window to close...");
  for (let i = 0; i < 31; i++) {
    await new Promise((r) => setTimeout(r, 60_000));
    log("       ...minute " + (i + 1) + "/31");
  }

  // 8. Validator revealVote
  const revealHash = await retryOnRPC("revealVote", () =>
    validator.revealVote(marketId, SCORE, salt)
  );
  log("[8/11] revealVote tx: " + revealHash);

  // 9. Wait 31 minutes for reveal window to close
  log("[9/11] Waiting 31 minutes for reveal window to close...");
  for (let i = 0; i < 31; i++) {
    await new Promise((r) => setTimeout(r, 60_000));
    log("       ...minute " + (i + 1) + "/31");
  }

  // 10. Anyone calls resolveDisputed
  const resolveHash = await retryOnRPC("resolveDisputed", () =>
    agent.resolveDisputed(marketId, "0x")
  );
  log("[10/11] resolveDisputed tx: " + resolveHash);

  // 11. Validator claims rewards + subscription
  try {
    const claimRewardHash = await retryOnRPC("claimRewards", () =>
      validator.claimRewards()
    );
    log("[11a/11] claimRewards tx: " + claimRewardHash);
  } catch (err) {
    log("[11a/11] claimRewards skipped (likely zero pending): " + (err as Error).message.split("\n")[0]);
  }
  try {
    const claimSubHash = await retryOnRPC("claimSubscription", () =>
      validator.claimSubscription()
    );
    log("[11b/11] claimSubscription tx: " + claimSubHash);
  } catch (err) {
    log("[11b/11] claimSubscription skipped: " + (err as Error).message.split("\n")[0]);
  }

  log("=== Done ===");
  log("Summary of all tx hashes (copy into README evidence section):");
  log("  openMarket:       " + openHash);
  log("  dispute:          " + disputeHash);
  log("  commitVote:       " + commitHash);
  log("  revealVote:       " + revealHash);
  log("  resolveDisputed:  " + resolveHash);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
