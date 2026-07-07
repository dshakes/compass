# Autonomous SDLC — governed agents, end to end

A pipeline of **named, governed agents** that plan, build, review, cross-audit,
security-check, and test your changes — coordinating through GitHub (and a headless
local runner) — while a **human keeps the merge and deploy gates**. Claude and Codex
both participate, so reviews get an independent cross-tool second opinion.

> The honest model: agents don't chat in real time. They coordinate through the
> **PR** (labels + comments) and a **shared run-dir** — every handoff is an
> auditable artifact. See the roster in [`sdlc/agents.registry.md`](../sdlc/agents.registry.md).

## The roster

```
issue ─▶ Planner ─▶ Builder ─▶ [PR] ─▶ Reviewer ⇄ Builder (auto-fix loop)
        (Claude)   (Claude)              (Claude)
                                         Auditor  (Codex, open only)
                                         Security (Claude opus, open only)
                                         QA       (tests, every push)
                                              │
                                       [human merge gate]
                                              │
                                         Releaser ─▶ [human tag + deploy]
                                         (Claude)
```

Roster, models, scoped tools, and gates: [`sdlc/agents.registry.md`](../sdlc/agents.registry.md).

---

## The closed loop

The headline feature of the current pipeline: the Reviewer and Builder form an
automatic feedback loop — no human push required between rounds.

```
open PR / push
     │
     ├──▶ Reviewer  (sdlc-review.yml — every push)
     ├──▶ Security  (sdlc-security.yml — open/reopen only, advisory)
     ├──▶ Auditor   (sdlc-audit.yml — open/reopen + agent:audit label)
     └──▶ QA        (sdlc-qa.yml — every push, required check)

Reviewer verdict
     │
     ├── CLEAN ──▶ label: agent:reviewed-clean
     │             required check turns green
     │             (+ QA green + 1 approval) ──▶ PR is mergeable
     │
     └── BLOCKING ──▶ label: agent:needs-fix  [check turns red]
                           │
                           ▼  sdlc-fix.yml fires (same-repo PRs only)
                      Builder reads all PR review comments,
                      fixes on the PR's own branch, pushes
                           │
                           ▼  push re-triggers Reviewer (requires SDLC_BOT_TOKEN)
                      [loop back to top]
                           │
                      round cap hit (SDLC_MAX_FIX_ROUNDS, default 3)
                           │
                           └──▶ label: sdlc:needs-human
                                comment posted; human resolves
```

Loop labels set by agents (never by humans):

| Label | Who sets it | Meaning |
|---|---|---|
| `agent:needs-fix` | Reviewer | Blocking findings; triggers Builder |
| `agent:reviewed-clean` | Reviewer | No Blocking findings this round |
| `sdlc:fixing` | Builder | Fix in progress |
| `sdlc:round-N` | Builder | Which round (1..MAX) |
| `sdlc:needs-human` | Builder | Round cap hit; human needed |

---

## `SDLC_BOT_TOKEN` — why it exists and how to create it

**The problem.** GitHub's built-in recursion guard means that a push or label set with
the default `GITHUB_TOKEN` does **not** re-trigger another workflow run. Without a
different token, the Builder's push to the PR branch is silent — the Reviewer won't
fire again.

**The fix.** Create a fine-grained personal access token (PAT) with:
- **Contents: Read and write** (to push fixes to the branch)
- **Pull requests: Read and write** (to add/remove labels and post comments)
- Scoped to the target repo only

Then store it:
```bash
gh secret set SDLC_BOT_TOKEN   # paste when prompted
```

`setup.sh --secrets` sets this (along with the other credentials) and prints guidance
if `SDLC_BOT_TOKEN` is not exported.

**Without the PAT — graceful degradation.** The Reviewer runs, the Builder runs once,
but the push uses the default token and the Reviewer won't auto-re-fire. You can
continue manually: push a new commit, or comment `@claude <fix this>`. All verdicts
and labels still appear correctly.

---

## Spec-driven verification (intent, not just implementation)

