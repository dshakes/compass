<div align="center">

# 🧭 compass

### The trust layer for Claude Code, Codex & Gemini — measured, not vibes.

Anyone can say "safe" and "cheap." compass hands you the number — and lets you reproduce it in 30 seconds: guardrails **100/100** on a 61-case bypass corpus, a router measured **~61% cheaper** than all-Opus at ~98% quality, **signed releases you verify** in one command. One config you own for every agent, in every repo — not a service. No `curl | sh`, no telemetry. **You always merge.**

*In plain terms: a tireless senior teammate for your AI coding agents — it reviews and fixes its own work, spends your money wisely, refuses the dangerous stuff, and still can't ship anything without your yes.*

[![ci](https://github.com/dshakes/compass/actions/workflows/ci.yml/badge.svg)](https://github.com/dshakes/compass/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/dshakes/compass?color=8A63D2)](https://github.com/dshakes/compass/releases)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-8A63D2.svg)](docs/05-plugin.md)
[![AGENTS.md](https://img.shields.io/badge/AGENTS.md-compatible-2ea44f.svg)](https://agents.md/)
[![status: alpha](https://img.shields.io/badge/status-alpha-orange.svg)](#safety-honesty--status)

</div>

<p align="center">
  <a href="docs/01-architecture.md" title="placeholder link — repoint to a demo/video/landing"><img src="assets/explainer.svg" alt="compass in three beats: ONE CONFIG (install once) → EVERY AGENT (Claude Code · Codex · Gemini · Cursor, one AGENTS.md, no drift) → AUTONOMOUS PRs (reviews · fixes itself · you merge). All opt-in: guardrails · red-team hardening · cost-tiered router · subagents/commands/MCP · scheduled fleet · human merge gate." width="900"></a>
</p>

<p align="center">
  <a href="#-the-part-people-screenshot-it-fixes-its-own-prs">▶ Watch it fix its own PR</a> &nbsp;·&nbsp; <a href="#why-its-different--measured-not-vibes">Why it's different</a> &nbsp;·&nbsp; <a href="#loops-all-the-way-up">The loops</a> &nbsp;·&nbsp; <b><a href="#install">Install</a></b> &nbsp;·&nbsp; <a href="#whats-in-the-box">What's in the box</a> &nbsp;·&nbsp; <a href="docs/11-using-compass.md">📚 Docs</a>
</p>

---

<div align="center">

### ⭐ The part people screenshot: it fixes its own PRs.

Open a pull request and compass **reviews it, security-checks it, runs the tests, cross-audits it with a second model — then pushes its own fixes until it's green.** You just merge.

**The idea in one line: the loop is the unit of work.** A one-shot agent stops at its first wrong answer. compass *loops* — **generate → test → critique → fix → repeat against a gate** — so quality comes from iteration, not one lucky prompt. The same closed loop runs a single PR, or your whole fleet of repos overnight. *(Try it locally in 30s, no tokens — [watch it ↓](#see-it-work).)*

</div>

---

## Why it's different — measured, not vibes

Every AI-agent config claims "safe" and "cheap." compass is the one that hands you the **number** — and lets a skeptic reproduce it in 30 seconds. Everyone has the same models; the edge is *configuration you can trust*, not another feature list. Four claims, four commands:

**🛡 Guardrails with a score.** Catastrophic commands and secret writes are blocked *before they run* — and the policy is eval-gated, not asserted. *(In human terms: it won't let the agent delete your machine or leak your keys, and it can prove how well.)*

```bash
compass bench     # → guardrail 100% precision/recall (61-case corpus), router 96.9% — in CI
# then ask the agent to `rm -rf /` or write a .env → denied; `rm -rf ./build` → allowed
```

**📉 Cost routing that's measured.** Cheap work goes to cheap models — scored against an eval set, ~61% cheaper than all-Opus at ~98% quality on a fair mix. *(In human terms: it stops paying Opus prices to fix a typo.)*

```bash
compass route "redesign the auth model"   # → opus
compass route "fix a typo"                 # → haiku
```

**🔏 Supply chain you can verify.** Releases carry keyless SLSA provenance, so a tampered or look-alike download is rejected. *(In human terms: you can prove the code you installed is the code I shipped.)*

```bash
compass verify v0.16.0     # → ✓ provenance verified
```

**🧪 Red-team resistance, measured.** Prompt-injection (direct/indirect/paste), CLAUDE.md poisoning, local safety-override, malware & insecure-code — scored against a labeled corpus that gates in CI, with optional escalation to a managed guardrails service (webhook · Bedrock · Azure). *(In human terms: a poisoned repo or web page can't quietly turn your agent against you.)*

```bash
compass redteam   # → injection corpus 100% P/R, then scans THIS repo's CLAUDE.md/MCP/settings
```

<p align="center">
  <a href="docs/17-red-team.md" title="placeholder link — repoint to a demo/video/landing"><img src="assets/red-team.svg" alt="compass red-team layer: untrusted input (prompt/paste · web/MCP/tool output · CLAUDE.md/AGENTS.md · .claude/settings.json) → decode &amp; normalize (base64/zero-width/homoglyph/leet) → detectors (injection · context-poisoning · safety-override · malware · insecure-code · prompt-leak), eval-gated 100% P/R → warn+audit / block / optional webhook·Bedrock·Azure → human merge gate." width="900"></a>
</p>

No service, no telemetry, no `--dangerously-skip-permissions`; `git pull` to update. The work it can't safely own, it hands back — **you keep the merge.**

---

## See it work

Three views, smallest leap of faith first — **feel it**, then **see the proof**, then **see how it works.**

**1 · The day-to-day feel** — guardrails, the cost-aware status line, the loop, and the crew, in ~25 seconds:

<p align="center">
  <a href="docs/11-using-compass.md" title="placeholder link — repoint to a demo/video/landing"><img src="demo/preview.gif" alt="Terminal demo: compass blocks 'rm -rf /' (red) while 'rm -rf ./build' is allowed (green), shows the cost-aware status line, then the autonomous PR loop — review · security · tests · Codex audit → BLOCKING auto-fixes on the branch and re-reviews → CLEAN → you merge." width="800"></a>
</p>

**2 · The headline, on a real PR** — a Blocking bug and red tests, and it pushes its *own* fix until the PR is green (then waits for you):

<p align="center">
  <a href="docs/09-sdlc.md" title="placeholder link — repoint to a demo/video/landing"><img src="assets/loop.gif" alt="The loop on a real PR: Reviewer flags a bug as Blocking + QA red → the Builder pushes a fix commit → re-review goes CLEAN, QA green → mergeable, awaiting your code-owner approval." width="820"></a>
</p>

**3 · How that loop works** — review · security · tests · Codex cross-audit run in parallel; Blocking findings get auto-fixed and re-reviewed (round-capped) until green, then it stops at you:

<p align="center">
  <a href="docs/09-sdlc.md" title="placeholder link — repoint to a demo/video/landing"><img src="assets/sdlc-loop.svg" alt="Autonomous SDLC loop: push a PR → Reviewer, Auditor (Codex), Security, QA run in parallel → BLOCKING labels agent:needs-fix → the Builder fixes on the branch and pushes → re-review (round cap ×3) → CLEAN → checks green → human merge gate → you merge." width="860"></a>
</p>

<p align="center"><sub>Run it locally in 30s with <code>~/compass/sdlc/orchestrate.sh "&lt;task&gt;"</code> (no tokens), or wire the GitHub loop for every PR. → <a href="docs/09-sdlc.md">how it works</a> · <a href="sdlc/SMOKETEST.md">reproduce it</a></sub></p>

And the everyday status line quietly keeps score, so you watch it earn its keep:
```text
Opus 4.8 · myrepo · main* · 45k ctx · $1.23 · 🧭 🛡1 🧹2 💡1 📉~$1.65
```
<sub>session spend, then today's compass activity: **🛡** footguns blocked · **🧹** files formatted · **💡** policy nudges · **📉~$** estimated saved vs all-Opus. Each piece shows only when there's something to report; nothing leaves your machine.</sub>

---

## Loops all the way up

Autonomy here isn't one big magic button — it's the *same closed loop* applied at four scales. Each runs until a gate says "done," then stops at a human. That's the whole trick: **iteration under a gate beats a single confident guess.**

| | Loop | What it drives | Where it stops |
|---|---|---|---|
| 🔁 | **The task loop** | generate → test → critique → fix → repeat — one change driven to green | when tests + review pass |
| 🔎 | **The review loop** | review → auto-fix the Blocking findings → re-review, round-capped (×3) | hands off to a human if still red |
| 🛰️ | **The fleet loop** | the whole pipeline, scheduled across *every repo you own*, overnight, test-gated | a PR per repo, **approve from your phone** |
| 👥 | **The workflow loops** | parallel agents that fan out, fact-check each other, and converge | one synthesized answer |

Every loop ends the same way — **you merge.** That gate never moves.

<p align="center">
  <a href="docs/14-fleet.md" title="placeholder link — repoint to a demo/video/landing"><img src="assets/fleet.svg" alt="The fleet: a scheduler fans governed agents across many repos in parallel; each runs the review → test → fix loop on its own branch, opens a PR, and waits at the human approval gate — approvable from your phone." width="860"></a>
</p>

---

## Install

**Pick the door that fits — all reversible, version-pinnable, no `curl | sh`.** You need an AI assistant ([Claude Code](https://code.claude.com); Codex/Gemini optional) + `git`. No API keys to get the manual, guardrails, crew, and CLI.

**🍺 Homebrew** — managed & versioned
```bash
brew tap dshakes/compass https://github.com/dshakes/compass
brew install dshakes/compass/compass     # latest release · --HEAD to track main
compass quickstart                       # previews, asks, then wires it into ~/.claude
```

**📦 Git clone** — own & edit your config *(recommended)*
```bash
git clone https://github.com/dshakes/compass ~/compass && cd ~/compass
git checkout v0.16.0     # optional: pin to a release instead of main
./quickstart.sh          # previews every change, asks first, fully reversible
```

**🧩 Claude Code plugin** — no terminal *(ideal for a team)*
```text
/plugin marketplace add dshakes/compass
/plugin install core@compass
```

**🛠️ By hand:** `make dry-run` (preview) → `make install` → `make doctor`. Symlink install means `git pull`/`brew upgrade` updates everything; `make uninstall` removes only what it added. → [Team rollout](docs/05-plugin.md)

### One config, every agent — native installs
The same operating manual + MCP servers, the way each tool expects them:

| Agent | Install | Loads |
|---|---|---|
| **Claude Code** | `/plugin install core@compass` (or `make install`) | `~/.claude/CLAUDE.md` + hooks + agents + commands + MCP |
| **Gemini CLI** | `gemini extensions install https://github.com/dshakes/compass` | `gemini-extension.json` → `GEMINI.md` + context7/fetch/git MCP |
| **Codex** | `make install` (symlinks `~/.codex/AGENTS.md`) | `AGENTS.md` + `config.toml` profiles + MCP |
| **Cursor · Copilot · OpenCode · Windsurf** | clone + `make install`; they read the repo's `AGENTS.md` | `AGENTS.md` (the [AGENTS.md](https://agents.md/) standard) |

`AGENTS.md` and `GEMINI.md` are one file — symlinks of the same manual, so a `git pull` updates every agent at once.

### ✅ Verify → your first run
```bash
compass doctor      # validate the install — expect "0 error"
compass status      # is compass active here, and what's loaded?
```
Then just open Claude Code as usual — the manual, guardrails, subagents, commands, and status line are already loaded. Feel it in a minute: ask for a dangerous command (blocked), run `/review` on your diff, or `compass route "<task>"` to see the tier it picks. No tokens, no signup for any of it.

---

## What's in the box

Everything below is **on after one install** or a single opt-in — the autonomous loops above sit on top of this. The README sells; the docs explain — each row links to the detail.

<p align="center">
  <a href="docs/16-hardening-and-frontier.md" title="placeholder link — repoint to a demo/video/landing"><img src="assets/hardening-frontier.svg" alt="The whole compass stack: a guarded base (manual · guardrail/secret/format/audit hooks · red-team injection scanners · cost-tiered router) under a frontier layer of closed loops — the autonomous SDLC pipeline, the scheduled fleet, and parallel dynamic workflows — all ending at a permanent human merge/deploy gate." width="900"></a>
</p>

| | Capability | One line | Deep dive |
|---|---|---|---|
| 🔁 | **Autonomous SDLC** | the review → security → tests → Codex audit → **auto-fix → re-review** loop; you merge | [09-sdlc](docs/09-sdlc.md) |
| 🛰️ | **The fleet** | the loop, scheduled across *all* your repos through a test gate; approve from your phone | [14-fleet](docs/14-fleet.md) |
| 👥 | **The crew + workflows** | 10 cost-tiered subagents · 12 slash-commands · 3 dynamic workflows that fact-check each other | [12](docs/12-every-agent.md) · [13](docs/13-workflows.md) |
| 🛡 | **Guardrails & scanning** | 4 hooks block disasters, catch secrets (write-hook + `compass scan`), auto-format, keep a JSONL audit log | [16-hardening](docs/16-hardening-and-frontier.md) |
| 🧪 | **Red-team hardening** | eval-gated defense vs prompt-injection (direct/indirect/paste), CLAUDE.md poisoning, local safety-override, malware & insecure code; optional webhook/Bedrock/Azure backend | [17-red-team](docs/17-red-team.md) |
| 🧭 | **Cost-tier router** | a standalone, reusable module — keyword heuristic → optional classifier → Haiku judge cascade; eval-gated | [router/](router/) |
| 🧰 | **The compass CLI** | `onboard · impact · drift · scan · redteam · sandbox · verify · audit-log · spend · dashboard` | [11-using](docs/11-using-compass.md) |
| 🔌 | **MCP + LSP** | curated, **version-pinned** MCP servers (context7 · fetch · git) + opt-in language-server intelligence | [04](docs/04-mcp.md) · [06](docs/06-lsp.md) |
| 🪪 | **Every agent, one source** | Claude Code · Codex · Gemini — plus Cursor/Windsurf/Copilot via the [`AGENTS.md`](https://agents.md/) standard | [12-every-agent](docs/12-every-agent.md) |
| 💰 | **Cost discipline** | routing scored & CI-gated, per-step budget caps, `compass spend`/`impact` to see the $ | [02-cost](docs/02-cost-and-models.md) |

---

## Safety, honesty & status

Built to be **trusted before it's run** — and honest about its limits.

- **You own the irreversible.** Agents prepare; humans push, merge, deploy. Required checks + a code-owner approval enforce it — there's no "merge to prod" button.
- **Readable & reversible.** No `curl | sh`. The installer backs up what it replaces, is idempotent, and `make uninstall` removes only what it added. Pin a tag, not `main`.
- **Guardrails reduce footguns; they are not a security boundary.** Keep least-privilege credentials and review your diffs. (For untrusted code, `compass sandbox` is a real boundary.)
- **Red-team hardening is defense-in-depth, not immunity.** It warns on prompt-injection (direct/indirect/paste), CLAUDE.md poisoning, and local safety-override, and refuses to grant project-level safety exceptions — but the cardinal rule (external content is data, not instructions) and the human gate are what actually hold. `compass redteam` measures it; see [`docs/17-red-team.md`](docs/17-red-team.md).
- **What talks to the network.** compass phones home to nothing. The auto-registered MCP servers reach non-Anthropic endpoints — `context7` → Upstash (library docs), `fetch` → URLs you request; `git` is local. Hooks are short, commented shell scripts in `claude/hooks/`; disable any via `claude/settings.json`.
- **Grounded, not invented.** Every capability maps to a documented Claude Code / Codex primitive — cited in [`docs/07-practices.md`](docs/07-practices.md).

> **Status: alpha.** The core — manual, hooks, subagents, commands, MCP, plugin — is stable and dogfooded daily. The **SDLC pipeline** is newer: its logic is statically validated in CI and exercised via a smoke-test checklist you run on your own repo — treat it as early. The **red-team layer** is new: its detectors are eval-gated in CI (precision/recall on a labeled corpus) and resist obfuscation (`compass redteam --attack`), but pattern detection is best-effort defense-in-depth, not immunity — and the managed-guardrail adapters are response-parsing contract-tested, with the **live Bedrock/Azure calls unverified in CI** (need your creds) and no live third-party benchmark scores (see [docs/17](docs/17-red-team.md)). **Dynamic workflows** are a Claude Code research preview. The human merge/deploy gate is permanent, by design.

---

## Docs

**[Start here → Using compass](docs/11-using-compass.md)** — install, the pieces in plain language, the daily workflow.

[Philosophy](docs/00-philosophy.md) · [Architecture](docs/01-architecture.md) · [Cost & models](docs/02-cost-and-models.md) · [Customize](docs/03-customize.md) · [MCP](docs/04-mcp.md) · [Plugin & team rollout](docs/05-plugin.md) · [LSP](docs/06-lsp.md) · [Practices](docs/07-practices.md) · [Defaults](docs/08-defaults.md) · [SDLC](docs/09-sdlc.md) · [Roadmap](docs/10-roadmap.md) · [Every agent](docs/12-every-agent.md) · [Dynamic workflows](docs/13-workflows.md) · [Fleet](docs/14-fleet.md) · [Competitive audit](docs/15-competitive-audit.md) · [Hardening + frontier](docs/16-hardening-and-frontier.md) · [Red-team](docs/17-red-team.md) · [Router module](router/README.md) · [ADRs](docs/adr/)

<div align="center"><br><sub>MIT · built to be shared · contributions welcome</sub></div>
