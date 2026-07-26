<div align="center">

# 🧭 compass

### Let your coding agent off the leash — not off the rails.

Guardrails, a hard budget cap, and a self-fixing PR loop for your AI coding agent.
`eval-gated guardrails 100/100` · `a budget cap that actually halts` · `you always merge`

[![ci](https://github.com/dshakes/compass/actions/workflows/ci.yml/badge.svg)](https://github.com/dshakes/compass/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/dshakes/compass?color=8A63D2)](https://github.com/dshakes/compass/releases)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-8A63D2.svg)](docs/05-plugin.md)
[![Codex](https://img.shields.io/badge/Codex-plugin-111111.svg)](docs/05-plugin.md)
[![Gemini](https://img.shields.io/badge/Gemini-extension-4285F4.svg)](docs/05-plugin.md)
[![status: beta](https://img.shields.io/badge/status-beta-8A63D2.svg)](#safety-honesty--status)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/dshakes/compass/badge)](https://securityscorecards.dev/viewer/?uri=github.com/dshakes/compass)

### 🧭 &nbsp;[**Explore the interactive site →**](https://dshakes.github.io/compass/)

<sub>the guided tour — live demos, clickable architecture, one-click install</sub>

</div>

<p align="center">
  <a href="docs/02-cost-and-models.md" title="Live budget ceiling — docs/02-cost-and-models.md"><img src="assets/budget-real.gif" alt="Real Claude Code session with COMPASS_MAX_USD=0.05: 'run ls' executes while session cost climbs $0.09 → $0.35, then 'run git log' is BLOCKED — 'Budget ceiling reached: this session has spent ~$0.35, at or over your $0.05 cap. Stopping before it spends more.'" width="820"></a>
</p>

<p align="center"><sub><b>Real session, no edits:</b> the cost climbs to $0.35, then the next action is <b>HALTED</b> at the $0.05 cap — before it spends more.</sub></p>

**compass is a local-first config layer for Claude Code, Codex & Gemini that stops your agent from doing three things it shouldn't** — burning your budget, running unsafe commands, and merging unverified code. Set `COMPASS_MAX_USD=5` and the session hard-stops at the cap; catastrophic commands are blocked before they run — and the guardrail policy is scored **100/100 in CI against a labeled corpus, not asserted.** You install it once, and **you always merge.**

```bash
# no curl|sh, fully reversible — then just open any repo in your agent
git clone https://github.com/dshakes/compass ~/compass && cd ~/compass && ./quickstart.sh
# or, inside Claude Code:   /plugin marketplace add dshakes/compass
```

<p align="center">
  <a href="https://dshakes.github.io/compass/">🌐 Site</a> &nbsp;·&nbsp; <a href="#why-its-different--measured-not-vibes">Why it's different</a> &nbsp;·&nbsp; <a href="#-the-part-people-screenshot-it-fixes-its-own-prs">The self-fixing PR loop</a> &nbsp;·&nbsp; <a href="#loops-all-the-way-up">Loops</a> &nbsp;·&nbsp; <b><a href="#install">Install</a></b> &nbsp;·&nbsp; <a href="#whats-in-the-box">What's in the box</a> &nbsp;·&nbsp; <a href="docs/11-using-compass.md">📚 Docs</a>
</p>

---

<div align="center">

### ⭐ The part people screenshot: it fixes its own PRs.

</div>

<p align="center">
  <a href="https://github.com/dshakes/compass-loop-demo/pull/1" title="The actual PR in this recording — click through and inspect every event"><img src="assets/loop.gif" alt="Real screen recording of the loop on a live PR: the Reviewer posts Blocking findings and labels agent:needs-fix → the Builder pushes 'fix: correct off-by-one' to the PR's own branch → re-review goes clean and agent:reviewed-clean replaces agent:needs-fix. No human touched it; the merge stays yours." width="820"></a>
</p>

<div align="center">

Open a PR and compass **reviews it, security-checks it, runs the tests, cross-audits it with a second model — then pushes its own fixes until it's green.** You merge. **☝ That's a real PR** — every event above is inspectable.

**The idea in one line: the loop is the unit of work.** A one-shot agent stops at its first wrong answer. compass *loops* — **generate → test → critique → fix → repeat against a gate** — so quality comes from iteration, not one lucky prompt. → [how the loop works](docs/09-sdlc.md) · [the thesis](docs/loop-engineering.md)

</div>

---

## Why it's different — measured, not vibes

Every AI-agent config claims "safe" and "cheap." compass is the one that hands you the **number** — and lets a skeptic reproduce it in 30 seconds. Everyone has the same models; the edge is *configuration you can trust*. Five claims, five commands:

**🛡 Guardrails with a score.** Catastrophic commands and secret writes are blocked *before they run* — and the policy is eval-gated in CI, not asserted.

```bash
compass bench     # → guardrail 100% precision/recall (61-case bench corpus; a separate 147-case bypass corpus gates CI), router 96.9%
# then ask the agent to `rm -rf /` or write a .env → denied; `rm -rf ./build` → allowed
```

**🧪 Red-team resistance, measured.** Prompt-injection (direct/indirect/paste), agent-config poisoning, local safety-override, malware & insecure-code — scored against a labeled corpus that gates CI, obfuscation-resistant (`--attack`), with optional escalation to a managed guardrails backend. *A poisoned repo or web page can't quietly turn your agent against you — and you can measure how well that holds.*

```bash
compass redteam            # → injection corpus 100% P/R (99 cases) + 100% obfuscation-robust, then scans THIS repo's config/MCP/settings
compass redteam --external # → score the detectors against a public corpus we DIDN'T write (honest: 90% precision, and we tell you why recall is what it is)
```
<sub>Most tools show you 100% on their own test set. We show that too — <b>and</b> the number against someone else's corpus, because a floor you can only hit on your own cases isn't a floor.</sub>

**💸 A budget ceiling that actually stops it.** Usage trackers *report* spend; compass *enforces* it — the session is **halted before the next tool call** once your dollar cap is reached. An agent can't quietly run up a $40 bill while you're away.

```bash
export COMPASS_MAX_USD=5     # this session hard-stops at $5 — blocked, not warned
compass spend --max-usd 5    # the same ceiling on the ledger, for scheduled / fleet runs
```

**📉 Cost routing that's measured.** Cheap work goes to cheap models — **~62% cheaper than all-Opus at 96.9% routing accuracy** on the 44-case routing evalset, with the pricing table and token assumptions stated in the output. Run the number, don't take it.

```bash
compass route "redesign the auth model"    # → opus
compass route "fix a typo"                 # → haiku
compass bench                              # → routed vs all-Opus: ~62% cheaper (assumptions printed)
```

**🔏 Supply chain you can verify.** Releases carry keyless SLSA provenance — a tampered or look-alike download is rejected — and the repo publishes an OpenSSF Scorecard. And before you trust *someone else's* plugin, scan it.

```bash
compass verify                 # resolves the latest release → ✓ provenance verified
compass audit-plugin ./their-marketplace   # injection · tool-poisoning · unpinned MCP · fetch-and-execute hooks — before you install
```

<p align="center">
  <a href="docs/17-red-team.md"><img src="assets/red-team.svg" alt="compass red-team layer: untrusted input (prompt/paste · web/MCP/tool output · CLAUDE.md/AGENTS.md · .claude/settings.json) → decode &amp; normalize (base64/hex/entity/zero-width/ASCII-smuggling/homoglyph/leet) → detectors (injection · authority-spoof · MCP tool-poisoning · context-poisoning · safety-override · data/DNS exfil · malware · insecure-code · prompt-leak), eval-gated 100% P/R → warn+audit / block / optional managed backend → human merge gate." width="900"></a>
</p>

No service, no telemetry, no `--dangerously-skip-permissions`; `git pull` to update. The work it can't safely own, it hands back — **you keep the merge.**

---

## See it work

**The day-to-day feel** — guardrails, the cost-aware status line, the loop, and the crew, in ~25 seconds:

<p align="center">
  <a href="docs/11-using-compass.md"><img src="demo/preview.gif" alt="Terminal demo: compass blocks 'rm -rf /' (red) while 'rm -rf ./build' is allowed (green), shows the cost-aware status line, then the autonomous PR loop — review · security · tests · second-model audit → BLOCKING auto-fixes on the branch and re-reviews → CLEAN → you merge." width="800"></a>
</p>

**How the loop works** — review · security · tests · cross-audit run in parallel; Blocking findings get auto-fixed and re-reviewed (round-capped) until green, then it stops at you:

<p align="center">
  <a href="docs/09-sdlc.md"><img src="assets/sdlc-loop.svg" alt="Autonomous SDLC loop: push a PR → Reviewer, Auditor (second model), Security, QA run in parallel → BLOCKING labels agent:needs-fix → the Builder fixes on the branch and pushes → re-review (round cap ×3) → CLEAN → checks green → human merge gate → you merge." width="860"></a>
</p>

<p align="center"><sub>Run it locally in 30s with <code>~/compass/sdlc/orchestrate.sh "&lt;task&gt;"</code> (no tokens), or wire the GitHub loop for every PR. → <a href="docs/09-sdlc.md">how it works</a> · <a href="sdlc/SMOKETEST.md">reproduce it</a></sub></p>

And the everyday status line quietly keeps score, so you watch it earn its keep:
```text
Opus 4.8 · myrepo · main* · 45k ctx · $1.23 · 🧭 🛡1 🧹2 💡1 📉~$1.65
```
<sub>session spend, then today's compass activity: **🛡** footguns blocked · **🧹** files formatted · **💡** policy nudges · **📉~$** estimated saved vs all-Opus. Nothing leaves your machine.</sub>

---

## Loops all the way up

Autonomy here isn't one big magic button — it's the *same closed loop* applied at four scales. Each runs until a gate says "done," then stops at a human. That's the whole trick: **iteration under a gate beats a single confident guess.**

| | Loop | What it drives | Where it stops |
|---|---|---|---|
| 🔁 | **The task loop** | generate → test → critique → fix → repeat — one change driven to green | when tests + review pass |
| 🔎 | **The review loop** | review → auto-fix the Blocking findings → re-review, round-capped (×3) | hands off to a human if still red |
| 🩺 | **The CI-fix loop** | any check suite goes red → failure log + auto-fix on the PR; main goes red → one free rerun, then a `ci-fix/*` PR | round cap → a human; never merges |
| 🛰️ | **The fleet loop** | the whole pipeline, scheduled across *every repo you own*, overnight, test-gated | a PR per repo, **approve from your phone** |
| 👥 | **The workflow loops** | parallel agents that fan out, fact-check each other, and converge | one synthesized answer |

A loop that runs while you sleep is five moves — **discovery → handoff → verification → persistence → scheduling** — and compass ships a primitive for each. It also guards the four costs a loop runs up *silently* (verification debt, comprehension rot, cognitive surrender, token blowout): an independent evaluator that assumes broken and *runs* it, `compass digest` to keep you understanding what merged, the permanent human gate, and per-day + live budget caps. → [the five moves & four guards](docs/20-loops.md) · [the thesis](docs/loop-engineering.md)

Every loop ends the same way — **you merge.** That gate never moves.

---

## Install

**Pick the door that fits — all reversible, version-pinnable, no `curl | sh`.** You need an AI assistant ([Claude Code](https://code.claude.com); Codex/Gemini optional) + `git`. No API keys for the manual, guardrails, crew, and CLI; the [autonomous PR loop and fleet](docs/09-sdlc.md) need model auth when you opt in.

**🍺 Homebrew** — managed & versioned
```bash
brew install dshakes/tap/compass         # latest release · --HEAD to track main
compass quickstart                       # previews, asks, then wires it into ~/.claude
```

**📦 Git clone** — own & edit your config *(recommended)*
```bash
git clone https://github.com/dshakes/compass ~/compass && cd ~/compass
git checkout "$(git describe --tags --abbrev=0)"   # optional: pin to the latest release
./quickstart.sh          # previews every change, asks first, fully reversible
```

**🧩 Claude Code plugin** — no terminal *(ideal for a team)*
```text
/plugin marketplace add dshakes/compass
/plugin install compass@compass
```

**🛠️ By hand:** `make dry-run` (preview) → `make install` → `make doctor`. → [Team rollout](docs/05-plugin.md)

> **What install actually does:** replaces your global `~/.claude` config (settings, `CLAUDE.md`, agents, skills, hooks…) with symlinks into the repo — so `git pull`/`brew upgrade` updates everything. Anything it replaces is **backed up first** to `~/.claude/backups/`; `--copy` copies instead of linking; `make uninstall` removes only what it added. Personal overrides (your model, plugins, UI prefs) live in `claude/settings.local.json` — gitignored, deep-merged at install, so your prefs never fight the shipped defaults.

### One config, every agent

| Agent | Native install (no terminal) | or own the files |
|---|---|---|
| **Claude Code** | `/plugin marketplace add dshakes/compass` → `/plugin install compass@compass` | `make install` |
| **Codex** | `codex plugin marketplace add dshakes/compass` → `/plugin install` | `make install` (`~/.codex/AGENTS.md` + `config.toml`) |
| **Gemini CLI** | `gemini extensions install https://github.com/dshakes/compass` | `./install.sh --gemini` (`~/.gemini/GEMINI.md`) |
| **Cursor · Copilot · OpenCode · Windsurf** | read the repo's `AGENTS.md` ([AGENTS.md](https://agents.md/) standard) | clone + `make install` |

`CLAUDE.md` · `AGENTS.md` · `GEMINI.md` are **one file** (symlinks), and the plugin/extension manifests are generated from one source and CI-checked (`scripts/check-vendor.sh`) — a `git pull` updates every agent at once and a manifest can't drift. The manifests are structure-validated in CI; the live `gemini extensions install` / `codex plugin marketplace add` paths are verified manually (those CLIs aren't in the runner).

**Enforcement, not just the manual.** Claude Code gets the full hook layer (guardrails, budget gate, scans). For everything else — Codex, Gemini, Cursor, any SDK — the **budget cap travels via `compass gate`**, a localhost proxy you point `ANTHROPIC_BASE_URL`/`OPENAI_BASE_URL` at, so the hard dollar ceiling holds for any agent, not only the one with hooks. → [02-cost](docs/02-cost-and-models.md)

### ✅ Verify → your first run
```bash
compass doctor      # validate the install — expect "0 error"
compass status      # is compass active here, and what's loaded?
```
Then open your agent as usual. Feel it in a minute: ask for a dangerous command (blocked), run `/review` on your diff, or `compass route "<task>"` to see the tier it picks. No tokens, no signup.

---

## What's in the box

Everything below is **on after one install** or a single opt-in — the autonomous loops sit on top. Each row links to the detail.

| | Capability | One line | Deep dive |
|---|---|---|---|
| 🔁 | **Autonomous SDLC** | the review → security → tests → cross-audit → **auto-fix → re-review** loop; you merge | [09-sdlc](docs/09-sdlc.md) |
| 🩺 | **CI auto-fix** | no CI failure goes unhandled: red PR checks feed the fix loop; red main gets one free rerun, then a `ci-fix/*` PR | [09-sdlc](docs/09-sdlc.md) |
| 🔄 | **Loop engineering** | the five moves wired up: `morning-triage` discovery · `pr-shepherd` PR handoff → merge gate · an acting/skeptic evaluator · `compass digest` · per-day budget cap | [20-loops](docs/20-loops.md) |
| 🛰️ | **The fleet** | the loop, scheduled across *all* your repos through a test gate; approve from your phone | [14-fleet](docs/14-fleet.md) |
| 👥 | **The crew + workflows** | cost-tiered expert subagents · slash-commands · dynamic workflows that fact-check each other | [agents roster](docs/agents-roster.md) · [12](docs/12-every-agent.md) · [13](docs/13-workflows.md) |
| 🛡 | **Guardrails & scanning** | a hook layer that blocks disasters, catches secrets (write-hook + `compass scan`), auto-formats, keeps a JSONL audit log | [16-hardening](docs/16-hardening-and-frontier.md) |
| 🧪 | **Red-team hardening** | eval-gated defense vs prompt-injection, config poisoning, safety-override, malware & insecure code | [17-red-team](docs/17-red-team.md) |
| 🧭 | **Cost-tier router** | a standalone, reusable module — keyword heuristic → optional classifier → judge cascade; eval-gated | [router/](router/) |
| 🧰 | **The compass CLI** | `onboard · impact · drift · scan · redteam · audit-plugin · gate · sandbox · verify · audit-log · spend · dashboard` | [11-using](docs/11-using-compass.md) |
| 🚦 | **Cross-agent enforcement** | `compass gate` — a localhost proxy that hard-caps spend for Codex/Gemini/any SDK, not just Claude Code | [02-cost](docs/02-cost-and-models.md) |
| 🔍 | **Plugin-security scanner** | `compass audit-plugin` — vet a third-party plugin/marketplace (injection · tool-poisoning · unpinned MCP · fetch-exec) before you install it | [17-red-team](docs/17-red-team.md) |
| 🔌 | **MCP + LSP** | curated, **version-pinned** MCP servers + opt-in language-server intelligence | [04](docs/04-mcp.md) · [06](docs/06-lsp.md) |
| 🪪 | **Every agent, one source** | Claude Code · Codex · Gemini — plus Cursor/Windsurf/Copilot via the [`AGENTS.md`](https://agents.md/) standard | [12-every-agent](docs/12-every-agent.md) |
| 💸 | **Live budget ceiling** | a hard cap that halts the session before the next tool call (`COMPASS_MAX_USD`), plus a per-day cap for unattended loops | [02-cost](docs/02-cost-and-models.md) |

---

## Safety, honesty & status

Built to be **trusted before it's run** — and honest about its limits.

- **You own the irreversible.** Agents prepare; humans push, merge, deploy. Required checks + code-owner approval enforce it.
- **Readable & reversible.** No `curl | sh`; the installer backs up what it replaces and `make uninstall` removes only what it added. Pin a tag, not `main`.
- **Guardrails reduce footguns; they are not a security boundary.** Keep least-privilege credentials and review your diffs. For untrusted code, `compass sandbox` is a real boundary. Red-team hardening is defense-in-depth, not immunity — the cardinal rule (external content is data, not instructions) and the human gate are what actually hold.
- **What talks to the network.** compass phones home to nothing. The pinned MCP servers reach the endpoints you'd expect (library docs, URLs you request); hooks are short, commented shell scripts in `claude/hooks/` — disable any in your settings.

> **Status: beta.** The core — manual, hooks, subagents, commands, MCP, plugin — is stable, dogfooded daily, and eval-gated in CI (guardrails + red-team scored on labeled corpora; run `compass bench` yourself). The **SDLC pipeline** is newer: statically validated in CI, exercised via a smoke-test you run on your own repo. Managed-guardrail adapters are contract-tested, with live cloud-backend calls unverified in CI (need your creds). **Dynamic workflows** are a research preview. The human merge/deploy gate is permanent, by design. → [full details](docs/17-red-team.md)

---

## Docs

**[Start here → Using compass](docs/11-using-compass.md)** — install, the pieces in plain language, the daily workflow.
**[The thesis → Loop engineering](docs/loop-engineering.md)** — why iteration-under-a-gate beats a one-shot guess.
**[In practice → The five moves](docs/20-loops.md)** — each move of a self-running loop, mapped to the primitive that builds it.

[Philosophy](docs/00-philosophy.md) · [Architecture](docs/01-architecture.md) · [Cost & models](docs/02-cost-and-models.md) · [Customize](docs/03-customize.md) · [MCP](docs/04-mcp.md) · [Plugin & team rollout](docs/05-plugin.md) · [LSP](docs/06-lsp.md) · [Practices](docs/07-practices.md) · [Defaults](docs/08-defaults.md) · [SDLC](docs/09-sdlc.md) · [Roadmap](docs/10-roadmap.md) · [Every agent](docs/12-every-agent.md) · [Workflows](docs/13-workflows.md) · [Fleet](docs/14-fleet.md) · [Competitive audit](docs/15-competitive-audit.md) · [Hardening](docs/16-hardening-and-frontier.md) · [Red-team](docs/17-red-team.md) · [Benchmark](docs/18-benchmark.md) · [Provenance](docs/19-provenance.md) · [Loops](docs/20-loops.md) · [Run any framework](docs/21-run-any-framework.md) · [Agents roster](docs/agents-roster.md) · [Router module](router/README.md) · [ADRs](docs/adr/)

<div align="center"><br><sub>MIT · built to be shared · contributions welcome</sub></div>
