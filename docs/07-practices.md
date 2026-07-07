# Practices we follow (and where they come from)

This repo doesn't invent best practices — it adopts published, **verifiable** ones
and cites them. Read the sources; don't take our word for it.

## Canonical sources
- **Anthropic — Best practices for Claude Code** — https://code.claude.com/docs/en/best-practices
  (the authoritative page; associated with the Claude Code team / Boris Cherny).
- **AGENTS.md standard** — https://agents.md/ (the cross-tool instructions file;
  read by Codex and 20+ other agents).
- **Andrej Karpathy** — "vibe coding" (https://x.com/karpathy/status/1886192184808149383)
  and the "tight leash on an over-eager junior" rhythm
  (https://x.com/karpathy/status/1915581920022585597).
- **Garry Tan — `gstack`** — https://github.com/garrytan/gstack (his real Claude Code
  skill set modeling an eng team: `/plan-*-review`, `/review`, `/ship`, `/careful`, …).
- **Community index** — `hesreallyhim/awesome-claude-code`
  (https://github.com/hesreallyhim/awesome-claude-code).

## What we adopted, and where it lives

| Practice (source) | Where it's encoded here |
|---|---|
| **Context is the scarce resource; keep memory lean or it gets ignored** (Anthropic) | `CLAUDE.md` is short; "Context hygiene" section; `make doctor` discourages bloat |
| **Give the agent a way to verify itself — highest leverage** (Anthropic) | `CLAUDE.md` principle 4; `/ship` runs tests; `test-runner` subagent; `core-lsp` diagnostics |
| **Explore → plan → code → commit** (Anthropic) | `CLAUDE.md` principle 3; `/tdd`, `architect` subagent, plan mode |
| **Lean, committed instructions file with build/test/style/etiquette** (Anthropic, agents.md) | `CLAUDE.md`/`AGENTS.md`; `bootstrap-agent-config` skill; `templates/CLAUDE.md.tmpl` |
| **`/clear` between tasks; reset after 2 failed corrections** (Anthropic) | `CLAUDE.md` "Context hygiene" |
| **Self-improving memory — write a rule after each correction** (Anthropic team) | `CLAUDE.md` "Teach me once" (+ native `#`) |
| **Subagents for file-heavy investigation in a separate context** (Anthropic) | 15 subagents in `claude/agents/` |
| **Writer/Reviewer with fresh context** (Anthropic) | `/ship` (writer) → `code-reviewer`/`security-auditor` (reviewer) |
| **Deterministic hooks for must-happen-every-time actions** (Anthropic, awesome-claude-code) | `claude/hooks/` (protect-paths, format-on-edit, …) |
| **Headless `claude -p` for CI / pre-commit / fan-out** (Anthropic) | documented below |
| **One instructions file across tools** (agents.md) | `AGENTS.md` → `CLAUDE.md` symlink (single source) |
| **Tight leash, small reviewable diffs, verify not rubber-stamp** (Karpathy) | `CLAUDE.md` principles 2 & 4; `acceptEdits` + guardrail hook |
| **Skills modeling team roles / explicit review gates** (gstack) | `/review`, `/ship`, `architect`, `security-auditor` |
| **Sprint sequence: think → plan → build → review → test → ship** (gstack) | the SDLC pipeline: Plan → Build → Review → Audit → Security → QA → PR (`sdlc/`) |
| **Cross-model second opinion (Claude + a second CLI)** (gstack `/codex`) | the **Auditor** runs `codex exec` / `openai/codex-action` on every PR |
| **Onboarding: "See it work" narrative, diagram-first explanation, example-forward quickstart, symptom-indexed troubleshooting** (gstack README) | README "See it work" + "How it fits together" (Mermaid) + deployment-model table; `docs/09` troubleshooting indexed by symptom |

## Headless mode (from Anthropic's guidance)
For CI, pre-commit, or large fan-out migrations:
```bash
claude -p "summarize what changed and flag risky diffs" --output-format json
# fan-out: list files, then loop one scoped run per file (test on 2-3 first)
```
Scope it with `--allowed-tools`; the `protect-paths` hook still applies.

## Honesty note (what we did NOT do)
- We did **not** fabricate a "Karpathy CLAUDE.md" or a "YC/Garry Tan best-practices
  document" — neither exists as a published artifact. Karpathy's principles come
  from his tweets; Tan's from the `gstack` repo. We cite the real things.
- AGENTS.md ↔ CLAUDE.md symlinking is **community convention**, not part of the
  agents.md spec. We use it because it works, not because a standard mandates it.
