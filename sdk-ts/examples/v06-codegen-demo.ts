/**
 * Crucible v0.6 — code-generation killer demo on Arc Testnet.
 *
 * The complete payment-conditional-on-quality lifecycle for a paid code-gen
 * service, end-to-end on a real chain:
 *
 *   1. Service is asked to write a Python function. Service generates code
 *      (via deterministic mock LLM — swap for real OpenAI/Anthropic in 5
 *      lines, see `runLLM`).
 *   2. Service signs an EIP-712 OpenAuth with TestcaseResolverV5 as the
 *      resolver (note: this demo settles optimistically; the dispute path
 *      requires a separate ~60 min run, see `v06-codegen-dispute.ts`).
 *   3. Agent opens a Crucible market — agent's USDC goes into escrow.
 *   4. Agent runs the testcases against the generated code LOCALLY (via
 *      Python child_process). If all pass, agent does NOT dispute.
 *   5. After the dispute window (60 seconds), anyone calls collectAfterWindow.
 *      Market settles at scoreBps = 10000:
 *        - Service receives `escrow - validatorSubscription`
 *        - Validator pool grows by 0.10% of escrow
 *
 * If you want to see the failure path: set FAULTY=1 in env, the mock LLM
 * will return buggy code, agent will see testcases fail and refuse to
 * collect optimistically. (The full dispute path needs commit-reveal
 * windows which take ~60 min; that's a separate demo script.)
 *
 * Run:
 *   npx tsx examples/v06-codegen-demo.ts
 *   FAULTY=1 npx tsx examples/v06-codegen-demo.ts
 */

import { keccak256, toBytes, parseEther, encodeAbiParameters } from "viem";
import {
  ServiceClientV6,
  AgentClientV6,
  CRUCIBLE_V6_ARC_TESTNET,
} from "../src/v06/index.js";
import type { Hex } from "../src/types.js";

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawnSync } from "node:child_process";

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

const FAULTY = !!process.env.FAULTY;

// ---------- the codegen task ----------
const PROMPT = "Write a Python function is_palindrome(s) that returns True if s is a palindrome (case-sensitive). Return only the function body.";

interface Testcase {
  input: string;
  expected: boolean;
}

const TESTCASES: Testcase[] = [
  { input: "racecar", expected: true },
  { input: "hello", expected: false },
  { input: "a", expected: true },
  { input: "", expected: true },
  { input: "Racecar", expected: false },          // case-sensitive
  { input: "abba", expected: true },
  { input: "level", expected: true },
];

// ---------- mock LLM ----------
/**
 * Deterministic mock LLM. In production, replace with:
 *   const completion = await openai.chat.completions.create({
 *     model: "gpt-4o-mini",
 *     messages: [{ role: "user", content: prompt }],
 *   });
 *   return completion.choices[0].message.content ?? "";
 *
 * The protocol does not depend on the LLM — it depends on the off-chain
 * testcases evaluating whatever code the service returns. So mock vs real
 * LLM is interchangeable for the demo.
 */
function runLLM(prompt: string, faulty: boolean): string {
  if (faulty) {
    // Buggy: case-insensitive (wrong per spec), and crashes on empty string
    return [
      "def is_palindrome(s):",
      "    s = s.lower()",                         // bug 1: case-insensitive
      "    return s[0] == s[-1] and is_palindrome(s[1:-1])",  // bug 2: empty-string crash
    ].join("\n");
  }
  // Correct implementation
  return [
    "def is_palindrome(s):",
    "    return s == s[::-1]",
  ].join("\n");
}

// ---------- evaluate codegen output against testcases ----------
interface TestResult {
  input: string;
  expected: boolean;
  actual: boolean | "error";
  pass: boolean;
}

function evaluateCode(code: string, testcases: Testcase[]): { results: TestResult[]; allPass: boolean } {
  const script = [
    code,
    "",
    "import sys, json",
    "cases = json.loads(sys.argv[1])",
    "out = []",
    "for c in cases:",
    "    try:",
    "        r = is_palindrome(c['input'])",
    "        out.append({ 'input': c['input'], 'expected': c['expected'], 'actual': bool(r), 'pass': bool(r) == c['expected'] })",
    "    except Exception as e:",
    "        out.append({ 'input': c['input'], 'expected': c['expected'], 'actual': 'error', 'pass': False })",
    "print(json.dumps(out))",
  ].join("\n");

  const tmpFile = path.join(os.tmpdir(), `codegen-${Date.now()}.py`);
  fs.writeFileSync(tmpFile, script);

  const proc = spawnSync("python", [tmpFile, JSON.stringify(testcases)], {
    encoding: "utf8",
    timeout: 5000,
  });
  fs.unlinkSync(tmpFile);

  if (proc.status !== 0) {
    console.log("Python execution failed:", proc.stderr);
    return { results: [], allPass: false };
  }
  const results = JSON.parse(proc.stdout) as TestResult[];
  const allPass = results.every((r) => r.pass);
  return { results, allPass };
}

