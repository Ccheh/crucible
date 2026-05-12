/**
 * Crucible v0 — live on-chain smoke test on Arc Testnet.
 *
 * Demonstrates the full optimistic settlement lifecycle:
 *   1. Service deposits bond into CrucibleMarket.
 *   2. Service whitelists the MockResolver.
 *   3. Service signs an EIP-712 OpenAuth with 60-second dispute window.
 *   4. Agent opens the market with the signed auth + 0.01 USDC escrow.
 *   5. Wait 65 seconds for the dispute window to expire.
 *   6. Anyone calls collectAfterWindow → service paid, bond released, market resolved.
 *
 * Then, separately demonstrates TestcaseResolver:
 *   - Service-wallet stakes 0.5 USDC as a validator.
 *   - Casts a vote on a synthetic market.
 *
 * All transactions are real on Arc Testnet. Tx hashes can be verified on
 * https://testnet.arcscan.app.
 *
 * Run:
 *   cd examples
 *   npx tsx live-smoke-test.ts
 */

import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  parseEther,
  keccak256,
  toBytes,
  encodeAbiParameters,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

// ---------- load .env from arc402 repo (shared keys) ----------
// Hardcoded absolute path because the user's project tree has Chinese-named
// parent directories that confuse Node's relative-path resolution on Windows.
const ENV_PATH = "D:\\桌面\\arc\\.env";
process.loadEnvFile(ENV_PATH);

const MAIN_PK = process.env.PRIVATE_KEY as Hex;
const SERVICE_PK = process.env.SERVICE_PRIVATE_KEY as Hex;
if (!MAIN_PK || !SERVICE_PK) throw new Error("Missing PRIVATE_KEY / SERVICE_PRIVATE_KEY in arc/.env");

const CHAIN_ID = 5042002;
const RPC = "https://rpc.blockdaemon.testnet.arc.network";

const CRUCIBLE_MARKET = "0x61996d505d6510a339f39c9923519b2f5350f61c" as Hex;
const MOCK_RESOLVER  = "0x76696e3c541eb32c81cfc1cbfb3e5e5ef1c4d35f" as Hex;
const TESTCASE_RESOLVER = "0xa12874e9f77be35efb9e3aeb19eb547b9f224195" as Hex;

const arc = defineChain({
  id: CHAIN_ID,
  name: "Arc Testnet",
  nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});
const transport = http(RPC, { timeout: 60_000, retryCount: 2 });
const publicClient = createPublicClient({ chain: arc, transport });

const mainAcc = privateKeyToAccount(MAIN_PK);
const svcAcc  = privateKeyToAccount(SERVICE_PK);
const mainWallet = createWalletClient({ account: mainAcc, chain: arc, transport });
const svcWallet  = createWalletClient({ account: svcAcc,  chain: arc, transport });

console.log(`Main wallet (acts as Agent):    ${mainAcc.address}`);
console.log(`Service wallet:                 ${svcAcc.address}\n`);

/* ----------------------------- minimal ABIs ----------------------------- */

const MARKET_ABI = [
  { type: "function", name: "depositBond", stateMutability: "payable", inputs: [], outputs: [] },
  { type: "function", name: "setResolverAllowed", stateMutability: "nonpayable",
    inputs: [{name:"resolver",type:"address"},{name:"allowed",type:"bool"}], outputs: [] },
  { type: "function", name: "bondPool", stateMutability: "view",
    inputs: [{type:"address"}], outputs:[{type:"uint256"}] },
  { type: "function", name: "bondLocked", stateMutability: "view",
    inputs: [{type:"address"}], outputs:[{type:"uint256"}] },
  { type: "function", name: "openMarket", stateMutability: "payable",
    inputs: [
      { name: "auth", type: "tuple", components: [
        {name:"service",type:"address"},
        {name:"agent",type:"address"},
        {name:"resolver",type:"address"},
        {name:"amount",type:"uint256"},
        {name:"bondLockAmount",type:"uint256"},
        {name:"commitmentHash",type:"bytes32"},
        {name:"disputeWindow",type:"uint64"},
        {name:"nonce",type:"uint256"},
        {name:"authExpiry",type:"uint256"},
      ]},
      { name: "signature", type: "bytes" },
    ],
    outputs: [{name:"marketId",type:"bytes32"}],
  },
  { type: "function", name: "collectAfterWindow", stateMutability: "nonpayable",
    inputs: [{name:"marketId",type:"bytes32"}], outputs: [] },
  { type: "function", name: "marketIdOf", stateMutability: "pure",
    inputs: [{type:"address"},{type:"address"},{type:"uint256"}],
    outputs: [{type:"bytes32"}] },
  { type: "function", name: "markets", stateMutability: "view",
    inputs: [{type:"bytes32"}],
    outputs: [
      {name:"service",type:"address"},
      {name:"agent",type:"address"},
      {name:"resolver",type:"address"},
      {name:"agentEscrow",type:"uint256"},
      {name:"bondLocked",type:"uint256"},
      {name:"commitmentHash",type:"bytes32"},
      {name:"disputeDeadline",type:"uint64"},
      {name:"scoreBps",type:"uint16"},
      {name:"status",type:"uint8"},
    ],
  },
] as const;

