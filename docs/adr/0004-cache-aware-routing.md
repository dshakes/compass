# ADR 0004 — Cache-aware cost-min as a router stage

- **Status:** **Accepted** (shipped in the `router/` module; OFF unless a warm tier is supplied)
- **Date:** 2026-06-02
- **Deciders:** repo owner
- **Refines:** the `router/` module (`router.json` + `route.sh`); does not move any trust boundary

## Context
The `router/` module is a deterministic, client-side cost-tier router (`router.json` spec +
`route.sh` reference impl), benchmarked by `bench.sh` on **cost-at-iso-quality**. It was
**cache-blind**: it priced each tier by per-token `cost` but ignored Anthropic **prompt
caching**, even though compass deliberately keeps long, stable, byte-identical prefixes (role
files + manual) that cache across steps. The owner asked the router to *exceed* commercial
client-side routers (Not Diamond) by folding cache economics into the decision — while keeping
the module's spine: deterministic, offline, spec-driven, eval-gated.

The state of the art frames the design: **Not Diamond** (client-side recommender, keep it
client-side), **RouteLLM** (cost-min under a quality floor), **prefix/KV-cache-aware routing**
(vLLM Router, SGLang, llm-d, Ray Serve — route same-prefix work to the *warm* worker), and the
**Anthropic cache params** (read 0.1×, write 1.25×@5m / 2×@1h; default TTL dropped to 5m in 2026).

## Decision
Add **stage 4.5 — cache-aware cost-min** to the pipeline
(`decide → confidence → length → bias → **cache** → escalation → clamps → domain`):

- **Off by default.** Runs only when `COMPASS_ROUTE_WARM` names already-warm tier(s).
- **Upgrade-only.** Among tiers in `[pick .. maxrank]` it picks the lowest expected cost
  `(warm? read_mult : write_mult)·tier.cost·P + tier.cost·D + tier.cost·out_weight·O`, reusing
  each tier's relative `cost`. It can only move the pick **up** to a warm, cheaper-in-expectation
  tier — **never below the pick**, so quality cannot drop. The **clamps** stage still bounds it
  (a cache upgrade can't exceed the ceiling).
- **Tunable via the spec.** A `cache` block in `router.json` (read/write multipliers, default
  P/D/O, out_weight); per-run overrides `COMPASS_PREFIX_TOKENS / TASK_TOKENS / OUTPUT_TOKENS /
  ROUTE_TTL`. `--ttl` recommends the cache-write TTL (5m vs 1h) from `COMPASS_ROUTE_REUSES /
  GAP_MIN` (1h only amortizes for ≥2 reuses across a >5m gap).
- **Gated.** `test.sh` adds cases pinning every behavior (warm upgrade, big-task no-upgrade,
  upgrade-only-never-downgrade, ceiling still caps, TTL recommendations). `bench.sh` is
  unaffected (no warm set in the evalset), so cost-at-iso-quality stays a clean regression gate.

### Companion cost dials (shipped in the same change, each OFF unless its signal is set)
- **Budget governor** (`budget` block + `COMPASS_ROUTE_BUDGET_USD`): near a spend cap, cheap-bias
  weak picks at `warn_pct` and apply `cap_ceiling` as a hard cost cap at `cap_pct` — a deliberate
  operator dial commercial routers don't expose. Spent is read from the env or today's `spend.tsv`.
- **Latency ceiling** (`--max-latency` + per-tier `latency`): caps the pick to the most-capable
  tier within a speed budget — a second objective, still deterministic.
- **Measurement**: `bench.sh --cache` reports effective $ saved vs cold (cache read/write modeled),
  gated on 100% decision-accuracy + savings > 0; `COMPASS_ROUTE_CACHELOG` + `bench.sh --calibrate`
  surface the realized cache-affinity rate.
- **Domain quality floors** (`domain_floors`): a detected domain (infra/api) raises the effective
  floor — folded into clamps so it holds against the cost dials but never lowers a higher pick.
- **Spec hardening** (`validate.sh`): schema validation (every tier reference resolves; patterns
  compile) + a **ReDoS lint** on rule patterns, gated in CI and `compass doctor`. The spec is a
  copied-around asset, so it's validated, not trusted.

All stages preserve parity when no signal is set, so the existing accuracy / cost-at-iso-quality
gates are untouched.

## How this exceeds Not Diamond / industry routers
- **Deterministic + reproducible + offline** — no recommender API, no latency, no data egress.
- **Cache-economics native** — folds read/write/TTL + a warm-set into the choice (the
  prefix/KV-cache-aware pattern), which Not Diamond's public product does not expose.
- **Doubly eval-gated, readable** — accuracy + cost-at-iso-quality (`bench.sh`) and the cache
  stage (`test.sh`); the decision boundary is a spec + corpus you can read, not a black box.
- **Secured** — every numeric signal is integer-validated before arithmetic/awk; the task text
  never enters awk or arithmetic; no `eval` on user data. The only `eval` is the existing,
  trusted `--fallback` config command (unchanged).

## Reachable levers (honest)
| Lever | via `claude -p` (SDLC loop) | via direct API (`claude-api`) |
|---|---|---|
| Cache-affinity / warm-tier selection | ✅ shipped (this stage; pass `COMPASS_ROUTE_WARM`) | ✅ |
| Byte-identical stable prefix | ✅ already | ✅ |
| TTL 5m↔1h | ❌ Claude Code manages a 5m cache itself → `--ttl` is a *recommendation* | ✅ `cache_control.ttl` |

## Consequences
- **Positive:** measured savings in the "small task on a warm prefix" regime; the reviewer can
  ride the warm Builder tier instead of cold-loading a cheaper one; spec-driven, so any host
  language implementing `router.json` inherits the same stage.
- **Bounded / honest:** cross-tier gains are second-order (the tier price gap dominates); the
  win is confined to small-`D`/large-`P` cases and long loops. TTL is a recommendation on the
  `claude -p` path. No learned router yet — that stays gated behind accumulated data + a future ADR.
- **Non-goals:** no semantic *response* cache for code (correctness risk); no hosted gateway/proxy.
