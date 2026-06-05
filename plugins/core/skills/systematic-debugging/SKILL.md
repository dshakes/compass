---
name: systematic-debugging
description: Use when something is broken — a failing test, panic, stack trace, error log, or wrong behavior whose cause isn't obvious. Reproduce it, form a hypothesis, PROVE the cause before changing code, then make the minimal root-cause fix and guard it with a test. For deep cases, hand off to the debugger subagent.
allowed-tools: Read, Grep, Glob, Bash, Edit
---

# Systematic debugging

Fix the cause, not the symptom — and prove the cause before you touch code.

## The method

1. **Reproduce** — get a reliable, minimal repro (a failing test is ideal). No repro → no fix.
2. **Hypothesize** — one specific, falsifiable guess about the cause ("X is null because Y").
3. **Prove it** — instrument/log/inspect to confirm the hypothesis *before* editing. If the
   evidence contradicts it, form a new hypothesis. Don't guess-and-change.
4. **Minimal fix** — change the smallest thing that addresses the proven root cause.
5. **Verify** — re-run the repro; it passes. Run the surrounding tests; nothing regressed.
   (See `verification-before-completion`.)
6. **Guard** — add/extend a test that would have caught it, so it can't silently return.

For a nasty one, delegate to the **`debugger`** subagent (or the `triage` command) — it
forms a hypothesis, proves it, and proposes the minimal fix.

## Red flags — you're not debugging, you're flailing

- **Changing code before reproducing** the problem.
- **Fixing the symptom** (swallow the error, bump the timeout) instead of the cause.
- **Several changes at once** — you won't know which one mattered.
- "It went away" with **no explanation of why** — it'll come back.
- Re-running hoping for a different result without changing your hypothesis.

## Done means

Root cause **proven** (not assumed) · minimal fix · repro now green · a regression test
added · no new failures. Anything less is **UNVERIFIED**.