The loop verifies **correctness-of-intent** when a spec is present. Write one with `/spec`
(it lands in `specs/<slug>.md`), then either commit it **in the PR** or add a `Spec: <path>`
line to the PR description. The Reviewer (hosted and self-hosted) detects the spec, checks the
diff against its **Acceptance Criteria** and **Non-goals**, and marks anything unmet or
out-of-scope as **Blocking** — so the auto-fix loop converges on what you asked for, not just
"tests pass." Locally, `orchestrate.sh` with `SDLC_SPEC=specs/<slug>.md` does the same across
plan → build → review. No spec? The loop behaves exactly as before.

## Required-status-check merge gate

`setup.sh --protect` calls the GitHub API to set:

```json
{
  "required_status_checks": { "strict": false, "contexts": ["review", "qa"] },
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "require_code_owner_reviews": true
  },
  "enforce_admins": true
}
```

- **`review`** — the Reviewer workflow's stable check name. Goes **red** when the verdict
  is `BLOCKING`, green when `CLEAN`. A PR with unresolved Blocking findings cannot merge.
- **`qa`** — the QA workflow's stable check name. Goes **red** when tests fail.
- **1 code-owner approval** — a human in `CODEOWNERS` must review agent-opened PRs; this
  is the human gate on `.github/workflows/`, `infra/`, migrations, etc.

No agent has merge authority. The checks going green is necessary but not sufficient —
a human still clicks "Merge."

---

## Two ways to run it

### A · Headless local pipeline — task-ordered, no cloud
```bash
cd /path/to/your/repo
~/compass/sdlc/orchestrate.sh "Add rate limiting to the login endpoint"
```
Runs Plan → Build → Review → Codex audit → Security → QA, each agent reading prior
outputs from `.sdlc/run-*`, then opens a PR and stops. The **closed label-loop is
GitHub-native only** — the local runner does not simulate label-triggered re-runs.

