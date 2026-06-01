# Competitive audit — where compass stands, and how it becomes world-class

> A code audit, a parity check against the rest of the field, and a prioritized
> path to making compass the best-in-class, futuristic version of itself.
> Written 2026-06-01. Treat the recommendations as a menu, not a mandate — the
> product's spine (readable config, human merge gate) is non-negotiable and
> nothing here moves it.

---

## 1. What compass actually is (so we compare it to the right things)

compass is **not** a coding agent. It's the **governance, configuration, and
orchestration layer** that sits *on top of* one (Claude Code / Codex / Gemini).
That makes it a different species from most "AI coding" products, and the
comparison has to be category-by-category. compass spans four categories at
once:

| Layer | What compass ships | The category it competes in |
|---|---|---|
| **Config / constitution** | `CLAUDE.md` ≙ `AGENTS.md`, 9 subagents, 12 commands, 4+3 hooks, MCP manifest | SuperClaude, gstack, spec-kit "constitution", awesome-claude-code configs |
| **Local orchestration** | `orchestrate.sh` pipeline, 3 dynamic workflows, `compass route` | BMAD-METHOD, claude-flow, Conductor/Vibe-Kanban |
| **Autonomous SDLC (cloud)** | self-fixing PR loop in GitHub Actions, Reviewer⇄Builder converge | Devin, Factory Droids, Cursor background agents, Codex cloud, GitHub Copilot coding agent |
| **Fleet + review** | scheduled cross-repo agents, mission-digest, cross-model audit, mobile control | Greptile/CodeRabbit/Qodo (review), Charlie, Sweep |

