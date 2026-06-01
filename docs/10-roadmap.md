# Roadmap — agentic directions

Grounded in **real Claude Code harness primitives** (no invented features — same rule as the
rest of the repo). **Most of this is now built and shipped as opt-in** (off by default; the
human merge/deploy gate is untouched). Per-item status:

| # | Capability | Status | Where |
|---|---|---|---|
| 1 | Work-type review routing | ✅ shipped | `sdlc-classify.yml` + `sdlc-design-review.yml` + `route` skill |
| 2 | Scheduled maintenance agents | ✅ shipped (opt-in) | `sdlc/routines/` · `setup.sh --routines` |
| 3 | Agent-team review | ✅ shipped (experimental) | `/team-review` |
| 4 | Goal-oriented convergence | ✅ shipped (opt-in) | `orchestrate.sh` `SDLC_CONVERGE=1` |
| 5 | Forked-subagent triage | ✅ shipped (opt-in) | `debugger` + `CLAUDE_CODE_FORK_SUBAGENT=1` |
| 6 | Cross-repo memory | ✅ shipped (opt-in hooks, local v1) | `session-memory.sh` · `record-learning.sh` · `mcp/compass-memory/` · ADR-0001 |
| 7 | WIP checkpointing | ✅ shipped (opt-in hook) | `claude/hooks/checkpoint-wip.sh` |
| 8 | Hooks-as-policy | ✅ shipped (opt-in hooks) | `route-intent.sh` + `require-tests.sh` (test-diff gate) |
| + | **Dynamic workflows** (parallel, adversarially-verified subagents) | ✅ shipped (research preview) | `claude/workflows/` → `/compass-review` `/compass-audit` `/compass-plan` · [docs](13-workflows.md) |
| + | **Router eval harness** (autoroute, measured) | ✅ shipped | `scripts/route-evalset.tsv` · `compass route --eval` (CI-gated) |
| + | **One-command quickstart** | ✅ shipped | `./quickstart.sh` · `compass quickstart` |
| + | Spec/intent-driven mode | ✅ shipped | `/spec` + `orchestrate.sh` `SDLC_SPEC=` |
| + | Browser agent | ✅ shipped (opt-in MCP) | `mcp/servers.json` → `browser` |
| + | Human-gated auto-merge | ✅ shipped (opt-in) | `setup.sh --protect` → `gh pr merge --auto` |
| + | **Eval-gated guardrail** (data-driven policy + bypass corpus) | ✅ shipped | `claude/hooks/lib/policy.sh` · `scripts/test-protect-paths.sh` · `compass bench` |
| + | **Actions audit** (drift · least-priv · pinning · injection) | ✅ shipped | `scripts/check-actions.sh` (CI + doctor) |
| + | **Parallel orchestrator** + test-impact + diff-size routing | ✅ shipped (opt-in) | `orchestrate.sh` `SDLC_PARALLEL=` `SDLC_TEST_IMPACT=` |
| + | **Cost-aware router** (confidence + budget bias) | ✅ shipped (opt-in) | `compass route --score` · `COMPASS_ROUTE_BUDGET_BIAS` |
| + | **Fleet brain** (recurring findings → proposed rules) | ✅ shipped (opt-in) | `compass policy-synth` · `sdlc/routines/policy-synth.yml` |
| + | **Reproducible benchmark** (precision/recall, CI-gated) | ✅ shipped | `compass bench` · `scripts/guardrail-corpus.tsv` |
| + | **Dashboard** (impact + spend + live fleet PRs) | ✅ shipped | `compass dashboard` |
| + | **SBOM + signed commits** (provenance) | ✅ shipped (opt-in) | `compass sbom` · `orchestrate.sh` `SDLC_SIGN=` `SDLC_SBOM=` |
| + | **spec-kit interop** | ✅ shipped | `orchestrate.sh` spec auto-discovery → [16](16-hardening-and-frontier.md) |

The detail below is the design rationale + how to enable each. Each was validated like the
rest of the pipeline (lint, shellcheck, selftest, CI). Cross-repo memory stays ADR-gated.

