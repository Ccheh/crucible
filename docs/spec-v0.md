# Crucible Protocol — v0 Specification (Working Draft)

> **Author**: Zen Chen
> **Date**: 2026-05-12
> **Status**: Pre-implementation design draft. Not yet stable, not yet shipped.
> **Working title**: Crucible. (Alternates: Crucible, Truss, Aegis, Veridian.)
> **Predecessor**: Built on top of Cadence (Arc402 protocol v0.1.0) as base payment layer.

---

## 0. The 30-second pitch

Every existing AI-payment protocol — Stripe, Lightning, Coinbase x402, Circle Nanopayments, Cadence v0.1 — treats AI service calls as **deterministic transactions**: pay X, receive Y, transaction closed.

But AI services are **probabilistic**: outputs are stochastic, quality is subjective, value resolves over time. The protocols don't model this. Buyers have no recourse if the LLM returned garbage; sellers have no way to differentiate their quality.

**Crucible is the missing settlement layer**: payment is conditional on a prediction-market-resolved quality outcome, not on delivery alone.

Built right, this becomes the **infrastructure layer for verifiable AI commerce** — applicable to LLM outputs, code generation, translation, search, prediction services, data labeling, content moderation, and any market where "useful" is subjective but determinable.

The user (Zen Chen, Polymarket strategy researcher) has a unique competitive advantage: prediction-market mechanism design is his domain. This protocol is essentially "Polymarket-style consensus, applied to AI service quality."

---

## 1. The structural problem with existing protocols

| Protocol | Assumption | Why it breaks for AI |
|---|---|---|
| Stripe | Buyer knows what they want, seller delivers | AI outputs are non-deterministic, quality subjective |
| Lightning | Payment = delivery confirmation | No quality dimension at all |
| Coinbase x402 | Service responds 200 = paid | Bad outputs still return 200 |
| Circle Nanopayments | Same as x402, just on Arc | Same blind spot |
| Cadence v0.1 (our previous work) | Same as Nanopayments | Adds rep-tier + refundable design, but core still binary |
| ERC-8183 | Discrete evaluator-arbitrated job | Multi-tx, heavy, doesn't suit per-call streaming |

**Common gap**: none of them treat the *outcome* of the AI service as an economic object.

## 2. The core insight

**AI service quality is a subjective claim that markets are uniquely suited to resolve.**

Polymarket has proved that liquid markets can produce trusted, real-time consensus on contentious facts. Apply this to AI:

- Service commits to a quality claim (off-chain text + on-chain hash)
- A short-lived market opens: "will this output be validated as meeting the claim?"
- Validators stake on YES / NO
- Resolution unlocks payment proportional to outcome

This is **not** novel as a primitive (UMA, Kleros, Augur all do market-based oracles). What's novel is:

1. **Per-call granularity**: micro-markets opening per API call, settling fast
2. **AI-specific resolution paths**: pluggable resolvers for code (testcase), translation (validator vote), prediction (real-world data via oracle), inference (ZK-ML or TEE)
3. **Integrated payment layer**: market outcome directly drives token flow without an extra arbitration round
4. **Composability with existing payment layers**: works alongside Cadence / Nanopayments / x402 as a settlement *enhancement*, not a replacement

## 3. Roles

| Role | Purpose | Bond / Stake | Reward |
|---|---|---|---|
| **Agent** | Pays for AI service, optionally disputes | USDC in escrow | Refund if service fails quality |
| **Service** | Provides AI output, commits to quality claim | Quality bond (USDC) | Payment if claim verified |
| **Validator** | Stakes on YES/NO of service's claim | Validator stake (USDC) | Share of market fee + winning stake redistribution |
| **Resolver** | Pluggable verification logic (contract) | None (pure code) | None (or small gas reimbursement) |
| **Disputer** | Challenges automatic resolution within window | Dispute bond (USDC) | Wins if dispute upheld |

Anyone can be any role. No permissioning. No KYC.

## 4. Protocol flow

```
Agent                Service              Crucible Contracts            Validators
  |                     |                       |                          |
  |--(1) HTTP POST----->|                       |                          |
  |                     |                       |                          |
  |<--(2) HTTP 402------|                       |                          |
  |    + requirements   |                       |                          |
  |                     |                       |                          |
  |--(3) signed claim-->|                       |                          |
  |                     |                       |                          |
  |<-(4) output+claim---|                       |                          |
  |  + commitmentHash   |                       |                          |
  |                     |                       |                          |
  |                     |--(5) openMarket------>|                          |
  |                     |   (commitmentHash,    |                          |
  |                     |    quality criteria,  |                          |
  |                     |    resolveDeadline)   |                          |
  |                     |                       |                          |
  |                     |                       |<--(6) stake YES/NO-------|
  |                     |                       |                          |
  |--(7) optional dispute---------------------->|                          |
  |    (bond)                                   |                          |
  |                     |                       |                          |
  |                     |                       |--(8) resolver.resolve()  |
  |                     |                       |  → quality score 0-10000 |
  |                     |                       |                          |
  |                     |<--(9) payout---------|----------------------> ↓  |
  |                     |   (score-weighted)    |   (rewards / slashes)    |
  |                     |                       |                          |
  |   ↑ refund if score < threshold             |                          |
```

