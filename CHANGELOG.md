# Changelog

All notable changes to the Crucible protocol.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased] — 2026-05-12

### Added — Crucible v0.6 protocol layer

The one remaining hole from v0.5 audit notes (stuck disputed markets) is now closed.

- `contracts/src/v06/CrucibleMarketV6.sol` adds:
  - **`forceResolveStale(marketId)`** — permissionless force-settle for stuck disputed markets. Callable by anyone after `STALE_RESOLVE_GRACE = 24 hours` from `disputedAt` AND when the resolver still cannot resolve (canResolve = false because no validators revealed). Settles at scoreBps=10000 (service wins by default — they delivered, validators ghosted, agent could have not disputed).
  - New `disputedAt` field on Market struct (set in `dispute()`) — times the stale grace.
  - New `MarketForceResolved` event for indexers.
  - EIP-712 domain bumped to `"6"` (same typehash structure as v0.5; just version isolation).
- `contracts/test/CrucibleMarketV6.t.sol` — 11 tests including stuck-market resolution at score=10000, callable-by-anyone, grace-not-passed revert, resolver-ready revert (when reveal happened normally), v0.5 carry-overs (per-market bondBps, subscription, openMarket).

Combined: **142 forge tests passing across v0 + v0.2 + v0.3 + v0.4 + v0.5 + v0.6**.

This effectively closes the "open for v0.5+" items list. Remaining work is operational (mainnet config, validator network bootstrapping) rather than protocol design.

### Added — Crucible v0.5 protocol layer

The v0.5 release closes the three remaining items I marked "open for v0.5+" in the v0.4 audit notes (the per-market bond config, the commit-reveal voting, and the configurable MIN_STAKE for mainnet).

- `contracts/src/v05/TestcaseResolverV5.sol` — adds:
  - **Commit-reveal voting**. Replaces the single-shot `vote()` of v0.4 with a two-phase flow: `commitVote(marketId, voteHash)` during a 30-min commit window, then `revealVote(marketId, score, salt)` during a 30-min reveal window. Hash is `keccak256(abi.encode(score, salt, marketId, voter))` — includes voter and marketId so it can't be replayed across markets or by other addresses. A validator who only commits but never reveals is NOT counted in resolution and is NOT locked by pendingVotes.
  - **Configurable MIN_STAKE**. Constructor takes `_minStake` (uint256, must be > 0). Mainnet deployments can deploy with 1+ USDC; testnet keeps 0.1 USDC. The `MIN_STAKE` is `immutable` so it can't change post-deploy.
  - `computeVoteHash(scoreBps, salt, marketId, voter)` view helper for off-chain commit construction.
  - State machine: None → CommitOpen (first commit) → RevealOpen (`> commitDeadline`) → Resolvable (`> revealDeadline`).
  - All v0.4 mechanics preserved: subscription pool with MasterChef accumulator, 40% voting weight cap, ERC-8004 reputation events, slashing on distance-from-median, pendingVotes guard, fee + reward distribution.
- `contracts/src/v05/CrucibleMarketV5.sol` — adds:
  - **Per-market `disputeBondBps`** field in `OpenAuth`. Services pick their own dispute friction at sign time. Validated at `openMarket` against `[MIN_DISPUTE_BOND_BPS=100, MAX_DISPUTE_BOND_BPS=5000]` (1% to 50%). `dispute()` requires exactly `(agentEscrow * bondBps) / 10000`.
  - `requiredDisputeBond(marketId)` now uses the market's own bondBps.
  - **EIP-712 typehash changed** to include `disputeBondBps` — bumps domain version to `"5"`. v0/v0.2/v0.3/v0.4 sigs cannot cross-replay against v0.5.
  - All v0.4 mechanics preserved: validator subscription routing on every settlement, ServiceReputation events, optimistic + disputed path math, resolver fee routing on dispute.

### Added — v0.5 tests (32 new, 131 total across all versions)

