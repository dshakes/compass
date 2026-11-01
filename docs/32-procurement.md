# Procurement evidence — what to hand a security review

A security team evaluating an AI coding agent asks the same five questions of every tool.
This page answers each with a **local artifact you can generate and attach** — no hosted
control plane — and names the two things a local-first layer cannot honestly claim.

| Question they ask | compass answer | Evidence command |
|---|---|---|
| Which actions can the agent take, and who decides? | Eval-gated allow/deny policy (`claude/hooks/lib/policy.sh`); `compass profile strict` makes hooks fail closed; a repo's `.compass/policy.conf` can only **tighten** | `compass profile` · `compass scan --config` |
| Is every gated action logged with identity, arguments and the policy decision? | Append-only JSONL trail, one object per gated/blocked action: `ts, decision, tool, repo, rule, detail` | `compass audit-log --json` (SIEM export, below) |
| Where are credentials, and is revocation immediate? | compass stores **no** credentials. Secret-file writes are blocked before they happen; `compass scan --config` flags secrets in agent/MCP config | `compass scan --config` · `compass audit-plugin <dir>` |
| What leaves the machine, and to whom? | Only the model calls your harness already makes. Optional egress: a managed guardrail backend (`COMPASS_GUARDRAIL_BACKEND`, off by default) and MCP servers you register | `compass scan --config` lists registered MCP servers · `docs/17-red-team.md` for the remote backend |
| What is the blast radius if the agent is hijacked, and is there a human gate? | Catastrophic commands and force-pushes are denied pre-execution; a hard dollar cap halts the session; **a human always merges** | `compass bench` (scored) · `COMPASS_MAX_USD` · `docs/09-sdlc.md` |

Supply-chain questions (SBOM, provenance, pinned actions) are answered by `compass verify`,
`compass sbom`, and the OpenSSF Scorecard badge in the README.

## OWASP Agentic Top-10 mapping

The per-risk mapping (ASI01–ASI10) with an honest **Covered / Partial / Not covered** column lives
in [17-red-team.md → OWASP mapping](17-red-team.md). Hand the reviewer that table, not a summary.

## SIEM export recipe

The trail is plain JSONL, so any collector that tails a file works. Example: ship new events as
they land, with a stable schema.

```bash
# one-shot export (last 10k events, newest last)
compass audit-log --json -n 10000 > compass-audit-$(date +%F).jsonl

# continuous: tail the ledger into your agent (Vector/Fluent Bit/Splunk UF all tail files)
tail -F ~/.compass/audit.jsonl
```

Schema (stable; additive changes only):

```json
{"ts":"2026-10-31T19:04:12Z","decision":"deny","tool":"Bash","repo":"/path/to/repo",
 "rule":"guardrail","detail":"<redacted reason — never the raw payload>"}
```

`decision` is `deny` or `warn`. `tool` is the harness tool name (`Bash`, `Write`, `mcp__…`) for a
blocked action, or the hook event (`UserPromptSubmit`, `PostToolUse`, `SessionStart`) for a scanner
finding. `rule` is the policy rule id or scanner class (`prompt-injection`, `indirect-injection`,
`context-poisoning`, `guardrail-backend`, …). `detail` is a redacted reason, never the payload.

## What a local-first layer cannot claim — say it up front

- **IdP-backed identity.** There is no per-user identity on an agent action beyond the OS user
  and git author. Agent-role attestation is designed but not built ([ADR-0007](adr/0007-agent-identity-attestation.md)).
- **Central retention.** The trail lives on each machine. Retention is whatever your SIEM
  applies after export; compass does not enforce it.
- **Every tool call.** The trail records **gated and blocked** actions, not every allowed call.
  If the review requires a full call log, pair compass with the harness's own transcript.
- **Regulatory compliance.** compass produces evidence a *deployer* can use; it is not a
  certification and makes no claim about any specific regulation.

## Evidence pack checklist

Run from the repo under review; attach the outputs.

```bash
compass verify                 # release provenance verified
compass bench                  # guardrail + router scores against the labeled corpora
compass redteam --external --split=test   # held-out score, with n and 95% CI
compass scan --config --sarif > compass-config.sarif    # agent/MCP config audit (SARIF)
compass audit-log --json -n 10000 > compass-audit.jsonl # the trail
compass sbom                   # SBOM for the installed release
```
