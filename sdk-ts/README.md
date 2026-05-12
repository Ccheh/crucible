# @crucible/sdk

TypeScript SDK for [Crucible](../README.md) — prediction-market-settled payments for probabilistic AI services on Arc.

## Three client classes, one per role

```ts
import { ServiceClient, AgentClient, ValidatorClient, CRUCIBLE_ARC_TESTNET, ARC_TESTNET } from "@crucible/sdk";
```

### Service-side: bond + sign auth

```ts
const service = new ServiceClient({
  privateKey: process.env.SERVICE_PK as `0x${string}`,
  marketAddress: CRUCIBLE_ARC_TESTNET.market,
});

// One-time setup
await service.depositBond(parseEther("1"));                       // 1 USDC bond
await service.setResolverAllowed(CRUCIBLE_ARC_TESTNET.mockResolver, true);

// Per call: generate output, then sign auth so the agent can open the market
const signedAuth = await service.signOpenAuth({
  agent: agentAddress,
  resolver: CRUCIBLE_ARC_TESTNET.mockResolver,
  amount: parseEther("0.01"),       // agent will pay 0.01 USDC
  bondLockAmount: parseEther("0.05"),// service stakes 0.05 USDC against this market
  commitmentHash,                   // hash of (input, testcases, expected output)
  disputeWindow: 60,                // seconds
});
// send signedAuth to the agent (over HTTP, IPFS, etc.)
```

### Agent-side: open / dispute / collect

```ts
const agent = new AgentClient({
  privateKey: process.env.AGENT_PK as `0x${string}`,
  marketAddress: CRUCIBLE_ARC_TESTNET.market,
});

// Open the market on-chain with the signed auth + payment
const { txHash, marketId } = await agent.openMarket(signedAuth);

// If the agent decides the output failed quality bar:
await agent.dispute(marketId);
// ... then a TestcaseResolver vote round runs ...
await agent.resolveDisputed(marketId);

// Optimistic path: do nothing during dispute window, then collect after
await agent.collectAfterWindow(marketId);

// Read state at any time
const state = await agent.getMarket(marketId);
// { service, agent, resolver, agentEscrow, bondLocked, commitmentHash,
//   disputeDeadline, scoreBps, status }
```

### Validator-side: stake + vote

```ts
const validator = new ValidatorClient({
  privateKey: process.env.VALIDATOR_PK as `0x${string}`,
  resolverAddress: CRUCIBLE_ARC_TESTNET.testcaseResolver,
});

await validator.stake(parseEther("0.5"));                          // min 0.1 USDC
await validator.vote(marketId, 7500);                              // 75% pass rate

// Later: ask to unstake (7-day cooldown)
await validator.requestUnstake(parseEther("0.1"));
// ... wait 7 days ...
await validator.completeUnstake();
```

## Built-in helpers

- `randomNonce()` — cryptographically random uint256-fitting nonce
- `computeMarketId(service, agent, nonce)` — deterministic market id matching the on-chain hash
- `codeGenCommitment({ input, testcases, expectedOutputHash })` — convention for code-gen markets
- `buildDomain(market, chainId)` — EIP-712 domain for OpenAuth signing
- `OPEN_AUTH_TYPES` — EIP-712 type definition

## Run the example

```sh
cd sdk-ts
npm install
# Requires PRIVATE_KEY + SERVICE_PRIVATE_KEY in the project-root .env
npm run demo
```

The demo:
1. Service generates a Python function (mock LLM).
2. Service signs an OpenAuth.
3. Agent opens the market with 0.01 USDC + 60s dispute window.
4. Agent runs testcases locally → all pass → does NOT dispute.
5. After 65s, agent calls `collectAfterWindow` → market resolves at score=10000, service paid.

Verified output: real on-chain transactions on Arc Testnet, ~2 minutes wall-clock.

## Test

```sh
npm test
```

7 SDK unit tests covering `computeMarketId`, `randomNonce`, `buildDomain`, `OPEN_AUTH_TYPES` consistency.

## License

[MIT](../LICENSE)
