# Changelog

All notable changes to the Crucible protocol.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased] — 2026-05-12

### Added — TypeScript SDK (`@crucible/sdk`)

- `ServiceClient` — `depositBond`, `withdrawBond`, `setResolverAllowed`, `signOpenAuth` (EIP-712), `bondPool`, `bondLocked`, `bondAvailable`
- `AgentClient` — `openMarket`, `dispute`, `collectAfterWindow`, `resolveDisputed`, `getMarket`
- `ValidatorClient` — `stake`, `requestUnstake`, `completeUnstake`, `vote`, `getStake`, `getMarket`
- Helpers: `computeMarketId`, `randomNonce`, `buildDomain`, `OPEN_AUTH_TYPES`, `codeGenCommitment`
- Constants: `ARC_TESTNET`, `CRUCIBLE_ARC_TESTNET`, `CRUCIBLE_MARKET_ABI`, `TESTCASE_RESOLVER_ABI`, `MarketStatus`
- 7 unit tests covering id derivation, nonce randomness, EIP-712 domain, type definitions

### Added — Demos

- `sdk-ts/examples/full-lifecycle.ts` — full code-gen lifecycle through SDK (mock LLM, real on-chain txs)
- `examples/live-smoke-test.ts` — low-level integration smoke test (direct viem calls)

Both verified live on Arc Testnet with real settlement transactions.

---

## [v0] — 2026-05-12

First testnet release. **NOT audited, NOT mainnet-ready.** Pre-alpha protocol design for review and integration testing.

### Added — Smart contracts

- `IResolver.sol` — pluggable verification interface (any resolver returns scoreBps 0..10000)
- `CrucibleMarket.sol` — per-call markets with:
  - Service bond pool (`depositBond` / `withdrawBond`)
  - Service-side resolver whitelist (`setResolverAllowed`)
  - EIP-712 service authorization (`OpenAuth` typed message, domain `"Crucible" version "1"`)
  - Optimistic dispute window (`disputeWindow` configurable per market)
  - `claimBatch` settlement at score: paid_to_service = `escrow × score / 10000`
  - Service-bond slashing proportional to `(10000 - score)`
  - Atomic, reentrancy-protected
- `TestcaseResolver.sol` — permissionless validator network:
  - Minimum stake 0.1 USDC
  - 7-day unstake cooldown (`requestUnstake` + `completeUnstake`)
  - Per-market voting (`vote(marketId, scoreBps)`) with stake-weighted aggregation
  - 1-hour voting window auto-opens on first vote
  - `IResolver` compliance (`canResolve` / `resolve` / `name`)
- `MockResolver.sol` — testing-only resolver (returns score from calldata)

### Added — Tests

- 13 `CrucibleMarketTest`: bond pool, openMarket happy path, openMarket reverts (resolver-not-allowed, forged-sig, replay), dispute lifecycle, collect-after-window, resolveDisputed at scores 0/5000/10000
- 17 `TestcaseResolverTest`: stake/unstake with cooldown, vote validation (min stake, score range, double-vote), pre-deadline / post-deadline behavior, stake-weighted resolution math, view function correctness, IResolver compliance

Total: **30 forge tests passing, 0 failures.** Foundry viaIR enabled.

### Added — Documentation

- `docs/spec-v0.md` — 15-section formal protocol specification
- `README.md` — reviewer-facing landing with live evidence, architecture diagram, SDK quick-start
- `LICENSE` (MIT)

### Deployed — Arc Testnet (chainId 5042002)

- `CrucibleMarket`: `0x61996d505d6510a339f39c9923519b2f5350f61c`
- `TestcaseResolver`: `0xa12874e9f77be35efb9e3aeb19eb547b9f224195`
- `MockResolver`: `0x76696e3c541eb32c81cfc1cbfb3e5e5ef1c4d35f`

Total deploy gas: ~6.18M (~0.247 USDC at 40 gwei).

### Verified — End-to-end on chain

Real lifecycle executed on Arc Testnet:
- Service bond deposit + resolver whitelist
- EIP-712 OpenAuth signature + agent market opening
- 60-second dispute window expiration
- Optimistic settlement at scoreBps=10000
- Validator stake + vote

8+ verifiable on-chain transactions documented in README.

### Known limitations

- **No slashing yet** — TestcaseResolver records votes; the contract does not yet penalize validators whose vote diverges from consensus. v0.2 work.
- **No reward fee pool** — validators currently vote without payment. v0.2 introduces a 1-3% market-fee share.
- **Validators use stake-weighted mean** for v0 simplicity. Median is more attack-resistant but requires sorting; planned for v0.2.
- **No challenge window** — single voting window only. v0.2 adds an optional second-round dispute.
- **MockResolver in production-leaning paths** — useful for testing only. Use TestcaseResolver or OracleResolver (v0.2) for real services.
- **No mainnet deployment** — pre-audit. Audit + mainnet are weeks 6-8 of the roadmap.

### Strategic context

Built after [Cadence (Arc402)](https://github.com/Ccheh/arc402) v0.1.0 (an open-source seller-side middleware for Circle Nanopayments) was shipped, then the team identified that the truly missing primitive in AI agent payments is **quality-conditional settlement**, not just payment routing. Crucible is the protocol layer that fills this gap.

Crucible composes with — does not compete with — Cadence, Nanopayments, x402, ERC-8183, and ERC-8004. It's the settlement layer above the payment layer.

---

[Unreleased]: https://github.com/Ccheh/crucible/compare/v0...HEAD
[v0]: https://github.com/Ccheh/crucible/releases/tag/v0
