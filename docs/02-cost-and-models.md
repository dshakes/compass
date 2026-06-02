# Cost & model routing

The single biggest lever on agent cost is **which model does which job**. Token
counts dwarf per-token price differences, so routing the bulk (mechanical, parallel
work) to cheap models while keeping deep reasoning on Opus wins on both cost *and*
speed.

## The three tiers

| Tier | Model | Where it's set | Jobs |
|---|---|---|---|
| **Cheap** | Haiku 4.5 | `test-runner` subagent | run tests, parse failures, triage logs, mechanical edits, "find all callers" sweeps |
| **Standard** | Sonnet 4.6 | `code-reviewer`, `go-engineer`, `rust-engineer`, `docs-writer`, `k8s-operator` | most feature coding, refactors, reviews, docs |
| **Deep** | Opus 4.8 | driver session + `architect`, `security-auditor`, `debugger` | architecture, security, subtle debugging |

The deep tier tracks the **newest** Opus — bumped to **Opus 4.8** (`claude-opus-4-8`,
shipped 2026-05-28) day one. Change a subagent's tier by editing the `model:` line in
its `claude/agents/<name>.md`. Accepted values: a model ID
(`claude-opus-4-8`, `claude-sonnet-4-6`, `claude-haiku-4-5-20251001`) or `inherit`.

## How the savings actually happen
- **Delegation keeps the driver's context small.** A subagent reads 20 files and
  returns a 5-line conclusion; the expensive driver context never holds those 20
  files. Less context = fewer tokens per subsequent turn.
- **Cheap models do the volume.** Test runs and log triage are high-token,
  low-reasoning. On Haiku they're nearly free.
- **`/cost`** re-plans a task into a delegation table before you spend.

## Effort level
`effortLevel: "high"` in `settings.json` buys deeper reasoning per turn (worth it
on the Opus driver). Subagents on cheaper models implicitly cost less per turn;
you can also dial Codex reasoning per profile (`deep`/`standard`/`cheap`).

**`/effort ultracode`** (Opus 4.8+) goes further: `xhigh` reasoning *plus* automatic
[dynamic-workflow](13-workflows.md) orchestration — Claude plans a fan-out workflow for
each substantive task instead of working turn-by-turn. It's the most expensive setting
(several workflows can run for one request), so reach for it on genuinely hard, wide
problems and drop back with `/effort high` for routine work.

## Prompt caching (automatic)
Claude Code **prompt-caches** the system prompt, tool definitions, and conversation
prefix automatically — you don't toggle it. compass is structured to maximize the hit
rate rather than fight it:
- **Stable system prefixes.** Each `orchestrate.sh` step passes a fixed role file via
  `--append-system-prompt-file` (`sdlc/roles/*.md`), and the operating manual is one
  unchanging file — a long, identical prefix that caches across steps and sessions.
- **Byte-identical loop prompts.** The converge loop (`SDLC_CONVERGE=1`) re-issues the
  *same* reviewer prompt every round, so each re-review reuses the cached prefix — a
  big reason iterating to green stays cheap.
- Keep your project `CLAUDE.md` lean (philosophy §3): a smaller stable prefix is both
  cheaper to cache and higher-signal. Building on the API directly? The `claude-api`
  skill bakes in `cache_control` so apps cache by default.

## Cache-aware routing (the router consumes the cache, [ADR-0004](adr/0004-cache-aware-routing.md))
`compass route` is a **two-stage, client-side, deterministic** router. Stage 1 sets a **quality
floor** (opus-class work is a hard floor, never downgraded); Stage 2 does **cache-aware cost-min**
over tiers at/above the floor, using Anthropic cache economics (read 0.1×, write 1.25×@5m / 2×@1h)
and a session **warm-set** (`COMPASS_ROUTE_WARM`). The decision only moves *up* to an already-warm
pricier tier when that's cheaper than cold-loading the floor — e.g. **warm Sonnet beats cold Haiku
when the task delta `D < ~⅓` of the cached prefix `P`** (small edits on a hot prefix, compass's
common case). With no cache signals it returns the floor, so default behaviour is unchanged.
Two CI gates keep it honest: `compass route --eval` (quality-floor accuracy ≥90%) and
`compass route --eval-cost` (cache decisions, 100% vs a hand-verified set); both roll up into
`compass bench`. `orchestrate.sh` feeds it the warm tier + diff-size under `SDLC_AUTOROUTE` so the
reviewer can ride the warm Builder tier instead of cold haiku.