- 21 `TestcaseResolverV5Test`: constructor validation (zero minStake reverts, alternate minStake works), commit-reveal edge cases (double commit, late commit, early reveal, late reveal, wrong score, wrong salt, no commit, double reveal), full lifecycle median, unrevealed commits do not count, anti-copy-attack demo, vote hash domain isolation, pendingVotes only on reveal, voting cap + subscription accumulator carry over.
- 11 `CrucibleMarketV5Test`: EIP-712 v5 domain, bond bps below/above range reverts, bond bps at min/max boundaries, different markets have different bonds, dispute uses per-market bond, tampered bond signature fails, subscription paid on optimistic path, ServiceReputation event emission, openMarket happy path with v5 struct shape.

Combined: **131 forge tests passing across v0 + v0.2 + v0.3 + v0.4 + v0.5**.

### Anti-collusion property gained

In v0.4 a validator could watch other validators' votes (since they were public on `vote()`) and free-ride by submitting an identical vote at the last second. That's mechanically free with no penalty — perfect for laundering bad votes.

In v0.5 the commit phase is a sealed-envelope phase. The hash `keccak256(score, salt, marketId, voter)` leaks no information about the score (the salt is 256 random bits). Validators must commit their own honest estimate; only after the commit window closes does anyone know what anyone else voted.

### Economic flexibility gained

Services can now match dispute friction to their value-at-stake:
- A free testnet sandbox can set `disputeBondBps = 100` (1%) — disputes are cheap, low-stakes UX.
- A high-value AI service ($0.10/call) can set `disputeBondBps = 2000` (20%) — disputes have real economic friction.

The signature requirement means agents must accept the service's chosen bondBps; an agent who doesn't like the friction simply doesn't open the market. This is the right side-of-the-table for the decision: services know their own quality assurance better than the protocol does.

### What v0.5 still doesn't solve (small leftover list for v0.6+)

- **Stuck disputed markets** — if everyone commits but no one reveals, the market is stuck in Disputed status with no resolution. v0.6 should add a force-resolve-default fallback after a grace period.
- **>70% stake attacker** — still mechanically impossible to mitigate on a single market. Validator network stake distribution is the only fix at this level.
- **Validator yield smoothing** — subscription distribution is event-driven (per fee deposit). Smoother yield would need block-time accrual; not on the critical path.
- **Cross-resolver reputation** — a validator's reputation is tracked per-resolver via events; an off-chain ERC-8004 indexer can aggregate. On-chain aggregation across resolvers is v0.7+ work.

### Added — Crucible v0.4 protocol layer

The v0.4 release directly attacks the three biggest items I marked "still open" in the v0.3 audit notes:

- `contracts/src/v04/IResolverSubscriptionReceiver.sol` — new interface (`notifyValidatorSubscription()`) that lets the market push a small always-on fee to resolvers on every settlement.
- `contracts/src/v04/TestcaseResolverV4.sol` — adds:
  - **MasterChef-style validator subscription pool**. `accSubscriptionPerStake` accumulator settles every validator's earned subscription on stake / unstake / claim. `claimSubscription()` lets validators withdraw at any time. `earnedSubscription(address)` is a view helper. This solves the v0.3 "validators only earn during disputes" problem — validators now earn proportional to stake on EVERY market settlement.
  - **Stake voting weight cap** (`MAX_VOTING_WEIGHT_BPS = 4000`). At resolve time, no single validator's effective stake for median computation exceeds 40% of total voter stake. Tested with `test_votingCap_capsLargeStake`: a 55%-stake validator voting against a 45%-stake honest cohort would win under v0.3 (median = 0); under v0.4 the cap lets the honest cohort outweigh them (median = 10000).
  - **ERC-8004 reputation events**. `ValidatorReputation(validator, marketId, vote, deviation, slashedAmount, honest)` emitted for each voter on resolve — a stable schema for off-chain reputation indexers.
  - Subscription accumulator is settled before slashing so slashed validators don't lose their pre-slash sub earnings.