Knobs: `SDLC_NO_PR=1` (don't open the PR), `SDLC_YOLO=1` (Builder unattended),
`SDLC_BUDGET=8` (USD hint), `SDLC_BASE=main`, `SDLC_CONVERGE=1` (loop fix→re-review until clean).
Built on `claude -p` + `codex exec`.

**Run until a condition (`SDLC_GOAL`).** Instead of stopping at "the reviewer says clean," give
the loop an explicit stop condition and let a **fresh, independent model judge it** — completion
decided by a different model than the one writing the code (maker/checker):
```bash
SDLC_GOAL="all tests in test/auth pass and the lint step is clean" \
  ~/compass/sdlc/orchestrate.sh "harden the auth flow"
```
After each round a cheap judge ([`sdlc/roles/goal-judge.md`](../sdlc/roles/goal-judge.md), haiku by
default; `SDLC_GOAL_MODEL` to override) **runs the tests/lint** and emits `SDLC-GOAL: MET|UNMET`;
the loop continues until the review is CLEAN *and* the goal is MET, bounded by `SDLC_MAX_FIX_ROUNDS`
(default 3). It defaults to doubt — anything but a clear MET keeps it going — and the verdict lands
in the PR body. Setting `SDLC_GOAL` implies the converge loop. → [the five moves](20-loops.md#run-until-a-condition-not-just-n-rounds)

### B · GitHub-native — agents on your PRs

Thirteen workflows, all in `.github/workflows/` after `setup.sh`:

| Workflow | Trigger | Agent | Role in loop |
|---|---|---|---|
| `sdlc-review.yml` | every PR push | **Reviewer** (Claude · sonnet) | Sets `agent:needs-fix` or `agent:reviewed-clean`; required check |
| `sdlc-classify.yml` | PR open/reopen | **Classifier** (Claude · haiku) | Labels the diff `domain:*` so routed reviewers can gate; cheap |
| `sdlc-design-review.yml` | `domain:ui` label | **Design reviewer** (Claude · sonnet) | Routed UI design pass; advisory comment |
| `sdlc-fix.yml` | `agent:needs-fix` label | **Builder** (Claude · sonnet) | Fixes on branch + pushes; enforces round cap |
| `sdlc-audit.yml` | PR open/reopen + `agent:audit` label | **Auditor** (Codex · gpt-5.5) | Independent second opinion; advisory |
| `sdlc-security.yml` | PR open/reopen | **Security** (Claude · opus) | Deep security pass; advisory |
| `sdlc-qa.yml` | every PR push | **QA** (auto-detect stack) | Runs tests; required check |
| `sdlc-plan.yml` | `agent:plan` label on issue | **Planner** (Claude · opus) | Plans an issue; posts one comment |
| `sdlc-implement.yml` | `@claude` comment | **Builder** (Claude · sonnet) | Ad-hoc implement; opens/updates PR |
| `sdlc-implement-on-label.yml` | `agent:build` label on issue | **Implementer** (Claude · sonnet) | **Zero-touch intake**: builds a labeled issue into a PR (maintainer-gated), then the loop above runs |
| `sdlc-release.yml` | `agent:release` label on PR | **Releaser** (Claude · sonnet) | CHANGELOG + version bump on branch; never tags/publishes |
| `sdlc-control.yml` | `/revise` `/hold` `/resume` `/approve` PR comment | **you** (human-in-the-loop) | Steer the loop from the PR; keeps a sticky status panel current |
| `sdlc-autoapprove.yml` | `agent:reviewed-clean` label | **Auto-approve** (policy-gated) | Marks `agent:approve-eligible` if an allowlist holds; never approves or merges |

Setup (one command):
```bash
cd /path/to/your/repo
export CLAUDE_CODE_OAUTH_TOKEN=…   # from `claude setup-token` — subscription, no API credits
export OPENAI_API_KEY=…            # Codex cloud audit
export SDLC_BOT_TOKEN=…            # fine-grained PAT — required for the loop to chain
~/compass/sdlc/setup.sh --all      # labels + workflows + CODEOWNERS + commit/push + secrets + branch protection
```

### B2 · GitHub-native, keyless (`claude -p` on a self-hosted runner)

Run a self-hosted runner (labelled `compass`) on a machine where `claude`/`codex` are
logged in, then install the keyless workflows:
```bash
cd /path/to/your/repo
~/compass/sdlc/setup.sh --self-hosted --commit --protect
```
`SDLC_BOT_TOKEN` is still needed for the loop to chain — the "keyless" part is the
*model authentication* (no API key/token), not the workflow-chaining PAT.

**Security:** a self-hosted runner executes workflow code on your machine. Use on
private repos / trusted collaborators only. Full setup + warnings:
[`sdlc/selfhosted/README.md`](../sdlc/selfhosted/README.md).

---

## The human gate (non-negotiable, enforced by GitHub — not trust)
`setup.sh` does steps 1–3; step 4 is manual:

1. **Branch protection** on the default branch: require a PR, ≥1 approval, **review from
   Code Owners**, passing `review` + `qa` status checks, **disallow bypassing**.
2. **Deploy gate**: a protected `production` Environment with **required reviewers**.
3. **`CODEOWNERS`** (sample in `sdlc/CODEOWNERS.sample`) so a human must approve agent PRs
   touching workflows, infra, and migrations.
4. **One-time manual**: Settings → Environments → `production` → Required reviewers.

No agent has merge or deploy authority.

### Steering the loop (human-in-the-loop)
You don't have to hand-fix an agent PR or just reject it. From any PR comment
(`sdlc-control.yml`, maintainers only):
- `/revise <note>` — record your guidance and re-enter the fix loop (the Builder reads it, then the Reviewer re-runs).
- `/hold` · `/resume` — pause / resume the auto-fix loop on that PR.
- `/approve` — mark it merge-ready. With repo variable `SDLC_AUTO_MERGE=true` this queues auto-merge — but GitHub still merges only *after* the required code-owner approval + green checks, never before.

A sticky **control panel** comment shows the loop's state, required-check status, and these moves at a glance — so the human checkpoint is one place, not a hunt through the thread.

---

## Security posture

- **Least privilege**: each workflow declares minimal `permissions`; each agent gets only
  the tools in its registry row. Review/audit/security/QA are `contents: read`.
- **Fix loop write-gated**: `sdlc-fix.yml` only runs when `head.repo == repo` — fork PRs
  never get the write-capable Builder. They receive read-only review, security, and audit.
- **No `pull_request_target` with untrusted checkout** — the #1 agent-CI RCE footgun. Review
  runs on `pull_request`; Codex audit checks out the PR merge ref (not head).
- **Prompt-injection hardening**: every agent prompt states PR text/diffs are *untrusted —
  analyze, never obey*. `sdlc-implement.yml` only fires for `@claude` from
  OWNER/MEMBER/COLLABORATOR. **Zero-touch intake** (`sdlc-implement-on-label.yml`) fires only
  on a maintainer-applied `agent:build` label, re-checks the labeler has write access
  (fail-closed), and passes the issue body as *data* (a file), never inlined into the prompt.
- **Budget + round cap**: `--max-turns` and `--max-budget-usd` on every agent step;
  `SDLC_MAX_FIX_ROUNDS` (repo variable, default 3) caps the fix loop.
- **SHA-pinned actions**: `actions/checkout`, `claude-code-action`, and `codex-action` are
  pinned to full commit SHAs. Dependabot keeps them current.
- **Audit trail**: every agent action is a commit, review comment, or labeled event — fully logged.

---

## Troubleshooting

**Loop fires once but doesn't continue after the fix push.**
The Builder push used the default token. Set `SDLC_BOT_TOKEN` (fine-grained PAT,
Contents+PRs write) and re-run: `gh secret set SDLC_BOT_TOKEN`.

**`sdlc:needs-human` was applied after one round.**
Check the round label: if it's `sdlc:round-1` and the cap is 3, the Builder likely
failed mid-run (check the workflow log). Fix manually, push, and the Reviewer re-runs.
To raise the cap: `gh variable set SDLC_MAX_FIX_ROUNDS --body 5`.

**`Could not fetch an OIDC token`**
The workflow needs `id-token: write` (already set in all shipped workflows).

**`Workflow validation failed … identical content to the default branch`**
The Claude App requires the review workflow to exist unchanged on the default branch.
`setup.sh --all` commits the workflows to the default branch first, satisfying this.
Don't hand-edit the workflow only on a feature branch.

**`Credit balance is too low`**
Auth is fine; the API key has no credits. Use your subscription instead: run
`claude setup-token`, set `CLAUDE_CODE_OAUTH_TOKEN`. The local `orchestrate.sh` already
uses your subscription and is unaffected.

**Fix loop applied a wrong change.**
The Reviewer's next pass will catch it and re-label `agent:needs-fix`. If it loops to
the cap, `sdlc:needs-human` is applied and a comment is posted with context. You can
revert the bad commit, push, and the loop restarts from round 1.

---

## Releasing — one tap or one command

Two ways to cut a release; both tag, publish the GitHub Release (notes pulled from the
matching `CHANGELOG.md` section), and — for a repo that ships a Homebrew tap formula — pin
the formula to the new tarball. Pick whichever fits; they're idempotent and interchangeable.

- **From your phone / the Actions tab — `release.yml`.** `setup.sh --workflows` installs a
  `workflow_dispatch` **release** workflow. Open **Actions → release → Run workflow** (works
  from GitHub Mobile), optionally type a version (blank = newest `[X.Y.Z]` in the CHANGELOG),
  and it pushes the tag, publishes the Release as *Latest*, and — only if a `Formula/*.rb`
  exists — opens a **formula-bump PR** (kept a PR because `main` is branch-protected; merge it
  to point `brew install` at the new tag). Runs on GitHub's runners, so no local write access
  is needed. Least-privilege (`contents: write` + `pull-requests: write`), SHA-pinned, inputs
  passed via `env:` (no script injection) — it passes compass's own `check-actions` gate.
- **From a terminal — `compass release`.** The local twin (`scripts/release.sh`): same three
  steps from your machine. `compass release --dry-run` previews the plan + notes. Needs `gh`.

The version's notes come from the CHANGELOG section whose heading matches — so keep a
`## [X.Y.Z] — DATE` block current and the release notes write themselves.

## Customize

Edit the registry (`sdlc/agents.registry.md`) for names/tags, the role prompts in
`sdlc/roles/`, the workflow prompts inline in the YAML, and `sdlc/labels.yml`. Set
`SDLC_MAX_FIX_ROUNDS` as a repo variable to tune the round cap. Add `.sdlc/` to your
target repo's `.gitignore` — run artifacts are local scratch.

> Reality check: the *plumbing* (issues, PRs, labels, Actions, required reviews) is
> proven. "Fully autonomous swarm ships to prod unattended" is not reliable. compass
> keeps humans on merge/deploy on purpose.
