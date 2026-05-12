# Security considerations — Crucible v0

> **Status**: pre-audit. This is the implementer's own threat-model and known-limits document. Read before integrating. Use with caution on testnet only.
>
> **NOT a substitute for an independent audit before mainnet deploy.** Audit is M2 of the roadmap.

## Scope

This document covers:

- `contracts/src/CrucibleMarket.sol` (~280 LOC, Solidity 0.8.28)
- `contracts/src/resolvers/TestcaseResolver.sol` (~180 LOC)
- `contracts/src/resolvers/MockResolver.sol` (~20 LOC; **production unsafe**, testing only)
- The off-chain EIP-712 OpenAuth message signed by services
- `@crucible/sdk` TypeScript SDK assembly of claims

Out of scope:

- Cadence (Arc402) protocol — its own security analysis
- Arc chain consensus and bridge security
- Off-chain LLM / validator code execution
- Client-side wallet security

## Assets at risk

1. **Agents' escrowed USDC** — locked in `CrucibleMarket.markets[marketId].agentEscrow`
2. **Service bond** — deposited via `depositBond()`, locked when markets open
3. **Validator stake** — locked in `TestcaseResolver.validatorStake[v]`
4. **Identity integrity** — services cannot be forced into markets they didn't authorize

## Adversary classes

### A1: Malicious service

**Capability**: controls a service endpoint; receives agent payments; can refuse to deliver or deliver garbage.

**Goals**: collect payment without delivering value, frame agents.

**Constraints**: must stake bond before any market can open. Bond is slashed proportionally to score < 10000 if the market is disputed and resolved against them.

### A2: Malicious agent

**Capability**: opens markets, sometimes disputes.

**Goals**: get service value without paying; dispute every market for free refunds.

**Constraints**: must put USDC in escrow up front. Cannot withdraw escrow once a market is open (only resolution-distributes).

### A3: Malicious validator

**Capability**: stakes minimum (0.1 USDC) and votes on markets.

**Goals**: sway resolution scores to extract value; collude with service or agent.

**Constraints**: stake is at risk (v0.2 will introduce slashing); votes are public and recorded on chain.

### A4: Malicious third party (MEV, observer)

**Capability**: observes the chain, mempool, public state.

**Goals**: front-run settlements; replay signed messages; steal claims in transit.

## Attack vectors and current mitigations

### V1: Service replay attack (A1)
**Vector**: Service tries to open the same market twice with the same OpenAuth.
**Mitigation**: `marketId = keccak256(service, agent, nonce)` is deterministic. Second openMarket reverts with `MarketAlreadyExists`.

### V2: Cross-version OpenAuth replay (A4)
**Vector**: OpenAuth signed for v0 contract is reused against v0.2 (when deployed with bumped domain version).
**Mitigation**: EIP-712 domain separator depends on `version`. Versioning is the planned migration path; cross-version replay is mathematically prevented.

### V3: Agent dispute spam (A2)
**Vector**: Agent disputes every market regardless of service quality, hoping validators will be biased toward refunds.
**Mitigation**: Dispute itself is free in v0 — but disputed markets must wait for resolver consensus. If agent disputes a good service, validators vote scoreBps≈10000, agent still pays. v0.2 adds dispute bond to make spam costly.

### V4: Validator collusion (A3)
**Vector**: One large validator votes scoreBps=0 on a good service to extract slash.
**Mitigation (partial)**: Stake-weighted means a small validator can't single-handedly swing resolution. Diverse validator participation makes collusion expensive. **v0 has no slashing yet**, so honest validators must outweigh malicious ones in stake share. v0.2 adds slashing for divergence-from-median.

### V5: Service-validator collusion (A1 + A3)
**Vector**: Service runs its own validator votes to confirm its own outputs.
**Mitigation (v0)**: weak — no on-chain check prevents this. **Disclosed limitation.** v0.2 will require N independent validators and add slashing.

### V6: Reentrancy via service payout (A1)
**Vector**: Service's `receive()` re-enters `collectAfterWindow` or `resolveDisputed`.
**Mitigation**: `nonReentrant` modifier on all state-mutating functions; checks-effects-interactions pattern (state updated before external call).

