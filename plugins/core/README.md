# Core — Claude Code plugin

Zero-config install of the machinery from [compass](../../README.md):
specialist subagents, workflow commands, guardrail + auto-quality hooks, a
repo-bootstrap skill, a terse output style, and parity MCP servers.

## Install

```bash
/plugin marketplace add dshakes/compass
/plugin install compass@compass
```

Local testing from a clone:
```bash
/plugin marketplace add ./compass
/plugin install compass@compass
```

## What you get

- **Subagents** (`/agents`): `architect`, `code-reviewer`, `security-auditor`,
  `debugger`, `go-engineer`, `rust-engineer`, `k8s-operator`, `test-runner`,
  `docs-writer` — cost-tiered across Haiku/Sonnet/Opus.
- **Commands**: `/ship` `/review` `/tdd` `/pr` `/adr` `/triage` `/scaffold` `/cost`.
- **Hooks**: `protect-paths` (blocks secret writes, `rm -rf /`, `curl|sh`,
  force-push/hard-reset to main), `format-on-edit`, `inject-context`, `notify`.
- **Skill**: `bootstrap-agent-config` — drafts a grounded `CLAUDE.md` for any repo.
- **Output style**: "Concise" (terse, answer-first) — enable via `/config`.
- **MCP servers**: `context7` (live docs), `fetch`, `git` — auto-registered.

## What a plugin can't carry (install these separately)

Plugins can't ship user-level **memory, permissions, model defaults, or a global
status line**. To get the full setup — the `CLAUDE.md` operating manual, the
`acceptEdits` + allow/deny permission posture, and the rich status line — clone
the repo and run `make install` instead of (or alongside) the plugin. See the
[root README](../../README.md). Don't run both methods at once, or hooks fire twice.

## Note on MCP
If you installed this plugin you already have `context7`/`fetch`/`git` — you do
**not** also need `make mcp`.