Each step is one or zero on-chain transactions. The Cadence base payment layer handles steps 1-3. Crucible adds 5-9.

## 5. On-chain components (contracts)

```
crucible/contracts/src/
├── CrucibleRegistry.sol           # services register, declare resolver, deposit bond
├── CommitmentVault.sol           # services post output commitment hashes
├── QualityMarket.sol             # the per-call prediction market
├── MarketFactory.sol             # opens new markets per commitment (deterministic addresses)
├── ResolutionEngine.sol          # adapter that calls a resolver contract & writes results
├── ValidatorVault.sol            # validators deposit stake + claim rewards
├── DisputeResolver.sol           # handles user-raised disputes (UMA-style optimistic)
├── ReputationWriter.sol          # writes outcomes back to ERC-8004 ReputationRegistry
└── resolvers/
    ├── IResolver.sol             # interface
    ├── TestcaseResolver.sol      # for code generation (run testcases on chain)
    ├── OracleResolver.sol        # for predictions (Chainlink, Pyth, etc.)
    ├── ValidatorVoteResolver.sol # for subjective tasks (validator network votes)
    ├── TEEResolver.sol           # for compute integrity (trusts TEE attestation)
    └── ZkMlResolver.sol          # (future) ZK proof of AI inference
```

**Key invariants:**
- No upgrade proxy. Migration via new domain version (same pattern as Cadence V1→V2).
- No admin keys. No pause function.
- Resolver contracts are pluggable but each is immutable once registered.
- Service must pre-commit to which resolver applies to its output.

## 6. Resolver types — the pluggable verification layer

This is the protocol's flexibility: different AI tasks need different verification.

### 6.1 TestcaseResolver (deterministic, fully on-chain)
- Service registers a set of testcase commitments at service-creation time
- For each output, agent provides input; resolver checks if output matches expected
- 100% on-chain, deterministic, fast
- **Use cases**: code generation, math, deterministic data transformations

### 6.2 OracleResolver (external data, on-chain)
- For predictions of real-world events
- Pulls from Chainlink / Pyth / UMA at resolveDeadline
- 100% on-chain, deterministic at resolution time
- **Use cases**: price predictions, election outcomes, sports, any oracle-resolvable fact

### 6.3 ValidatorVoteResolver (subjective, hybrid)
- Validators stake to vote YES/NO on quality
- Schelling-point game: honest validators converge on truth
- 100-1000 ms resolution time after votes collected
- **Use cases**: translation quality, content moderation, creative writing assessment, subjective code review

### 6.4 TEEResolver (trusted hardware, hybrid)
- Service runs inference in TEE (Intel SGX, AWS Nitro)
- TEE produces attestation that inference was correct + input/output were as claimed
- Verifies attestation on chain
- **Use cases**: private inference, "we ran exactly the model we said we ran" claims

### 6.5 ZkMlResolver (future, full crypto)
- Service produces ZK proof that inference matched stated model + input
- Currently expensive (proof generation > 30s for medium models); will improve
- **Use cases**: long-term — when ZK ML matures, replaces TEE for trust-minimized scenarios

**The protocol does not pick winners.** Services choose their resolver; agents see the choice and decide whether to trust it. Market dynamics select for trustworthy combinations.

## 7. Validator economics (the hard part)

For ValidatorVoteResolver, validators are the crux. Game theory must work or the whole protocol fails.

### 7.1 Stake mechanics
- Validator deposits ≥ minStake USDC into ValidatorVault
- Stake locks for cooldown period (e.g., 7 days) on any withdrawal
- Total stake determines vote weight

### 7.2 Voting
- Per market: validator votes (YES, score 0-10000) with stake-weighted weight
- Voting window: e.g., 60 seconds after market opens
- Validators can sample only some markets (not required to vote on all)

### 7.3 Resolution
- Median or weighted-mean of votes = market resolution score
- Quorum required: at least N validators or M% of total stake participating

