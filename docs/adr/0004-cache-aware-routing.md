# ADR 0004 — Cache-aware model routing: a two-stage, eval-gated, client-side router

- **Status:** **Accepted** (shipped; default behaviour unchanged, cache stage activates only with signals)
- **Date:** 2026-06-01
- **Deciders:** repo owner
- **Supersedes nothing; refines the routing in [`docs/02`](../02-cost-and-models.md) and the `route` skill**

## Context
compass's router (`scripts/compass-route.sh`) was a deterministic keyword *difficulty* classifier:
task → `haiku|sonnet|opus`. It was **cache-blind** — it never accounted for Anthropic **prompt
caching**, even though compass is deliberately structured to maximize cache hits (stable role-file
prefixes, byte-identical converge prompts; see `docs/02`). The owner asked for a router that
*exceeds* commercial client-side routers (Not Diamond) by folding cache economics into the decision,
while staying deterministic, secure, and **evaluated** — the properties a hosted black box can't offer.

The state of the art informs the design:
- **Not Diamond** — a *client-side recommender* (data/keys never leave you), optionally trained on
  your eval set. → keep it client-side; make our eval set the calibration signal.
- **RouteLLM** — a strong/weak router with a tunable **cost-quality threshold**, eval-driven. → route
  as *cost-min subject to a quality floor*, not a fixed table.
- **Prefix / KV-cache-aware routing** (vLLM Router, SGLang, llm-d, Ray Serve) — route same-prefix work
  to the **warm** worker; "check cache before routing." → translate to "don't tier-hop off a warm prefix."
- **Anthropic cache params** — cache **read = 0.1×**, **write = 1.25× (5m) / 2× (1h)** input; the
  default TTL dropped to 5m in March 2026. → warm-state and TTL are first-class cost variables.

This changes how spend decisions are made, so it gets its own ADR.

## Decision
A **two-stage, client-side, deterministic** router:

1. **Stage 1 — quality floor (capability).** The keyword classifier (`route_one`) sets the *minimum
   safe* tier. An **opus-class** task (security, architecture, auth/crypto, concurrency, multi-tenancy,
   migration, protocol/threat) is a **HARD floor: returned as-is, never entering Stage 2.** This is the
   security/quality guarantee — cache savings can never downgrade high-stakes work.
2. **Stage 2 — cache-aware cost-min (`route_decide`).** Among tiers **at or above the floor**, pick the
   lowest *expected* cost using the model:
   `cost(tier) = (warm ? 0.1 : write_mult)·price·P + price·D + price·OUTF·O`
   with `price` Haiku≈1 / Sonnet≈3.6 / Opus≈18 (input-relative), `write_mult` 1.25 (5m) or 2 (1h),
   `P` = stable cached prefix, `D` = task delta, `O` = output. The only way the choice moves **up** is
   when an already-**warm** pricier tier is cheaper in expectation than cold-loading the floor — e.g.
   **warm Sonnet beats cold Haiku when `D < ~⅓·P`** (small task on a hot prefix). With no cache signals,
   Stage 2 returns the floor, so **default behaviour and the accuracy eval are unchanged.**

The single explicit cost-quality knob (`COMPASS_ROUTE_BUDGET_BIAS=low`, RouteLLM-style) may drop a
*weak sonnet default* one tier to haiku — never opus, never a keyword-matched floor.

## How this exceeds Not Diamond / industry routers
- **Deterministic + reproducible** — no API call, no <50ms recommender latency, no data leaving the
  client; identical input → identical decision, forever.
- **Evaluated in CI, two ways** — `route --eval` gates the **quality floor** (≥90% accuracy) and
  `route --eval-cost` gates the **cache-aware cost decisions** (100% vs a hand-verified labeled set).
  A hosted router can't show you its decision boundary; ours is a corpus you can read and extend.
- **Cache-economics native** — folds Anthropic read/write/TTL params and a session **warm-set** into
  the decision (the prefix/KV-cache-aware pattern), which Not Diamond's public product does not expose.
- **Secured** — every numeric signal (`COMPASS_PREFIX_TOKENS` / `TASK_TOKENS` / `OUTPUT_TOKENS`) is
  integer-validated before arithmetic; the task text never enters `awk`/arithmetic (no injection, no
  `eval`); only fixed patterns and validated numbers do.
- **Zero dependency, offline** — pure bash + awk; runs where there's no network.

## Reachable levers (honest)
| Lever | via `claude -p` (SDLC loop) | via direct API (`claude-api` skill) |
|---|---|---|
| Cache-affinity / no tier-hop (model choice) | ✅ shipped (`orchestrate.sh` exports `COMPASS_ROUTE_WARM` + `COMPASS_TASK_TOKENS`) | ✅ |
| Byte-identical stable prefix | ✅ already | ✅ |
| TTL 5m↔1h selection | ❌ Claude Code manages caching internally (5m default) | ✅ `cache_control.ttl` |

So the **model-selection / affinity** levers ship now; **TTL** is exposed on the direct-API path and
documented as the lever to pull in the cloud loop once `claude-code-action` surfaces it. No fake knobs.

## Consequences
- **Positive:** measured cache savings in the "small task on a warm prefix" regime; review can ride the
  warm Builder tier (`SDLC_AUTOROUTE`) instead of cold haiku; every claim is CI-gated; spine unchanged.
- **Negative / bounded:** cross-tier gains are second-order — the tier price gap dominates, so wins are
  confined to small-`D`/large-`P` cases and long loops. We say so rather than overclaim.
- **Non-goals:** no semantic *response* cache for code (correctness risk); no hosted gateway/proxy; no
  learned router yet (Phase 3, needs accumulated `spend.tsv` — the deterministic floor stays the guardrail).

## Status of the plan
P0 (cost model + `--eval-cost` + bench) and P1–P2 (cache-affinity + cost-min default + orchestrate
wiring) are **shipped**. P3 (learned calibration from `spend.tsv`) remains deliberately gated behind
accumulated data + a future ADR.
