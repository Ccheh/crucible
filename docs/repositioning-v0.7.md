# Crucible v0.7 — The Graded-Resolution Layer for Arc

> **Repositioning, May→June 2026.** Crucible began as "prediction-market-settled
> AI service quality." v0.7 generalizes it into what Circle's own Arc Blueprints
> ask builders to construct but Circle does not build: a neutral, USDC-bonded,
> **graded** resolution layer that turns any intersubjective outcome into a
> continuous score and splits escrow *proportionally* — the layer that sits
> above the now-commoditized payment rails (Nanopayments / x402) and fills the
> Evaluator hole ERC-8183 explicitly leaves open.

---

## TL;DR

- **One engine, three faces:** AI-service quality, prediction-market outcomes,
  and (roadmap) futarchy governance — all resolve through the same staked,
  commit-reveal Schelling resolver returning a score in `[0, 10000]`.
- **Live on Arc Testnet (chain 5042002):**
  - `CrucibleMarketV7` — `0x9934bAF33bcF0dfD14040f8ddd5DdF18eCfEFb59`
  - `ScalarResolverV7` — `0x85b332122371f3c08253844B6170e8daC0c8c2fB`
  - `Erc8183ProportionalAdapter` — `0x44A0a6DEFE24F8CA84a3E5390Ab3f656Db306CaB`
  - `ScalarResolverV8` (ERC-8004 identity) / `ScalarResolverV9` (calibration-weighted)
  - 185 forge tests + fuzz invariants passing.
- **Four differentiators**, each verified in code, against the closest
  competitor (KAMIYO, Solana) and the incumbent (UMA): **continuous (not
  bucketed)** payout · **no token (USDC-bonded)** · **staker-participant
  decoupling** · **Arc-native + ERC-8183 / identity-optional**.

---

## Why this layer, and why now

Circle ships the rails — Nanopayments (x402 + Gateway), Agent Wallets, Paymaster,
CCTP, StableFX, ERC-8004 identity, ERC-8183 job escrow. Every one of them stops
at the same boundary: **outcomes**.

- Nanopayments is pure pay-per-call: no conditional release, no recourse.
- ERC-8183's evaluator is **binary** (accept/reject) and the standard text says
  "evaluation logic and reputation systems can all be layered around that
  common flow" — i.e. it leaves the verdict layer to builders.
- Circle's own `circlefin/arc-escrow` sample validates with a single off-chain
  LLM, binary, testnet-only.
- The Arc prediction-market Blueprint provides "primitives to build better
  prediction-market infrastructure" and explicitly **no oracle / resolution /
  dispute mechanism**.

Meanwhile the incumbent resolution layer is publicly failing: the June 2 2026
$60M MSTR/Bitcoin Polymarket market, resolved under disputed UMA token-voting
(WSJ, May 2026: >50% of votes from top-10 wallets; ~1-in-5 disputes had a voter
financially exposed to the contract they ruled on). The flaw is **structural**:
in UMA the settlement/governance token *is* the betting token. It cannot be
patched without breaking UMA's anonymity model.

Crucible v0.7 is the resolution layer Circle punts and UMA cannot fix — built
Arc-native, where identity/compliance hooks make the fix expressible.

---

## Architecture (ride the rails, don't rebuild them)

```
   ERC-8183 job escrow  ─┐                       x402 / Nanopayments call ─┐
   (binary accept/reject)│                       (pay-per-call, no recourse)│
                         ▼                                                  ▼
            Erc8183ProportionalAdapter  ◄────────  CrucibleMarketV7  ◄──────┘
            (binary → proportional split)          (escrow + typed dispute +
                         │                           pre-committed criteria)
                         └──────────► reads score ◄──────────┘
                                        │
                                ScalarResolverV7
                        (staked, commit-reveal Schelling,
                         staker-participant DECOUPLED,
                         continuous score 0..10000)
```