const RESOLVER_ABI = [
  { type: "function", name: "stake", stateMutability: "payable", inputs: [], outputs: [] },
  { type: "function", name: "validatorStake", stateMutability: "view",
    inputs: [{type:"address"}], outputs: [{type:"uint256"}] },
  { type: "function", name: "vote", stateMutability: "nonpayable",
    inputs: [{name:"marketId",type:"bytes32"},{name:"scoreBps",type:"uint16"}], outputs: [] },
  { type: "function", name: "getMarket", stateMutability: "view",
    inputs: [{type:"bytes32"}],
    outputs: [
      {name:"votingDeadline",type:"uint64"},
      {name:"finalScore",type:"uint16"},
      {name:"resolved",type:"bool"},
      {name:"voterCount",type:"uint256"},
    ],
  },
] as const;

/* ============== PHASE 1: optimistic settlement end-to-end ============== */

console.log(`==== PHASE 1: optimistic settlement (60-second window) ====\n`);

// Step 0: ensure service has some gas
const svcBal = await publicClient.getBalance({ address: svcAcc.address });
if (svcBal < parseEther("0.6")) {
  console.log(`[setup] service wallet has only ${svcBal} wei -- topping up 0.6 USDC from main`);
  const topup = await mainWallet.sendTransaction({
    to: svcAcc.address,
    value: parseEther("0.6"),
  });
  await publicClient.waitForTransactionReceipt({ hash: topup });
  console.log(`        tx: https://testnet.arcscan.app/tx/${topup}\n`);
}

// Step 1: service deposits bond
console.log(`Step 1: service deposits 0.5 USDC bond into CrucibleMarket`);
const bondTx = await svcWallet.writeContract({
  address: CRUCIBLE_MARKET, abi: MARKET_ABI, functionName: "depositBond",
  value: parseEther("0.5"),
});
await publicClient.waitForTransactionReceipt({ hash: bondTx });
console.log(`        bond tx: https://testnet.arcscan.app/tx/${bondTx}`);
const bondPool = await publicClient.readContract({
  address: CRUCIBLE_MARKET, abi: MARKET_ABI, functionName: "bondPool", args: [svcAcc.address],
});
console.log(`        bondPool[service] = ${bondPool} wei\n`);

// Step 2: service whitelists MockResolver
console.log(`Step 2: service whitelists MockResolver`);
const allowTx = await svcWallet.writeContract({
  address: CRUCIBLE_MARKET, abi: MARKET_ABI, functionName: "setResolverAllowed",
  args: [MOCK_RESOLVER, true],
});
await publicClient.waitForTransactionReceipt({ hash: allowTx });
console.log(`        allow tx: https://testnet.arcscan.app/tx/${allowTx}\n`);

// Step 3: service signs OpenAuth (EIP-712)
console.log(`Step 3: service signs EIP-712 OpenAuth (disputeWindow = 60s for fast demo)`);
const nonce = BigInt(Date.now());
const commitmentHash = keccak256(toBytes("crucible-smoke-commitment"));
const disputeWindow = 60n;
const authExpiry = BigInt(Math.floor(Date.now() / 1000) + 600);
const amount = parseEther("0.01");
const bondLock = parseEther("0.05");

const domain = {
  name: "Crucible",
  version: "1",
  chainId: CHAIN_ID,
  verifyingContract: CRUCIBLE_MARKET,
} as const;

