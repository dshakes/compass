---
name: verification-before-completion
description: Use before claiming ANY task done, fix verified, check passing, or PR ready. Establish how the change is checked and actually run it — tests, typecheck, lint, the local gate, or the app itself — and observe it pass. Never report "should work" or pass along a subagent's unproven claim.
allowed-tools: Read, Grep, Glob, Bash
---

# Verification before completion

The highest-leverage habit and a compass hard line: **a claim is not proof.**

## The iron rule

I do not say "done", "fixed", "verified", or "passing" unless I ran the check and saw it
pass. If I could not run it, I label the result **UNVERIFIED** and say why. This binds
delegated work too: a subagent's "verified" is a claim — **I re-run the gate** on what it
returns.

## How to verify (pick what fits the change)

- Tests for the touched code: `go test` · `cargo test` · `pytest` · `npm/pnpm test` · `npx tsc`.
- The compass gates: `make doctor` (config/guardrail/red-team) · `compass bench` (guardrail/router) · `compass redteam` (injection).
- Behavior that tests don't cover: **run the app/CLI and observe it** (use the `run`/`verify` skills).
- A diff before shipping: `/review` or `compass-review` (adversarially verified).

## Red flags — stop, you have not verified

- About to write **"this should work"** / "this should fix it".
- Marking done with tests **failing, skipped, or never run**.
- Reporting a **subagent's result** without re-running the gate yourself.
- "It compiles" used as a stand-in for "it works".
- Claiming a perf/security improvement with **no measurement**.

## Checklist before I say done

1. I named the check *before* calling it done, and ran it.
2. Output shows it **passed** (pasted/summarized honestly — failures shown, not hidden).
3. Skipped a step? I said which and why.
4. Couldn't verify? It's labelled **UNVERIFIED**, not "done".