The strategic insight in the README — *"everyone has the same models, the edge
is configuration"* — is correct and is **exactly** the thesis the rest of the
field converged on in 2026 (model routing as "a routing problem, not a branding
problem" — Factory; "constitution as immutable principles" — spec-kit). compass
is on the right axis. The questions are: **how good is the execution**, and
**where is it behind the frontier**.

---

## 2. Code & engineering audit

### 2.1 What's genuinely strong

- **Honesty as a design value.** `protect-paths.sh` opens by declaring itself
  "BEST-EFFORT footgun-prevention, NOT a security boundary." The README has a
  "Deliberately NOT on the roadmap" section. This is rare and it's a moat —
  trust is the scarce resource for autonomous tooling.
- **Real CI rigor.** `.github/workflows/ci.yml` gates on `shellcheck -S error`,
  `actionlint` (incl. embedded shell), a **router accuracy floor** (`compass
  route --eval` fails the build below 90%), SDLC selftest, memory-store
  redaction tests, and a **plugin-sync check** (`sync-plugin.sh --check`) that
  catches `claude/` ↔ `plugins/core/` drift. Most config repos have none of this.
- **Cost discipline is implemented, not just claimed.** `orchestrate.sh`
  captures `total_cost_usd` per step into `costs.tsv`, hard-caps each step at
  `BUDGET/4`, and the router is a *deterministic, evaluated* function
  (`compass-route.sh`), not a vibe.
- **Portability care.** Comments explicitly handle macOS bash 3.2 (no
  associative arrays — see `compass-route.sh:50`), jq→python3→grep fallbacks in
  `lib/common.sh`, and the `route_one` "run in current shell so globals
  propagate" note. Someone thought about the edges.
- **Fail-safe direction is correct.** When neither `jq` nor `python3` exists,
  `protect-paths.sh:47` folds the raw payload into the checked string — erring
  toward *block*, never toward a silent allow.
- **The dynamic-workflow pattern is genuinely ahead.** `compass-review.js`'s
  "review → adversarially refute each finding → keep only survivors" with a
  `default to refuted=true if unsure` is a real precision technique, not theater.
  It directly attacks the #1 complaint about AI review (noise).

### 2.2 Findings (code-audit agent results)

> **The concrete bug/security/robustness findings from the deep read of the
> hooks, scripts, and GitHub Actions workflows are tracked in §6 (Findings
> register), populated by the code-audit pass.** The headline structural
> observations are below.

**[DRIFT, medium] Two parallel workflow trees.** `sdlc/workflows/*.yml` (13
files) and `sdlc/selfhosted/*.yml` (11 files) plus `.github/workflows/sdlc-*`
overlap heavily. There's a sync check for the *plugin* but not for the *SDLC
workflow variants* — they can diverge silently. Recommend a single templated
source + a generator, or a `check-workflows`-style diff gate.

**[ROBUSTNESS, medium] Guardrail is regex-based and bypassable by design.**
`protect-paths.sh` is honest about this, but the gap between "what users
*think* it blocks" and "what it *can* block" is the single biggest trust risk.
Examples a careless (not malicious) agent could still execute: `find . -delete`,
`git push origin +HEAD:main` (the `+refspec` force form — the regex looks for
`--force`/`-f`), `rm -rf /usr` (only bare `/` and `/*` are caught, not `/usr`,
`/etc`, `/var`), `truncate -s 0`, `> importantfile`. See §6 for the full list.

**[TEST-GAP] The guardrail itself has no bypass-corpus test.** `test-cli.sh`
covers route/spend/impact/notify/listen, and `selftest.sh` covers the loop, but
there is no table-driven "these 40 dangerous strings must be blocked, these 20
safe ones must pass" test for `protect-paths.sh` — the highest-stakes file in
the repo. This is the most important test to add.

### 2.3 Net assessment

For a config/orchestration repo this is **top-decile engineering**: linted,
tested, honest, portable, reversible. It is meaningfully more rigorous than
SuperClaude (no CI shellcheck/actionlint gate) or typical `gstack`-style dotfile
configs. The weaknesses are (a) the guardrail's coverage vs. its perceived
promise, (b) workflow-tree drift, and (c) test gaps on the safety-critical path.

---

## 3. Parity check vs. the rest of the field

Legend: ✅ first-class · 🟡 partial / opt-in / experimental · ⬜ absent · ➖ N/A for category.

### 3.1 vs. config frameworks (SuperClaude, spec-kit, gstack, claude-flow)

| Capability | compass | SuperClaude | spec-kit | gstack |
|---|---|---|---|---|
| One constitution, multi-agent | ✅ (`AGENTS.md` symlink) | ✅ | ✅ ("constitution") | ✅ |
| Cost-tiered subagents | ✅ | 🟡 personas, not priced | ⬜ | ✅ |
| Deterministic model router + **eval gate** | ✅ (unique) | ⬜ | ⬜ | 🟡 |
| Guardrail hooks (block/format) | ✅ | 🟡 | ⬜ | ✅ |
| Spec-driven mode | 🟡 (`/spec`, `SDLC_SPEC=`) | 🟡 | ✅ (the whole product) | ⬜ |
| Self-learning / memory hooks | 🟡 (ADR-gated MCP) | ✅ session memory | ⬜ | ✅ (GBrain) |
| CI-enforced quality of the config itself | ✅ (unique strength) | ⬜ | 🟡 | ⬜ |
| Adversarial multi-agent review | ✅ (dynamic workflows) | 🟡 | ⬜ | ⬜ |

**Read:** compass leads on *rigor, routing, and adversarial review*; trails on
*persistent learning/memory* (its strongest gap vs. SuperClaude & gstack) and is
*roughly at parity but not category-leading* on spec-driven (spec-kit owns that).

### 3.2 vs. autonomous SDLC (Devin, Factory, Cursor bg agents, Codex cloud, Copilot agent)

| Capability | compass | Devin / Factory | Cursor bg / Codex cloud |
|---|---|---|---|
| Self-fixing PR loop | ✅ | ✅ | ✅ |
| Human merge gate enforced | ✅ (spine) | 🟡 (configurable) | 🟡 |
| Cross-model audit (Claude↔Codex) | ✅ (differentiator) | 🟡 (Factory routes models) | ⬜ |
| Runs on *your* infra, keyless option | ✅ | ⬜ (SaaS) | ⬜ (SaaS) |
| Readable, `git pull`-able, no service | ✅ (differentiator) | ⬜ | ⬜ |
| Hosted dashboard / web UI | ⬜ (GitHub + statusline only) | ✅ | ✅ |
| Parallel multi-task across a repo | 🟡 (sequential pipeline) | ✅ (parallel Droids) | ✅ |
| Sandboxed cloud VM per task | ⬜ (GitHub Actions runner) | ✅ | ✅ |
| Benchmarked task success (SWE-bench-style) | ⬜ | ✅ (published) | ✅ |

**Read:** compass's differentiators are **transparency + cross-model audit +
runs-on-your-infra**. Its gaps are **no first-class UI**, **sequential not
parallel** task execution, and **no published success-rate benchmark** — the
three things the funded SaaS players lead on.

### 3.3 vs. AI review (CodeRabbit, Greptile, Qodo)

| Capability | compass | CodeRabbit | Greptile | Qodo |
|---|---|---|---|---|
| Multi-dimension PR review | ✅ (5 dims, parallel) | ✅ | ✅ | ✅ |
| Adversarial false-positive suppression | ✅ (skeptic refute) | 🟡 | 🟡 | 🟡 |
| **Whole-repo / cross-repo index (RAG)** | ⬜ | 🟡 | ✅ (full index) | ✅ (multi-repo) |
| Bundled deterministic linters (40+) | 🟡 (formatters only) | ✅ | 🟡 | ✅ |
| Auto-generate missing tests | ✅ (`test-architect`) | ⬜ | ⬜ | ✅ |
| Published bug-catch benchmark | ⬜ | ✅ | ✅ (82%) | ✅ |

**Read:** compass reviews the **diff and code it touches**; the leaders review
against a **whole-codebase index**. That's the biggest review-quality gap, and
it's the same gap as §3.1's memory gap — both are solved by *persistent
codebase context*.

---

## 4. The four gaps that matter (synthesis)

Across every category the same handful of gaps recur. In priority order:

1. **Persistent codebase/org context (RAG + memory).** Shows up as the review
   gap (Greptile/Qodo index the repo; compass sees only the diff) *and* the
   learning gap (SuperClaude/gstack remember; compass forgets between sessions).
   compass has the *design* (ADR-0001, `mcp/compass-memory/`) but it's gated off.
   **This is the single highest-leverage investment.**
2. **A visible control surface.** Everyone funded ships a UI/dashboard. compass
   deliberately uses GitHub + a statusline + mobile relays — philosophically
   sound, but "I can't *see* the fleet" is a real adoption tax. A read-only,
   zero-infra **local TUI / `compass dashboard`** closes most of this without
   betraying the no-service principle.
3. **Parallelism.** `orchestrate.sh` is strictly sequential; Factory's Droids
   and Cursor's bg agents fan out. compass already enabled
   `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` and the dynamic-workflow primitive —
   the orchestrator just hasn't adopted parallel execution yet (roadmap §3/§5b).
4. **Proof.** The funded players publish SWE-bench / bug-catch numbers. compass
   proves *cost saved* and *footguns blocked* (great!) but never *task success
   rate* or *review precision/recall*. A reproducible eval would convert
   "trust me" into "here's the number."

---

## 5. Recommendations — the path to world-class & futuristic

Grouped by horizon. Each maps to a real, shipped harness primitive (compass's
own rule), is opt-in, and leaves the human merge gate untouched.

### Now — hardening (close the trust gaps; low effort, high credibility)

- **R1 · Guardrail bypass-corpus test.** Add a table-driven test
  (`scripts/test-protect-paths.sh`) with ~40 must-block / ~20 must-allow command
  strings, wired into CI. Highest ROI item in the repo — it protects the file
  everyone trusts most.
- **R2 · Close the cheap guardrail gaps.** Add `find … -delete`, the
  `git push origin +ref:main` force form, `rm -rf` of common system dirs
  (`/usr /etc /var /bin /lib /boot`), and redirect-truncation (`> file`) of
  tracked files. Keep it honest — these are footgun coverage, not a sandbox.
- **R3 · De-dup the workflow trees.** One templated source for
  `sdlc/workflows` vs `sdlc/selfhosted` + a CI diff gate, mirroring the existing
  plugin-sync check. Removes silent drift.
- **R4 · Pin GitHub Actions + least-privilege audit.** Verify every workflow has
  a minimal top-level `permissions:` block and no untrusted
  `${{ github.event.* }}` interpolated into `run:` (script-injection class). CI
  already runs actionlint; add the permissions assertion.

### Next — close the field's lead (medium effort, high differentiation)

- **R5 · Turn on persistent context (the big one).** Promote
  `compass-memory` from ADR-scaffold to an opt-in default: a `SessionStart`
  hook injects top-relevant prior learnings; `Stop`/`SubagentStop` records
  durable ones; redaction + per-repo trust tiers already designed. Then feed the
  **review workflow** repo context too — even a lightweight `ctags`/embeddings
  index of touched-symbols' call sites closes most of the Greptile/Qodo gap
  without a hosted service.
- **R6 · `compass dashboard` (zero-infra TUI).** A read-only terminal panel
  (or a single static HTML it writes to `~/.compass/`) that renders fleet PR
  state, spend, footguns-blocked, and converge-loop status from the existing
  ledgers + `gh`. Gives the "I can see it" surface without becoming a service.
- **R7 · Parallel orchestrator.** Adopt the dynamic-workflow / agent-team
  primitive in `orchestrate.sh --team` so Review/Security/QA run concurrently
  (roadmap §3). Same gates, lower wall-clock — directly answers Factory/Cursor.
- **R8 · Publish a benchmark.** A small, reproducible eval: run the SDLC loop on
  a fixed set of seeded-bug repos, report fix-rate + review precision/recall +
  $/task, gated in CI like the router eval already is. Converts the pitch from
  adjectives to numbers.
- **R9 · Test-impact selection + diff-size routing.** Already on the roadmap
  (§10): run only tests affected by the diff; use haiku review for ≤N-line
  diffs. Pure latency/cost win.

### Futuristic — the leapfrog bets (where compass can lead, not follow)

- **R10 · "Policy-as-code" guardrails with an eval, not regex.** Evolve hooks
  from grep patterns to a small, declarative, *tested* policy file (the OWASP/
  NIST/EU-AI-Act "AI gateway guardrail" pattern the enterprise field is moving
  to) — compass already has the eval-gate muscle (`route --eval`) to make policy
  changes *measured*. This would make compass the only readable, self-hosted,
  *evaluated* guardrail layer.
- **R11 · Cross-model, cost-aware smart router (real, not keyword).** Today's
  router is a deterministic keyword matcher (good, honest, evaluated). The
  frontier (Factory, Requesty-style gateways) routes per-subtask across
  providers by measured difficulty/cost. Keep the deterministic floor; add an
  optional learned tier scored against the same evalset.
- **R12 · A "fleet brain" — org-wide learnings + auto-policy.** Once R5 memory
  exists, let the fleet *learn its own guardrails*: recurring review findings →
  a proposed `CLAUDE.md` rule or a new policy check (human-approved). This is
  the self-improving loop the "self-learning hooks" crowd is gesturing at, but
  governed and auditable.
- **R13 · Spec-kit interop.** spec-kit owns spec-driven dev and works with 30+
  agents. Rather than compete, make compass *consume* a spec-kit `spec.md`/
  `plan.md` natively in `orchestrate.sh` (compass already has `SDLC_SPEC=`). Be
  the *governance + execution* layer under the spec-driven standard.
- **R14 · Supply-chain & SBOM gate + signed Builder commits.** Already flagged
  (roadmap §11). In a world of autonomous PRs, "this fix was generated by an
  agent, here's its provenance and SBOM delta" becomes a trust differentiator no
  SaaS competitor offers transparently.

---

## 6. Findings register (code-audit pass)

> Populated from the deep read of hooks / scripts / workflows. Each item:
> `[TAG] severity — file:line — description → fix`.

_(pending — folded in from the background code-audit agent.)_

---

## 7. One-paragraph verdict

compass is on the **correct strategic axis** (configuration & governance is the
edge, not models) and its **execution rigor is top-decile** for its category —
honest, linted, evaluated, reversible. To become *world-class* it must close the
field's two structural leads — **persistent codebase/org context** (which fixes
both the review-depth and the learning gap at once) and a **visible control
surface** — while hardening the one place perception outruns reality: the
**guardrail**. To become *futuristic*, it should turn its unique muscle —
*evaluated, readable, self-hosted policy* — into a **self-improving, measured
governance layer** that the funded SaaS players structurally cannot match,
because their value is in the black box and compass's is in the daylight.
