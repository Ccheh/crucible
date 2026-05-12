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

## v0 scope (what we're shipping first)

- **Contracts**: `CrucibleRegistry`, `MarketFactory`, `QualityMarket`, `ResolutionEngine`, `ReputationWriter`, `IResolver`, `TestcaseResolver`
- **First use case**: paid code generation (e.g., agent pays an LLM-backed API to write a function; pays only if testcases pass)
- **First demo**: a Cadence-compatible service that returns generated Python code; testcases run by validators; agent's escrow refunds if tests fail
- **Timeline**: 6 weeks to demo-ready, 12 weeks to first real integration
- **NOT in v0**: ValidatorVoteResolver, TEE, ZK ML, mainnet, audit

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

**Pre-alpha.** Specification phase. No contracts deployed yet. No tests yet. See [docs/spec-v0.md](docs/spec-v0.md) for current design.

## License

[MIT](LICENSE)

## Author

[Zen Chen](https://github.com/Ccheh) — Strategy Researcher @ Polymarket. MSc Data Science (Sheffield).

Polymarket-style market design is the underlying mechanism for Crucible's quality resolution. This is the "Polymarket consensus, applied to AI service quality" protocol.