// ---------- main ----------
async function main() {
  console.log("=".repeat(60));
  console.log("Crucible v0.6 — code-generation killer demo");
  console.log("Mode: " + (FAULTY ? "FAULTY (buggy LLM)" : "CORRECT (working LLM)"));
  console.log("=".repeat(60));

  // 0. Setup
  const market = CRUCIBLE_V6_ARC_TESTNET.market;
  const resolver = CRUCIBLE_V6_ARC_TESTNET.resolver;
  const service = new ServiceClientV6({ privateKey: SERVICE_PK, marketAddress: market });
  const agent = new AgentClientV6({ privateKey: AGENT_PK, marketAddress: market });

  console.log("Service: %s", service.address);
  console.log("Agent:   %s", agent.address);
  console.log("Market:  %s", market);

  // 1. Service generates code via "LLM"
  console.log("\n[1/6] Service generates code for task:");
  console.log("       %s", PROMPT);
  const code = runLLM(PROMPT, FAULTY);
  console.log("       Generated:");
  console.log(code.split("\n").map((l) => "         " + l).join("\n"));

  // 2. Service commits to commitmentHash = keccak256(prompt || testcases || code)
  const commitmentHash = keccak256(
    encodeAbiParameters(
      [{ type: "string" }, { type: "string" }, { type: "bytes32" }],
      [PROMPT, JSON.stringify(TESTCASES), keccak256(toBytes(code))]
    )
  );

  // 3. Ensure service has bond. Skip deposit if already enough.
  const bondAvailable = await service.bondAvailable();
  console.log("\n[2/6] Service bond status: %s ether available", (Number(bondAvailable) / 1e18).toFixed(4));
  if (bondAvailable < parseEther("0.01")) {
    console.log("       Depositing 0.05 USDC bond...");
    await service.depositBond(parseEther("0.05"));
    await service.setResolverAllowed(resolver, true);
  }

  // 4. Service signs OpenAuth.
  console.log("\n[3/6] Service signs OpenAuth (escrow 0.001 USDC, bond 0.002 USDC, 5% dispute bond)");
  const signed = await service.signOpenAuth({
    agent: agent.address,
    resolver,
    amount: parseEther("0.001"),
    bondLockAmount: parseEther("0.002"),
    disputeBondBps: 500,
    commitmentHash,
    disputeWindow: 60,
  });
  console.log("       OpenAuth nonce: %s", signed.auth.nonce.toString());

  // 5. Agent opens market (retry on RPC congestion).
  let openResult: { txHash: Hex; marketId: Hex } | undefined;
  for (let attempt = 1; attempt <= 5; attempt++) {
    try {
      openResult = await agent.openMarket(signed);
      break;
    } catch (err) {
      const msg = (err as Error).message.split("\n")[0];
      console.log("       openMarket attempt %d failed: %s", attempt, msg);
      if (attempt === 5) throw err;
      await new Promise((r) => setTimeout(r, 10_000));
    }
  }
  if (!openResult) throw new Error("openMarket exhausted retries");
  const openHash = openResult.txHash;
  const marketId = openResult.marketId;
  console.log("\n[4/6] Agent opens market");
  console.log("       tx: %s", openHash);
  console.log("       marketId: %s", marketId);

  // 6. Agent runs testcases LOCALLY (off-chain).
  console.log("\n[5/6] Agent runs testcases locally...");
  const { results, allPass } = evaluateCode(code, TESTCASES);
  if (results.length === 0) {
    throw new Error("Python execution failed. Make sure `python` is on PATH.");
  }
  for (const r of results) {
    const tick = r.pass ? "✓" : "✗";
    console.log("       %s is_palindrome(%j) -> %s (expected %s)",
      tick, r.input, JSON.stringify(r.actual), JSON.stringify(r.expected));
  }
  const passCount = results.filter((r) => r.pass).length;
  console.log("       %s / %s passing", passCount, results.length);

  // 7. Agent's decision.
  if (allPass) {
    console.log("\n[6/6] All testcases pass → agent does NOT dispute → optimistic settle");
    console.log("       Waiting 65 seconds for dispute window to close...");
    await new Promise((r) => setTimeout(r, 65_000));

    let collectHash: Hex | undefined;
    for (let attempt = 1; attempt <= 4; attempt++) {
      try {
        collectHash = await agent.collectAfterWindow(marketId);
        break;
      } catch (err) {
        console.log("       Collect attempt %d failed; retrying in 5s...", attempt);
        if (attempt === 4) throw err;
        await new Promise((r) => setTimeout(r, 5_000));
      }
    }
    console.log("       Settled at scoreBps=10000.");
    console.log("       collect tx: %s", collectHash);
  } else {
    console.log("\n[6/6] Some testcases failed → agent WOULD dispute");
    console.log("       (Full dispute path requires ~60 min commit + reveal cycle.");
    console.log("        See v06-codegen-dispute.ts for that lifecycle.)");
    console.log("");
    console.log("       For this demo run, we stop here — the protocol's");
    console.log("       'optimistic OR dispute' decision is made off-chain");
    console.log("       by the agent based on these test results.");
    console.log("");
    console.log("       Pass rate: %d/%d. Settling at this rate via");
    console.log("       resolveDisputed would pay service: ~%d%% of escrow,",
      passCount, results.length, Math.round((passCount / results.length) * 100));
    console.log("       agent: ~%d%% of escrow + proportional bond slash.",
      Math.round((1 - passCount / results.length) * 100));
  }

  console.log("\n" + "=".repeat(60));
  console.log("Done. See https://testnet.arcscan.app/tx/<txHash> for any tx above.");
  console.log("=".repeat(60));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
