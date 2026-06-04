<div align="center">

# 🧭 compass

### The trust layer for Claude Code, Codex & Gemini — measured, not vibes.

Anyone can say "safe" and "cheap." compass hands you the number — and lets you reproduce it in 30 seconds: guardrails **100/100** on a 61-case bypass corpus, a router measured **~61% cheaper** than all-Opus at ~98% quality, **signed releases you verify** in one command. One config you own for every agent, in every repo — not a service. No `curl | sh`, no telemetry. **You always merge.**

[![ci](https://github.com/dshakes/compass/actions/workflows/ci.yml/badge.svg)](https://github.com/dshakes/compass/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/dshakes/compass?color=8A63D2)](https://github.com/dshakes/compass/releases)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-8A63D2.svg)](docs/05-plugin.md)
[![AGENTS.md](https://img.shields.io/badge/AGENTS.md-compatible-2ea44f.svg)](https://agents.md/)
[![status: alpha](https://img.shields.io/badge/status-alpha-orange.svg)](#safety-honesty--status)

</div>

<p align="center">
  <img src="assets/explainer.svg" alt="compass in three beats: ONE CONFIG (install once) → EVERY AGENT (Claude Code · Codex · Gemini · Cursor, one AGENTS.md, no drift) → AUTONOMOUS PRs (reviews · fixes itself · you merge). All opt-in: guardrails · cost-tiered router · subagents/commands/MCP · scheduled fleet · human merge gate." width="900">
</p>

<p align="center">
  <b><a href="#install">Install ↓</a></b> &nbsp;·&nbsp; <a href="#see-it-work">▶ watch it fix its own PR</a> &nbsp;·&nbsp; <a href="docs/11-using-compass.md">📚 start here</a> &nbsp;·&nbsp; <a href="#whats-in-the-box">What's in the box</a> &nbsp;·&nbsp; <a href="#docs">Docs</a>
</p>

---

<div align="center">

### ⭐ The part people screenshot: it fixes its own PRs.

Open a pull request and compass **reviews it, security-checks it, runs the tests, cross-audits it with a second model — then pushes its own fixes until it's green.** You just merge.

**Why it works: the loop is the unit of work.** A one-shot agent stops at its first wrong answer. compass *loops* — **generate → test → critique → fix → repeat against a gate** — so quality comes from iteration, not from one lucky prompt. That same closed loop drives every PR, every scheduled fleet run, and every parallel workflow. *(Try it locally in 30 seconds, no tokens — [watch the loop ↓](#see-it-work).)*

</div>

---

## Why it's different — measured, not vibes

Every AI-agent config claims "safe" and "cheap." compass is the one that hands you the **number** — and lets a skeptic reproduce it in 30 seconds. Everyone has the same models; the edge is *configuration you can trust*, not another feature list.

**🛡 Guardrails with a score.** Catastrophic commands and secret writes are blocked *before they run* — and the policy is eval-gated, not asserted:

```bash
compass bench     # → guardrail 100% precision/recall (61-case corpus), router 96.9% — in CI
# then ask the agent to `rm -rf /` or write a .env → denied; `rm -rf ./build` → allowed
```

**📉 Cost routing that's measured.** Cheap work goes to cheap models — scored against an eval set, ~61% cheaper than all-Opus at ~98% quality on a fair mix:

```bash
compass route "redesign the auth model"   # → opus
compass route "fix a typo"                 # → haiku
```

**🔏 Supply chain you can verify.** Releases carry keyless SLSA provenance, so a tampered or look-alike download is rejected:

```bash
compass verify v0.14.0     # → ✓ provenance verified
```

No service, no telemetry, no `--dangerously-skip-permissions`; `git pull` to update. The work it can't safely own, it hands back — **you keep the merge.**

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
git checkout v0.14.0     # optional: pin to a release instead of main
./quickstart.sh          # previews every change, asks first, fully reversible
```

**🧩 Claude Code plugin** — no terminal *(ideal for a team)*
```text
/plugin marketplace add dshakes/compass
/plugin install core@compass
```

**🛠️ By hand:** `make dry-run` (preview) → `make install` → `make doctor`. Symlink install means `git pull`/`brew upgrade` updates everything; `make uninstall` removes only what it added. → [Team rollout](docs/05-plugin.md)

### ✅ Verify → your first run
```bash
compass doctor      # validate the install — expect "0 error"
compass status      # is compass active here, and what's loaded?
```
Then just open Claude Code as usual — the manual, guardrails, subagents, commands, and status line are already loaded. Feel it in a minute: ask for a dangerous command (blocked), run `/review` on your diff, or `compass route "<task>"` to see the tier it picks. No tokens, no signup for any of it.

---

## See it work

<p align="center">
  <img src="demo/preview.gif" alt="Terminal demo: compass blocks 'rm -rf /' (red) while 'rm -rf ./build' is allowed (green), shows the cost-aware status line, then the autonomous PR loop — review · security · tests · Codex audit → BLOCKING auto-fixes on the branch and re-reviews → CLEAN → you merge." width="780">
</p>
<p align="center"><sub>Guardrails · cost-aware status line · the self-fixing loop · the crew — in ~25 seconds.</sub></p>

The autonomous loop, as architecture and on a real PR:

<p align="center">
  <img src="assets/sdlc-loop.svg" alt="Autonomous SDLC loop: push a PR → Reviewer, Auditor (Codex), Security, QA run in parallel → BLOCKING labels agent:needs-fix → the Builder fixes on the branch and pushes → re-review (round cap ×3) → CLEAN → checks green → human merge gate → you merge." width="860">
</p>
<p align="center">
  <img src="assets/loop.gif" alt="The loop on a real PR: Reviewer flags a bug as Blocking + QA red → the Builder pushes a fix commit → re-review goes CLEAN, QA green → mergeable, awaiting your code-owner approval." width="800">
</p>
<p align="center"><sub>Review · security · tests · Codex cross-audit → auto-fixes its own Blocking findings → green → <b>you merge</b>. Run it locally in 30s with <code>~/compass/sdlc/orchestrate.sh "&lt;task&gt;"</code> (no tokens), or wire the GitHub loop for every PR. → <a href="docs/09-sdlc.md">how it works</a> · <a href="sdlc/SMOKETEST.md">reproduce it</a></sub></p>

The everyday status line quietly keeps score so you can see it earning its keep:
```text
Opus 4.8 · myrepo · main* · 45k ctx · $1.23 · 🧭 🛡1 🧹2 💡1 📉~$1.65
```
<sub>session spend, then today's compass activity: **🛡** footguns blocked · **🧹** files formatted · **💡** policy nudges · **📉~$** estimated saved vs all-Opus (once spend is logged). Each piece shows only when there's something to report; nothing leaves your machine.</sub>

---

## What's in the box

<p align="center">
  <img src="assets/hardening-frontier.svg" alt="The whole compass stack: a guarded base (manual · guardrail/secret/format/audit hooks · cost-tiered router) under a frontier layer of closed loops — the autonomous SDLC pipeline, the scheduled fleet, and parallel dynamic workflows — all ending at a permanent human merge/deploy gate." width="900">
</p>

Everything below is **on after one install** or a single opt-in. The README sells; the docs explain — each row links to the detail.

**The top three are loops** — they don't answer once, they iterate against a gate until it passes, then hand you the result:

| | Capability | One line | Deep dive |
|---|---|---|---|
| 🔁 | **Autonomous SDLC** *(loop)* | review → security → tests → Codex cross-audit → **auto-fixes its own Blocking findings** → re-reviews → green; you merge | [09-sdlc](docs/09-sdlc.md) |
| 🛰️ | **The fleet** *(scheduled loop)* | governed agents patch/test/de-flake *all* your repos through a test gate on a schedule; approve from your phone | [14-fleet](docs/14-fleet.md) |
| 👥 | **The crew + workflows** *(parallel loops)* | 10 cost-tiered subagents · 12 slash-commands · 3 dynamic workflows that fan out, fact-check each other, and converge | [12](docs/12-every-agent.md) · [13](docs/13-workflows.md) |
| 🛡 | **Guardrails & scanning** | 4 hooks block disasters, catch secrets (write-hook + `compass scan`), auto-format, and keep a JSONL audit log | [16-hardening](docs/16-hardening-and-frontier.md) |
| 🧭 | **Cost-tier router** | a standalone, reusable module — keyword heuristic → optional local classifier → Haiku judge cascade; eval-gated | [router/](router/) |
| 🧰 | **The compass CLI** | `onboard · impact · drift · scan · sandbox · verify · audit-log · spend · dashboard` | [11-using](docs/11-using-compass.md) |
| 🔌 | **MCP + LSP** | curated, **version-pinned** MCP servers (context7 · fetch · git) + opt-in language-server intelligence | [04](docs/04-mcp.md) · [06](docs/06-lsp.md) |
| 🪪 | **Every agent, one source** | Claude Code · Codex · Gemini — plus Cursor/Windsurf/Copilot via the [`AGENTS.md`](https://agents.md/) standard | [12-every-agent](docs/12-every-agent.md) |
| 💰 | **Cost discipline** | model routing scored & CI-gated, per-step budget caps, `compass spend`/`impact` to see the $ | [02-cost](docs/02-cost-and-models.md) |

The fleet is the loop pointed at *every* repo you own — one scheduled run, reviewed and test-gated, waiting for your approval:

<p align="center">
  <img src="assets/fleet.svg" alt="The fleet: a scheduler fans governed agents across many repos in parallel; each runs the review → test → fix loop on its own branch, opens a PR, and waits at the human approval gate — approvable from your phone." width="860">
</p>

---

## Safety, honesty & status

Built to be **trusted before it's run** — and honest about its limits.

- **You own the irreversible.** Agents prepare; humans push, merge, deploy. Required checks + a code-owner approval enforce it — there's no "merge to prod" button.
- **Readable & reversible.** No `curl | sh`. The installer backs up what it replaces, is idempotent, and `make uninstall` removes only what it added. Pin a tag, not `main`.
- **Guardrails reduce footguns; they are not a security boundary.** Keep least-privilege credentials and review your diffs. (For untrusted code, `compass sandbox` is a real boundary.)
- **What talks to the network.** compass phones home to nothing. The auto-registered MCP servers reach non-Anthropic endpoints — `context7` → Upstash (library docs), `fetch` → URLs you request; `git` is local. Hooks are short, commented shell scripts in `claude/hooks/`; disable any via `claude/settings.json`.
- **Grounded, not invented.** Every capability maps to a documented Claude Code / Codex primitive — cited in [`docs/07-practices.md`](docs/07-practices.md).

> **Status: alpha.** The core — manual, hooks, subagents, commands, MCP, plugin — is stable and dogfooded daily. The **SDLC pipeline** is newer: its logic is statically validated in CI and exercised via a smoke-test checklist you run on your own repo — treat it as early. **Dynamic workflows** are a Claude Code research preview. The human merge/deploy gate is permanent, by design.

---

## Docs

**[Start here → Using compass](docs/11-using-compass.md)** — install, the pieces in plain language, the daily workflow.

[Philosophy](docs/00-philosophy.md) · [Architecture](docs/01-architecture.md) · [Cost & models](docs/02-cost-and-models.md) · [Customize](docs/03-customize.md) · [MCP](docs/04-mcp.md) · [Plugin & team rollout](docs/05-plugin.md) · [LSP](docs/06-lsp.md) · [Practices](docs/07-practices.md) · [Defaults](docs/08-defaults.md) · [SDLC](docs/09-sdlc.md) · [Roadmap](docs/10-roadmap.md) · [Every agent](docs/12-every-agent.md) · [Dynamic workflows](docs/13-workflows.md) · [Fleet](docs/14-fleet.md) · [Competitive audit](docs/15-competitive-audit.md) · [Hardening + frontier](docs/16-hardening-and-frontier.md) · [Router module](router/README.md) · [ADRs](docs/adr/)

<div align="center"><br><sub>MIT · built to be shared · contributions welcome</sub></div>
