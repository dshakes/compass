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
| + | **Cross-agent budget proxy** (enforcement for Codex/Gemini/SDKs) | ✅ shipped (experimental) | `compass gate` → `scripts/compass-gate.py` |
| + | **Plugin-security scanner** (injection · tool-poisoning · unpinned MCP · fetch-exec) | ✅ shipped | `compass audit-plugin` · operator `--baseline` |
| + | **External red-team corpus** (public set we didn't write) | ✅ shipped (report-only) | `compass redteam --external` → [17](17-red-team.md) |
| + | **Advanced router engine** (9-stage cost-aware, opt-in) | ✅ shipped | `COMPASS_ROUTE_ENGINE=advanced` · `router/` |
| + | **Cost benchmark** (routed vs all-Opus, reproducible) | ✅ shipped | `compass bench` → [18](18-benchmark.md) |
| + | **Task-success benchmark** (seeded-bug oracles) | ✅ shipped (CI validates structure) | `sdlc/taskbench/` |
| + | **Agent-identity provenance in the loop** (role/model/run per commit) | ✅ shipped (opt-in) | `orchestrate.sh` `SDLC_TRACE=1` |
| + | **Repo context pack for review** (touched-symbol call sites) | ✅ shipped (opt-in) | `orchestrate.sh` `SDLC_CONTEXT=1` · `scripts/context-pack.sh` |
| + | **OpenSSF Scorecard** (supply-chain posture) | ✅ shipped | `.github/workflows/scorecard.yml` |
| + | **Headless budget cap** (transcript-JSONL cost fallback) | ✅ shipped | `claude/hooks/budget-gate.sh` |

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

## Phase 5 — multi-agent safety, provenance, and identity

### 12. Team/workflow-scale guardrails 🟡  *(policy enforcement across fan-outs)*
Today the injection scanner and budget caps operate per-session (single agent,
single loop). As fan-out multi-agent runs grow — parallel review teams, fleet
sweeps, dynamic workflows — the same controls need to operate **across the
fan-out**: injection scanning on inter-agent messages, budget enforcement across
the whole orchestration (not just per-subagent cap), and policy propagation so a
child agent can't exceed permissions the parent doesn't have.

**Design.** Extend `orchestrate.sh` with an inter-agent message bus that pipes
each outbound message through `injection_findings` before delivery; add an
orchestration-level token budget that tracks spend across all subagents and hard-
stops the fan-out when exceeded.
**Maps to:** ASI07 (insecure inter-agent communication) + ASI08 (cascading
failures) in the OWASP Agentic Top-10.
**Status:** not built; design phase. Requires the agent-team primitive to stabilise. 🟡

### 13. Eval-driven routing 🟡  *(feed scored eval outcomes back into routing weights)*
The router currently scores on a fixed labeled set. Each scored eval run — from
`compass bench`, CI gates, or a post-run analysis — is a signal: tasks that were
routed to the wrong tier (or succeeded cheaply on a high tier) should shift the
routing weights. Feeding outcomes back closes the loop between "what the corpus
says" and "what the live workload rewards."
**Design.** A lightweight feedback record (task description, assigned tier, outcome,
cost) written by `orchestrate.sh` → periodic roll-up by `compass policy-synth` →
proposed weight update to `router/spec.yml` for human review and CI re-gate.
**Status:** designed, not built; depends on structured post-run cost records. 🟡

### 14. Per-task/per-PR hard budget caps 🟢  *(wired into the autonomous loop)*
Round caps exist today. Hard token/spend caps are documented but not wired into
the autonomous convergence loop as a first-class exit condition — a long-running
run can exceed intent. **Design.** Add a `SDLC_BUDGET_USD` env to `orchestrate.sh`
that reads the running cost from the per-step `total_cost_usd` field and halts
(with a summary PR comment) when the cap is reached, before any more turns.
**Status:** primitive is available (cost tracking exists); wiring is the work. 🟢

### 15. Agent identity / attestation 🔵  *(SPIFFE-style identity for SDLC roles)*
Today there is no cryptographic assertion of *which* agent produced a given output.
A Reviewer verdict and a Builder commit are distinguished only by convention. With
SPIFFE-style workload identity, each compass SDLC role (Builder, Reviewer, Security,
QA) carries a short-lived, verifiable identity certificate — so a downstream gate
can verify "this commit was authored by the Builder role" rather than trusting the
commit author field.
**Maps to:** ASI03 (agent identity & privilege abuse) in the OWASP Agentic Top-10.
**Status:** design only; requires external identity infrastructure. ADR required
before building. 🔵

### 16. Provenance — signed Agent Trace records 🟡  *(landing now)*
`compass trace` is being implemented in a parallel branch. It will produce
**Agent Trace** records (the open [Agent Trace spec](https://github.com/cursor/agent-trace))
for AI-assisted commits: a structured, signable artifact that captures which
agent, which model, which prompts, and which tool calls produced a given change —
analogous to SLSA provenance for source, but for the agent turn that wrote it.
Combined with SLSA build provenance (already on every compass release), this
closes the chain from "AI wrote this" to "here is the verifiable record."
**Status:** `compass trace` implementation in progress; spec is stable. 🟡

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
each validated like the closed loop (CI: actionlint + selftest; live smoke test is a checklist you run in [`sdlc/SMOKETEST.md`](../sdlc/SMOKETEST.md)).

> Want one built? **Work-type routing (#1)** is the shippable next step; **`babysit-prs`
> (#2)** is the most striking "it runs itself" demo. Cross-repo memory (#6) needs an ADR first.
