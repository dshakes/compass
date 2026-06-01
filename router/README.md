# router — a deterministic cost-tier router

A tiny, dependency-free, **language-agnostic** model router: given a task description it
picks the cheapest tier that can do the job well (`haiku` / `sonnet` / `opus`). No network,
no model call, no training — a pure function of the task string and a rules spec.

It's deliberately *not* a cross-vendor quality-maximizer (OpenRouter / Not Diamond do that
with trained meta-models + an API round-trip). It's a **spend dial** you embed in your own
agent loop: microsecond, offline, deterministic, auditable. Per RouterBench, trained routers
only modestly beat trivial baselines on a realistic mix — so a good keyword+length heuristic
captures most of the savings with none of the latency/cost/dependency.

## The reusable asset is `router.json`

Everything routing-specific lives in [`router.json`](router.json) — tiers (rank + relative
cost + model id), the default tier, and an **ordered** list of `{tier, pattern, reason}` rules.
The algorithm any host implements is the same ~10 lines:

> lowercase the task → walk `rules` in order → first `pattern` (ERE, case-insensitive) that
> matches wins → else `default`.

Keep `router.json` as the single source of truth; `route.sh` is just the reference impl, and
`bench.sh` scores *any* implementation against `evalset.tsv`.

## Files

| File | What |
|------|------|
| `router.json` | the spec — tiers, costs, ordered rules (the asset to copy into other repos) |
| `route.sh` | reference implementation (bash + jq + grep) — `route.sh [--explain] "<task>"` |
| `evalset.tsv` | labeled ground truth: `split` (base / holdout / adversarial) · tier · task |
| `bench.sh` | accuracy **and cost-at-iso-quality**, gated; `bench.sh` exits non-zero below floors |
| `test.sh` | module unit tests |

## Embedding in another app

Load `router.json`, implement the matcher. Examples:

**Go**
```go
type Rule struct{ Tier, Pattern, Reason string }
type Spec struct{ Default string; Rules []Rule }
func Route(task string, s Spec) string {
    lc := strings.ToLower(task)
    for _, r := range s.Rules {
        if regexp.MustCompile("(?i)" + r.Pattern).MatchString(lc) { return r.Tier }
    }
    return s.Default
}
```

**Python**
```python
import json, re
spec = json.load(open("router.json"))
def route(task: str) -> str:
    lc = task.lower()
    for r in spec["rules"]:
        if re.search(r["pattern"], lc, re.I): return r["tier"]
    return spec["default"]
```

**TypeScript**
```ts
const spec = JSON.parse(await readFile("router.json", "utf8"));
export const route = (task: string): string =>
  spec.rules.find((r: any) => new RegExp(r.pattern, "i").test(task.toLowerCase()))?.tier
  ?? spec.default;
```

**Rust** — same shape with the `regex` crate (`Regex::new(&format!("(?i){}", r.pattern))`).

Whatever the host language, score it the same way: emit `split<TAB>expected<TAB>got` per
eval case and feed it through the same math `bench.sh` uses.

## Metrics — why not just "accuracy"

Routing literature (RouteLLM, RouterBench) reports **cost-at-iso-quality**, not classification
accuracy, because the "which tier" classifier is only modestly better than naive on a real mix.
`bench.sh` reports both:

- **accuracy** — exact tier match vs the label.
- **quality-retained** — % where the chosen tier is **≥ the minimum-adequate (label) tier**.
  This is the honest stand-in for "iso-quality": did we pick a capable-enough tier?
- **underserve** — % routed *below* adequate (the real quality risk; over-serving only wastes cost).
- **cost vs all-opus** — the savings (e.g. "39% of all-opus → saves 61%").
- **efficiency** — cost-optimal / router-cost (100% = spent exactly what each task needed).

