# SDLC closed-loop — live smoke test

Static validation (YAML, actionlint, embedded shellcheck, `sdlc/selftest.sh`) runs in CI
and proves the *logic*. This checklist proves the **live GitHub behavior** that can only be
exercised on a real repo — the Claude GitHub App, `structured_output`, and PAT-driven
workflow chaining. Run it once per major change to the pipeline.

## Prerequisites (one-time)
- [ ] A **private** test repo with a tiny test suite (so `qa` is meaningful).
- [ ] [Claude GitHub App](https://github.com/apps/claude) installed on it.
- [ ] Secrets set: `CLAUDE_CODE_OAUTH_TOKEN` (or `ANTHROPIC_API_KEY`), `OPENAI_API_KEY`,
      and **`SDLC_BOT_TOKEN`** (fine-grained PAT: Contents + Pull requests = write).
- [ ] `~/compass/sdlc/setup.sh --all` run on it (labels, the SDLC workflows on the default
      branch, CODEOWNERS, branch protection with required checks `review` + `qa`).
- [ ] Confirm: `gh api repos/<owner>/<repo>/branches/<default>/protection` shows
      `required_status_checks.contexts = ["review","qa"]`.

## 1 · Clean PR — agents pass, PR becomes mergeable
- [ ] Open a small, correct PR.
- [ ] `sdlc-review` runs → check **green**, label **`agent:reviewed-clean`**.
- [ ] `sdlc-qa` runs → check **green**. `sdlc-security` + `sdlc-audit` post comments.
- [ ] PR shows **mergeable** after a code-owner approval. ✅ proves the happy path + gate.

## 2 · Buggy PR — the loop closes itself (the headline test)
- [ ] Open a PR with an obvious **Blocking** defect (e.g. a clear correctness/security bug
      the Reviewer will flag, ideally also breaking a test).
- [ ] `sdlc-review` → check **red**, label **`agent:needs-fix`**, inline comments posted.
- [ ] **`sdlc-fix` fires automatically** → labels **`sdlc:round-1`** + **`sdlc:fixing`**;
      a new commit by the bot appears **on the PR's own branch**.
- [ ] That push **re-triggers `sdlc-review`** (this is the PAT-chaining check — if it does
      *not* re-run, `SDLC_BOT_TOKEN` is missing/insufficient).
- [ ] Loop repeats; on success → **`agent:reviewed-clean`**, `review` green. ✅ proves the
      closed loop end to end.

## 3 · Round cap — stops and escalates
- [ ] Open a PR with a defect the Builder can't resolve (e.g. an intentionally
      contradictory requirement). Optionally lower the cap: `gh variable set SDLC_MAX_FIX_ROUNDS --body 2`.
- [ ] After the cap: label **`sdlc:needs-human`**, `agent:needs-fix` removed, and a
      "round cap hit" comment posted. ✅ proves the loop terminates (no infinite spend).

## 4 · On-demand agents
- [ ] Comment **`@claude <small change>`** on a PR → `sdlc-implement` pushes to that PR's
      branch (not a new divergent PR) and the Reviewer re-runs.
- [ ] Label an **issue** `agent:plan` → `sdlc-plan` posts a plan comment.
- [ ] Label a PR `agent:audit` → `sdlc-audit` re-runs. Label `agent:release` → `sdlc-release`
      commits a CHANGELOG/version bump to the branch (and does **not** tag/merge).

## 5 · The gate holds
- [ ] With `review` **red** (a Blocking PR), confirm the **Merge button is blocked**.
- [ ] Confirm no agent can merge — only a human, after checks are green + approval.

## Watch budget & cost
- [ ] Each fix round costs model spend (`--max-budget-usd` per step). Confirm `sdlc:round-N`
      stops at the cap; watch the Actions usage on the first real run.

## Rollback
- Disable a single agent: delete its `.github/workflows/sdlc-*.yml`.
- Disable the loop only: remove `sdlc-fix.yml` (review/audit/etc. still run).
- Full removal: delete `.github/workflows/sdlc-*.yml`, the `agent:*`/`sdlc:*` labels, and
  relax branch protection (`required_status_checks`).

> If steps 1–3 pass on a real repo, the loop is verified live. Until then, treat the
> GitHub-native loop as **statically validated only** (see CI: actionlint + selftest).
