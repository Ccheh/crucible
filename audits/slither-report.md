# Crucible — Slither static analysis report

> **What this is**: self-run static analysis with the public Slither tool
> across all 6 protocol versions (v0 → v0.6).
> **What this isn't**: a formal independent audit. No external audit firm
> has reviewed Crucible. Treat all 6 versions as research-grade pending audit.

**Tool**: [slither-analyzer](https://github.com/crytic/slither) v0.11.5
**Solidity**: 0.8.28
**Scope**: `contracts/src/` (27 contracts across 6 versions + resolvers + interfaces)
**Date**: 2026-05-13
**Total detectors run**: 101
**Total findings**: 97 — **none high or medium severity**. Breakdown by category:

| Category | Count | Severity | Action |
|---|---|---|---|
| `low-level-calls` for native USDC transfer | ~50 | Informational | **No fix** — required pattern for native-value transfers on Arc |
| `costly-operations-inside-a-loop` (storage updates in vote tallying) | 3 | Informational | **No fix** — intentional; per-voter slashing requires per-voter state writes |
| `cyclomatic-complexity` (`resolve()` in v0.2+) | 4 | Informational | **Acknowledged** — `resolve()` is the protocol's central state machine, complexity reflects the design (vote tallying + median + slash + settlement in one tx) |
| `naming-convention` (DOMAIN_SEPARATOR, MIN_STAKE) | 7 | Informational | **No fix** — EIP-712 / constants conventions |
| `timestamp` comparisons | ~30 | Informational | **No fix** — vote window / dispute window timing is intentional |

## Why so many findings (and why none are actionable)

Crucible's 27 contracts cover 6 protocol versions of an evolving design.
Slither runs across all of them. Repeated patterns (low-level USDC transfers
in every settlement function, EIP-712 DOMAIN_SEPARATOR getters in every
market version, timestamp checks for every voting window) inflate the count.

The actual underlying issue count is closer to **5 patterns**, each repeated
across versions. After de-duplication:

1. **Low-level call pattern for native USDC** — required, intentional, every settle/withdraw site uses it identically.
2. **Costly storage write inside vote-tally loop** — `totalStake -= slashAmt` per voter. Intentional; per-voter state must update for correct accounting. Vote count is bounded by validator set size, not by Sybil influx (each validator needs ≥ `MIN_STAKE` USDC).
3. **`resolve()` cyclomatic complexity** — `resolve()` walks all voters, computes weighted median, applies distance-from-median slashing, and distributes settlement in a single transaction. Atomicity is the design.
4. **EIP-712 `DOMAIN_SEPARATOR()` not in mixedCase** — standard EIP-712 convention. Same as every Uniswap/OpenZeppelin EIP-712 contract.
5. **`block.timestamp` for window comparisons** — intentional; voting windows are minutes-to-hours long, 15-second miner manipulation is irrelevant.

## High-confidence non-findings

Slither did NOT flag:
- **Reentrancy**: zero matches. All state-changing external calls happen after
  the relevant storage writes; `ReentrancyGuard.nonReentrant` is used on
  `claimRewards`, `completeUnstake`, `withdrawBond`, `dispute`,
  `collectAfterWindow`, `resolveDisputed`.
- **Arithmetic overflow**: zero matches.
- **Tx.origin authorization**: zero matches.
- **Unsafe delegatecall**: zero matches.
- **Unbounded loops**: `resolve()`'s voter loop is bounded by validator set
  size, which has economic gating (`MIN_STAKE` per validator).

## Per-version severity assessment

| Version | Total findings | Real issues found | Status |
|---|---|---|---|
| v0     | ~15 | 0 (all informational patterns) | Live on Arc Testnet |
| v0.2   | ~15 | 0 | Superseded by v0.3 |
| v0.3   | ~15 | 0 | Superseded by v0.4 |
| v0.4   | ~17 | 0 | Superseded by v0.5 |
| v0.5   | ~17 | 0 | Superseded by v0.6 |
| **v0.6 (production)** | **~17** | **0** | **Live on Arc Testnet** |

## How to reproduce

```sh
cd contracts
pip install slither-analyzer  # tested with 0.11.5
solc-select install 0.8.28
solc-select use 0.8.28
slither src/ \
  --solc-remaps "openzeppelin-contracts/=lib/openzeppelin-contracts/ forge-std/=lib/forge-std/src/" \
  --filter-paths "lib|test"
```

## Honest caveats

Slither catches automatable issues only. It does not catch:

- **Economic attacks specific to stake-weighted Schelling consensus** — these
  are covered by 142 forge tests across 11 test suites, including:
  - `test_votingCap_capsLargeStake` (40% voting weight cap holds against 50-70% stake attackers)
  - `test_median_outlierDoesNotDragConsensus_v2WouldFail` (median over mean fix)
  - `test_dispute_usesPerMarketBond` (sybil dispute spam economic)
  - `test_optimistic_subscriptionPaid` (MasterChef-style validator yield correctness)
- **Game-theoretic edge cases** like coordinated voter ghosting (mitigated
  by v0.6's `forceResolveStale` fallback).
- **Cross-protocol composability** with Cadence — handled at the application
  layer, see `hackathon-submission/integration/cross-protocol.ts`.

A real audit by an audit firm (Trail of Bits, ChainSecurity, OpenZeppelin)
would cost $10K-$50K and take 2-6 weeks. This is not a substitute. It is the
best self-served evidence we can offer pre-funding.
