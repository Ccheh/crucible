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