- **CrucibleMarketV7** — holds USDC escrow; a service signs an EIP-712 `OpenAuth`
  carrying both a `commitmentHash` (the deliverable) and, new in v0.7, a
  **separate `criteriaHash`** (the rubric). On dispute the agent declares a
  typed `DisputeKind` (Objective | Intersubjective) and the market fires
  `onDispute` on the resolver.
- **ScalarResolverV7** — generalized resolver: validators stake USDC, vote via
  commit-reveal, and the contract takes a **stake-weighted median** (40% weight
  cap), slashing by distance-from-median. Returns a **continuous** score.
- **Erc8183ProportionalAdapter** — standard-agnostic bridge: escrow in, read the
  resolved score, split `amount × score / 10000` to the worker and the remainder
  to the client. Score 10000 == ERC-8183 `complete`; 0 == `reject`; everything
  between is the upgrade ERC-8183 cannot express.

All three are **admin-keyless** (no owner, immutable wiring).

---

## The four differentiators (verified in code)

| Axis | Crucible v0.7 | KAMIYO (Solana, closest) | UMA (incumbent) |
|---|---|---|---|
| **Payout granularity** | **continuous** `[0,10000]` → linear proportional (`testFuzz_previewSplit_conserves`, 256 runs) | **4-bucket step** (`calculate_refund`: <50→100%, 50-64→75%, 65-79→35%, 80-100→0% — scores 50 & 64 pay identically) | binary (true/false) |
| **Security asset** | **USDC bond, no token** | mandatory `$KAMIYO` pump.fun memecoin (50/escrow fee + 100k stake) | UMA token (settlement token == betting token) |
| **Judge ≠ participant** | **enforced**: market's service+agent barred from voting (`onDispute` + commit/reveal gate; `test_decoupling_blocksSelfVoteSkew`) | **coupled**: one StakePosition both earns yield and gates voting | **coupled by design** (the MSTR failure mode) |
| **Substrate** | **Arc-native**, USDC-settled, ERC-8183 + ERC-8004 ready, identity-gating optional | Solana-first (SOL settlement), no Arc, no ERC-8183 | Polygon/ETH, anon-only (can't add identity) |

> Honest framing for any pitch: **do not** claim "first graded refund" (KAMIYO
> shipped graded-ish on Solana first) or "they're just simple oracle voting"
> (KAMIYO has commit-reveal + median + ZK + Kani proofs). Lead with: continuous
> vs their step function, no-token, and Arc-native + ERC-8183 + decoupling.

---

## Mechanism-design core

1. **Staker-participant decoupling.** The unfakeable property UMA lacks. A
   market's own parties can never resolve it. Enforced at the protocol level via
   a keyless conflict registry the bound market populates on dispute.

2. **Pre-committed, machine-checkable criteria.** `criteriaHash` is signed at
   open time and is *separate* from the deliverable commitment. Resolution is
   judged against fixed, pre-registered rules — directly attacking the
   "ambiguous / retroactively re-interpreted criteria" that decided the MSTR
   dispute.

3. **Typed dispute taxonomy.** The disputer must declare the lens
   (Objective | Intersubjective) on-chain; the classification is fixed and
   emitted, not negotiated after the fact.

---

## Security: a real vulnerability found and fixed (iteration 4)

During self-audit we found a **window-denial bypass** of decoupling: because
`marketId = keccak256(service, agent, nonce)` is known in advance and the
resolver's commit window originally bootstrapped on the first commit, a
participant could pre-commit to its own market to exhaust the 30-minute commit
clock *before* the dispute (and its conflict registration) landed — leaving
honest validators unable to commit, the market stale, and `forceResolveStale`
settling at score 10000 in the participant's own favor.

**Fix:** voting windows are now opened by the bound market inside `dispute()`
(`onDispute`, atomic with conflict registration); any commit before that reverts
`VotingNotOpen`. Proven by `test_cannotCommitBeforeVotingOpened` and
`test_allConflicted_noVotes_cannotResolve`.

---

## Live deployment (Arc Testnet, chain 5042002)

| Contract | Address | Deploy tx |
|---|---|---|
| CrucibleMarketV7 | `0x9934bAF33bcF0dfD14040f8ddd5DdF18eCfEFb59` | `0x6ba571a3e940cc4465a7e5ff73e32f45c19781724fb1f2bf5f7c733609ead983` |
| ScalarResolverV7 | `0x85b332122371f3c08253844B6170e8daC0c8c2fB` | `0xd8113bc89004e0316288251c1dd72452b816abbc0efcc7ba27071221811c7720` |
| Erc8183ProportionalAdapter | `0x44A0a6DEFE24F8CA84a3E5390Ab3f656Db306CaB` | `0xc92706c44645ab275d1b160f4a26603fc078459370e2d59f7f9961f895116cec` |

Tests: **185 passing** (142 v0–v0.6 baseline + 30 v0.7 + 7 V8 identity + 6 V9
calibration, incl. fuzz invariants). EIP-712 domain `"Crucible" / "7"`.

---

## Honest limitations & roadmap

- **Sybil**: decoupling bars the *literal* service/agent addresses; a determined
  participant could vote from a fresh wallet. **M2 (done)** adds ERC-8004
  identity-level decoupling — `ScalarResolverV8`
  (`0xDf518581DA89f214F2260b343f9569DD5C8BC5A4`, Arc Testnet) bars
  every address a participant's *identity* controls (`linkIdentity` +
  identity-keyed conflict). Registry is dormant (`address(0)`) until a canonical
  ERC-8004 IdentityRegistry is live on Arc; identity behavior is proven by the
  V8 test suite.
