# Safe autonomy — the demo

> An autonomous loop you can actually walk away from.

Most "agent runs by itself" demos show the happy path: a loop churns and a PR
appears. The interesting question is the other one — *what happens when the loop
reaches for something it shouldn't, or runs too long?* This demo answers that. It
walks a goal-gated loop through a small fixture task and shows the guards holding
while you're not watching.

## The four beats

1. **A goal-gated loop starts.** The stop condition is a real gate — tests green
   *and* a fresh judge signs off — not "the worker thinks it's done." You close the
   laptop at turn 1.
2. **The guardrail holds.** Mid-loop the agent reaches past the line —
   `git push --force origin main`, a write to `~/.aws/credentials`, a write to
   `.env`. Each is **blocked before it runs** by the `protect-paths.sh` guardrail.
3. **The budget gate caps spend.** Spend climbs turn over turn; at the `$0.40`
   ceiling the `budget-gate.sh` hook **halts the loop**. No runaway overnight bill.
4. **Converge → human merge gate.** The loop finishes the fix, the judge signs off,
   and it **hands you a PR and stops.** Nothing auto-merges. Humans own merge and
   deploy, always.

## What's real vs. narrated

The point of the demo is that the guards are *real*, so they are:

- **Beats 2 and 3 drive the actual compass hooks** —
  [`claude/hooks/protect-paths.sh`](../../claude/hooks/protect-paths.sh) and
  [`claude/hooks/budget-gate.sh`](../../claude/hooks/budget-gate.sh) — with real
  JSON on stdin. The `BLOCKED` / `HALTED` lines and their reasons are the hooks'
  own output, not a mockup. Change the hooks and the demo changes with them.
- **The loop turns (plan / build / review / qa / judge) are narrated** in place of
  live `claude -p` calls, so the demo is deterministic, offline, and safe in CI. A
  live run would swap the narration for real model turns; the guards are identical
  either way — that's the whole design (guards live in scripts, not in the model).

## Run it

```sh
./run.sh          # full pacing — for watching or recording the GIF
./run.sh --mock   # zero-pause, deterministic — the CI path
./run.sh --help
```

Both modes drive the real hooks. `--mock` only drops the presentation pauses.

## Safety of the demo itself

- **Non-destructive.** All git work happens in a throwaway repo under a `mktemp`
  dir, removed on exit (`trap`). The budget gate reads from a throwaway
  `COMPASS_HOME`, also in the temp dir. Nothing outside it is touched.
- **No network. No real model calls.** Runs fully offline.
- `bash -n` and `shellcheck` clean.

## How it fits the product

This is the concrete version of the loop-engineering thesis in
[`docs/loop-engineering.md`](../../docs/loop-engineering.md) and the five moves in
[`docs/20-loops.md`](../../docs/20-loops.md): the gate is the whole game, memory
lives on disk, resource ceilings stop a non-converging loop from *spending*, and a
human sits at the irreversible step. The [`morning-triage`](../../claude/skills/morning-triage/SKILL.md)
skill is how such a loop finds its task in the first place.

Recording instructions for the GIF are in [`RECORDING.md`](./RECORDING.md).
