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

### 1-hour cache TTL (extended)
The default cache lives **5 minutes**; the extended TTL is **1 hour** (GA). 1h costs ~2× on
the *write* but reads stay at 0.1× — a net win **only when the same large prefix is reused
across calls more than 5 minutes apart**, which is exactly the SDLC pipeline + converge loop
(`review → fix → review` can span minutes-to-an-hour). It's **not** a win for one-shots
(`compass onboard`, the router's tiny LLM fallback) — those would just pay the write premium.

Claude Code exposes this only as an **env var** (`ENABLE_PROMPT_CACHING_1H=1`, v2.1.108+) —
no CLI flag, no `settings.json` field. compass applies it where it pays:
- **`sdlc/orchestrate.sh`** exports `ENABLE_PROMPT_CACHING_1H=1` for its `claude -p` steps
  (opt out with `SDLC_CACHE_1H=0`).
- **GitHub SDLC loop** (`claude-code-action`): set it as a repo/Actions env var or in the
  workflow's `env:` if you want the hosted converge loop on the 1h TTL too.
- **Interactive sessions:** add `export ENABLE_PROMPT_CACHING_1H=1` to your shell rc if your
  day is long, context-heavy sessions (the common case); skip it for short, bursty ones.
- It does **not** apply to the raw-API path in `router/fallback-llm.sh` — that prompt is below
  the 1,024-token cache minimum, so caching is a no-op there regardless of TTL.

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

> **Cache-aware routing** ([`router/`](../router/) module, [ADR-0004](adr/0004-cache-aware-routing.md)).
> The deterministic router adds a **cache-aware cost-min** stage that folds Anthropic prompt-cache
> economics (read 0.1×, write 1.25×@5m / 2×@1h) + a session warm-set into the pick — riding an
> already-warm tier when it's cheaper than cold-loading a cheaper one (upgrade-only, never a quality
> drop). Plus a **budget governor**, a **latency ceiling**, **domain quality floors**, and spec
> **validation + ReDoS lint** — each off unless its signal is set. `router/bench.sh --cache` reports
> the effective $ saved; see [`router/README.md`](../router/README.md).

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