const OpenAuthTypes = {
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

const authMessage = {
  service: svcAcc.address,
  agent: mainAcc.address,
  resolver: MOCK_RESOLVER,
  amount,
  bondLockAmount: bondLock,
  commitmentHash,
  disputeWindow,
  nonce,
  authExpiry,
} as const;

const signature = await svcAcc.signTypedData({
  domain,
  types: OpenAuthTypes,
  primaryType: "OpenAuth",
  message: authMessage,
});
console.log(`        signed by service (no on-chain action yet)\n`);

// Step 4: agent submits openMarket with payment
console.log(`Step 4: agent (main wallet) calls openMarket(auth, sig) with 0.01 USDC`);
const openTx = await mainWallet.writeContract({
  address: CRUCIBLE_MARKET, abi: MARKET_ABI, functionName: "openMarket",
  args: [authMessage, signature],
  value: amount,
});
const openRcpt = await publicClient.waitForTransactionReceipt({ hash: openTx });
console.log(`        open tx: https://testnet.arcscan.app/tx/${openTx}`);
console.log(`        gas used: ${openRcpt.gasUsed}`);

const marketId = await publicClient.readContract({
  address: CRUCIBLE_MARKET, abi: MARKET_ABI, functionName: "marketIdOf",
  args: [svcAcc.address, mainAcc.address, nonce],
});
console.log(`        marketId: ${marketId}\n`);

// Verify market state
const m = await publicClient.readContract({
  address: CRUCIBLE_MARKET, abi: MARKET_ABI, functionName: "markets", args: [marketId],
});
console.log(`        market state: status=${m[8]} (1=Open), escrow=${m[3]}, bondLocked=${m[4]}\n`);

// Step 5: wait for dispute window to pass
console.log(`Step 5: waiting 65 seconds for 60-second dispute window to expire...`);
await new Promise(r => setTimeout(r, 65_000));
console.log(`        done.\n`);

// Step 6: anyone calls collectAfterWindow
console.log(`Step 6: anyone (using main wallet) calls collectAfterWindow(marketId)`);
const svcBalBefore = await publicClient.getBalance({ address: svcAcc.address });
const collectTx = await mainWallet.writeContract({
  address: CRUCIBLE_MARKET, abi: MARKET_ABI, functionName: "collectAfterWindow",
  args: [marketId],
});
await publicClient.waitForTransactionReceipt({ hash: collectTx });
console.log(`        collect tx: https://testnet.arcscan.app/tx/${collectTx}`);
const svcBalAfter = await publicClient.getBalance({ address: svcAcc.address });
console.log(`        service balance: ${svcBalBefore} -> ${svcBalAfter} (gained ${svcBalAfter - svcBalBefore} wei)`);

const mFinal = await publicClient.readContract({
  address: CRUCIBLE_MARKET, abi: MARKET_ABI, functionName: "markets", args: [marketId],
});
console.log(`        market final state: status=${mFinal[8]} (3=Resolved), scoreBps=${mFinal[7]} (10000=perfect)\n`);

/* =================== PHASE 2: TestcaseResolver stake + vote =============== */

console.log(`==== PHASE 2: TestcaseResolver validator stake + vote ====\n`);

// main wallet acts as a validator now (has more balance than service)
console.log(`Step 1: main-wallet stakes 0.2 USDC into TestcaseResolver`);
const stakeTx = await mainWallet.writeContract({
  address: TESTCASE_RESOLVER, abi: RESOLVER_ABI, functionName: "stake",
  value: parseEther("0.2"),
});
await publicClient.waitForTransactionReceipt({ hash: stakeTx });
console.log(`        stake tx: https://testnet.arcscan.app/tx/${stakeTx}`);

const stakeAmt = await publicClient.readContract({
  address: TESTCASE_RESOLVER, abi: RESOLVER_ABI, functionName: "validatorStake",
  args: [mainAcc.address],
});
console.log(`        validatorStake[main] = ${stakeAmt} wei\n`);

// Vote on a synthetic marketId
console.log(`Step 2: validator (main) votes scoreBps=7500 on a synthetic market`);
const syntheticMarketId = keccak256(toBytes(`crucible-vote-test-${Date.now()}`));
const voteTx = await mainWallet.writeContract({
  address: TESTCASE_RESOLVER, abi: RESOLVER_ABI, functionName: "vote",
  args: [syntheticMarketId, 7500],
});
await publicClient.waitForTransactionReceipt({ hash: voteTx });
console.log(`        vote tx: https://testnet.arcscan.app/tx/${voteTx}`);

const mState = await publicClient.readContract({
  address: TESTCASE_RESOLVER, abi: RESOLVER_ABI, functionName: "getMarket",
  args: [syntheticMarketId],
});
console.log(`        synthetic market state: deadline=${mState[0]} (1h from vote), voters=${mState[3]}\n`);

/* =================== SUMMARY =================== */

console.log(`================== SUMMARY ==================`);
console.log(`All Crucible v0 contracts working live on Arc Testnet.\n`);
console.log(`Phase 1 (CrucibleMarket optimistic lifecycle):`);
console.log(`  - Bond deposit:   ${bondTx}`);
console.log(`  - Whitelist:      ${allowTx}`);
console.log(`  - Open market:    ${openTx}`);
console.log(`  - Collect:        ${collectTx}`);
console.log(`Phase 2 (TestcaseResolver validator network):`);
console.log(`  - Validator stake: ${stakeTx}`);
console.log(`  - Validator vote:  ${voteTx}\n`);
console.log(`Total real txs: 6, ~80 seconds wall-clock.`);
console.log(`All verifiable on https://testnet.arcscan.app`);
