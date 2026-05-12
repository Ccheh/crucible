/**
 * End-to-end Crucible lifecycle demo, using the @crucible/sdk.
 *
 * Scenario: a paid AI code-generation service.
 *   1. Agent asks the service to write a Python function: `is_even(n)`.
 *   2. Service generates the code, computes a commitment hash, and signs an
 *      EIP-712 OpenAuth (with a 60-second dispute window for fast demo).
 *   3. Agent opens the Crucible market with 0.01 USDC escrow.
 *   4. Agent locally runs testcases against the code. (In this demo: hardcoded
 *      passing testcases — in real use the agent would actually exec the code
 *      against test inputs and decide whether to dispute.)
 *   5. Agent does NOT dispute (testcases pass) — lets the window expire.
 *   6. After 65s wall-clock, anyone calls collectAfterWindow → market resolves
 *      at scoreBps=10000 (optimistic, no dispute) → service paid in full.
 *
 * This is end-to-end real Arc Testnet execution, driven entirely through SDK calls.
 */

import { keccak256, toBytes, parseEther } from "viem";
import {
  ServiceClient,
  AgentClient,
  CRUCIBLE_ARC_TESTNET,
  ARC_TESTNET,
  MarketStatus,
  codeGenCommitment,
  type Hex,
} from "../src/index.js";

// ---------- load shared .env ----------
const ENV_PATH = "D:\\桌面\\arc\\.env";
process.loadEnvFile(ENV_PATH);

const MAIN_PK = process.env.PRIVATE_KEY as Hex;
const SERVICE_PK = process.env.SERVICE_PRIVATE_KEY as Hex;
if (!MAIN_PK || !SERVICE_PK) throw new Error("Missing PRIVATE_KEY / SERVICE_PRIVATE_KEY in .env");

const MARKET = CRUCIBLE_ARC_TESTNET.market;
const MOCK_RESOLVER = CRUCIBLE_ARC_TESTNET.mockResolver;

// ---------- the "AI code generation service" (mock) ----------

interface CodeGenRequest {
  functionSignature: string;
  description: string;
  testcases: { input: string; expectedOutput: string }[];
}

interface CodeGenResult {
  code: string;
  commitmentHash: Hex;
}

/**
 * Generate code for a request. In a real service this would call an LLM.
 * Here we just return a hardcoded correct implementation.
 */
function aiCodeGen(req: CodeGenRequest): CodeGenResult {
  // Mock LLM response: hardcoded correct implementation
  const code = `def is_even(n):\n    return n % 2 == 0`;

  // Commitment hash binds (input, testcases, output) — agent and service
  // both compute this same hash off-chain to verify they're seeing the same
  // payload before any on-chain action.
  const testcasesEncoded = req.testcases.map(t => `${t.input}->${t.expectedOutput}`).join("\n");
  const expectedOutputHash = keccak256(toBytes(code));
  const commitmentHash = codeGenCommitment({
    input: req.functionSignature + ":" + req.description,
    testcases: testcasesEncoded,
    expectedOutputHash,
  });
  return { code, commitmentHash };
}

// Agent-side testcase runner: in the real world this would actually exec code.
// For this demo we hardcode "all pass" since we know the code is correct.
function runTestcases(code: string, testcases: { input: string; expectedOutput: string }[]): {
  passed: number;
  total: number;
} {
  // Demo: trust that the code is correct (in production: spawn a sandbox)
  return { passed: testcases.length, total: testcases.length };
}

// ---------- main flow ----------

const service = new ServiceClient({
  privateKey: SERVICE_PK,
  marketAddress: MARKET,
  chain: ARC_TESTNET,
});

const agent = new AgentClient({
  privateKey: MAIN_PK,
  marketAddress: MARKET,
  chain: ARC_TESTNET,
});

console.log(`Service address: ${service.address}`);
console.log(`Agent address:   ${agent.address}\n`);