### 7.4 Reward / slash
- **Honest** (vote within tolerance of resolution): receive share of market fee (collected from service's bond and the spread between agent's escrow and service's earned share)
- **Dishonest** (vote far from resolution): forfeit fraction of stake proportional to distance from consensus
- **Absent**: no penalty (validators don't have to vote on every market), but no fee earned

### 7.5 Bootstrap problem (real concern)

In v0, the validator network is thin. Options:
- **Subsidy**: protocol-treasury bootstrapped fee pool that pays validators above market-fee rate for first N months
- **Validator-as-service**: services with high quality bond can act as their own validators on their own markets (with disclosed conflict) — bootstraps participation
- **Anchor validators**: invite trusted parties (Circle, an audit firm, etc.) to seed the network with reputation
- **Self-resolution**: for v0, services can choose TestcaseResolver or OracleResolver if validator network too thin

The v0 MVP **does not require a thriving validator network**. It can ship with only TestcaseResolver and OracleResolver active. ValidatorVoteResolver is unlocked at v0.2 when economics make sense.

## 8. Service economics

### 8.1 Service registration
- Service deposits **quality bond** (e.g., 100 USDC or more — operator-defined)
- Bond is locked while service is registered; refundable on de-register after cooldown

### 8.2 Per-call quality bond
- For high-stake claims, service can stake **additional per-call bond** on top of base bond
- Higher per-call bond = stronger commitment = market opens with prior that quality is high

### 8.3 Slashing on bad output
- If market resolves score < some threshold (e.g., 3000 / 10000), service is slashed proportionally
- Slashed amount: split between agent (compensation) + validators (reward)

### 8.4 Reputation accrual
- Each resolved market emits a ReputationEvent to ERC-8004
- Service's reputation = function of historical scores
- Buyers see reputation before deciding to call

## 9. Agent economics (unchanged from Cadence)

Agent flow is the same as Cadence v0.1:
- Pre-deposit USDC into PaymentEscrow
- Sign EIP-712 claim per call (now includes commitmentHash field, see §10.1)
- Payment held in escrow until market resolves

After resolution:
- score = resolveScore (0-10000)
- payout = claim.amount × (score / 10000)
- refund = claim.amount - payout
- (Plus: agent gets share of service's slashed bond if score is very low)

## 10. EIP-712 message extensions

Crucible extends Cadence's Claim type:

```
CrucibleClaim(
    address agent,
    address service,
    uint256 amount,
    uint256 nonce,
    uint256 expiry,
    bytes32 commitmentHash,   // hash of service's quality commitment
    address resolver,          // which resolver applies to this market
    uint256 resolveDeadline    // when the market resolves
)
```

EIP-712 domain: `name="Crucible", version="1"`, `verifyingContract=QualityMarket`.

This is **incompatible** with Cadence's existing EIP-712 messages — by design (different protocol, different domain).

## 11. Failure modes & attack vectors

### 11.1 Sybil validator attack
- Attacker creates many validator addresses with minimum stake
- Mitigation: stake-weighted voting; large stake = large weight; many small stakes = no individual influence
- Also: cooldown periods discourage churn

### 11.2 Collusion (service + validator)
- Service bribes validator to vote YES on bad output
- Mitigation: economic — colluding validators forfeit stake when other honest validators vote NO; the cheaper the bribe, the smaller the stake at risk → smaller swing in resolution
- For small markets: protocol can require minimum N independent validators (Sybil-resistant) before resolution

### 11.3 DoS on resolver
- Attacker spams markets to drain validator attention
- Mitigation: market-opening fee paid by service; bots ignore unprofitable markets

### 11.4 Resolver bug / manipulation
- TestcaseResolver: services could pre-compute outputs that pass tests but are useless
- Mitigation: agents see test set before purchasing; can choose to not buy
- ValidatorVoteResolver: bribed validators (see 11.2)
- OracleResolver: oracle compromise — out of scope, inherited risk

### 11.5 Agent dispute spam
- Agent disputes every call to delay payment
- Mitigation: dispute bond; loser of dispute forfeits bond

### 11.6 Service exit scam
- Service collects payments, then exit-scams without delivering quality
- Mitigation: quality bond is locked > one-month cooldown; community can monitor and challenge during this window

## 12. v0 MVP scope (what to build first)

Aim: ship in **6-8 weeks**, full-time. Smaller scope is acceptable.

### Must-ship (MVP v0.1)
- CrucibleRegistry, CommitmentVault, MarketFactory, QualityMarket, ResolutionEngine, ReputationWriter
- TestcaseResolver (simplest, deterministic, no validators needed)
- OracleResolver (Chainlink/Pyth/UMA integration)
- TypeScript SDK to integrate from existing Cadence codebase
- Reference service example (a paid code-gen API using TestcaseResolver)
- 30+ tests including 2-3 invariant tests

### v0.2 (post-MVP, 4-6 weeks later)
- ValidatorVoteResolver
- ValidatorVault, DisputeResolver
- Game-theoretic stress tests
- Bootstrap validator program

### v0.3+ (future)
- TEEResolver
- ZkMlResolver
- Composability with Cadence claims (use Cadence as base payment layer + Crucible on top)
- Cross-chain settlement via CCTP

## 13. Comparison with related protocols

| Protocol | What it does | How Crucible differs |
|---|---|---|
| **UMA Optimistic Oracle** | General-purpose subjective fact resolution | Crucible is AI-quality-specialized, pluggable resolvers, integrated payment |
| **Kleros** | Decentralized arbitration | Crucible is automatic via markets, not arbitration courts (faster, cheaper) |
| **Chainlink** | Push oracle for objective data | Crucible integrates Chainlink as one resolver type; protocol is the layer on top |
| **Augur / Polymarket** | Prediction markets | Crucible per-call markets are micro / short-lived / programmatically opened |
| **Cadence (Arc402)** | Payment escrow with batched settle | Cadence is the BASE PAYMENT LAYER. Crucible is the SETTLEMENT LAYER on top. |
| **Circle Nanopayments** | x402 on Arc | Crucible is orthogonal — could settle Nanopayments-pattern claims via Crucible markets |
| **ERC-8183** | Discrete job escrow with evaluator | Similar evaluator concept, but 8183 is heavy per-job; Crucible is per-call |
| **Akash / Bittensor** | Compute marketplaces | Crucible is quality-resolution; could be the settlement layer for Akash compute |

**Crucible's unique position**: it's the FIRST protocol to combine (a) per-call AI service granularity + (b) market-resolved quality + (c) integrated payment layer + (d) pluggable resolution mechanisms.

## 14. Open design questions

Decisions still to make before code:

1. **EIP-712 vs EIP-3009 for CrucibleClaim** — interop with Circle Gateway pattern?
2. **Market resolution math** — median vs. weighted mean vs. Schelling-point?
3. **Quorum requirements** — fixed N or % of total stake?
4. **Validator cooldown period** — 7 days enough? 30 days too long?
5. **Bootstrap subsidy** — protocol treasury? Or pure organic?
6. **Resolver registration** — anyone can register a new resolver, or curated?
7. **Cross-resolver markets** — can a single market use multiple resolvers? Weighted?
8. **Privacy** — should agent identities be obscured? ZK proofs?
9. **Fee economics** — what % of payments go to validator pool vs protocol treasury vs reduced for agent?
10. **MVP go-to-market** — code-gen (clearest TestcaseResolver use case)? Or AI prediction services (clearest OracleResolver use case + Polymarket alignment)?

## 15. Why this is worth doing

### Why not just stay with Cadence v0.1?
- Cadence is "Nanopayments-compatible OSS reference + 2 small primitives". Useful but not category-defining.
- Crucible is "the missing settlement layer for probabilistic services". This is a 10x bigger swing.

### Why solo founder can ship this
- Spec design — leverages user's prediction-market expertise
- v0 MVP scope (TestcaseResolver + OracleResolver only) avoids the hardest part (validator economics)
- Reuses Cadence's payment escrow as base layer (don't reinvent)

### Why it composes with the broader stack
- Cadence remains useful as base payment SDK
- Circle Nanopayments / x402 can interop (Crucible markets settle outputs from any payment source)
- ERC-8004 reputation grows organically (every resolved market writes to it)
- LangChain / MCP agents can use Crucible-protected endpoints with no code change (Crucible-aware SDK handles dispute window transparently)

### Why now
- AI agent commerce is going to explode 2026-2028. The settlement layer is being defined now. Circle is defining the *payment* layer; Crucible can define the *quality settlement* layer.
- Polymarket-style market design is a peak-skill area; Zen has direct expertise. Defensible moat.
- Audit-prep mindset: small scope, careful design, no admin keys, no upgrade proxies.

---

## Decisions needed before next phase

To move from spec to implementation, the following must be decided:

1. **Name**: Crucible / Crucible / Truss / other?
2. **Repo strategy**: New repo `github.com/Ccheh/crucible` OR new folder in arc402 (`/crucible/`)?
3. **v0 scope confirmed**: TestcaseResolver + OracleResolver only for first ship?
4. **Initial use case to optimize for**: code generation (`TestcaseResolver`) or AI predictions (`OracleResolver`)?
5. **Timeline target**: 6 weeks MVP? 8 weeks? Open?
6. **Honest sanity check**: is the user OK with this potentially failing technically (the protocol is hard) or commercially (the market may not adopt)? This is genuine R&D, not safe execution.

---

*This spec is intentionally a first draft. Every section is debatable. Iterate before shipping.*

---

# Crucible Protocol — v0.2 Addendum

> **Date**: 2026-05-12
> **Status**: Designed and implemented (54/54 tests passing, not yet deployed).
> **Scope**: Hardens v0's validator economics. Does NOT redesign the core mechanism — the v0 conceptual layer is unchanged.

## What v0.2 adds

Three concrete additions:

1. **Validator slashing** (`TestcaseResolverV2`). Validators whose vote diverges from the stake-weighted consensus by more than `TOLERANCE_BPS = 1500` (15 percentage points) lose stake proportional to the excess distance, capped at `MAX_SLASH_BPS = 1000` (10% of their stake) per market resolution. This is the v0.2 fix to V4 (validator collusion) in the security analysis.

2. **Validator reward fee pool**. `CrucibleMarketV2` siphons `RESOLVER_FEE_BPS = 200` (2%) of the agent escrow on the disputed-resolution path and forwards it via `notifyFee(marketId)` to the resolver. The resolver pools per-market fees and distributes them pro-rata to honest validators (within tolerance) along with the redistributed-slashed stake. Validators withdraw via `claimRewards()`.

3. **Pending-vote-aware unstake**. Validators cannot `completeUnstake` until every market they voted on has resolved. This fixes the flash-vote-and-exit attack class (V11 in security analysis).

## Math

Resolution flow (3-pass in a single tx):

```
Pass 1: finalScoreBps = stake-weighted mean of votes
Pass 2: for each voter v with distance d = |vote_v - finalScoreBps|:
          if d <= TOLERANCE_BPS:    honestStake += stake_v
          else:                      slashAmt = stake_v * min((d - TOLERANCE_BPS)*MAX_SLASH_BPS / 8500, MAX_SLASH_BPS) / 10000
                                     validatorStake[v] -= slashAmt
                                     totalSlashed += slashAmt
Pass 3: rewardPool = feePool + totalSlashed
        for each honest voter v:    pendingReward[v] += rewardPool * stake_v / honestStake
```

Settlement math (CrucibleMarketV2):

```
on dispute path:
  resolverFee     = agentEscrow * RESOLVER_FEE_BPS / 10000
  if resolver accepts notifyFee:
    settleEscrow  = agentEscrow - resolverFee
  else (fallback):
    settleEscrow  = agentEscrow            # fee stays in escrow, split per score
  paidToService   = settleEscrow * scoreBps / 10000
  refundToAgent   = settleEscrow - paidToService
  bondSlash       = bondLocked * (10000 - scoreBps) / 10000
  totalToAgent    = refundToAgent + bondSlash

on optimistic path (collectAfterWindow):
  no resolver fee; service collects full escrow.
```

## Cross-version isolation

`CrucibleMarketV2` ships with EIP-712 domain `"Crucible" version "2"`. v0 signatures cannot cross-replay against v0.2, and vice versa — domain separators differ by the version field.

## What v0.2 does NOT solve (still open for v0.3+)

- **Median consensus**. v0.2 still uses stake-weighted mean; a single large validator can still drag resolution. Median voting requires sorting and is planned for v0.3.
- **Sybil dispute spam**. Disputes are still free in v0.2 (only gas). A dispute bond is the v0.3 fix.
- **Mainnet-ready**. Pre-audit. Audit + median voting are the prerequisites.
- **Validator equilibrium at low dispute rate**. Validators only earn during disputes. A healthy market with rare disputes could starve validators of rewards. Solution: future versions might add a small per-market keep-alive fee, or rely on validators having other reasons to stake (their own service reputation, cross-market voting).

## Why this design

The v0.2 changes were chosen because they:

1. Directly address the top three known limitations from `docs/security-considerations.md` (V4 collusion, V11 flash-exit, validator-economics-missing).
2. Add NO new admin surface — all parameters are contract constants. To change them, deploy v0.3.
3. Stay backward-compatible at the IResolver interface level. v0 resolvers still work with v0 markets; v0.2 resolvers also work with v0 markets (notifyFee just goes unused).
4. Fee is only charged on the disputed path — well-behaved services pay no premium. Bad services pay the cost of arbitration, as designed.

## Implementation footprint

```
contracts/src/v02/
├── IResolverFeeReceiver.sol      ~15 LOC  (optional resolver extension)
├── CrucibleMarketV2.sol          ~245 LOC (fee routing + EIP-712 v2)
└── TestcaseResolverV2.sol        ~280 LOC (slashing + rewards + pendingVotes)

contracts/test/
├── CrucibleMarketV2.t.sol         8 tests passing
└── TestcaseResolverV2.t.sol      16 tests passing
```

Combined v0 + v0.2: **54/54 tests passing**, all forge-verifiable via `forge test`.

---

# Crucible Protocol — v0.3 Addendum

> **Date**: 2026-05-12
> **Status**: Designed and implemented (76/76 tests passing across v0 + v0.2 + v0.3, not yet deployed).
> **Scope**: Two changes that close the most-cited attack vectors from the v0.2 audit (median consensus + dispute bond).

## What v0.3 adds

1. **Stake-weighted median consensus** in `TestcaseResolverV3`, replacing the stake-weighted mean of v0.2. A minority outlier voting an extreme value can no longer drag the consensus regardless of their stake (as long as their stake is below majority). Closes the V3-style "single large stake drags resolution" attack documented in `docs/security-considerations.md`.

2. **Dispute bond** in `CrucibleMarketV3`. Agents must attach a 5% bond when calling `dispute(marketId)`. Bond is split at settlement proportional to score (score=10000 → bond to service, score=0 → bond refunded to agent). Closes the V3-style "free dispute spam" attack vector.

## Median algorithm

```
At resolve(marketId):
  1. Insertion-sort (vote, stake) pairs by vote ascending. O(M²) memory ops.
  2. threshold = totalVotedStake / 2
  3. Walk sorted array; the first index where cumulative stake >= threshold
     is the median. Return its vote.
```

Median runtime: O(M²) sort + O(M) walk. For typical M ≤ 20 voters per market on Arc Testnet, sort cost is <250 ops — gas-bounded. For M > 60 a future version should switch to sorted-on-insert.

## Dispute-bond settlement math

```
On dispute(marketId):
  expected = (agentEscrow * DISPUTE_BOND_BPS) / 10000   // 5%
  require msg.value == expected
  market.disputeBond = expected
  market.status = Disputed

On resolveDisputed(marketId, ...):
  // ... compute settleEscrow, paidToService, refundEscrow, bondSlash as in v0.2
  bondToService = disputeBond * scoreBps / 10000
  bondRefund    = disputeBond - bondToService
  totalToService = paidToService + bondToService
  totalToAgent   = refundEscrow + bondSlash + bondRefund
```

Outcomes:
- scoreBps = 0 (service totally wrong): agent gets all of (escrow refund, full bond slash, full bond refund). Zero cost for justified dispute.
- scoreBps = 10000 (service totally right): service gets all of (full escrow, dispute bond). Agent loses 5% of escrow for frivolous dispute.
- scoreBps = 5000 (middle): bond splits evenly; agent partially compensated.

## Cross-version isolation

`CrucibleMarketV3` ships with EIP-712 domain `"Crucible" version "3"`. v0 / v0.2 / v0.3 signatures cannot cross-replay between contracts (each pair has distinct domain separators).

## What v0.3 still does NOT solve (open for v0.4+)

- **MIN_STAKE = 0.1 USDC** unchanged for testnet ease. Mainnet config will raise it.
- **Validator equilibrium at low dispute rate** — validators still only earn during disputes. Open question for the economic model.
- **Per-market dispute bond configuration** — v0.3 bond is a contract constant. Future versions may let services specify their own bond rate via OpenAuth (which would bump the EIP-712 typehash).
- **No on-chain dispute reputation** — ERC-8004 events still v0.4+.
- **No commit-reveal for votes** — validators can see each others' votes. Front-running risk is low because voting window is short and votes are weighted by stake, but still a future hardening.

## Implementation footprint

```
contracts/src/v03/
├── CrucibleMarketV3.sol           ~285 LOC (adds dispute bond + bond split math)
└── TestcaseResolverV3.sol         ~265 LOC (replaces mean with insertion-sort + median)

contracts/test/
├── CrucibleMarketV3.t.sol          11 tests passing
└── TestcaseResolverV3.t.sol        11 tests passing
```

The IResolverFeeReceiver interface (defined in `v02/`) is reused unchanged — v0.3 resolver implements the same interface so any future market version that accepts `IResolverFeeReceiver` can plug in v0.3 resolvers and vice versa.

Combined v0 + v0.2 + v0.3: **76/76 tests passing**, all forge-verifiable via `forge test`.

---

# Crucible Protocol — v0.4 Addendum

> **Date**: 2026-05-12
> **Status**: Designed and implemented (99/99 tests passing across all versions, not yet deployed).
> **Scope**: Three changes that close the three remaining "open" items from the v0.3 audit. Implements the missing validator equilibrium, the stake-cap protection, and the ERC-8004-compatible event surface.

## What v0.4 adds

### 1. Always-on validator subscription (MasterChef-style accumulator)

Every settlement (optimistic AND disputed) sends `VALIDATOR_SUBSCRIPTION_BPS = 10` (0.10% of agent escrow) to the resolver via the new `IResolverSubscriptionReceiver.notifyValidatorSubscription()` interface. The resolver pools these subscriptions globally with the standard accumulator pattern:

```
accSubscriptionPerStake += (subscription * 1e18) / totalStake
validatorEarning[v] = (stake[v] * accSubscriptionPerStake / 1e18) - subscriptionDebt[v]
```

When a validator stakes/unstakes, `_settleValidator` snapshots their earned amount into `pendingSubscriptionReward[v]` and resets their debt. They claim with `claimSubscription()`.

This means validators now earn a baseline yield from normal protocol operation, not just from rare disputes. **This is the v0.4 fix for the v0.3 economic equilibrium concern.**

### 2. Stake voting weight cap (`MAX_VOTING_WEIGHT_BPS = 4000`)

At resolve time, each validator's effective stake for the median computation is `min(realStake, totalVoterStake * 40% / 100%)`. No single voter can swing the median by more than 40% of total voter weight.

The protection range:
- < 40% stake: cap is a no-op; mechanism behaves identically to v0.3
- 40–70% stake: cap kicks in and lets the rest of the voters outweigh the dominant one
- > 70% stake: even capping to 40% leaves the dominant one as a plurality (insufficient by itself, but combined with sympathetic minority votes still potentially controlling)

The cap **does** affect slashing — the cap is only applied to weight in the median computation. The slash penalty is computed against REAL stake (so a capped large validator who deviates from consensus still loses real money proportional to their full stake).

### 3. ERC-8004-compatible reputation events

Two new events with stable schemas designed for off-chain ERC-8004 reputation indexers:

```solidity
// Per-validator after each resolved market
event ValidatorReputation(
    address indexed validator,
    bytes32 indexed marketId,
    uint16 vote,
    uint256 deviation,
    uint256 slashedAmount,
    bool honest
);

// Per-service after each settlement
event ServiceReputation(
    address indexed service,
    bytes32 indexed marketId,
    uint16 finalScoreBps,
    uint256 bondSlashed
);
```

This aligns with Circle's Agent Stack (Agent Marketplace + ERC-8004) which expects reputation data to be queryable from on-chain events.

## Settlement math

### Optimistic path (collectAfterWindow)

```
subscription   = agentEscrow * VALIDATOR_SUBSCRIPTION_BPS / 10000
settleEscrow   = agentEscrow - subscription (if resolver accepts)
paidToService  = settleEscrow
```

### Disputed path (resolveDisputed)

```
subscription   = agentEscrow * VALIDATOR_SUBSCRIPTION_BPS / 10000
resolverFee    = agentEscrow * RESOLVER_FEE_BPS / 10000
settleEscrow   = agentEscrow - subscription (if accepted) - resolverFee (if accepted)
paidToService  = settleEscrow * scoreBps / 10000
refundEscrow   = settleEscrow - paidToService
bondSlash      = bondLocked  * (10000 - scoreBps) / 10000
bondToService  = disputeBond * scoreBps / 10000
bondRefund     = disputeBond - bondToService
```

A $0.01 escrow now incurs:
- 0.10% subscription always
- 2.00% resolver fee on dispute
- 5.00% dispute bond from agent on dispute

For a healthy market with rare disputes (say 1% dispute rate), the effective cost to a service is dominated by the always-on 0.10% subscription. For the validator economics: a network with 10k calls/day at $0.01 each generates $10/day of subscription, split pro-rata by stake.

## Voting weight cap example (the key test)

| Stake | v0.3 weight | v0.4 weight | Vote |
|---|---|---|---|
| v1: 55% | 55% | 40% (capped) | 0 |
| v2: 30% | 30% | 30% | 10000 |
| v3: 15% | 15% | 15% | 10000 |

- Under v0.3: median pivot at cumulative ≥ 50% → first entry (v1's 55% > 50%) → **median = 0**. v1 dominates.
- Under v0.4: total capped weight = 85; threshold = 42.5; cumulative [40 (v1), 70 (v2+v1), 85 (all)]. First ≥ 42.5 is at v2 → **median = 10000**. Honest majority recovers.

## What v0.4 does NOT solve (open for v0.5+)

- **MIN_STAKE = 0.1 USDC** unchanged for testnet ease. Mainnet config should raise to 1+ USDC.
- **Per-market dispute bond configuration** — still a contract constant. Adding to OpenAuth would change the EIP-712 typehash (heavy SDK churn).
- **Commit-reveal voting** — still vulnerable to validators front-running each others' votes. Low risk on a 1-hour voting window with stake-weighted aggregation, but real for high-value markets.
- **>70% stake attacker** — the 40% cap helps in the 40–70% range but cannot recover correctness when one party holds supermajority. There is no on-chain mechanism that can; this would require a stake distribution policy at validator-network level.

## Implementation footprint

```
contracts/src/v04/
├── IResolverSubscriptionReceiver.sol   ~15 LOC
├── CrucibleMarketV4.sol                ~310 LOC
└── TestcaseResolverV4.sol              ~330 LOC

contracts/test/
├── CrucibleMarketV4.t.sol               9 tests passing
└── TestcaseResolverV4.t.sol            14 tests passing
```

Combined v0 + v0.2 + v0.3 + v0.4: **99/99 tests passing**.

---

# Crucible Protocol — v0.5 Addendum

> **Date**: 2026-05-12
> **Status**: Designed and implemented (131/131 tests passing across all versions, not yet deployed).
> **Scope**: Three changes that close the three remaining "open for v0.5+" items from the v0.4 audit. The protocol is now substantially feature-complete for the test/audit cycle.

## What v0.5 adds

### 1. Commit-reveal voting

The single biggest anti-collusion upgrade. Replaces v0.4's `vote(marketId, score)` with two-phase:

```
Commit phase  (first 30 min):
  voteHash = keccak256(abi.encode(score, salt, marketId, voter))
  commitVote(marketId, voteHash)

Reveal phase  (next 30 min):
  revealVote(marketId, score, salt)
  → verifies hash matches → records vote
```

The hash leaks no information about `score` (256-bit salt prevents brute force). Validators must commit their own honest estimate; the commit phase ends before anyone learns what anyone else voted. Eliminates the v0.4 risk of validators copying each others' votes at the last second.

A validator who commits but doesn't reveal is **not** counted in resolution AND is **not** locked by pendingVotes — clean opt-out semantics.

### 2. Configurable MIN_STAKE

```solidity
constructor(uint256 _minStake) {
    require(_minStake > 0, "minStake must be > 0");
    MIN_STAKE = _minStake;
}
```

Mainnet deployments can pick 1+ USDC for real sybil deterrence. Testnet keeps 0.1 USDC for easy bootstrap. `immutable` so the contract doesn't grow an admin surface.

### 3. Per-market dispute bond

```solidity
struct OpenAuth {
    ...
    uint16 disputeBondBps;   // NEW in v0.5
    ...
}
```

Services pick their own dispute friction at OpenAuth sign time. Bounds: `[100 bps (1%), 5000 bps (50%)]`. A free testnet API can use 100 bps; a high-value LLM gateway can use 2000 bps. Agents who don't like the chosen friction simply don't open the market — service-side decision.

EIP-712 typehash changes (struct shape changed), so domain version bumps to `"5"` — sigs cannot cross-replay against v0.4 or earlier.

## Settlement math (unchanged from v0.4, parametrized by per-market bondBps)

```
disputeBond    = agentEscrow * market.disputeBondBps / 10000  (v0.5: per-market)
subscription   = agentEscrow * VALIDATOR_SUBSCRIPTION_BPS / 10000  (10 bps every settle)
resolverFee    = agentEscrow * RESOLVER_FEE_BPS / 10000             (200 bps on dispute)
settleEscrow   = agentEscrow - subscription (if accepted) - resolverFee (if dispute and accepted)
paidToService  = settleEscrow * scoreBps / 10000
refundEscrow   = settleEscrow - paidToService
bondSlash      = bondLocked  * (10000 - scoreBps) / 10000
bondToService  = disputeBond * scoreBps / 10000
bondRefund     = disputeBond - bondToService
```

## Implementation footprint

```
contracts/src/v05/
├── CrucibleMarketV5.sol           ~290 LOC (per-market bondBps + EIP-712 v5)
└── TestcaseResolverV5.sol         ~370 LOC (commit-reveal + config MIN_STAKE)

contracts/test/
├── CrucibleMarketV5.t.sol          11 tests passing
└── TestcaseResolverV5.t.sol        21 tests passing
```

Combined v0 + v0.2 + v0.3 + v0.4 + v0.5: **131/131 tests passing**.

## What v0.5 still doesn't solve

The leftover list has shrunk considerably:

1. **Stuck disputed markets** — if everyone commits but no one reveals, the market is stuck in Disputed status with no resolution path. v0.6 needs a force-resolve-default function that the agent or service can call after a grace period. Trivial to add.
2. **>70% stake attacker** — still mechanically impossible on a single market. Validator network stake distribution is the policy-level fix.
3. **Validator yield smoothing** — subscription distribution is event-driven (per fee deposit). Smoother yield would need block-time accrual; not on the critical path.
4. **Cross-resolver reputation aggregation** — `ValidatorReputation` events are per-resolver; an off-chain ERC-8004 indexer can aggregate. On-chain aggregation across resolvers is v0.7+.

None of these block testnet deployment or audit-prep. v0.6 = stuck-market fallback (10-line fix). v0.7 = bigger work.

