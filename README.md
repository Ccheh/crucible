# Crucible

> **Stake-weighted Schelling consensus on AI output quality, used as a payment-settlement primitive.** A research-grade protocol on Arc that asks: *what if AI service payments resolved on a market-derived quality score, not just delivery?*

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Arc Testnet](https://img.shields.io/badge/Arc%20Testnet-v0.6%20live-blue)](https://testnet.arcscan.app/address/0x6535a3cbb4235746b732ab5d55c6b0988f381a20)
[![Tests](https://img.shields.io/badge/tests-142%2F142%20passing-success)](#)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-blue)](contracts/foundry.toml)
[![TypeScript](https://img.shields.io/badge/TypeScript-strict-blue)](sdk-ts/tsconfig.json)

> **Read this first**: this is a **research-grade protocol with no production adopters yet**. The mechanism design is the contribution. Use it as a reference for thinking about quality-conditional settlement on programmable money; **don't deploy it under real value without an audit + real validator bootstrap.** Honest limits section is [below](#honest-limits).

---

## At a glance

```
6 protocol versions shipped (v0 → v0.6), each frozen as deployable artifact
142 forge tests + 7 SDK tests passing
v0.6 live on Arc Testnet — deployed for ~0.088 USDC of gas
TypeScript SDK supports both v0 (initial release) and v0.6 (latest)
MIT licensed, no admin keys, no upgrade proxy, ~2,600 LOC Solidity
Built above Cadence (Arc402) base payment layer

What this is:    research-grade reference implementation
What this isn't: production payment rail (yet) — no third-party adopters,
                 pre-audit, validator network not bootstrapped
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

## The thesis

Today's payment rails (Stripe, Lightning, x402, Circle Nanopayments, Cadence) treat AI calls as **deterministic transactions** — pay X, receive Y, done. But AI is probabilistic: outputs are stochastic, quality is subjective. Existing rails settle on **delivery confirmation**, not **outcome quality**.

**Crucible explores what a quality-conditional settlement primitive looks like**: payment held in escrow, output evaluated by a stake-weighted validator consensus, funds released proportional to a 0–10000 quality score.

| Protocol | Quality awareness | Resolution mechanism |
|---|---|---|
| Stripe | None (fraud signals only) | Centralized chargeback |
| Lightning | None | None |
| Coinbase x402 | None | 200 OK = paid |
| Circle Nanopayments | None | Same as x402 |
| Cadence (Arc402) | None | None |
| **Crucible** | **Market-resolved score per call** | **Pluggable resolvers + stake-weighted validator consensus + optimistic dispute** |

### Why "prediction market" is the right reference (and where the framing is loose)

The mechanism is **closer to UMA's optimistic oracle / Augur's stake-weighted Schelling consensus** than to Polymarket-style order-book markets:

- ✅ **Like prediction markets**: subjective claims are resolved by economic stake-weighted voting; honest validators are rewarded, dissenters slashed proportional to distance from consensus.
- ❌ **Unlike prediction markets**: there is **no order book, no continuous price discovery, no liquidity provider**. The "market" is a one-shot voting round with a 30-min commit + 30-min reveal window.

So "prediction-market-settled" is a marketing handle. The technically precise label is **stake-weighted Schelling consensus on output quality, with proportional-distance slashing**. The README uses the looser phrase because it lands faster; the contracts implement the precise mechanism.

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

## Roles (defined in the protocol; no active network yet)

| Role | What they do | Skin in the game | Reward |
|---|---|---|---|
| **Agent** | Pays for AI service, optionally disputes (with bond from v0.3+) | USDC in escrow + dispute bond | Refund proportional to (10000-score) |
| **Service** | Provides AI output, commits to quality claim | Bond posted to bondPool, locked per market | Payment proportional to score |
| **Validator** | Stakes USDC, commits + reveals a vote per disputed market (v0.5+) | Validator stake (>= MIN_STAKE) | Subscription yield (v0.4+) + dispute reward share |
| **Resolver** | Pluggable on-chain verification logic | None (pure code) | None directly; receives fees + subscriptions for distribution |

The protocol is permissionless by design — no KYC, no central operator, no admin keys. **The active set is empty today**: no third-party services use Crucible for real traffic, and the validator network is the smart contract waiting for stakers. This is infrastructure waiting for adopters.

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

## Honest limits

The mechanism design and engineering are real. The market validation is not. Specifically:

- **No production adopters.** Every on-chain transaction was generated by our own scripts. No third-party AI service uses Crucible. The "validator network" today is **the smart contracts, not an active set of staked validators** — we deployed the infrastructure but it has not bootstrapped a real network.
- **Pre-audit.** 142 forge tests pass, but no independent security audit. Treat as testnet-only research code.
- **The killer demo (real LLM end-to-end) is in progress** — see [`sdk-ts/examples/`](sdk-ts/examples/). The deterministic mock LLM is shipped; the real-API integration is the next milestone, not a current claim.
- **ERC-8004 reputation events are emitted but not yet read** by any indexer. The schema is designed for forward compatibility when ERC-8004 indexers emerge; today they are just structured log events.
- **Arc-specificity is loose.** Crucible could run on any EVM chain. We chose Arc because (a) USDC native gas keeps sub-cent settlement clean, and (b) Arc is Circle's agentic-economy bet. There is no technical mechanism that requires Arc specifically.
- **Schelling consensus has a known >50%-stake-attack ceiling.** The 40% voting weight cap mitigates the 40–70% range; >70% stake by a single coordinated party cannot be mitigated by any one-shot mechanism. This is a property of the design, not a bug.
- **Validator economics require dispute volume to bootstrap.** Subscription pool (v0.4) gives validators baseline yield from all settlements, but the absolute amounts at testnet scale are negligible. Real economics need mainnet traffic.

If you're considering integrating, treat this as **research infrastructure on a probabilistic-AI-payment thesis Circle is also pursuing**, not as production-ready rails.

## v0 scope (shipped, 2026-05-12)

✅ **Contracts on Arc Testnet** (six versions, v0 → v0.6): `CrucibleMarket*`, `TestcaseResolver*`, `MockResolver`, `IResolver` interface, `IResolverFeeReceiver` interface, `IResolverSubscriptionReceiver` interface
✅ **TypeScript SDK**: `@crucible/sdk` with v0 clients + new `v06` module (ServiceClientV6, AgentClientV6, ValidatorClientV6)
✅ **Spec v0**: 15 sections + v0.2–v0.6 addenda in [docs/spec-v0.md](docs/spec-v0.md)
✅ **End-to-end optimistic-path demo on Arc Testnet** (real txs) — see [`sdk-ts/examples/v06-optimistic.ts`](sdk-ts/examples/v06-optimistic.ts)
✅ **142 forge tests + 7 SDK tests passing**

⏳ **Open items** (we are deliberately stopping protocol work to focus here):
- Real LLM integration in a demo (no more API stubs)
- Real-chain dispute-path lifecycle evidence (commit + reveal + resolveDisputed txs in README)
- Independent audit (M2 of original roadmap)
- Mainnet deploy with raised MIN_STAKE

❌ **NOT in any current version**: ZK-ML resolver, TEE resolver, mainnet, audit, third-party integrators.

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

[Zen Chen](https://github.com/Ccheh) — MSc Data Science (Sheffield). Building on Arc.

Crucible's resolution mechanism is closest in spirit to **UMA's optimistic-oracle stake-weighted Schelling consensus**, applied to AI service quality at per-call granularity. The "prediction market" framing in the lead is a marketing handle; the precise label is documented in [The thesis](#the-thesis) section.
