# Crucible

> **The graded-resolution layer for Arc** — a USDC-bonded, staker-participant-decoupled Schelling resolver that turns any intersubjective outcome into a *continuous* score and splits escrow proportionally. The verdict layer Circle's Blueprints punt to builders, and that UMA's token-vote model structurally cannot fix. *(v0.7 repositioning — see [`docs/repositioning-v0.7.md`](docs/repositioning-v0.7.md). Originally framed as "Schelling consensus on AI output quality used as a payment-settlement primitive.")*

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Arc Testnet](https://img.shields.io/badge/Arc%20Testnet-v0.7%20live-blue)](https://testnet.arcscan.app/address/0x9934bAF33bcF0dfD14040f8ddd5DdF18eCfEFb59)
[![Tests](https://img.shields.io/badge/tests-191%2F191%20passing-success)](#)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-blue)](contracts/foundry.toml)
[![TypeScript](https://img.shields.io/badge/TypeScript-strict-blue)](sdk-ts/tsconfig.json)

> **Read this first**: this is a **research-grade protocol with no production adopters yet**. The mechanism design is the contribution. Use it as a reference for thinking about quality-conditional settlement on programmable money; **don't deploy it under real value without an audit + real validator bootstrap.** Honest limits section is [below](#honest-limits). Self-run [Slither static analysis](audits/slither-report.md) reports no high or medium severity findings.

---

## At a glance

```
9 protocol versions shipped (v0 → v0.7 + V8/V9/V10 resolvers), each a deployable artifact
191 forge tests + 7 SDK tests passing
v0.7 live on Arc Testnet — graded-resolution layer (V7/V8/V9/V10 resolvers deployed)
TypeScript SDK supports both v0 (initial release) and v0.6 (latest)
MIT licensed, no admin keys, no upgrade proxy, ~2,600 LOC Solidity
Built above Cadence (Arc402) base payment layer
Composes upward via a CrucibleMetricOracle adapter that exposes a
  resolved market's scoreBps as an IMetricOracle for Helm
  (deployed at 0x8d7efaacbf2e944e459801f891577b40fa6124c4 on Arc Testnet,
   maintained in the Helm repo: github.com/Ccheh/helm)

What this is:    research-grade reference implementation
What this isn't: production payment rail (yet) — no third-party adopters,
                 pre-audit, validator network not bootstrapped
```

### v0.7 (current — latest) — Arc Testnet — graded-resolution layer

| Component | Address on Arc Testnet |
|---|---|
| **CrucibleMarketV7** | [`0x9934bAF33bcF0dfD14040f8ddd5DdF18eCfEFb59`](https://testnet.arcscan.app/address/0x9934bAF33bcF0dfD14040f8ddd5DdF18eCfEFb59) |
| **ScalarResolverV7** *(staker-participant decoupled)* | [`0x85b332122371f3c08253844B6170e8daC0c8c2fB`](https://testnet.arcscan.app/address/0x85b332122371f3c08253844b6170e8dac0c8c2fb) |
| **Erc8183ProportionalAdapter** | [`0x44A0a6DEFE24F8CA84a3E5390Ab3f656Db306CaB`](https://testnet.arcscan.app/address/0x44a0a6defe24f8ca84a3e5390ab3f656db306cab) |
| **ScalarResolverV8** *(M2: ERC-8004 identity-level decoupling)* | [`0xDf518581DA89f214F2260b343f9569DD5C8BC5A4`](https://testnet.arcscan.app/address/0xdf518581da89f214f2260b343f9569dd5c8bc5a4) |
| **ScalarResolverV9** *(M3: calibration-weighted consensus)* | [`0xae78729a7656c36215D1676c2Bd2E273aF3343fc`](https://testnet.arcscan.app/address/0xae78729a7656c36215d1676c2bd2e273af3343fc) |
| **ScalarResolverV10** *(M4: value-weighted calibration — anti-farming)* | [`0xb377b32a65166bcA3d9b14B8C5c1B636817F4c01`](https://testnet.arcscan.app/address/0xb377b32a65166bca3d9b14b8c5c1b636817f4c01) |

Deployment txs: market [`0x6ba571a3…`](https://testnet.arcscan.app/tx/0x6ba571a3e940cc4465a7e5ff73e32f45c19781724fb1f2bf5f7c733609ead983) · resolver [`0xd8113bc8…`](https://testnet.arcscan.app/tx/0xd8113bc89004e0316288251c1dd72452b816abbc0efcc7ba27071221811c7720) · adapter [`0xc92706c4…`](https://testnet.arcscan.app/tx/0xc92706c44645ab275d1b160f4a26603fc078459370e2d59f7f9961f895116cec) · V9 [`0xb5868bea…`](https://testnet.arcscan.app/tx/0xb5868beafc9bdecc460e4119f2ea463a21706882f9c40be90864877a1ad5d7b0) · V10 [`0x03caf35e…`](https://testnet.arcscan.app/tx/0x03caf35ec790969939767e9e0352f6ddf0e2d9b9d38229a7779d7910c64e9ccf)

**New in v0.7:** continuous proportional payout (fuzz-proven conservation) · **staker-participant decoupling** (a market's own parties can't resolve it) · pre-committed `criteriaHash` + typed dispute taxonomy · an **ERC-8183 binary→proportional adapter**. A window-denial bypass of decoupling was found & fixed during self-audit (see CHANGELOG).

**M2/M3/M4 since:** **ERC-8004 identity-level decoupling** (`ScalarResolverV8` — bars every address a participant's *identity* controls); **calibration-weighted consensus** (`ScalarResolverV9` — `voteWeight = stake × earned-accuracy calibration`, 0.25×…1.50×, so fresh capital is worth half a proven validator's; a self-generated on-chain reputation that needs no external ecosystem); and **value-weighted calibration** (`ScalarResolverV10` — the calibration step scales with a market's economic weight, closing the V9 calibration-farming vector demonstrated in our own test suite). Honestly scoped: calibration is a *bounded tilt* toward accuracy, not a whale defense, and V10 kills cheap farming but not a capitalised self-dealing cartel (see Honest limits). Full write-up: [`docs/repositioning-v0.7.md`](docs/repositioning-v0.7.md) · Grant draft: [`docs/grant-application-v0.7.md`](docs/grant-application-v0.7.md).

### v0.6 — Arc Testnet (previous)

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
- **Pre-audit.** 191 forge tests pass, but no independent security audit. Treat as testnet-only research code.
- **The killer demo (real LLM end-to-end) is in progress** — see [`sdk-ts/examples/`](sdk-ts/examples/). The deterministic mock LLM is shipped; the real-API integration is the next milestone, not a current claim.
- **ERC-8004 reputation events are emitted but not yet read** by any indexer. The schema is designed for forward compatibility when ERC-8004 indexers emerge; today they are just structured log events.
- **Arc-specificity is loose.** Crucible could run on any EVM chain. We chose Arc because (a) USDC native gas keeps sub-cent settlement clean, and (b) Arc is Circle's agentic-economy bet. There is no technical mechanism that requires Arc specifically.
- **Schelling consensus has a known >50%-stake-attack ceiling.** The 40% voting weight cap mitigates the 40–70% range; >70% stake by a single coordinated party cannot be mitigated by any one-shot mechanism. This is a property of the design, not a bug. **Calibration-weighting (V9) does *not* change this ceiling** — it is a bounded 0.25×…1.50× tilt toward earned accuracy, so it makes fresh capital worth less and lets proven validators decide among comparable-stake camps, but a supermajority whale is still bounded by the cap + validator-set distribution, not by calibration.
- **Calibration-farming — demonstrated in V9, fixed in V10 (value-weighting).** Because calibration rewards a track record of voting-with-consensus, a cartel can *manufacture* that record by voting with itself on throwaway markets. `test_limitation_farmedCartelBeatsFreshHonest` (V9) proves a 2-validator cartel farmed to the 1.50× ceiling overrides **four** equal-stake *fresh* honest validators while holding **half** the stake. **`ScalarResolverV10` closes the cheap version of this:** the per-market calibration step now scales with the market's economic weight (resolver fee ∝ escrow), so a dust market grants ≈ zero calibration. `test_fix_dustFarmingCannotOverrideHonest` replays the exact attack on dust markets and the cartel stays fresh — the market resolves to the honest `2000`, not the cartel's `10000` — while `test_headline_stillWorks_onValuedMarkets` shows the legitimate mechanism intact on real-value markets. **Honest residual:** value-weighting kills the *cheap* dust-spam farm but not a *capitalised* self-dealing cartel that routes real escrow through markets it controls (it recovers most of the fee via its own validators; true cost = gas + capital lockup + commit/reveal time per step). The deeper fix — crediting calibration only for agreement with validators outside the voter's recent cohort (cohort-diversity) — is the next milestone. We ship the demonstrated limitation *and its fix* in the open rather than hide either.
- **Validator economics require dispute volume to bootstrap.** Subscription pool (v0.4) gives validators baseline yield from all settlements, but the absolute amounts at testnet scale are negligible. Real economics need mainnet traffic.

If you're considering integrating, treat this as **research infrastructure on a probabilistic-AI-payment thesis Circle is also pursuing**, not as production-ready rails.

## v0 scope (shipped, 2026-05-12)

✅ **Contracts on Arc Testnet** (six versions, v0 → v0.6): `CrucibleMarket*`, `TestcaseResolver*`, `MockResolver`, `IResolver` interface, `IResolverFeeReceiver` interface, `IResolverSubscriptionReceiver` interface
✅ **TypeScript SDK**: `@crucible/sdk` with v0 clients + new `v06` module (ServiceClientV6, AgentClientV6, ValidatorClientV6)
✅ **Spec v0**: 15 sections + v0.2–v0.6 addenda in [docs/spec-v0.md](docs/spec-v0.md)
✅ **End-to-end optimistic-path demo on Arc Testnet** (real txs) — see [`sdk-ts/examples/v06-optimistic.ts`](sdk-ts/examples/v06-optimistic.ts)
✅ **191 forge tests + 7 SDK tests passing**

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
