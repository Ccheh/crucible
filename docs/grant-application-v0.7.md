# Circle Developer Grant — Crucible: the Graded-Resolution Layer for Arc

**Applicant:** Zen Chen (Zhenmin Chen) — MSc Data Science (Sheffield, ranked #1
in cohort); Strategy Researcher @ Polymarket (quant / mechanism design on
USDC-settled prediction markets). GitHub [@Ccheh](https://github.com/Ccheh).
**Project:** Crucible — github.com/Ccheh/crucible
**Track:** Agentic commerce / prediction markets (2026 Arc track)
**Ask:** $25K USDC, milestone-based.

---

## 1. The problem (in Circle's own words)

Circle has shipped the rails for the agentic economy and named the markets it
wants built on Arc — and in every case **explicitly left the resolution layer to
builders**:

- The **Agentic Economy Blueprint** invites pay-per-result AI services and says
  "builders must construct… quality assurance" — but Nanopayments is pure
  pay-per-call with no recourse, and `circlefin/arc-escrow` validates only
  binary, single-LLM, testnet-only.
- **ERC-8183** (the Arc agent-job standard) ships a **binary** evaluator and
  documents the gap: "if an AI evaluator approves bad work… the client loses
  money with no recourse built into the base standard."
- The **Prediction-Market Blueprint** offers "primitives to build better
  prediction-market infrastructure" and **no oracle, resolution, or dispute
  mechanism** at all.

The incumbent that *does* resolve — UMA — is publicly failing on exactly this:
the **June 2 2026 $60M MSTR/Bitcoin** Polymarket dispute, where (WSJ, May 2026)
>50% of votes came from the top-10 wallets and ~1-in-5 disputes had a voter with
a direct financial stake in the outcome they ruled on. The flaw is structural:
UMA's settlement token *is* the betting token, and it cannot be fixed without
breaking UMA's anonymity model.

**There is no graded, conflict-resistant, Arc-native resolution layer.** That is
the gap Crucible fills.

## 2. What we built (already live on Arc Testnet)

A neutral, USDC-bonded, **graded** resolution layer — one staked commit-reveal
Schelling engine that turns any intersubjective outcome into a continuous score
`[0,10000]` and splits escrow *proportionally*, composing under Circle's own
rails rather than competing with them.

**Deployed, chain 5042002, 172 tests + fuzz passing:**
- `CrucibleMarketV7` `0x9934bAF33bcF0dfD14040f8ddd5DdF18eCfEFb59`
- `ScalarResolverV7` `0x85b332122371f3c08253844B6170e8daC0c8c2fB`
- `Erc8183ProportionalAdapter` `0x44A0a6DEFE24F8CA84a3E5390Ab3f656Db306CaB`

## 3. Why it's defensible (vs the field, honestly)

| | Crucible v0.7 | KAMIYO (closest, Solana) | UMA |
|---|---|---|---|
| payout | **continuous proportional** | 4-bucket step | binary |
| security | **USDC, no token** | mandatory $KAMIYO memecoin | reflexive UMA token |
| judge≠participant | **enforced on-chain** | coupled | coupled (the MSTR flaw) |
| substrate | **Arc + USDC + ERC-8183/8004** | Solana, no Arc | Polygon, anon-only |

The moat is founder-fit: applying Polymarket-grade mechanism design to the exact
failure mode the incumbent is bleeding on, on the one chain whose identity
primitives let it be fixed differently. (We do **not** claim "first graded
refund" — KAMIYO shipped graded-ish on Solana — nor that competitors lack rigor.
We win on continuity + no-token + Arc-native + decoupling.)

## 4. Circle / Arc integration (core to the value flow, not bolted on)

- **USDC** is the escrow, the bond, and the validator stake — settlement is
  denominated end-to-end in USDC (native gas on Arc).
- **ERC-8183**: the `Erc8183ProportionalAdapter` plugs into the standard's
  open evaluator slot, upgrading binary→proportional.
- **ERC-8004**: validator/service reputation events already emitted; identity
  linking is milestone 2.
- Composes with **Nanopayments / x402** (the conditional-release the x402
  Foundation has only roadmapped) and **StableFX/EURC** for multi-currency
  markets.

## 5. Milestones (3 months, $25K)

| # | Deliverable | Proof | $ |
|---|---|---|---|
| **M1 (done)** | v0.7 graded-resolution layer live on Arc Testnet: decoupling, criteria pre-commitment, typed disputes, ERC-8183 adapter; window-denial vuln found & fixed; 172 tests + fuzz | the 3 addresses above + repo | $5K |
| **M2** | ERC-8004 identity linking (sybil-resistant decoupling) + optional identity-gated resolver pool with on-chain disclosure — the compliance seam only Arc can serve | contracts + tests + testnet demo | $7K |
| **M3** | End-to-end reference: an ERC-8183 / x402 AI service paid proportional-to-quality on Arc, with a public browser verifier (anyone re-runs the resolution) | live demo + walkthrough video | $7K |
| **M4** | Security: external audit prep, economic stress tests of the median+slash game, formal invariants; first external integrator (LOI) | audit report + integrator | $6K |

## 6. Traction & path

- Live testnet deployment + 172 tests today (M1 complete before funding).
- Open-source (MIT), admin-keyless, no token — aligned with Arc's institutional
  posture.
- Picks-and-shovels to a Circle-funded demand wave: the dozens of Arc
  escrow/agentic teams (HackMoney, Agentic-Commerce hackathon) all hand-roll
  milestone/usage logic — a drop-in "release X% on a resolved 0–100 score" is
  composable pull. ETHGlobal Cannes even posts an unfilled bounty for
  prediction-market resolution with real-world signal.

## 7. Founder fit

Polymarket strategy/mechanism-design background = direct, non-replicable edge on
the exact problem (resolution mechanism design under adversarial, high-stakes
conditions). MSc Data Science (#1 cohort). Solo, but shipping fast: this layer
went design→implementation→on-chain in one sprint, with a real vulnerability
caught and fixed in self-audit.

---

*Disclosure: Crucible is an independent, open-source project on Arc testnet,
built in a personal capacity; not affiliated with or endorsed by Circle.*