- **Fresh-wallet sybil weight — now mitigated without waiting on the ecosystem.**
  `ScalarResolverV9` (`0xae78729a7656c36215D1676c2Bd2E273aF3343fc`, Arc Testnet)
  adds **calibration-weighted consensus**: `voteWeight = stake × calibration`,
  where calibration ∈ `[0.25×, 1.50×]` is an accuracy track record the contract
  generates itself (rises when you vote with consensus, falls on outliers). A
  fresh wallet starts at 0.50× — worth half a proven validator's stake — and a
  proven-inaccurate one decays to 0.25×. This is the durable fix that, unlike
  ERC-8004 reputation-weighting (≈zero adoption on Arc today), works **now**
  because the reputation is self-generated on-chain.
  **Honest scope:** calibration is a *bounded tilt* (0.25×…1.50×), not a whale
  defense — a supermajority whale is still bounded by the 40% vote cap +
  validator-set distribution, not by calibration. Proven by a control/treatment
  test pair: equal stake and identical votes resolve to `2000` with fresh
  validators, but flip to `8000` once the high camp has *earned* its
  calibration (`test_headline_calibrationFlipsBetweenEqualStakeCamps`).
  **And its flip side — calibration is farmable at bootstrap (disclosed +
  demonstrated):** a cartel can manufacture a consensus track record by voting
  with itself on throwaway markets; `test_limitation_farmedCartelBeatsFreshHonest`
  shows a farmed 2-cartel overriding four fresh-honest validators with half the
  stake. Bounded because (1) farming costs real USDC per market, (2) the edge
  vanishes once honest validators also accrue calibration (bootstrap-only), and
  (3) value-weighted calibration gain (scale the step by resolved escrow) is the
  durable fix — future work. We ship the limitation visibly rather than hide it;
  the headline and its flip side are the *same* mechanism.
- **Compliance-gated resolver pool** (identity-gated proposers/disputers with
  on-chain disclosure) — the seam only Arc can serve — is designed, not yet
  built.
- **Futarchy face (Helm)** reuses the same resolver and is the second vertical.
- No mainnet until audit; Arc mainnet itself is targeted summer 2026.