**Maturity legend:** 🟢 stable primitive · 🟡 experimental primitive · 🔵 needs external infra (MCP/runner).
**Version note:** some primitives below require a recent Claude Code (`/schedule`, `/goal`,
`claude agents` ≈ v2.1.139+; **dynamic workflows** ≈ v2.1.154+ and **Opus 4.8** / `/effort
ultracode` from 2026-05-28). Check `claude --version`; treat anything unverified on your
build as aspirational.

---

## Phase 1 — near-term, shippable on today's stack

### 1. Work-type review routing 🟢  *(the gstack technique we flagged)*
**Today:** every PR runs all reviewers (Reviewer + Security + QA + Codex). That's thorough
but over-reviews small/typed changes. **gstack** routes by work type (UI → design review,
API → devex review, arch → eng review).

**Design.** A cheap classifier step on the diff sets a `domain:*` label, and reviewers gate
on it:
- A new `sdlc-classify.yml` (Claude · haiku, `--json-schema '{"domain": "ui|api|infra|docs|core"}'`)
  runs first on PR open and applies one `domain:*` label.
- Each specialist reviewer adds an `if:` on its domain (e.g., a `design-review` only on
  `domain:ui`; `Security` always; `QA` always). The closed loop is unchanged.
- A `route` **skill** (`invokeByUser: only-if-relevant`) does the same locally in
  `orchestrate.sh`.

**Tradeoffs.** Saves cost/noise on typed PRs; risk of mis-route (mitigate: Security + QA
always run regardless of domain). Classifier adds ~1 cheap call per PR.
**Status:** designed, not built. Smallest, highest-value next step — I can implement it.

---

## Phase 2 — autonomous, harness-native (the "futuristic" set)

### 2. Scheduled maintenance agents 🟢  *(`/schedule` + `/goal`)*
Background agents that run on cron and **open PRs** into the existing closed loop — so the
human gate and required checks still apply. Each is a named routine.

| Routine | Cron | What it does | Tools |
|---|---|---|---|
| `babysit-prs` | every 30m | nudge stalled `agent:needs-fix` PRs; escalate `sdlc:needs-human` to a ping | `gh`, PushNotification |
| `dep-refresh` | weekly | bump deps, run tests, open a PR if green | `Bash(go/cargo/npm…)`, `gh pr create` |
| `flaky-triage` | nightly | re-run recently failed CI, cluster flakes, file an issue | `gh`, `Bash(test runners)` |
| `doc-freshness` | weekly | diff code vs docs, open a docs PR for drift | `Read`, `Edit`, `gh` |

**Mechanism.** `/schedule "<prompt>" --interval "<cron>"` spawns a detached agent (seen in
`claude agents`); scope it with `--allowedTools` and a `--max-turns`/budget cap; pair with
`/goal` for "work until <condition>." Agents **never merge** — they stop at a PR.
**Tradeoffs.** Real spend on a timer → hard budget caps + `claude agents` visibility are
mandatory. Start with one (`babysit-prs`) before a fleet.
**Status:** primitive is stable; routines not yet shipped. 🟢

### 3. Agent-team SDLC 🟡  *(`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` — already enabled in `settings.json`)*
Today the headless pipeline is **sequential** (`claude -p` → `codex exec`, one after
another). Agent teams let Reviewer / Security / QA run as **parallel teammates** with a
shared task list and `SendMessage`, coordinated by a lead that synthesizes findings — a
genuine "agents talking to each other," not just posting to a PR.