- `contracts/src/v04/CrucibleMarketV4.sol` — adds:
  - **`VALIDATOR_SUBSCRIPTION_BPS = 10`** (0.10% of agent escrow) charged on EVERY settlement (optimistic + disputed), routed to the resolver via `notifyValidatorSubscription()`. Graceful fallback: if resolver doesn't implement the interface, value stays in escrow.
  - **`ServiceReputation(service, marketId, finalScoreBps, bondSlashed)`** emitted on every resolve — ERC-8004-compatible service reputation feed.
  - Extended `MarketResolved` event signature includes both `resolverFee` and `validatorSubscription` for indexer transparency.
  - EIP-712 domain version `"4"` — cross-version replay isolation against v0 / v0.2 / v0.3.

### Added — v0.4 tests

- 14 `TestcaseResolverV4Test`: subscription accumulator math (single, equal pair, unequal stake, late joiner, claim+zero, zeroTotalStake edge), voting cap (caps 55% stake / no-op on uncapped scenario), ERC-8004 reputation event emission, slash settles subscription before stake reduction, pendingVotes guard.
- 9 `CrucibleMarketV4Test`: EIP-712 v4 domain, optimistic subscription paid, optimistic subscription bounces with MockResolver, disputed subscription+fee both paid, ServiceReputation event, dispute requires exact bond, score=10000 settlement (frivolous dispute), requiredDisputeBond view, openMarket happy path.

Combined: **99 forge tests passing across v0 + v0.2 + v0.3 + v0.4**.

### Economic implications

A market with $0.01 USDC of agent escrow now pays:
- `0.001 USDC` (10 bps) into the validator subscription pool — distributed pro-rata across all stakers
- `0.0002 USDC` (2 bps) into the dispute resolver pool — only on dispute path, only to participating voters
- `0.0005 USDC` (5 bps) dispute bond from the agent — only when agent calls dispute

For a busy service (10k calls/day at $0.01 each): the validator pool accrues $10/day, split across staked validators. A validator with 10% of total stake earns $1/day on a 10-USDC stake (~3.65x USDC APY before any dispute upside). Earnings track stake share linearly. This is the equilibrium the v0.3 audit said was missing.

### What v0.4 still doesn't solve (open for v0.5+)

- **MIN_STAKE = 0.1 USDC** still low; mainnet config should raise.
- **Per-market dispute bond configuration** — still a contract constant; OpenAuth typehash change is the cost.
- **Commit-reveal voting** — still vulnerable to validators copying each others' votes (low risk on a 1-hour voting window but a hardening point).
- **Median is dragged by a single validator at exactly the 40% cap** — the cap helps in the 50–70% range but caps don't solve the >70% case (and can't, mechanically).

### Added — Crucible v0.3 protocol layer

- `contracts/src/v03/CrucibleMarketV3.sol` — v0.3 market with:
  - **Dispute bond**: agents must attach `(agentEscrow * DISPUTE_BOND_BPS) / 10000` (5% of escrow) of additional value when calling `dispute(marketId)`. The bond is split between service and agent at settlement proportional to the final scoreBps — score=10000 sends the entire bond to the service (cost of frivolous disputes), score=0 returns it fully to the agent (justified dispute).
  - **EIP-712 domain version `"3"`** — v0.3 sigs cannot cross-replay against v0/v0.2.
  - **`requiredDisputeBond(marketId)`** view helper for off-chain agents.
  - All v0.2 mechanics preserved: bond pool, resolver whitelist, RESOLVER_FEE_BPS routing, OpenAuth EIP-712 typehash unchanged.
- `contracts/src/v03/TestcaseResolverV3.sol` — v0.3 resolver with:
  - **Stake-weighted median consensus** replacing v0.2's stake-weighted mean. A minority outlier voting an extreme value can no longer drag the consensus regardless of their stake (so long as their stake is less than majority).
  - Algorithm: insertion-sort `(vote, stake)` pairs at resolve time, then find smallest score `v` such that cumulative stake of `votes ≤ v` covers ≥ 50% of total voted stake.
  - All other v0.2 mechanics carried unchanged: slashing on distance-from-consensus, fee-pool intake via `notifyFee`, pendingVotes-aware unstake, claimRewards.