### Splits
- **base** — the curated cases the rules were authored against (rule-coverage, expect high).
- **holdout** — fair, naturally-phrased, *not* used to tune rules (generalization).
- **adversarial** — keyword-free paraphrases + misleading-keyword cases. A **generalization
  probe**, not a quality gate — its floor is a regression *tripwire*. A low score here is the
  honest signal of where a heuristic needs help (e.g. an LLM-classifier fallback for the
  ambiguous middle), *not* something to fix by overfitting rules to the probe.

### Current numbers (`bash bench.sh`)
- base + holdout (fair distribution): **~98% accuracy, ~98% quality-retained, ~61% cheaper than all-opus**.
- adversarial: **~33% accuracy, ~47% underserve** — the real ceiling of pure keyword routing.

## Deterministic vs real (two layers of "iso-quality")

`bench.sh` is the **deterministic** layer: quality is modeled by the labeled minimum-adequate
tier. The **real** layer — run each tier on each task, judge the outputs, derive the true
quality-vs-cost curve — needs tokens and is non-deterministic. To add it, write a `bench-live.sh`
that emits the same `split<TAB>expected<TAB>got` TSV from real model runs/judgments; the same
cost math applies and the same floors gate it (just off the CI path).

## Knobs (v1.1)

The full pipeline is: **decide(tier) → confidence → length-rules → bias → escalation → clamps → domain.**
With no flags it reproduces v1.0 exactly (`strategy: first-match`, `bias: balanced`, escalation off,
clamps no-op). Each knob has a spec default and a CLI/env override.

| Knob | Flag / env | What it does |
|------|-----------|--------------|
| **matching strategy** | `--strategy first-match\|max-hits\|weighted` | how a tier is chosen. `first-match` = ordered, first rule wins. `max-hits` = most *keyword* hits wins. `weighted` = Σ(hits × rule.weight). |
| **rule veto** | rule field `unless` (ERE) | a rule is skipped when its `unless` also matches — kills false positives (e.g. opus `auth` *unless* `typo`). |
| **length rules** | spec `length_rules: [{min_words, at_least}]` | raise the floor for long tasks (a 60-word "comment …" isn't trivial). |
| **bias** | `--bias cheap\|balanced\|quality` · `COMPASS_ROUTE_BIAS` | on **low-confidence** picks only: `cheap` downgrades a tier, `quality` upgrades — the cost↔quality dial. Confident picks are untouched. |
| **escalation (cascade)** | `--escalate-below N` · `--fallback "CMD"` | if confidence < N: run `CMD` (task on stdin → prints a tier) and use it; with no fallback, bump one tier. The hybrid: heuristic for the confident majority, a smart call for the ambiguous middle. |
| **clamps** | `--floor TIER` · `--ceiling TIER` · `--allow t1,t2` | hard bounds applied last. `ceiling` = cost cap (never opus); `floor` = quality SLA (never haiku); `allow` = explicit allowlist. |
| **pricing/model profiles** | `--profile NAME` (spec `profiles`) | per-tier cost/model override so `bench.sh` reflects *your* prices and each app maps tiers to its own models. |
| **domain axis** | `--domain` (spec `domains`) | also emit a specialist (ui/api/infra/docs/core) — a second, orthogonal classification. |
| **local overlay** | `--local FILE` (auto: `router.local.json`) | per-app/per-repo rules + scalar overrides without forking the base spec (local rules take priority). |
| **telemetry** | `--log FILE` | append `ts⇥tier⇥confidence⇥task` per call — feed real misroutes back into the evalset. |
| **output** | `--json` · `--score` · `--explain` | structured `{tier,confidence,model,cost,reason[,domain]}` · `tier⇥confidence` · reason on stderr. |

Measure any knob's tradeoff: `bench.sh --route-args "--bias cheap --ceiling sonnet"` reports the
cost-at-iso-quality under that setting. (Bias/escalation only move *low-confidence* picks, so they
barely shift the curated evalset — their effect shows on real ambiguous traffic.)

## Roadmap
- A trained/LLM classifier as the `--fallback` for the ambiguous middle (the escalation hook is ready).
- Auto-grow the evalset from `--log` telemetry (ties into `compass policy-synth`).