// Step 0: ensure service has enough bond available
const bondAvail = await service.bondAvailable();
console.log(`Service bond available: ${bondAvail} wei`);
if (bondAvail < parseEther("0.1")) {
  console.log(`Bond is low — depositing additional 0.2 USDC`);
  const tx = await service.depositBond(parseEther("0.2"));
  console.log(`  deposit tx: https://testnet.arcscan.app/tx/${tx}`);
}
console.log();

// Step 1: agent makes code-gen request to service
console.log(`Step 1: agent requests code generation`);
const request: CodeGenRequest = {
  functionSignature: "is_even(n: int) -> bool",
  description: "Return True if n is even, else False.",
  testcases: [
    { input: "is_even(0)", expectedOutput: "True" },
    { input: "is_even(2)", expectedOutput: "True" },
    { input: "is_even(3)", expectedOutput: "False" },
    { input: "is_even(-4)", expectedOutput: "True" },
  ],
};

console.log(`Step 2: service generates code (off-chain)`);
const generated = aiCodeGen(request);
console.log(`  code:\n${generated.code.split("\n").map(l => "    " + l).join("\n")}`);
console.log(`  commitmentHash: ${generated.commitmentHash}\n`);

console.log(`Step 3: service signs EIP-712 OpenAuth (60s dispute window)`);
const signedAuth = await service.signOpenAuth({
  agent: agent.address,
  resolver: MOCK_RESOLVER,
  amount: parseEther("0.01"),
  bondLockAmount: parseEther("0.05"),
  commitmentHash: generated.commitmentHash,
  disputeWindow: 60,
});
console.log(`  signed by service (off-chain), nonce: ${signedAuth.auth.nonce}\n`);

console.log(`Step 4: agent opens market on-chain`);
const { txHash: openTx, marketId } = await agent.openMarket(signedAuth);
console.log(`  open tx:   https://testnet.arcscan.app/tx/${openTx}`);
console.log(`  marketId:  ${marketId}\n`);

console.log(`Step 5: agent runs testcases locally`);
const testResult = runTestcases(generated.code, request.testcases);
console.log(`  passed ${testResult.passed} / ${testResult.total} testcases`);
const allPass = testResult.passed === testResult.total;
console.log(`  -> ${allPass ? "ALL PASS — will NOT dispute" : "FAILED — would dispute"}\n`);

if (!allPass) {
  // Dispute path (not exercised in this demo since our mock LLM always returns correct code)
  console.log(`Step 6 (alt): agent disputes`);
  await agent.dispute(marketId);
  console.log(`  market now in Disputed state — would await TestcaseResolver vote`);
  console.log(`  (full dispute resolution requires 1h voting window + validators — see Week 2 work)\n`);
  process.exit(0);
}

console.log(`Step 6: wait 65 seconds for 60s dispute window to expire...`);
await new Promise(r => setTimeout(r, 65_000));
console.log(`  done.\n`);

console.log(`Step 7: anyone (agent calls it here) collects after window`);
const collectTx = await agent.collectAfterWindow(marketId);
console.log(`  collect tx: https://testnet.arcscan.app/tx/${collectTx}\n`);

console.log(`Step 8: verify final market state`);
const final = await agent.getMarket(marketId);
console.log(`  service:         ${final.service}`);
console.log(`  agent:           ${final.agent}`);
console.log(`  escrow paid:     ${final.agentEscrow} wei (transferred to service)`);
console.log(`  bond locked:     ${final.bondLocked} wei (released back to service pool)`);
console.log(`  scoreBps:        ${final.scoreBps} (10000 = optimistic full pay)`);
console.log(`  status:          ${final.status} (${final.status === MarketStatus.Resolved ? "Resolved" : "OTHER"})\n`);

console.log(`================== SUMMARY ==================`);
console.log(`Full Crucible lifecycle ran end-to-end through @crucible/sdk:`);
console.log(`  - off-chain: service generated code + signed auth`);
console.log(`  - on-chain (open):    ${openTx}`);
console.log(`  - on-chain (collect): ${collectTx}`);
console.log(`  - market state:       Resolved at scoreBps=10000`);
console.log(`Verifiable: https://testnet.arcscan.app/address/${MARKET}\n`);
console.log(`In production: replace aiCodeGen() with a real LLM call. Everything else stays.`);
