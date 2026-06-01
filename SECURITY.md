# Security Policy

## Scope
`compass` is configuration for AI coding agents (Claude Code + Codex): hooks,
subagents, commands, skills, MCP/LSP wiring, and an installer. It ships shell
scripts that run on your machine and a `PreToolUse` guardrail.

**The guardrail hooks reduce footguns; they are not a security boundary.** They
stop common accidents (secret writes, secrets pasted into file *content*, `rm -rf /`,
`curl|sh`, force-push to `main`), not a determined attacker or a cleverly-phrased
command. Keep using least-privilege credentials and review diffs. **When you need an
actual boundary** — running untrusted code, a downloaded build, an agent executing a
script you didn't write — use `compass sandbox -- <cmd>`: a real OS sandbox (bwrap /
firejail / macOS sandbox-exec) with no network and writes confined to cwd + temp. It
refuses rather than run unconfined if no backend is available (no fake sandboxing).

**Secret scanning has two layers.** The `protect-paths` write-hook blocks an agent
from writing a recognizable live credential (Anthropic/OpenAI/AWS/GitHub/GCP/Slack/
Stripe… formats) into a file. `compass scan [--staged|--all]` is the commit-boundary
companion — run it in a pre-commit hook or CI; its built-in detectors are the
deterministic gate and it uses `gitleaks` for extra depth when installed. Both honor
an `allowlist secret` marker on a line for deliberate placeholders/fixtures.

## What talks to the network (egress)
compass itself phones home to nothing. Network calls happen only through tools you enable:

| Endpoint | When | Default |
|---|---|---|
| **Anthropic API** | Claude Code / `claude-code-action` / `claude -p` | core to using Claude |
| **Upstash (context7 MCP)** | live library-docs lookups | auto-registered (secret-free) |
| **Arbitrary URLs (fetch MCP)** | when the agent fetches a page | auto-registered |
| **OpenAI (Codex)** | the SDLC cross-audit (`codex` / `codex-action`) | opt-in (SDLC only) |
| **GitHub API** | SDLC workflows, optional `github` MCP | opt-in |
| **Live web pages (Playwright `browser` MCP)** | UI/web tasks — *can act on live sites* | opt-in, off by default |
| **Your Postgres (`postgres` MCP)** | read-only SQL | opt-in, project-scoped |
| **OpenRouter** | `codex --profile router` (cost router) | opt-in, off by default |
| **Local model — Ollama/LM Studio** | `codex --profile local` | opt-in; **local only**, no egress |

No telemetry. The `compass-memory` MCP is **local-only** (SQLite over stdio, no network). compass modifies shared files only by symlinking config into `~/.claude`, `~/.codex`, and (with `--gemini`) `~/.gemini` (backed up; `make uninstall` reverts all three). No feature uses `--dangerously-skip-permissions`.

## Audit trail
Every blocked/gated action is appended to `${COMPASS_HOME:-~/.compass}/audit.jsonl`
(one JSON object per line: ts · decision · tool · repo · rule · redacted detail). Read
it with `compass audit-log` (table, `--since`, or `--json` for SIEM export). Details are
redacted reasons — never the raw secret or payload.

## Supply chain & release provenance
- **MCP servers are version-pinned** (never `@latest`); `scripts/check-mcp.sh` enforces
  pins + manifest integrity in `setup-mcp` pre-flight, `doctor`, and CI, so a compromised
  upstream release isn't auto-pulled.
- **Releases carry provenance.** Every `v*` tag triggers `release-sign.yml`, which emits a
  keyless [SLSA build-provenance attestation](https://slsa.dev) for the source tarball.
  Verify any download with `compass verify [vX.Y.Z]` (or `gh attestation verify <tarball>
  --repo dshakes/compass`). The Homebrew formula additionally pins the tarball `sha256`.

## Reporting a vulnerability
Please report security issues **privately** — do not open a public issue.
- Use GitHub's **Report a vulnerability** (Security → Advisories), or
- Email **chandu1221@gmail.com** with details and a reproduction.

You'll get an acknowledgment within a few days. Once a fix ships, we'll credit you
(unless you prefer to remain anonymous).

## Good practices when using compass
- Read the hooks and scripts before `make install` — that's why they're short.
- Never put secrets in `CLAUDE.md`/`AGENTS.md`; use `${ENV}` refs for MCP servers.
- Point database MCP servers at a **read-only** role or replica.
- Pin the marketplace to a tag (not `main`) for team rollouts.