**Design.** `orchestrate.sh --team` spins a lead + 3 teammates; lead assigns review/
security/qa tasks, teammates message conflicts ("Security flags the input the Reviewer
OK'd"), lead writes one reconciled verdict. Team hooks (`TaskCompleted`, `TeammateIdle`)
gate quality and reap idle teammates.
**Tradeoffs.** Experimental: no teammate resumption, task-status lag, one team per lead.
Parallel = higher peak spend. Keep the proven sequential path as default; teams opt-in.
**Status:** flag on; coordinator not built. 🟡 — adopt for interactive review first, where
the rough edges (resumption) don't bite.

### 4. Goal-oriented orchestrator 🟢  *(`/goal`)*
Wrap `orchestrate.sh` with a completion condition ("all required checks green + 0 Blocking")
so the driver keeps iterating turns until met (or a cap), instead of a fixed step list —
mirrors the cloud loop's "until clean," locally.
**Status:** stable primitive; not wired into `orchestrate.sh`. 🟢

### 5. Forked subagents for parallel triage 🟡  *(`CLAUDE_CODE_FORK_SUBAGENT=1`)*
For the `debugger`/`triage` paths: fork N isolated subagents to test competing root-cause
hypotheses in parallel, return the one that reproduces+fixes. Bounded fan-out, cheap models.
**Status:** opt-in flag; not used by our agents yet. 🟡

### 5b. Dynamic workflows 🟡  *(shipped — research preview, `v2.1.154+`)*
The evolution of agent teams (§3): instead of Claude orchestrating subagents turn-by-turn,
the plan lives in a **script** the runtime executes in the background — fanning out tens to
hundreds of subagents, with loops/branching/intermediate-results in script variables, not the
chat context. The leverage isn't just *more* agents; it's the **quality pattern** — agents
adversarially verify each other before anything is reported.
**Shipped:** three workflows in `claude/workflows/`, each routing stages to compass's own
cost-tiered subagents (`agentType`): `/compass-review` (parallel dimensions → adversarial
verify → one verdict), `/compass-audit` (multi-modal finders → loop-until-dry → 2-of-3 vote),
`/compass-plan` (N angles → judge panel → grafted synthesis). Shape + JS syntax validated in
CI (`scripts/check-workflows.sh`). Full design + limits: [`docs/13-workflows.md`](13-workflows.md).
**Tradeoffs.** Research preview (the save path + runtime are still moving); a run spends real
tokens across many agents → it buys thoroughness, not free coverage. Off-switch:
`CLAUDE_CODE_DISABLE_WORKFLOWS=1`. The human still merges.
**Status:** shipped, research-preview-gated. 🟡

---

## Phase 3 — needs external infra

### 6. Cross-repo org memory 🔵  *(MCP knowledge server + per-repo auto-memory)*
**Honest constraint:** Claude Code's auto-memory (`~/.claude/projects/<repo>/memory/`) is
**per-repo and machine-local** — there is **no native org-wide knowledge base** (gstack's
"GBrain" is its own external service). To get cross-repo learnings you need an **MCP server**
fronting a shared store.

**Design.** A small `compass-memory` MCP server (HTTP, project scope) over a vector/SQL store:
`search(query)` and `record(learning, repo, tags)`. A `SubagentStop`/`Stop` hook records
durable learnings; `SessionStart` injects the top relevant ones. Per-repo trust tiers
(read-write / read-only / deny) like gstack.
**Tradeoffs.** Real service to run + secure (it sees code context — encryption + tenancy
matter; this crosses a trust boundary → **ADR required** before building). Start read-only.
**Status:** design only; deliberately gated behind an ADR. 🔵

### 7. Continuous WIP checkpointing 🟢  *(hooks)*  *(gstack `checkpoint_mode`)*
A `PostToolUse`/`Stop` hook auto-commits WIP to a scratch ref with a structured
`[compass-context]` body (decisions, remaining work, failed approaches) so a crash/compaction
loses nothing; `/ship` squashes WIP before the PR so bisect stays clean. `PreCompact` hook
can snapshot state before context compaction.
**Tradeoffs.** Noisy local history (mitigate: scratch ref + squash-on-ship). Pure-hook, no
new infra.
**Status:** designed; not built. 🟢

### 8. Hooks-as-policy 🟢  *(shipped, opt-in)*
Beyond the guardrail: a `UserPromptSubmit` hook that **routes** ("this looks like a
migration → load the `/adr` skill first"), and a `PostToolUse` hook that **enforces**
("a code edit landed with no test diff → nudge for one"). CLAUDE.md *advises*; only a hook
fires deterministically every time.
**Shipped:** `claude/hooks/route-intent.sh` (intent → ADR/spec/security nudge) and
`claude/hooks/require-tests.sh` (source edited with no test file in the diff → one-line
nudge; silent once any test is touched; tested in `scripts/test-cli.sh`). Both are
**advisory** (add context, never block) and **opt-in** — wire under `hooks.UserPromptSubmit`
/ `hooks.PostToolUse` in `settings.json` when you want them. We keep them advisory on
purpose: a hard block on every untested edit fights the natural write-code-then-test flow.
**Status:** shipped, opt-in. 🟢

---

## Phase 4 — cross-vendor, cost & latency (real problems, grounded primitives)

### 9. LLM-agnostic / IDE-native via the AGENTS.md standard 🟢
`AGENTS.md` (Linux Foundation Agentic AI Foundation) is read natively by Codex, Cursor,
Windsurf, Copilot, Amp, Devin; Gemini CLI reads `GEMINI.md` or `AGENTS.md` via `context.fileName`.
- **Shipped:** `./install.sh --gemini` (one manual → Gemini CLI); per-repo `AGENTS.md` already
  feeds Cursor/Windsurf/Copilot; MCP manifest is cross-tool. See [`docs/12-every-agent.md`](12-every-agent.md).
- **Next:** auto-register the MCP manifest into Gemini CLI / Cursor (`scripts/setup-mcp.sh`);
  per-repo `GEMINI.md` symlink in `new-repo.sh`; a Gemini-driven cloud SDLC agent (`gemini -p`)
  as a third cross-model auditor. 🔵

### 10. Cost-effective, low-latency SDLC 🟢
The loop is already built for this: checks fire **in parallel** on a PR (not sequential),
models are **cost-tiered** (classify = haiku, QA = deterministic/free, review = sonnet, the
opus security + Codex audit run **once on open**, not every push), **routing** runs domain
reviewers only where they apply, and **round caps** bound spend.
- **Shipped:** `orchestrate.sh SDLC_LITE=1` (skip audit + opus security → review + QA + human
  gate only — fast/cheap for small changes); classifier-gated routing; parallel cloud checks;
  **bring-your-own-model** (`codex --profile local` → Ollama, `--profile router` → OpenRouter)
  for the cheap tier; **spend pre-estimate + post-run analysis** (per-step `total_cost_usd` →
  `costs.tsv` + PR "Spend" line). See [`docs/02-cost-and-models.md`](02-cost-and-models.md).
- **Shipped since:** the **router is now measured** — `compass route --eval` scores the
  deterministic tier-picker against `scripts/route-evalset.tsv` and **CI gates** on an accuracy
  floor, so `SDLC_AUTOROUTE` is a checked claim. **Prompt caching** is documented + structurally
  exploited (stable system prefixes, byte-identical converge-loop prompts) in
  [`docs/02`](02-cost-and-models.md).
- **Next:** diff-size-gated model selection (haiku review for ≤N-line diffs); GitHub Actions
  dependency caching in `sdlc-qa.yml`; **test-impact selection** (run only tests affected by the
  diff) for low-latency QA; a **first-class smart router** (cross-provider, cost-aware) and a
  rolling spend dashboard; optional merge-queue. 🔵

### 11. More governed, more tested 🟢
- **Shipped:** required status checks (`review` + `qa`), ADR-gated trust boundaries, self-tests
  (`selftest.sh` + `compass-memory` tests) in CI, a security-auditor pass on load-bearing code.
- **Next:** an optional **dependency-audit / SBOM** step and a **coverage gate** in the QA
  workflow; signed commits from the Builder; a periodic `security-review` routine. 🔵

---

## Deliberately NOT on the roadmap (honesty)
- **A fully unattended merge-to-prod swarm.** The human merge/deploy gate is the product's
  spine, not a limitation. Agents open PRs; humans ship.
- **The browser agent** (gstack `/browse`) — different problem domain; out of scope for an
  agent-config repo.
- **Vendoring a heavyweight memory service** into compass — #6 stays an optional MCP
  integration behind an ADR, never a hard dependency.

---

## How these compose
The through-line: **the PR (and its required checks + human gate) stays the coordination
medium and the safety boundary.** Everything above either *feeds* that loop (scheduled
agents open PRs; routing trims who reviews) or *enriches* it (teams/memory/checkpoints) —
none of it removes the human from merge or deploy. We ship one item at a time, behind a flag,
each validated like the closed loop was (live smoke test in [`sdlc/SMOKETEST.md`](../sdlc/SMOKETEST.md)).

> Want one built? **Work-type routing (#1)** is the shippable next step; **`babysit-prs`
> (#2)** is the most striking "it runs itself" demo. Cross-repo memory (#6) needs an ADR first.