- v0.3 resolver name returns `"TestcaseResolverV3"`.

### Added — v0.3 tests (22 new, 76 total across v0 + v0.2 + v0.3)

- 11 `CrucibleMarketV3Test`: EIP-712 v3 domain check, dispute requires exact bond (revert cases), score=0 / 5000 / 10000 dispute-bond split math, optimistic-path zero-bond zero-fee, `requiredDisputeBond` view, openMarket happy path.
- 11 `TestcaseResolverV3Test`: median single-voter, median equal-stake, **median-outlier-resistance** (the test that justifies v0.3: 4 honest + 1 outlier at extreme → mean would be 7200 but median = 9000), stake-weighted median with no majority, majority-stake-wins (intentional), slashing on outlier vs median, fee distribution, pendingVotes guard, claimRewards.

The median-outlier-resistance test is the most important: under v0.2 a 20%-stake outlier voting 0 drags the mean from 9000 down to 7200 (the consensus is materially wrong). Under v0.3 the median stays at 9000 and the outlier is slashed.

Combined: **76 forge tests passing** across v0 + v0.2 + v0.3.

### What v0.3 still doesn't solve (open for v0.4+)

- **MIN_STAKE = 0.1 USDC** still too low for mainnet sybil deterrence. Held constant for v0.3 to keep the testnet network easy to seed.
- **Validator equilibrium at low dispute rate** — validators still only earn during disputes.
- **Per-market dispute bond configuration** — v0.3 bond is a contract constant. Future versions may let services specify their own bond rate.
- **No on-chain dispute reputation** — ERC-8004 events still v0.4+.

### Added — Crucible v0.2 protocol layer

- `contracts/src/v02/IResolverFeeReceiver.sol` — optional `notifyFee(bytes32 marketId) external payable` interface that lets resolvers receive a validator-reward fee from the market.
- `contracts/src/v02/CrucibleMarketV2.sol` — v0.2 market with:
  - **EIP-712 domain version `"2"`** for cross-version replay isolation
  - **`RESOLVER_FEE_BPS = 200`** (2%) of agent escrow routed to the resolver via `notifyFee` on the disputed-resolution path (push BEFORE `resolve()`, so the resolver can in-line the fee in its reward distribution)
  - Graceful fallback when the resolver does NOT implement `notifyFee` (try/catch keeps the fee in the escrow and splits it normally)
  - No resolver fee on the optimistic / `collectAfterWindow` path — well-behaved services pay no premium
- `contracts/src/v02/TestcaseResolverV2.sol` — v0.2 validator network resolver with:
  - **Slashing**: `TOLERANCE_BPS = 1500` (15pp), `MAX_SLASH_BPS = 1000` (10% cap). Validators whose vote diverges beyond tolerance from stake-weighted consensus lose stake proportional to excess distance.
  - **Reward fee pool**: accepts deposits via `notifyFee(marketId)`; distributes (`feePool + totalSlashed`) pro-rata to honest validators inside `resolve()`.
  - **Pending-vote-aware unstake**: `completeUnstake` reverts with `PendingVotes(count)` until all of the validator's voted-on markets have resolved. Closes the flash-vote-and-exit attack class.
  - Three-pass resolution (mean → slash → distribute) in a single transaction.
  - `claimRewards()` push-style withdrawal for validators.

### Added — v0.2 tests

- 8 `CrucibleMarketV2Test`: optimistic-path (no fee), disputed-fee-routed (resolver gets fee, validators earn), disputed-fee-bounces (mock resolver, fee stays in escrow), score-max / score-zero edge cases, EIP-712 v2 domain check, openMarket happy path + resolver-whitelist revert.
- 16 `TestcaseResolverV2Test`: slashing math at multiple distances, no-slash within tolerance, reward distribution to honest validators, slashed-stake redistribution, fee-pool intake, pendingVotes blocking unstake, claimRewards flow, post-resolve notifyFee revert.

Combined: **54 forge tests passing across v0 + v0.2** (added `via_ir = true` to `foundry.toml` to handle TestcaseResolverV2 stack depth).

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
