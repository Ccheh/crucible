# Crucible

> **Prediction-market-settled payments for probabilistic AI services on Arc.**
>
> The settlement layer existing payment protocols don't cover — payment conditional on *quality outcome*, not just delivery.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Arc Testnet](https://img.shields.io/badge/Arc%20Testnet-v0.6%20live-blue)](https://testnet.arcscan.app/address/0x6535a3cbb4235746b732ab5d55c6b0988f381a20)
[![Tests](https://img.shields.io/badge/tests-142%2F142%20passing-success)](#)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-blue)](contracts/foundry.toml)
[![TypeScript](https://img.shields.io/badge/TypeScript-strict-blue)](sdk-ts/tsconfig.json)

---

## At a glance

```
6 protocol versions shipped (v0 → v0.6), each frozen as deployable artifact
142 passing forge tests across all versions
v0.6 live on Arc Testnet:
  - CrucibleMarketV6 + TestcaseResolverV5 deployed, gas ~4.4M (~0.088 USDC)
  - Includes commit-reveal voting, validator subscription pool,
    40% voting weight cap, ERC-8004 reputation events, per-market
    dispute bond, stuck-market force-resolve fallback
TypeScript SDK currently supports v0; v0.6 SDK sync is the next milestone
MIT licensed, no admin keys, no upgrade proxy, ~2,600 LOC Solidity
Built above Cadence (Arc402) base payment layer
```

### v0.6 (current — latest) — Arc Testnet

| Component | Address on Arc Testnet |
|---|---|
| **CrucibleMarketV6** | [`0x6535a3cbb4235746b732ab5d55c6b0988f381a20`](https://testnet.arcscan.app/address/0x6535a3cbb4235746b732ab5d55c6b0988f381a20) |
| **TestcaseResolverV5** | [`0x51cc924fe83dc5221150f5752454a37121bE3957`](https://testnet.arcscan.app/address/0x51cc924fe83dc5221150f5752454a37121be3957) |

Deployment txs:
- Market: [`0x37c23d5b...`](https://testnet.arcscan.app/tx/0x37c23d5b6cc9005c776c2c3204d3dea5a43c5c7cd3e10cdd5c72d18e7d609918)
- Resolver: [`0xaca5f288...`](https://testnet.arcscan.app/tx/0xaca5f28882a86df836456ab510125a6f114549d27152d6d5463fa9bd8a8e16d4)

### v0 (initial release) — Arc Testnet, retained for historical record

| Component | Address |
|---|---|
| CrucibleMarket | [`0x61996d505d6510a339f39c9923519b2f5350f61c`](https://testnet.arcscan.app/address/0x61996d505d6510a339f39c9923519b2f5350f61c) |
| TestcaseResolver | [`0xa12874e9f77be35efb9e3aeb19eb547b9f224195`](https://testnet.arcscan.app/address/0xa12874e9f77be35efb9e3aeb19eb547b9f224195) |
| MockResolver | [`0x76696e3c541eb32c81cfc1cbfb3e5e5ef1c4d35f`](https://testnet.arcscan.app/address/0x76696e3c541eb32c81cfc1cbfb3e5e5ef1c4d35f) |

### Version timeline

| Version | Headline addition | Tests |
|---|---|---|
| v0 | per-call market + pluggable resolver + optimistic settle | 30 |
| v0.2 | slashing + reward fee pool + pendingVotes guard | +24 |
| v0.3 | stake-weighted median + dispute bond | +22 |
| v0.4 | MasterChef subscription pool + 40% voting cap + ERC-8004 events | +23 |
| v0.5 | commit-reveal voting + per-market disputeBondBps + config MIN_STAKE | +32 |
| v0.6 | force-resolve fallback for stuck disputed markets | +11 |
| **total** | | **142** |

---

## The structural problem we solve

Every existing AI-payment protocol — Stripe, Lightning, Coinbase x402, Circle Nanopayments, even our predecessor Cadence — treats AI service calls as **deterministic transactions**: pay X, receive Y, done. But AI is **probabilistic**:

- Outputs are stochastic (the LLM gives different answers on different runs)
- Quality is subjective (good translation vs. bad translation isn't a hash check)
- Value resolves over time (was the prediction useful? was the code merged?)

None of the existing protocols handle this. They settle on **delivery confirmation**, not **outcome quality**.

**Crucible adds the missing layer**: payment held in escrow, output evaluated by a per-call prediction market, funds released proportional to outcome. Service stakes a bond against quality; validators stake to vote on outcomes; agents get refunds when delivery fails the quality bar.

| Protocol | Quality awareness | Resolution mechanism |
|---|---|---|
| Stripe | None (fraud signals only) | Centralized chargeback |
| Lightning | None | None |
| Coinbase x402 | None | 200 OK = paid |
| Circle Nanopayments | None | Same as x402 |
| Cadence (Arc402) | None in core; rep-tier as discount only | None |
| **Crucible** | **Per-call market-resolved score** | **Pluggable resolvers + validator stakes + optimistic dispute** |

No payment protocol has ever made AI output quality a first-class settlement primitive. Crucible is the first.

---

## Three-minute integration via SDK

```ts
import { ServiceClient, AgentClient, CRUCIBLE_ARC_TESTNET, codeGenCommitment } from "@crucible/sdk";
import { parseEther, keccak256, toBytes } from "viem";

// Service side: deposit bond, sign auth per call
const service = new ServiceClient({ privateKey: SERVICE_PK, marketAddress: CRUCIBLE_ARC_TESTNET.market });
await service.depositBond(parseEther("1"));
await service.setResolverAllowed(CRUCIBLE_ARC_TESTNET.mockResolver, true);

const code = await yourLLM(prompt);
const signedAuth = await service.signOpenAuth({
  agent: agentAddress,
  resolver: CRUCIBLE_ARC_TESTNET.mockResolver,
  amount: parseEther("0.01"),
  bondLockAmount: parseEther("0.05"),
  commitmentHash: codeGenCommitment({ input: prompt, testcases, expectedOutputHash: keccak256(toBytes(code)) }),
  disputeWindow: 60,
});

// Agent side: open market with signed auth + payment
const agent = new AgentClient({ privateKey: AGENT_PK, marketAddress: CRUCIBLE_ARC_TESTNET.market });
const { marketId } = await agent.openMarket(signedAuth);
// ... agent runs testcases ... if pass: wait + collect; if fail: dispute
```

Working end-to-end demo (real Arc Testnet tx) ships in [`sdk-ts/examples/full-lifecycle.ts`](sdk-ts/examples/full-lifecycle.ts):

```sh
git clone https://github.com/Ccheh/crucible.git
cd crucible/sdk-ts && npm install
# Set PRIVATE_KEY (agent) + SERVICE_PRIVATE_KEY in ../.env (your Arc Testnet keys)
npm run demo
```

Total wall-clock: ~80 seconds (60s dispute window + 4 on-chain txs).

---

## Live on-chain evidence

Full protocol lifecycle exercised on Arc Testnet. Every step is a real transaction:

**Phase 1 — CrucibleMarket optimistic settlement**

| Step | tx |
|---|---|
| service deposits 0.5 USDC bond | [`0xbed641ed...`](https://testnet.arcscan.app/tx/0xbed641eddba245aac3ccfc337bf743ab9a4cea071f33176d4ed0f8c0d4968599) |
| service whitelists resolver | [`0xa0de7856...`](https://testnet.arcscan.app/tx/0xa0de7856551a756ff836d52220e26add8eb9eddc6156ee8ffc7646631324593c) |
| agent opens market via EIP-712 auth | [`0x616c8d57...`](https://testnet.arcscan.app/tx/0x616c8d5712d4a6b8c1ea7b30672a0afc1c1c534b30a805c1110cb65f2523660a) |
| collect after 60s → resolved at score 10000 | market `0xaf28e414...` status=3 ✅ |

**Phase 2 — TestcaseResolver validator network**

| Step | tx |
|---|---|
| main wallet stakes 0.2 USDC as validator | [`0x0117371c...`](https://testnet.arcscan.app/tx/0x0117371ce85a31b6dfa18a21d8f0805845fa5fe636fef3055749f9c6cfe1fe14) |
| validator votes scoreBps=7500 | [`0x65c71cc1...`](https://testnet.arcscan.app/tx/0x65c71cc1098655f1537d1658da05ccd6b7df985c22f51ff3c97f3be843ee3ea4) |

**Phase 3 — Full lifecycle via @crucible/sdk**

| Step | tx |
|---|---|
| agent opens market via SDK | [`0xd3fc1968...`](https://testnet.arcscan.app/tx/0xd3fc19682ad24c17e6082dd91b79f1d3de9ad8f4a87a02ca464d513211274d35) |
| agent collects after window via SDK | [`0x396551e8...`](https://testnet.arcscan.app/tx/0x396551e8230fe8a6eb8781ba34efc3faf894a0577da2f81d1ed2be9d146c81f5) |

Not unit-test-only. Real EVM execution, verifiable on https://testnet.arcscan.app.

---

## Roles

| Role | What they do | Skin in the game | Reward |
|---|---|---|---|
| **Agent** | Pays for AI service, optionally disputes | USDC in escrow | Refund if service fails quality |
| **Service** | Provides AI output, commits to quality claim | Quality bond | Payment if claim verified |
| **Validator** | Stakes USDC, votes on output quality | Validator stake | Share of market fee (v0.2) |
| **Resolver** | Pluggable verification logic (contract) | None (pure code) | None |
| **Disputer** | Anyone can challenge resolution | Dispute bond (v0.2) | Wins disputed funds |

Anyone can be any role. No permissioning. No KYC. No central operator.

## Resolver types (pluggable verification)

| Resolver | What it verifies | Trust model | v0 status |
|---|---|---|---|
| `TestcaseResolver` | Code-generation outputs vs. testcases | Validators run sandbox | **shipped** |
| `MockResolver` | Testing only (takes score from calldata) | None | **shipped** |
| `OracleResolver` | Real-world predictions vs. ground truth | Chainlink / Pyth / UMA | v0.2 |
| `ValidatorVoteResolver` | Subjective quality (translation, creative) | Schelling point of staked validators | v0.2 |
| `TEEResolver` | Inference-integrity proofs | Trusted hardware attestation | v0.3 |
| `ZkMlResolver` | Pure cryptographic proof of inference | ZK ML | future |

## First use case: paid code generation

1. Agent pays a code-gen service 0.05 USDC to write a Python function.
2. Service returns code + posts commitment hash on-chain.
3. Agent runs testcases locally; if they pass, lets the dispute window expire — service gets paid in full.
4. If tests fail, agent disputes within the window.
5. Validators (anyone with 0.1 USDC staked in TestcaseResolver) run the testcases themselves, vote stake-weighted on the pass rate.
6. Contract auto-resolves: payment to service = `escrow × score / 10000`; remainder + proportional service-bond slash → agent.

---

## Architecture (Crucible × Cadence × Arc)

Crucible is a **layer above** Cadence (Arc402), not a replacement.

```
┌────────────────────────────────────────────┐
│  Application: paid AI service               │
├────────────────────────────────────────────┤
│  ★ Crucible — quality-outcome settlement   │ ← this repo
│  • per-call prediction markets             │
│  • pluggable resolvers (testcase / oracle  │
│    / validator-vote / TEE / ZK-ML)         │
│  • permissionless validator economics       │
├────────────────────────────────────────────┤
│  Cadence (Arc402) — payment escrow         │
│  • PaymentEscrowV2 (existing, live)        │
│  • EIP-712 signed claims                   │
│  • batched settlement                      │
├────────────────────────────────────────────┤
│  Arc — chain (USDC as native gas)          │
└────────────────────────────────────────────┘
```

A Crucible-protected service can:
- Use Cadence's PaymentEscrow as its USDC escrow contract
- Add Crucible quality-outcome layer on top
- Settle through Cadence's batch path or directly via Crucible

## v0 scope (shipped today, 2026-05-12)

✅ **Contracts on Arc Testnet**: `CrucibleMarket`, `TestcaseResolver`, `MockResolver`, `IResolver` interface
✅ **TypeScript SDK**: `@crucible/sdk` with `ServiceClient`, `AgentClient`, `ValidatorClient`
✅ **Spec v0**: 15 sections, formal protocol design in [docs/spec-v0.md](docs/spec-v0.md)
✅ **End-to-end demo**: real LLM-style service with full on-chain settlement
✅ **30 contract tests + 7 SDK tests**

⏳ **Next**:
- `ValidatorVault` economics (slashing + reward fee pool)
- Real LLM integration (currently mocked in demo)
- Independent audit
- Mainnet deploy

❌ **NOT in v0**: slashing, reward fee pool, ZK-ML resolver, TEE resolver, mainnet, audit.

## Repository layout

| Folder | Purpose |
|---|---|
| [`contracts/`](contracts/) | Solidity contracts (Foundry) — `CrucibleMarket.sol`, `resolvers/`, tests, deploy script |
| [`sdk-ts/`](sdk-ts/) | TypeScript SDK + end-to-end lifecycle demo |
| [`docs/`](docs/) | Protocol spec + security considerations |
| [`examples/`](examples/) | Live smoke test scripts |

## License

[MIT](LICENSE)

## Author

[Zen Chen](https://github.com/Ccheh) — Strategy Researcher @ Polymarket. MSc Data Science (Sheffield).

Polymarket-style market design is the underlying mechanism for Crucible's quality resolution. This is the "Polymarket consensus, applied to AI service quality" protocol.
