# SDLC agent registry

The governed roster. Every autonomous action is performed by one of these agents,
under its stated **mandate**, **engine**, **least-privilege tools**, and **gate**.
Names are stable; `tag` is the machine label that drives the pipeline.

> **Prime directive:** agents do all the labor; a **human approves the irreversible
> steps** — merge to a protected branch, and deploy/publish. No agent merges or
> deploys. (Enforced by branch protection + required reviews, not trust.)

| Agent | Mandate | Engine | Tag | Tools (scoped) | Gate | Runs in |
|---|---|---|---|---|---|---|
| **Planner** | Triage an issue → a concrete plan / ADR. No code. | Claude · opus | `agent:plan` | Read, Grep, Glob, WebSearch | — | GitHub-native |
| **Builder** | Fix review feedback on the PR branch; push (closes the loop). Also: `@claude` ad-hoc implement. | Claude · sonnet | `agent:build` / `agent:needs-fix` | Read, Edit, Write, Grep, Glob, Bash(build/test/git) | — | GitHub-native + local |
| **Reviewer** | Correctness/convention review; inline comments; emits `BLOCKING`/`CLEAN` verdict; drives the fix loop. | Claude · sonnet | `agent:review` | Read, Grep, Glob, Bash(git diff/log) | **required check** (red on Blocking) | GitHub-native + local |
| **Auditor** | Independent cross-audit (second opinion). No edits. | Codex · gpt-5.5 | `agent:audit` | read-only sandbox | — | GitHub-native |
| **Security** | Secrets / authz / injection / tenancy. Advisory (does not gate merge). | Claude · opus | `agent:security` | Read, Grep, Glob, Bash(git diff) | — | GitHub-native + local |
| **QA** | Run the test suite; fail the check on test failure. | auto-detect | `agent:qa` | test runner (go/cargo/npm/pytest/make) | **required check** (red on failure) | GitHub-native + local |
| **Releaser** | Changelog + version bump on the PR branch. Never tags, publishes, or merges. | Claude · sonnet | `agent:release` | Read, Edit, Bash(git, gh) | **human approve** | GitHub-native |
| **Test-architect** | Generate unit + e2e tests for a change, run + validate them; the **safety gate** — no adequate tests, no approve/merge. | Claude · sonnet | (gate) | Read, Edit, Write, Grep, Glob, Bash(build/test/cov) | **gates** approve/merge | subagent / local |

## Fleet & routines (scheduled / cross-repo agents)

Opt-in, scheduled or comment-driven. Same prime directive: **no agent merges or deploys.** See [`docs/14-fleet.md`](../docs/14-fleet.md).

| Agent | Mandate | Engine | Trigger | Tools (scoped) | Gate | Governs |
|---|---|---|---|---|---|---|
| **vuln-remediate** | Scan deps + SAST + GitHub alerts; auto-fix only the SAFE ones into a **test-gated PR**, file an issue for the rest. | Claude · sonnet | nightly cron + dispatch | scan tools + Bash(build/test/git/gh), branch `routine/security-*` only | never merges; **tests must pass** | per-repo |
| **mission-digest** | Maintain ONE pinned "fleet panel" issue of every PR's state; @mention the maintainer on new `needs-human`. | gh-only (no model) | `*/30` cron (best-effort) + dispatch | Bash(gh pr/issue read+edit) | read + one issue | per-repo |
| **fleet-digest** | Cross-repo: aggregate open-PR state across ALL repos in `fleet/repos.txt` into ONE pinned panel issue in the control repo; @mention `FLEET_MAINTAINER` on new `needs-human` anywhere. gh-only, idempotent. | gh-only (no model) | `*/30` + dispatch | Bash(gh pr list/issue edit); Issues:write on control repo only | read + one issue | cross-repo (needs `FLEET_TOKEN`) |
| **issue-poller** | Cross-repo: scan each repo in `fleet/repos.txt` for maintainer-labeled `agent:autofix` issues; swap label to `agent:build` to trigger that repo's own zero-touch intake loop. Never edits code or merges. `max_per_run` cost guard (default 5). Idempotent (each issue dispatches once). | gh-only (no model) | `*/30` + dispatch | Bash(gh issue list/edit); Issues:write on target repos | label-swap only | cross-repo (needs `FLEET_TOKEN`) |
| **auto-approve** | Mark a reviewed-clean PR `agent:approve-eligible` if it passes the allowlist. **Comment + label only; never a GitHub Approval; never merges.** | gh-only (no model) | `pull_request: labeled` | Bash(gh pr comment/edit) | **[ADR-0003](../docs/adr/0003-auto-approve-trust-boundary.md)**; off by default | per-repo |
| **compass listen** | Relay iMessage/WhatsApp slash-commands (`/status`, `/approve\|/hold\|/resume #N`, `/build #N`) to GitHub PR comments or issue labels. **Enforces nothing itself** — posts comments that the governed per-repo `sdlc-control.yml` workflow then executes. Local daemon only; needs `gh` authenticated + reachable iMessage/WhatsApp bridge. UNVERIFIED end-to-end. | Node 22 daemon (no model) | long-running local process | Bash(gh pr comment, gh issue label); no direct merge/approve | relay only; gate enforced by sdlc-control.yml | local → per-repo |
| **ci-fix** | "No CI failure goes unhandled": PR check red → failing log commented + `agent:needs-fix` (existing fix loop + round cap take over); default-branch red → one free rerun, then a CI medic opens a `ci-fix/*` PR. Kill switch `SDLC_CI_FIX=off`. Local form: `compass schedule add ci-watch`. | gh glue + Claude · sonnet | `check_suite: completed` | Bash(gh) + edit on `ci-fix/*` branch only; $5/30-turn cap | PR/comment only; never merges | per-repo |
| **dep-refresh · flaky-triage · doc-freshness · babysit-prs** | (existing routines) — dep bumps, flake clustering, doc drift, PR nudges. | Claude · sonnet/haiku | weekly/nightly/6h cron | per [routines README](routines/README.md) | issue/PR only | per-repo |

