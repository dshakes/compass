# Scheduled routines — agents on a timer

Cron-scheduled agents that keep a repo healthy and **open PRs/issues into the normal SDLC
loop** (so review/QA/human-merge still apply). They **never merge or deploy**. Opt-in —
they're not installed by `setup.sh --all`.

| Routine | Schedule | Does | Writes | Opens |
|---|---|---|---|---|
| `babysit-prs.yml` | every 6h | nudge PRs stuck in `sdlc:needs-human` / red checks | comments | — |
| `dep-refresh.yml` | weekly (Mon) | bump deps, test, summarize | a branch | a PR |
| `flaky-triage.yml` | nightly | cluster recent CI failures into flakes | — | an issue |
| `morning-triage.yml` | daily (06:00 UTC) | the loop's **discovery** move: read failed CI + new issues + merged commits, judge what's worth doing, reconcile one pinned "triage state" issue (durable memory); hand-off to the SDLC loop is opt-in (`TRIAGE_AUTO_HANDOFF=on`) | — | an issue (state) + findings |
| `doc-freshness.yml` | weekly (Mon) | fix docs that drifted from code | a branch | a PR |
| `vuln-remediate.yml` | nightly (04:00 UTC) | scan deps (govulncheck/npm audit/pip-audit/cargo audit) + Dependabot/code-scanning alerts; auto-fix SAFE ones into a test-gated PR on `routine/security-*`; file one de-duped issue for the rest | a branch | a PR + an issue |
| `mission-digest.yml` | `*/30` best-effort | maintain ONE pinned "fleet panel" issue of every open PR's state; @mention `FLEET_MAINTAINER` only on a NEW `needs-human` transition; gh-only (no model) | — | an issue (once; updates it each run) |

> **`ci-fix`** (`sdlc/workflows/sdlc-ci-fix.yml`) — the "no CI failure goes unhandled"
> loop. Not a cron routine: it fires the moment any check suite completes red. PR failure →
> failing log commented + `agent:needs-fix` (the existing fix loop + round cap take over);
> default-branch failure → one free rerun, then a budget-capped CI medic opens a `ci-fix/*`
> PR. On by default once installed; disable with repo variable `SDLC_CI_FIX=off`. Local
> no-Actions equivalent: `compass schedule add ci-watch --daily` (prompt:
> [`prompts/ci-watch.md`](prompts/ci-watch.md)).

> **`auto-approve`** (`sdlc/workflows/sdlc-autoapprove.yml`) — policy-gated eligibility
> signal that fires when a PR is labeled `agent:reviewed-clean`. Off by default; enable
> with repo variable `SDLC_AUTOAPPROVE=on`. Never calls `gh pr review --approve` and
> never merges — comment + label only. Governed by ADR-0003. Installed by `setup.sh --all`
> (not `--routines`), because it is a workflow-trigger workflow, not a scheduled routine.

## Install
```bash
cd <your-repo>
~/compass/sdlc/setup.sh --routines        # copies these into .github/workflows/ + commits
# or copy individually:
cp ~/compass/sdlc/routines/babysit-prs.yml .github/workflows/
```
They use the same secrets as the pipeline (`CLAUDE_CODE_OAUTH_TOKEN`, `SDLC_BOT_TOKEN`,
and `OPENAI_API_KEY` only if a routine calls Codex). Each has a `workflow_dispatch:` trigger
so you can run it on demand from the Actions tab before trusting the cron.

## Safety
- **Budget caps** (`--max-budget-usd`, `--max-turns`) on every routine — scheduled spend is
  bounded. Watch the first few runs in the Actions tab / `claude agents`.
- **Least privilege**: `babysit`/`flaky` are read-mostly; `dep-refresh`/`doc-freshness` push
  only to their own `routine/*` branch, never a protected branch.
- **No merge, no deploy** — every routine stops at a PR or comment. Humans own the rest.
- Start with **one** (`babysit-prs`), confirm the cadence/cost, then add more.

## Local alternative (no GitHub Actions)
On a machine where `claude` is logged in, the [`/schedule`](https://docs.claude.com) skill
(Claude Code ≥ v2.1.147) runs the same idea as a local routine, e.g.
`/schedule "nudge PRs stuck in sdlc:needs-human; comment only, never merge" --interval "0 */6 * * *"`,
visible in `claude agents`.
