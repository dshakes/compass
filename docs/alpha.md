# For alpha users

Thanks for trying **compass** — a config that makes Claude Code + Codex behave like a
senior engineer in every repo, with an optional governed, autonomous SDLC pipeline.
It's **alpha**: the core is dogfooded and stable; the SDLC pipeline is newer. Expect
rough edges, and please file them.

## Get started in 60 seconds
```bash
git clone https://github.com/dshakes/compass ~/compass && cd ~/compass
make dry-run     # see exactly what it will change
make install     # symlinks into ~/.claude + ~/.codex (backs up anything it replaces)
make doctor      # validate
```
Now every repo you open has the operating manual, guardrail hooks, specialist
subagents, workflow commands (`/ship` `/review` `/tdd` …), and MCP servers.
Prefer not to touch your global config? Install just the machinery as a plugin:
```bash
/plugin marketplace add dshakes/compass && /plugin install core@compass
```

## Try the autonomous SDLC (keyless — uses your subscription)
```bash
cd <any-repo>
~/compass/sdlc/orchestrate.sh "add input validation to <X>"
# plan → build → review → Codex cross-audit → security → QA → opens a PR you merge
```
No API key or credits needed — it runs `claude -p` / `codex exec` on your login.

### …or the closed loop on your GitHub PRs
Want the agents to run **on every PR** and auto-fix their own review findings —
open PR → review/security/QA/audit → if Blocking, the Builder fixes on the branch and
pushes → re-review → repeat until clean (you still merge)?
```bash
cd <any-repo>          # needs the Claude GitHub App installed
export CLAUDE_CODE_OAUTH_TOKEN=…  OPENAI_API_KEY=…  SDLC_BOT_TOKEN=…
~/compass/sdlc/setup.sh --all     # installs the SDLC workflows + the merge gate
```
The loop auto-chains only with `SDLC_BOT_TOKEN` (a fine-grained PAT). Full walkthrough,
the why, and troubleshooting: [`09-sdlc.md`](09-sdlc.md). **Newest piece — treat as early.**

## What to expect (alpha)
- **You always merge & deploy.** Agents stop at a PR. That's by design.
- **Cloud PR automation** (the closed review⇄fix loop) needs the GitHub App + a
  `SDLC_BOT_TOKEN` PAT, or a self-hosted runner for the keyless path — see
  [`09-sdlc.md`](09-sdlc.md). The local pipeline above needs neither.
- **Pin a release** (e.g. `v0.13.0`), not `main`, for stability.
- It's safe to uninstall: `make uninstall` removes only what it added (backups in `~/.claude/backups/`).

## Please report
- Bugs / ideas → the issue templates (`/issues/new/choose`).
- Questions / show-and-tell → Discussions.
- Include `make doctor` output for bugs.

Honest north star: this is footgun-prevention + leverage, **not** a hands-off autopilot.
Keep reviewing diffs; that's where the value compounds.
