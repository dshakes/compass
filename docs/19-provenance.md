# Code provenance — Agent Trace records for AI-assisted commits

`compass verify` proves a *release* wasn't tampered with. This layer answers the
question underneath it: **which lines of this commit did an AI write, with which tool,
model, and session?** — and makes the answer verifiable instead of vibes.

It implements the open, vendor-neutral **Agent Trace** specification
(https://github.com/cursor/agent-trace, CC BY 4.0): a JSON record linking a commit's
changed line ranges to the conversation/tool/model that produced them. compass adds
the missing half — **optional cryptographic signing** — so the attribution can't be
silently fabricated or stripped without that being visible.

> **Honest framing.** Attribution is *best-effort*: the record says what the
> environment claimed (`COMPASS_TRACE_TOOL`, `COMPASS_TRACE_MODEL`, session id), and a
> signature proves who *attached* the record, not that the AI truly wrote those lines.
> This is a disclosure + forensics artifact, not a tamper-proof audit system. The
> human merge gate never moves (ADR-0006).

---

## Why bother

- **Review policy** — "AI-assisted diffs get the stricter review lane" needs a
  machine-readable marker, not a PR-description convention.
- **Forensics** — when a line breaks production, trace it back to the agent session
  that wrote it (`files[].ranges` → `metadata.session_id`).
- **Disclosure trends** — AI-transparency expectations are hardening into
  machine-readable requirements (e.g. the EU AI Act's transparency direction).
  An open-spec record per commit is the cheapest way to be ready.

## How to use it

```bash
compass trace emit            # print the Agent Trace record for HEAD (stdout or --out FILE)
compass trace attach          # store it as a git note under refs/notes/agent-trace
compass trace show            # print the attached record
compass trace verify          # 0 = a well-formed record is attached (+ signature, if any)
```

All four take an optional `<commit>` (default `HEAD`). Records are deterministic per
commit, so `attach` is idempotent — re-run it freely.

Attribution comes from the environment, with sensible defaults (a Claude Code session
is auto-detected via `CLAUDE_SESSION_ID`):

| Env | Becomes | Default |
|---|---|---|
| `COMPASS_TRACE_TOOL` / `_TOOL_VERSION` | `tool.name` / `tool.version` | `claude-code` in a session, else `unknown` |
| `COMPASS_TRACE_MODEL` | `contributor.model_id` (models.dev form, e.g. `anthropic/claude-opus-4-5`) | omitted |
| `COMPASS_TRACE_SESSION` | `metadata.session_id` | `$CLAUDE_SESSION_ID` |
| `COMPASS_TRACE_CONVERSATION_URL` | `conversations[].url` | omitted |

## What signing adds

Unsigned, the record is an honest hint anyone could edit. With **cosign** installed:

```bash
compass trace attach --sign                    # keyless (OIDC), or:
COSIGN_KEY=cosign.key compass trace attach --sign
```

signs the record blob and stores the signature under `refs/notes/agent-trace-sig`.
`compass trace verify` then checks it — `COSIGN_PUB` for key-based, or
`COMPASS_TRACE_CERT_IDENTITY` + `COMPASS_TRACE_OIDC_ISSUER` for keyless. No cosign is
**never** an error: attach works unsigned, and verify reports `unsigned` with a
warning but still passes. Provenance should be easy to adopt and hard to fake — in
that order.

## Sharing the records

Git notes are **local by default** — a plain `git push` does not send them:

```bash
git push origin refs/notes/agent-trace refs/notes/agent-trace-sig   # publish
git fetch origin 'refs/notes/*:refs/notes/*'                        # consume
```

CI can then gate on disclosure where you want it: `compass trace verify "$SHA"`.

## Limitations (read this)

- **Best-effort attribution.** Env-supplied tool/model/session; nothing diffs the
  agent's actual keystrokes against the human's. Ranges are whole-hunk (the new side
  of `git diff --unified=0`), so a hunk the human edited still attributes to the agent.
- **Notes don't follow rewrites.** Rebase/amend changes the sha and orphans the note;
  re-attach after history surgery.
- **A signature proves the signer, not authorship.** Keyless signing identifies the
  OIDC identity that ran `attach` — that's accountability, not proof of generation.
- **Never blocks.** No commit hook, no gate; it's evidence for humans and CI to read.