### V7: Insufficient bond griefing (A1)
**Vector**: Service signs OpenAuth claiming bond it doesn't have, then agent's openMarket call reverts after paying for gas.
**Mitigation**: `bondLocked + bondLockAmount > bondPool` reverts at openMarket. Gas is lost by the agent (small cost). Future: client-side preflight check.

### V8: Signature malleability (A4)
**Vector**: Modified-but-valid EIP-712 signature accepted.
**Mitigation**: OpenZeppelin ECDSA library handles signature normalization (rejects s > secp256k1n/2).

### V9: Pre-window collection (A1)
**Vector**: Service calls `collectAfterWindow` before dispute window expires.
**Mitigation**: `block.timestamp <= disputeDeadline` reverts with `WindowNotPassed`.

### V10: TestcaseResolver vote flood (A4)
**Vector**: Attacker creates many minimal-stake validator accounts (Sybil) to bias resolution.
**Mitigation**: Stake-weighted voting means small stakes have small weight. Minimum stake 0.1 USDC filters trivial sybils. **But large stakes can still buy influence** — this is acknowledged.

### V11: Flash-vote-and-exit (A3)
**Vector**: Stake → vote → request unstake → bypass slashing once it exists.
**Mitigation**: `UNSTAKE_COOLDOWN = 7 days` makes stake unavailable during cooldown. v0.2 adds slashing during cooldown.

### V12: Validator stake withdrawal during pending votes (A3)
**Vector**: Validator votes, then requests unstake, completes 7 days later — but markets haven't resolved yet.
**Mitigation (partial)**: Cooldown is currently a flat 7 days regardless of pending votes. v0.2 should extend cooldown until all of the validator's pending votes are resolved.

### V13: First-deposit DoS (A2)
**Vector**: Agent's escrow underflow / state corruption.
**Mitigation**: Solidity 0.8.x checked arithmetic on all balance subtractions. `unchecked` blocks are confined to provably-safe locations.

### V14: MockResolver in production (A1 + ignorance)
**Vector**: Someone deploys MockResolver-using service in production.
**Mitigation**: MockResolver explicitly labeled "DO NOT USE IN PRODUCTION" in contract NatSpec. Production should use TestcaseResolver, OracleResolver (v0.2), or a custom resolver.

## Known limitations & explicit non-goals

1. **No slashing in v0.** Validators have no economic penalty for bad votes. Mitigated by minimum stake + cooldown, but not solved until v0.2.
2. **No challenge / second-round window.** Single voting window only. Validators cannot challenge the consensus once formed.
3. **Stake-weighted mean is attackable** by a single large stake. Median (with sorting) is the v0.2 fix.
4. **No upgrade proxy.** Migration via new contract + new EIP-712 domain version. Same posture as Cadence.
5. **Resolver registration is per-service-whitelist, not protocol-curated.** Services pick their own resolvers; agents must verify which resolver applies before paying.
6. **No on-chain dispute reputation.** ERC-8004 reputation events are planned for v0.3+.
7. **No privacy.** Every market's amount, score, and votes are public.
8. **Block-gas-limit sensitive.** Very large `claimBatch` (not present in Crucible v0, but the concept exists) could fail under congestion.

## Proposed audit scope (M2)

- Full review of `CrucibleMarket.sol` and `TestcaseResolver.sol`
- EIP-712 conformance across SDK and contract
- Resolver-pluggability attack surface (malicious IResolver implementations)
- Slashing math when added in v0.2
- Game-theoretic analysis of validator economics (separately, possibly with formal-methods practitioner)

Target budget: $15K-25K USDC, 1-2 weeks of focused auditor time.

## Disclosures and contact

Responsible disclosure: please open a private security advisory on the GitHub repo (`Security` tab → `Report a vulnerability`). Do not disclose publicly until coordinated.

No security incidents to date. Contract has not been mainnet-deployed.

---

**Last reviewed**: 2026-05-12
**Next review**: post-audit
