# 34 · Review benchmark: precision and recall of the reviewer

compass publishes guardrail, router and red-team precision/recall. This adds the missing
one: how often the reviewer finds the real bug, and how often it cries wolf on a correct diff.

Run: `compass reviewbench [--reviewer CMD] [--cases DIR] [--json]`. CI (no tokens):
`bash sdlc/reviewbench/validate.sh`.

## What is measured

The corpus (`sdlc/reviewbench/cases/<id>/`) has 14 cases: `base/` (the tree before the PR),
`diff.patch` (the PR under review) and `labels.json` (`{expect: flag|clean, bugs:[{file,
line_start, line_end, class}]}`, lines on the patched side).

- 8 seeded defects: off-by-one, unchecked error, unquoted shell var, hardcoded secret, file
  race, null deref, resource leak, SQL injection.
- 6 suspicious-looking but correct diffs: refactor, test-only change, dependency bump with
  lockfile, doc change, a deliberate `rm -rf ./build` in a Makefile, shell hardening.

A finding is a **TP** if its (file, line) falls inside a labeled bug range (each bug counts
once), an **FP** if it is anywhere else or on a clean case, and a labeled bug with no finding
is an **FN**. Severity is ignored: a nit on a clean diff is still a false alarm. Output is
precision, recall, F1, each with a 95% Wilson interval (same function as the red-team
scorer), and `$/case` when the reviewer reports cost.

## Protocol: plug in any reviewer

`CMD <case-dir>` prints one JSON line per finding:
`{"file":"stats.py","line":6,"severity":"blocking","message":"..."}`, plus an optional
`{"meta":{"cost_usd":0.12}}` line.

Exit non-zero (or time out, default 600s) to fail that case only: its bugs score as FN.
Three consecutive errors, or reaching `COMPASS_MAX_USD`, halt the run. The shape follows the
`compass-review` workflow findings, with `line` split out of `path:line` for range matching.

Shipped: `reviewers/mock.sh` (from the labels; `MOCK_NOISE=n` adds n FPs per case,
`MOCK_MISS=n` drops the first n flag cases) and `reviewers/claude.sh` (the `orchestrate.sh`
review step: reviewer role, `SDLC_REVIEW_MODEL` default sonnet, plan mode, read-only tools,
`--max-budget-usd 0.25`; only the output format differs).

## Results

CI asserts the scorer on the mock (perfect = 100/100; `MOCK_NOISE=1` = 8 TP, 14 FP;
`MOCK_MISS=2` = R 75). Real run, 2026-11-01, `claude -p` model `sonnet`, one run, no retries, cap `COMPASS_MAX_USD=3`:

| TP | FP | FN | Precision (95% CI) | Recall (95% CI) | F1 | Cost |
|----|----|----|--------------------|-----------------|----|------|
| 5 | 4 | 3 | 55.6% (26.7-81.1) | 62.5% (30.6-86.3) | 58.8% | $1.77 total, $0.126/case |

All six clean diffs produced zero findings. All four FPs sit on flag cases (off-by-one,
unchecked error, file race, secret in config), which suggests a right finding on a line
outside the labeled range; findings were not kept, so that is a hypothesis, not measured.

## Caveats

- 14 cases (8 positives): wide intervals; P and R are not distinguishable from the ~76 / ~51
  public AI-review leaderboards report.
- Self-authored corpus, one bug per case, small files: easier than real PRs and prone to
  overfitting. Same caveat as the red-team corpus.
- Line matching is strict: a correct finding at the call site, not the bug site, scores wrong.