## The closed loop (review ⇄ fix)

The Reviewer and Builder are wired into an automatic feedback loop on every PR push:

```
open PR / push
     │
     ▼
Reviewer (every push) ──── CLEAN ────▶ label: agent:reviewed-clean
Security (open/reopen)                     │
Auditor  (open/reopen)                     ▼
QA       (every push)              [required checks green]
                                           │
     ▲                                     ▼
     │                              human merge (gated)
     │
Reviewer ── BLOCKING ──▶ label: agent:needs-fix
                               │
                               ▼ (triggers sdlc-fix.yml — same-repo PRs only)
                         Builder reads PR comments,
                         fixes on the PR's own branch,
                         pushes (re-triggers Reviewer)
                               │
                    ┌──────────┘
                    │  repeat up to SDLC_MAX_FIX_ROUNDS (default 3)
                    │  each round: label sdlc:round-N, sdlc:fixing
                    │
                    └── cap hit ──▶ label: sdlc:needs-human
                                   (human resolves, then re-pushes or re-labels)
```

**Loop labels** (set by agents, not humans):

| Label | Set by | Meaning |
|---|---|---|
| `agent:needs-fix` | Reviewer | Blocking findings found; triggers Builder |
| `agent:reviewed-clean` | Reviewer | No Blocking findings this round |
| `sdlc:fixing` | Builder | Fix in progress (in-flight marker) |
| `sdlc:round-N` | Builder | Round counter (N = 1..SDLC_MAX_FIX_ROUNDS) |
| `sdlc:needs-human` | Builder | Round cap hit; human intervention needed |

**The loop requires `SDLC_BOT_TOKEN`** (a fine-grained PAT: Contents=write, Pull
requests=write on the repo). GitHub will not let a push or label set with the default
`GITHUB_TOKEN` re-trigger another workflow (its built-in recursion guard). Without the PAT,
review + one fix still run, but the loop stops there — human pushes or `@claude` to continue.

**Fork PRs** get review, security, and audit but never the write-capable fix loop
(`sdlc-fix.yml` is gated to `head.repo == repo`).

## Pipeline (label state machine — full)
```
issue ──▶ [agent:plan] ──▶ Builder opens PR
                                 │
                           ┌─────┴──────────────────────────────────────────────────┐
                           │  on every push                                          │
                           │  Reviewer ─ CLEAN ─▶ agent:reviewed-clean              │
                           │      │                                                  │
                           │  BLOCKING                                               │
                           │      ▼                                                  │
                           │  agent:needs-fix ──▶ Builder ──▶ push ──▶ (loop back)  │
                           │  (or sdlc:needs-human when cap hit)                    │
                           │                                                         │
                           │  on open/reopen: Security (advisory) + Auditor         │
                           │  on every push:  QA (required check)                   │
                           └─────────────────────────────────────────────────────────┘
                                 │ both required checks green + 1 code-owner approval
                                 ▼
                           [human merge gate]
                                 │
                           [agent:release] ──▶ Releaser preps CHANGELOG/version
                                 │
                           [human tag + deploy gate]
```

- **Coordination medium:** the PR — labels advance state, comments carry each agent's output.
- **Cross-audit:** flip Reviewer ↔ Auditor to audit a Codex-authored branch with Claude.
- **`orchestrate.sh`** (local): runs Planner → Builder → Reviewer → Auditor → Security → QA
  → opens a PR. The Reviewer/Security/QA local agents are direct `claude -p` / `codex exec`
  calls; the closed label-loop is GitHub-native only.

## Governance invariants
1. **Least privilege.** Each workflow sets explicit minimal `permissions`; each agent gets
   only the tools in its row. Default token is read-only; writes are per-job.
2. **Human owns the irreversible.** Merge to protected branches and deploy require human
   approval (branch protection + required reviews + protected Environments). `setup.sh
   --protect` sets required checks `review` + `qa` + 1 code-owner approval.
3. **Untrusted input.** PR titles/bodies/comments/diffs are treated as hostile — agents are
   told to ignore embedded instructions; `pull_request_target` with untrusted checkout is
   never used.
4. **Budget + loop guards.** Every headless run caps `--max-turns` and `--max-budget-usd`;
   `SDLC_MAX_FIX_ROUNDS` (default 3) caps the auto-fix loop; hitting the cap labels
   `sdlc:needs-human` and posts a comment.
5. **`SDLC_BOT_TOKEN`** — a fine-grained PAT (Contents+PRs write) is required for the loop
   to chain. Without it the workflow degrades gracefully (one round, then manual).
6. **Audit trail.** Every agent action is a commit, review, or labeled comment — fully logged.
