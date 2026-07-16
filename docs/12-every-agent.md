# Every agent, one source

compass keeps **one** operating manual — `claude/CLAUDE.md` — and `AGENTS.md` is a symlink to
it. `AGENTS.md` is the **open, cross-tool standard** for agent instructions, now governed by the
Linux Foundation's **Agentic AI Foundation** (alongside MCP). So the same manual already steers
most coding agents — not just Claude Code. Edit it once; every agent reads it.

## Who consumes it, and how

| Agent / IDE | Reads | How compass feeds it |
|---|---|---|
| **Claude Code** | `~/.claude/CLAUDE.md` | `make install` (symlink) |
| **Codex** | `~/.codex/AGENTS.md` | `make install` (symlink → same manual) |
| **Gemini CLI** | `~/.gemini/GEMINI.md`, or `AGENTS.md` via `context.fileName` | `./install.sh --gemini` (symlinks `GEMINI.md` → the manual) |
| **Cursor** | `AGENTS.md` natively (+ `.cursor/rules/`) | per-repo `AGENTS.md` — already there after `make new-repo` |
| **Windsurf** | auto-discovers `AGENTS.md` → Cascade Rules | per-repo `AGENTS.md` — no action |
| **GitHub Copilot / Amp / Devin** | `AGENTS.md` natively | per-repo `AGENTS.md` — no action |

The global manual covers operating *principles* (understand first, stay in scope, verify before
"done," cost discipline) that apply to any agent. A few Claude-Code-specific references
(`/commands`, hooks) are harmless context for other tools — the principles are the point.

### Gemini CLI — two ways
- **Global manual:** `./install.sh --gemini` symlinks `~/.gemini/GEMINI.md` → the same manual.
- **Per-repo AGENTS.md:** add to `~/.gemini/settings.json` so Gemini also reads the repo's `AGENTS.md`:
  ```json
  { "context": { "fileName": ["AGENTS.md", "GEMINI.md"] } }
  ```
  (If both exist in a dir, Gemini CLI prefers `GEMINI.md`.)

## MCP is cross-tool too
MCP is the other Agentic-AI-Foundation standard. compass's single manifest
([`mcp/servers.json`](../mcp/servers.json)) registers servers in Claude **and** Codex today;
Gemini CLI and Cursor also speak MCP, so the same servers (context7, fetch, git, …) are
portable there. → [MCP guide](04-mcp.md)

## Budget enforcement for non-Claude agents

Claude Code's built-in budget gate works only for sessions that render the status line or write a
transcript. `compass gate` closes the gap: it's a localhost reverse proxy that enforces
`COMPASS_MAX_USD` / `COMPASS_MAX_USD_DAY` for **any** agent that speaks the Anthropic or OpenAI
API:

```bash
compass gate &                           # start the proxy (port 4141)
export ANTHROPIC_BASE_URL=http://127.0.0.1:4141
export OPENAI_BASE_URL=http://127.0.0.1:4141
# run Codex, SDK scripts, or any framework here — caps apply
```

Once the cap is reached, further requests get a 402 before hitting upstream. Cost is tracked in
the shared `~/.compass/spend.tsv` ledger alongside Claude Code sessions.
→ full details in [cost & models](02-cost-and-models.md#cross-agent-budget-enforcement----compass-gate-experimental)

## Why this matters
You don't bet on one vendor. Switch or mix Claude Code, Codex, Gemini, Cursor, Windsurf — your
team's operating manual, conventions, and guardrail *intent* travel with you, from one file.

---
Sources: [agents.md](https://agents.md/) · [Gemini CLI — GEMINI.md / context.fileName](https://geminicli.com/docs/cli/gemini-md/) · [Windsurf — AGENTS.md](https://docs.windsurf.com/windsurf/cascade/agents-md). AGENTS.md + MCP are under the Linux Foundation's Agentic AI Foundation (Dec 2025).
