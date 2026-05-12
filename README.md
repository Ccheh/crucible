# Crucible

> **Prediction-market-settled payments for probabilistic AI services on Arc.**
>
> The settlement layer existing payment protocols don't cover — payment conditional on *quality outcome*, not just delivery.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Status](https://img.shields.io/badge/status-pre--alpha-orange)](#status)

---

## The 30-second pitch

Every existing AI-payment protocol — Stripe, Lightning, Coinbase x402, Circle Nanopayments — treats AI calls as **deterministic transactions**: pay X, receive Y, done. But AI is **probabilistic**: outputs are stochastic, quality is subjective, value resolves over time.

**Crucible** adds the missing primitive: payment held in escrow, output evaluated by a **per-call prediction market**, funds released proportional to outcome. Service stakes a bond; validators stake to vote on quality; agents get refunds when delivery fails.

Built on top of [Cadence (Arc402)](https://github.com/Ccheh/arc402) as the base payment layer.

## Why this is genuinely new

| Protocol | Quality awareness | Resolution mechanism |
|---|---|---|
| Stripe | None (fraud signals only) | Centralized chargeback |
| Lightning | None | None |
| Coinbase x402 | None | 200 OK = paid |
| Circle Nanopayments | None | Same as x402 |
| Cadence (Arc402) | None in core; rep-tier as discount only | None |
| **Crucible** | **Per-call market-resolved score** | **Pluggable resolvers + validator stakes + optimistic dispute** |

No payment protocol has ever made quality a first-class settlement primitive. Crucible is the first.

## Roles

- **Agent** — pays for AI service, optionally disputes
- **Service** — provides AI output, commits to quality claim, stakes bond
- **Validator** — stakes capital to vote on output quality (Schelling-point game)
- **Resolver** — pluggable verification logic (contract, immutable per registration)
- **Disputer** — challenges optimistic resolution within window

Anyone can be any role. No permissioning. No KYC. No central operator.

## Resolver types (pluggable verification)

| Resolver | What it verifies | Trust model | v0 status |
|---|---|---|---|
| `TestcaseResolver` | Code-generation outputs vs. testcases | Validators run sandbox | **v0 priority** |
| `OracleResolver` | Real-world predictions vs. ground truth | Chainlink / Pyth / UMA | v0.2 |
| `ValidatorVoteResolver` | Subjective quality (translation, creative) | Schelling point of staked validators | v0.2 |
| `TEEResolver` | Inference-integrity proofs | Trusted hardware attestation | v0.3 |
| `ZkMlResolver` | Pure cryptographic proof of inference | ZK ML | future |

## v0 scope (shipped today)

✅ **Contracts deployed to Arc Testnet** (see addresses above):
- `CrucibleMarket` — per-call market with EIP-712 service auth + optimistic dispute window
- `TestcaseResolver` — permissionless validator stake/vote network with 7-day unstake cooldown, stake-weighted score consensus, 1-hour voting window
- `IResolver` — pluggable verification interface
- `MockResolver` — for testing only

✅ **30 passing tests**:
- 13 CrucibleMarket: bond pool, openMarket happy/error paths, dispute lifecycle, score 0/5000 payment math
- 17 TestcaseResolver: stake/unstake with cooldown, vote validation (min stake, range, double-vote), stake-weighted resolution, view function correctness

⏳ **Next (Week 2 onward)**:
- TypeScript SDK (`@crucible/sdk` for service + agent + validator clients)
- End-to-end paid code-gen demo (LLM API service + validator agent + market resolution)
- Mainnet-ready audit prep doc
- ValidatorVault economic stress tests

❌ **Not in v0** (slated for v0.2+): slashing, reward fee pool, ZK ML resolver, TEE attestation resolver, mainnet, independent audit.

## First use case: paid code generation

The motivating real-world example:

1. Agent pays a code-gen service 0.05 USDC to write a Python function.
2. Service returns the code + posts commitment hash on-chain.
3. Agent runs the testcases locally; if they pass, lets the dispute window expire — service gets paid in full.
4. If tests fail, agent disputes within the window.
5. Validators (anyone with 0.1 USDC staked in TestcaseResolver) run the testcases themselves, vote stake-weighted on the pass rate.
6. After voting window closes, contract auto-resolves: payment to service = `escrow × score / 10000`; remainder + proportional service-bond slash → agent.

**This is the protocol that's missing from Circle Nanopayments / x402 / Stripe / Lightning** — none of them have a quality-conditional settlement layer.

## Comparison: Crucible × Cadence (the relationship)

Crucible is a **layer above** Cadence, not a replacement.

```
┌────────────────────────────────────────────┐
│  Application: paid AI service               │
├────────────────────────────────────────────┤
│  ★ Crucible — quality-outcome settlement   │ ← new
│  • per-call prediction markets             │
│  • pluggable resolvers                     │
│  • validator economics                     │
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

## Repository layout

| Folder | Purpose |
|---|---|
| `contracts/` | Solidity contracts (Foundry) |
| `sdk-ts/` | TypeScript SDK (W2 work) |
| `docs/` | Protocol spec + design docs |
| `examples/` | Reference integrations |

## Status

**Pre-alpha — v0 LIVE on Arc Testnet** (2026-05-12).

| Contract | Arc Testnet address |
|---|---|
| **CrucibleMarket** | [`0x61996d505d6510a339f39c9923519b2f5350f61c`](https://testnet.arcscan.app/address/0x61996d505d6510a339f39c9923519b2f5350f61c) |
| **TestcaseResolver** | [`0xa12874e9f77be35efb9e3aeb19eb547b9f224195`](https://testnet.arcscan.app/address/0xa12874e9f77be35efb9e3aeb19eb547b9f224195) |
| **MockResolver** (for testing) | [`0x76696e3c541eb32c81cfc1cbfb3e5e5ef1c4d35f`](https://testnet.arcscan.app/address/0x76696e3c541eb32c81cfc1cbfb3e5e5ef1c4d35f) |

**30 tests passing** (13 CrucibleMarket + 17 TestcaseResolver). See [docs/spec-v0.md](docs/spec-v0.md) for design.

### Live on-chain end-to-end verification (Arc Testnet, 2026-05-12)

Full protocol lifecycle exercised on the live deployed contracts. Every step is a real on-chain transaction:

**Phase 1 — CrucibleMarket optimistic settlement** (service stakes bond, agent opens market with EIP-712 service authorization, 60-second dispute window, automatic resolution at score=10000):

| Step | tx |
|---|---|
| service deposits 0.5 USDC bond | [`0xbed641ed...`](https://testnet.arcscan.app/tx/0xbed641eddba245aac3ccfc337bf743ab9a4cea071f33176d4ed0f8c0d4968599) |
| service whitelists MockResolver | [`0xa0de7856...`](https://testnet.arcscan.app/tx/0xa0de7856551a756ff836d52220e26add8eb9eddc6156ee8ffc7646631324593c) |
| agent opens market with 0.01 USDC + EIP-712 auth | [`0x616c8d57...`](https://testnet.arcscan.app/tx/0x616c8d5712d4a6b8c1ea7b30672a0afc1c1c534b30a805c1110cb65f2523660a) |
| collect after 60s window → market resolves at score 10000 | market `0xaf28e414...` status `3` (Resolved), payments distributed ✅ |

**Phase 2 — TestcaseResolver validator network** (validator stakes, casts a vote on a synthetic market; voting deadline auto-opens 1h from first vote):

| Step | tx |
|---|---|
| main wallet stakes 0.2 USDC into TestcaseResolver | [`0x0117371c...`](https://testnet.arcscan.app/tx/0x0117371ce85a31b6dfa18a21d8f0805845fa5fe636fef3055749f9c6cfe1fe14) |
| validator votes scoreBps=7500 on synthetic market | [`0x65c71cc1...`](https://testnet.arcscan.app/tx/0x65c71cc1098655f1537d1658da05ccd6b7df985c22f51ff3c97f3be843ee3ea4) |

**This is not unit-test-only.** Every flow above is real EVM execution on Arc Testnet, verifiable on-chain.

## License

[MIT](LICENSE)

## Author

[Zen Chen](https://github.com/Ccheh) — Strategy Researcher @ Polymarket. MSc Data Science (Sheffield).

Polymarket-style market design is the underlying mechanism for Crucible's quality resolution. This is the "Polymarket consensus, applied to AI service quality" protocol.