## Bring your own model — local LLMs & cost routers (Codex side)
The cheapest token is one you don't pay for. Codex talks to **any OpenAI-compatible endpoint**,
so a tier can run on a **local model** (free, private) or a **cost router**:

| Profile | Backend | Use |
|---|---|---|
| `codex --profile local` | **Ollama / LM Studio** (`localhost:11434/v1`) | grunt work on a free local model — zero API cost |
| `codex --profile router` | **OpenRouter** (one key → many models) | route to the cheapest *capable* model per task |

These ship **inert** in `codex/config.toml` (`[model_providers.ollama|openrouter]` + the
`local`/`router` profiles) — the default tiers are unchanged; opt in per command. Set
`OPENROUTER_API_KEY` for the router; pull a coding model (e.g. `ollama pull qwen2.5-coder`) for
local. Edit the example model names to ones you actually have.

**Honest limit:** this lever is **Codex-side**. Claude Code's core agent runs Claude (or Claude
via **Bedrock/Vertex** for enterprise: `CLAUDE_CODE_USE_BEDROCK` / `..._VERTEX`) — it does *not*
run arbitrary local/OpenRouter models. So the cross-tool play is: Claude Code for deep Claude
reasoning, a **local/router-backed Codex** for cheap high-volume work + the independent audit.
Cross-provider *smart routing* as a first-class compass layer is roadmapped (`docs/10-roadmap.md` §10).

## Watching spend (pre/post budgeting)
- **Live (interactive):** the status line shows estimated session cost (`$x.xx`) and context
  size, so you notice a runaway before it's expensive. `/cost` is the deliberate pre-plan.
- **Per-run budget cap:** every autonomous step is hard-capped — `--max-budget-usd` on each
  cloud workflow step and on each `orchestrate.sh` Claude step (`SDLC_BUDGET`/4 by default).
- **Pre-run estimate:** `orchestrate.sh` prints the per-step cap and total budget hint before
  it starts — you know the ceiling up front.
- **Post-run analysis:** when `jq` is present, `orchestrate.sh` captures each step's real cost
  (`claude -p --output-format json` → `total_cost_usd`) into `.sdlc/run-*/costs.tsv`, prints a
  per-step breakdown + total, and includes a **Spend** line in the PR body. (QA is free; the
  Codex audit isn't tallied.)
- **Aggregate across runs/repos:** each step's cost is also appended to a global ledger
  `~/.compass/spend.tsv`. `compass spend [--week|--month|--all]` rolls it up by model and repo;
  set a ceiling with `COMPASS_BUDGET_USD` (or `budget_usd=` in `~/.compass/config`) and it shows
  OK / over-80% / over.
- **Is it worth it?** `compass impact` answers "how is compass benefiting me" — footguns blocked,
  files auto-formatted, spend by model, and an **estimated `$` saved** vs running everything on
  Opus (a rough multiple-based estimate, labelled as such).

## Auto-routing the model — now measured
`compass route "<task>"` maps a task to the cheapest-correct tier (haiku/sonnet/opus) by a
deterministic keyword heuristic. `orchestrate.sh` uses it for the Builder step **only** when
`SDLC_AUTOROUTE=1` (off by default; the default stays Sonnet).

The honest caveat used to be "no eval set, so a wrong route can hurt quality more than it
saves." That gap is now closed: a labeled ground-truth set lives at
[`scripts/route-evalset.tsv`](../scripts/route-evalset.tsv), and

```bash
compass route --eval        # score the router; per-tier recall + accuracy
```

scores the router against it. **CI gates on it** — a routing change that drops below the floor
(`COMPASS_ROUTE_MIN_ACCURACY`, default 90%) fails the build, so accuracy is a checked claim, not
a vibe. The set also documents the heuristic's limits honestly: a couple of context-dependent
tasks (e.g. "a backward-compatible proto contract change") are irreducible misses for *keyword*
routing — which is exactly why `SDLC_AUTOROUTE` stays opt-in. Add real mis-routes to the set as
they surface; that's how it earns its keep.

## Rules of thumb baked into `CLAUDE.md`
- Don't re-read a file you just edited.
- Don't re-run a search you already delegated.
- Prefer one well-scoped subagent over many main-thread file reads.
- Reserve Opus for where a wrong answer is expensive.
