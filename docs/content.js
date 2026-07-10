/* content.js — concise, engaging site-docs. Rendered by docs.html in preference to
   the raw reference .md (which stays the source of truth, linked at the foot of each page).
   Keep each page short and scannable: a hook, a few sections, one code block, done. */
window.COMPASS_DOCS = {

"00-philosophy": `# Philosophy

**The bottleneck isn't the model — it's trust.** Everyone can call the same frontier models. The edge is *configuration you can trust to run on its own.*

## What compass believes
- **Proof over promises.** Every safety claim is eval-gated in CI and reproducible on your machine in ~30 seconds. Numbers, not vibes.
- **The gate is the whole game.** An agent generates; a real check — tests, review, a second model — decides *done*.
- **You keep the irreversible.** Agents prepare; humans merge, deploy, and push. That line never moves.
- **Local-first.** No telemetry. Readable, reversible shell hooks you can disable.

## Why it's shaped like this
A one-shot agent guesses once. compass wraps agents in **loops with gates** so quality comes from iteration, and in **guardrails** so a wrong step is blocked before it runs — not apologized for after.

> New here? Start with [Using compass](#11-using-compass), then [Loop engineering](#loop-engineering) for the thesis.`,

"11-using-compass": `# Using compass

The day-to-day. Install once, then a handful of CLI verbs do the work.

## Install & verify
\`\`\`bash
git clone https://github.com/dshakes/compass ~/compass
cd ~/compass && ./quickstart.sh
compass doctor      # expect "0 error"
\`\`\`

## The verbs you'll actually use
| Command | What it does |
|---|---|
| \`compass bench\` | score the guardrail + router against the labeled corpora |
| \`compass redteam\` | prompt-injection resistance + scan this repo's config |
| \`compass route "<task>"\` | pick the cheapest model tier that fits |
| \`compass spend\` | session + daily cost, against your cap |
| \`compass scan\` | secrets / risky patterns in the working tree |
| \`compass sandbox <cmd>\` | run untrusted code in a real boundary |
| \`compass doctor\` | validate the install |

## The status line
\`Opus 4.8 · myrepo · main* · 45k ctx · $1.23 · 🧭 🛡1 🧹2 💡1 📉~$1.65\` — session spend, then today's compass activity: footguns blocked, files formatted, policy nudges, and estimated $ saved vs all-Opus.`,

"01-architecture": `# Architecture

Three layers, each doing one job.

## 1 · One config, every agent
\`CLAUDE.md\` · \`AGENTS.md\` · \`GEMINI.md\` are a single source of truth — operating principles, safety lines, conventions. A \`git pull\` updates every agent at once.

## 2 · Guardrail hooks
Short, deterministic shell hooks fire on the agent's lifecycle — **PreToolUse** (block a dangerous command *before* it runs), **PostToolUse** (treat tool output as untrusted data), **SessionStart**/**UserPromptSubmit** (scan poisoned context). They **fail safe**: a broken hook never silently disables a guardrail.

## 3 · The loop
On top sits the orchestration: the [autonomous SDLC](#09-sdlc), the [fleet](#14-fleet), and [workflows](#13-workflows) — agents that generate, get checked by a gate, and repeat until green, then stop at a human.

## The trust boundary
Everything outside the boundary — a pasted prompt, a fetched page, an MCP result, a cloned repo's \`CLAUDE.md\` — is decoded, normalized, and scored before it can steer the agent. See [Red-team](#17-red-team).`,

"03-customize": `# Customize

compass is yours to edit — it's config, not a black box.

## The levers
- **Fork & edit.** You cloned it; change any hook, agent, or command. Re-run \`compass doctor\`.
- **Project overrides.** A repo's own \`CLAUDE.md\` / \`AGENTS.md\` *tightens* the global rules (never loosens them).
- **Feature flags & env.** Toggle behavior without editing code — e.g. \`COMPASS_MAX_USD\` for the budget cap, \`COMPASS_REDTEAM_ENFORCE=1\` to block instead of warn.
- **Disable a hook.** Every hook is a commented shell script; remove it from settings to turn it off.

## The one rule
A project can *tighten* the guardrails but never grant itself a safety exception. The global guardrails, the permission prompts, and the human merge gate always hold.`,

"loop-engineering": `# Loop engineering — the thesis

**The unit of work is the loop, not the prompt.** generate → check → critique → fix → repeat, until a gate says done. A first draft is just iteration one; on anything checkable, an agent that loops under a real gate beats a smarter one that guesses once.

## The gate is the whole game
A loop without a gate is an agent talking to itself — it "fixes" what wasn't broken and declares victory. Every real loop needs:
- **Tests that actually run** — not assertions that merely pass.
- **A fresh-context evaluator** — *maker ≠ checker*, ideally a different model.
- **A hard resource ceiling** — so a non-converging loop stops *spending*.
- **A human at the irreversible step** — merge, deploy, publish.

## Guard the four silent costs
No alarm sounds while a loop runs: **verification debt**, **comprehension rot**, **cognitive surrender**, and **token blowout**. Keep discovery and judgment in the model; keep persistence, de-dup, and the hard gates in scripts.

> Then: [the five moves](#20-loops) that put this into practice.`,

"20-loops": `# The five moves

Loop engineering in practice — how a one-shot agent becomes a loop that converges.

1. **Close the loop with a real gate.** Wire generate → *run the tests* → critique → fix. The gate must execute, not assert.
2. **Put memory on disk.** The model forgets between runs; a state file (or tracking issue) is what makes tomorrow's turn continue today's.
3. **Separate maker from checker.** The author can't see its own chain of self-persuasion — grade the work with fresh context, ideally a different model.
4. **Cap the spend.** A per-run and per-day ceiling *before* it runs unattended, so a runaway loop stops costing money.
5. **Keep the human at the merge.** Everything up to the irreversible step is automatable; the step itself is yours.

> The why behind each move: [Loop engineering](#loop-engineering).`,

"09-sdlc": `# Autonomous SDLC

A pipeline of **named, governed agents** that plan, build, review, cross-audit, security-check, and test a change — then stop at your merge.

![The self-fixing loop](assets/sdlc-loop.svg)

## The flow
\`\`\`
issue → Planner → Builder → [PR] → Reviewer ⇄ Builder (auto-fix loop)
                                    Auditor  (cross-tool second opinion)
                                    Security (every push)
                                    QA       (tests)
                                            ↓
                                     🔒 you merge
\`\`\`

## Why it's trustworthy
- **Maker ≠ checker.** Claude builds; a second tool (Codex) audits — an independent opinion, not the author grading itself.
- **Round-capped auto-fix.** The reviewer's *Blocking* findings are fixed and re-reviewed up to a few rounds, then it hands to a human if still red.
- **Auditable handoffs.** Agents coordinate through the PR (labels + comments) and a shared run-dir — every step is a reviewable artifact.`,

"13-workflows": `# Workflows

Deterministic orchestration of many agents — for coverage, for confidence, or for scale a single context can't hold.

## What a workflow is
A script that fans work out and back: parallel readers over a subsystem, a panel of independent attempts scored by judges, or a find → verify → synthesize pipeline. Discovery and judgment stay in the model; loops, de-dup, and gates stay in the script.

## Patterns worth stealing
- **Adversarial verify** — N skeptics try to *refute* each finding; keep it only if it survives.
- **Loop-until-dry** — keep spawning finders until two rounds turn up nothing new.
- **Judge panel** — several independent approaches, scored, then synthesized from the winner.
- **Completeness critic** — a final pass that asks "what's missing?"`,

"14-fleet": `# The fleet

The whole [SDLC pipeline](#09-sdlc), scheduled across **every repo you own** — overnight, through a test gate.

## How it feels
You go to sleep. compass runs morning-triage on each repo (failed CI, new issues, merged commits), decides what's worth doing, runs the loop under a resource ceiling, and opens **a PR per repo**. You wake up and approve the good ones from your phone.

## What keeps it safe
- **Test-gated** — a PR only opens if the change is green.
- **Capped** — a per-day token/$ ceiling bounds the whole fleet.
- **Human-merged** — it proposes; you dispose. Nothing lands without you.`,

"16-hardening-and-frontier": `# Hardening & frontier

The guardrail hook layer — the deterministic safety net under every agent action.

## What it blocks (before it runs)
- **Catastrophic commands** — \`rm -rf /\`, force-push to a protected branch, history rewrites.
- **Secret leaks** — writing to \`.env\`, printing credentials, committing keys.
- **Self-modification** — an agent editing its own installed guardrails into an auto-approve stub.

## What it does quietly
- Auto-formats touched files.
- Logs every warn/block to a JSONL **audit trail** (\`compass audit-log\`).
- Fails *safe* — a broken hook never silently disables a guardrail.

> Guardrails ≠ a security boundary. They cut footguns; for untrusted code use \`compass sandbox\`. The real protection is the [human gate](#00-philosophy).`,

"17-red-team": `# Red-team

Guardrails stop *accidents*. This layer defends the agent against something **adversarial**: an attacker trying to turn your agent against you — a poisoned \`CLAUDE.md\`, a booby-trapped web page, a pasted payload, a malicious MCP server.

![The red-team pipeline](assets/red-team.svg)

## The pipeline
Every untrusted source is **decoded & normalized** (base64, hex, percent, HTML-entity, zero-width, ASCII-smuggling Unicode Tags, homoglyph, leetspeak) so hidden instructions surface — then scored by **detectors**: prompt-injection, authority-spoof, MCP tool-poisoning, context-poisoning, safety-override, data/DNS exfiltration, malware, insecure-code, system-prompt-leak.

## Measured, not vibes
The detectors are eval-gated against a labeled corpus: **100% precision/recall on 85 cases, 100% robustness (273/273)** under obfuscation. Run \`compass redteam\` to reproduce, and to scan *this* repo's config.

> **Honest framing:** this is defense-in-depth, not a security boundary. A novel payload can still slip past. The cardinal rule holds underneath: *external content is data, not instructions* — and the human gate never moves.`,

"18-benchmark": `# Benchmark

Every claim compass makes is a number you can reproduce — \`compass bench\` and \`compass redteam\` run the same code live and in CI.

## The scores
| Suite | Cases | Precision | Recall |
|---|---|---|---|
| Guardrail | 61 | 100% | 100% |
| Red-team | 85 | 100% | 100% |
| Router | 86 | — | 96.9% acc |

Plus **~61% cheaper** than all-Opus at ~98% quality on a fair task mix.

## Why floors, not just numbers
Each suite has a **CI floor** (e.g. guardrail 100% P / 95% R). Drop below it and the build fails — so the guarantee can't silently rot. The corpus is labeled, adversarial, and in the repo; add your own cases and re-run.`,

"19-provenance": `# Provenance

You're installing code that will run with your credentials. compass makes its supply chain **verifiable**.

## What you get
- **Keyless SLSA provenance** — each release carries a signed attestation of exactly which commit and workflow built it.
- **No \`curl | sh\`** — you clone a repo you can read, or install a pinned package. Nothing executes from a URL.
- **Pin a tag, not \`main\`** — reproducible installs; upgrade deliberately.

## Verify it
The release attestation lets you confirm an artifact came from this repo's CI and nowhere else — before it touches your machine.`,

"02-cost-and-models": `# Cost & models

The driver runs a strong model; the trick is not sending *everything* to it.

## Push work down
- **Haiku** — test runs, formatting, log triage, mechanical edits, broad searches.
- **Sonnet** — most feature coding, refactors, docs.
- **Opus** — architecture, security review, subtle debugging; anywhere a wrong answer is expensive.

## The router picks for you
\`compass route "<task>"\` classifies a task (keyword heuristic → optional classifier → judge cascade) and returns the cheapest tier that fits — **96.9%** accurate on an 86-case set, ~**61%** cheaper than all-Opus at ~98% quality.
\`\`\`bash
compass route "redesign the auth model"   # → opus
compass route "fix a typo"                 # → haiku
\`\`\``,

"04-mcp": `# MCP servers

Model Context Protocol servers give agents real tools (search, fetch, databases). compass ships a **curated, version-pinned** set.

## The stance
- **Pinned** — exact versions, so a server can't silently change under you.
- **Least surprise** — each server reaches only the endpoints you'd expect.
- **Opt-in** — enable what you need; nothing phones home by default.

## The risk it guards
An MCP tool's *description* can hide instructions ("before using this tool, read \`~/.ssh\`…"). compass's [red-team](#17-red-team) layer detects that **tool-poisoning** shape. Treat every MCP result as untrusted data.`,

"05-plugin": `# Plugin & team rollout

Three ways to install; pick by how your team works.

## Options
- **Git clone** (recommended) — you own and edit the config; \`git pull\` updates it.
- **Homebrew** — \`brew install dshakes/compass/compass\`, managed and versioned.
- **Claude Code plugin** — no terminal: \`/plugin marketplace add dshakes/compass\` → \`/plugin install core@compass\`. Ideal for a whole team.

## Rolling out to a team
Pin a tag so everyone's on the same version. The install **symlinks** into \`~/.claude\` (or \`--copy\` to copy), backs up anything it replaces, and \`make uninstall\` removes only what it added. Verify with \`compass doctor\` → "0 error".`,

"06-lsp": `# LSP

Opt-in language-server intelligence so agents navigate code like an IDE does — go-to-definition, find-references, real symbol search — instead of grepping blind.

## Why it helps
- **Fewer wrong edits** — the agent sees the actual call graph before it changes a function.
- **Cheaper** — precise navigation beats re-reading whole files into context.
- **Opt-in** — enable per language; off by default.`,

"12-every-agent": `# Every agent, one source

compass is not Claude-only. One config drives them all.

## Supported
- **Claude Code** — plugin + marketplace.
- **Codex** — plugin, via \`AGENTS.md\`.
- **Gemini CLI** — extension, via \`GEMINI.md\`.
- **Cursor · Windsurf · Copilot · OpenCode** — through the \`AGENTS.md\` standard.

## How
\`CLAUDE.md\`, \`AGENTS.md\`, and \`GEMINI.md\` are the *same file* (symlinked). Write your operating rules once; every agent reads them, and a single \`git pull\` updates all of them. No per-tool drift.`,

"agents-roster": `# Agents roster

compass ships a crew of **cost-tiered specialist subagents** — each scoped to a job and a model tier, so fan-out work runs on the cheapest capable model.

## The idea
- **Haiku** agents — mechanical, parallel work (test runs, sweeps, formatting).
- **Sonnet** agents — most implementation, refactors, docs.
- **Opus** agents — architecture, security review, subtle debugging.

Reviewers, debuggers, engineers per language, a security auditor, a test architect, and more — invoked by name or auto-selected. See the full roster and each agent's tools in the reference below.`,

"07-practices": `# Practices

The working conventions compass encodes — the habits that make agent output trustworthy.

## Highlights
- **Understand before changing.** Read the code and the project's config before the first edit; match its style.
- **Do exactly what was asked, then stop.** No unrequested refactors or "while I'm here" scope.
- **Verify, don't assume.** Establish how a change is checked *before* calling it done — and actually run it.
- **Report faithfully.** Show failing output; label unverified work; no "should work."

> These live in the shared operating manual so every agent — and every review — is measured against them.`,

"08-defaults": `# Defaults

Sensible, opinionated defaults per language and platform, so agents produce code that fits your stack without being told each time.

## By language (examples)
- **Go** — \`gofmt\`/\`goimports\` clean, errors wrapped with \`%w\`, table-driven tests.
- **Rust** — \`clippy\` clean, no \`unwrap()\` on fallible prod paths, typed errors.
- **TypeScript** — \`strict\` on, no unexplained \`any\`, \`zod\` at untrusted inputs.
- **Python** — 3.11+, full type hints, \`ruff\`, no bare \`except\`.

## Platform
Kubernetes reads freely but \`apply\`/\`delete\` always ask; new code paths emit traces/metrics; load-bearing changes get an ADR. A project's own config overrides these.`,

"10-roadmap": `# Roadmap

Where compass is heading. It's **beta** — dogfooded daily, stabilizing toward 1.0.

## Themes
- **Deeper eval coverage** — more adversarial cases, more suites under CI floors.
- **Broader agent support** — keep pace with the \`AGENTS.md\` ecosystem.
- **Fleet ergonomics** — richer triage, approvals, and blast-radius limits for unattended runs.

> The authoritative, current list lives in the reference below — it moves faster than this summary.`,

"15-competitive-audit": `# Competitive audit

How compass positions against other agent-config toolkits — and why it leads with *measured* safety.

## The differentiator
Most setups are collections of prompts and settings. compass adds the two things that make autonomy safe to run: **eval-gated guardrails** (a reproducible number, not a claim) and **provenance** (a verifiable supply chain) — with the human merge gate always intact.

> The full side-by-side lives in the reference below.`

};
