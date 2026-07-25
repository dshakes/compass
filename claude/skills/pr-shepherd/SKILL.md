---
name: pr-shepherd
description: Take every open PR end-to-end — diagnose failing checks, classify them (real defect vs mechanical vs environmental), fix the mechanical ones on the PR branch, re-verify, and stop at the merge gate. Use on demand ("handle the open PRs") or on an interval via /loop (e.g. "/loop 15m /pr-shepherd"). Merges only when the human has granted merge authority in the current session; otherwise reports ready-to-merge.
allowed-tools: Read, Grep, Glob, Bash, Edit, Write
---

# PR shepherd — the loop's handoff + verification moves, applied to PRs

A loop has five moves: **discovery → handoff → verification → persistence → scheduling**
(see [docs/20-loops.md](../../docs/20-loops.md)). `morning-triage` is discovery — it finds
work. This skill is what happens *after* a PR exists: no PR sits red waiting for a human to
diagnose a check that a machine can read. It shepherds each open PR to exactly one of three
outcomes: **merged** (gate satisfied + authority granted), **ready-to-merge** (reported), or
**inbox** (needs a human, with the diagnosis already written).

## Enumerate

`gh pr list --state open --json number,title,author,isDraft,isCrossRepository,headRefName,statusCheckRollup`

Skip drafts. **Fail closed on forks**: if `isCrossRepository` is true — or the field is
missing from the response — the PR is read-only: diagnose and comment, never check out into a
pushable worktree, never push.

## Diagnose — read the check, don't guess

For each red check, read the actual failing step (`gh run view <run-id> --log-failed`) and
classify it. The class decides the action — this is the judgment step, don't skip it:

| class | signature | action |
|---|---|---|
| **environmental** | missing secrets (Dependabot actor), runner flake, quota | note it; if it recurs, fix the *workflow* (root cause), not the PR |
| **mechanical** | drift/sync gates, lint, format, lockfile, generated files | fix it on the PR branch |
| **real defect** | failing tests on changed logic, security finding | never auto-fix silently — comment the diagnosis on the PR, mark `inbox` |

A failure that pattern-matches "flake" still gets its log read once. Silence is not success:
a check that never ran (skipped, stuck queue) is a finding, not a pass.

## Fix — mechanical only, verified before pushed

Work in a scratch worktree (`git worktree add … origin/<branch>`), never in the main checkout:

1. Make the smallest fix the failing gate names (e.g. the gate says
   `run: cp sdlc/workflows/X .github/workflows/` — run that).
2. **Run the same gate locally and watch it pass** before pushing. Never push a guess.
3. Push to the PR branch with a commit message that names the gate it satisfies.
4. **Three strikes**: after 3 failed fix attempts on one PR, stop — mark it `inbox` with what
   was tried. A non-converging loop must stop spending
   ([the resource-ceiling principle](../../docs/20-loops.md)).

## Gate — where the loop stops

Merge requires **all** of:

- every non-environmental check green (environmental reds are named in the report, not ignored);
- the human granted merge authority *in the current session* ("validate and merge",
  "/pr-shepherd --merge"). Authority is per-session, never assumed from a past one;
- squash merge, never force-push, never merge red, never bypass a required check.

Without authority: report the PR as **ready-to-merge** with a one-line verdict per check.
The merge button is the human's; the shepherd's job is to make pressing it trivial.

## Persist

Append one row per touched PR to `state/shepherd.md` (create if absent) so the next run
resumes instead of re-diagnosing. **The agent forgets; the repo does not.**

```markdown
| pr | class | action | status |
|---|---|---|---|
| #71 | mechanical (mirror drift) | synced templates, pushed | merged |
| #74 | real defect (auth test) | diagnosis commented | inbox |
```

## Schedule

- On demand: `/pr-shepherd`.
- Interval: `/loop 15m /pr-shepherd` — each firing re-reads state, handles what changed.
- Every firing re-reads `state/shepherd.md` first; a PR already `inbox` stays with the human
  until they act — don't re-litigate it every run.
