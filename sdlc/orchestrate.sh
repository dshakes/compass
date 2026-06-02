#!/usr/bin/env bash
# orchestrate.sh — headless, task-ordered SDLC pipeline (run from your target repo).
#
# Agents hand off IN ORDER through a shared run-dir (.sdlc/run-*) and the feature
# branch; each reads the prior agents' outputs. The PR is the human gate — this
# script never merges or deploys.
#
#   Plan → Build → Review → Audit(Codex) → Security → QA → open PR (STOP)
#
# Usage:
#   ~/compass/sdlc/orchestrate.sh "Add rate limiting to the login endpoint"
# Env:
#   SDLC_NO_PR=1     stop before opening a PR (inspect the branch yourself)
#   SDLC_YOLO=1      Builder runs --permission-mode bypassPermissions (fully unattended)
#   SDLC_BUDGET=8    total USD budget hint; per-Claude-step cap is BUDGET/4
#   SDLC_BASE=main   base branch for the PR (default: current branch)
#   SDLC_CONVERGE=1  after review, loop fix→re-review until CLEAN or SDLC_MAX_FIX_ROUNDS (default 3)
#   SDLC_SPEC=path   spec-driven: plan/build to this spec; review verifies vs its acceptance criteria
#   SDLC_LITE=1      fast/cheap: skip Codex audit + opus security (keep review + QA + human gate)
set -uo pipefail

TASK="${1:-}"; [ -n "$TASK" ] || { echo "usage: orchestrate.sh \"<task description>\""; exit 2; }
SDLC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROLES="$SDLC_DIR/roles"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "run inside the target git repo"; exit 2; }
command -v claude >/dev/null || { echo "claude CLI required"; exit 2; }

TS="$(date +%Y%m%d-%H%M%S)"
RUN=".sdlc/run-$TS"; mkdir -p "$RUN"
BASE="${SDLC_BASE:-$(git symbolic-ref --short HEAD 2>/dev/null || echo main)}"
SLUG="$(printf '%s' "$TASK" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | cut -c1-40)"
BRANCH="sdlc/${SLUG:-task}-$TS"
BUDGET="${SDLC_BUDGET:-8}"; STEP_BUDGET="$(awk "BEGIN{printf \"%.2f\", $BUDGET/4}")"
BUILD_PERM="acceptEdits"; [ "${SDLC_YOLO:-0}" = 1 ] && BUILD_PERM="bypassPermissions"
REPO="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")")"
TASKTAG="$(printf '%s' "$TASK" | tr '\t\n' '  ' | cut -c1-60)"
# Builder model: sonnet by default. SDLC_AUTOROUTE=1 auto-picks the cheapest-correct tier
# via scripts/compass-route.sh — EXPERIMENTAL, no evals yet, so it's OFF by default.
BUILD_MODEL="${SDLC_BUILD_MODEL:-sonnet}"
[ "${SDLC_AUTOROUTE:-0}" = 1 ] && BUILD_MODEL="$("$SDLC_DIR/../scripts/compass-route.sh" "$TASK" 2>/dev/null || echo sonnet)"

# Signed Builder commits (R14, opt-in): SDLC_SIGN=1 signs commits in this run for
# provenance ("this fix came from the agent, here's the signature"). Requires a
# configured signing key (gpg or SSH); we enable repo-local signing + pass -S to our
# own safety-net commits. No key configured → git just warns; the run still completes.
SIGN_FLAG=""
if [ "${SDLC_SIGN:-0}" = 1 ]; then SIGN_FLAG="-S"; git config commit.gpgsign true 2>/dev/null || true; fi

# 1-hour prompt-cache TTL: this pipeline makes many model calls that reuse the SAME repo
# context, and the converge loop (review→fix→review) re-reads it across gaps >5min — so the
# longer cache keeps reads hot (0.1x input price) instead of re-paying full input each round.
# Net win here despite the 2x cache-write premium, precisely because of the reuse. Claude Code
# reads this env flag at startup; the child `claude -p` calls inherit it. SDLC_CACHE_1H=0 opts
# out (back to the default 5min TTL — better for genuine one-shots, not this loop).
if [ "${SDLC_CACHE_1H:-1}" = 1 ]; then export ENABLE_PROMPT_CACHING_1H=1; fi

# Spec-kit interop (R13): if SDLC_SPEC is unset, auto-discover a spec-kit / spec-driven
# spec so compass becomes the governance+execution layer UNDER the spec-driven standard
# (github/spec-kit, BMAD, Kiro) rather than competing with it. First match wins; opt out
# with SDLC_NO_SPEC_DISCOVERY=1.
if [ -z "${SDLC_SPEC:-}" ] && [ "${SDLC_NO_SPEC_DISCOVERY:-0}" != 1 ]; then
  for cand in .specify/specs/*/spec.md specs/*/spec.md specs/spec.md spec.md SPEC.md docs/spec.md; do
    if [ -f "$cand" ]; then SDLC_SPEC="$cand"; printf '  spec-kit: discovered spec → %s (set SDLC_NO_SPEC_DISCOVERY=1 to disable)\n' "$cand"; break; fi
  done
fi

# Spec-driven (opt-in): if SDLC_SPEC points at a spec file, plan/build to it and review vs it.
SPEC_CLAUSE=""
if [ -n "${SDLC_SPEC:-}" ] && [ -f "$SDLC_SPEC" ]; then
  SPEC_CLAUSE="

This work has a SPEC at $SDLC_SPEC — read it and treat its Acceptance Criteria as the contract; respect its Non-goals."
fi

log(){ printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
note(){ printf '  %s\n' "$*"; }

# Spend tracking: with jq we capture each step's real cost (claude -p --output-format json
# reports total_cost_usd) into costs.tsv; without jq we stream text and skip the tally.
COSTS="$RUN/costs.tsv"; HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1

# claude_step <name> <role> <model> <perm> <tools> <prompt>  -> $RUN/<name>.md
claude_step(){
  local name="$1" role="$2" model="$3" perm="$4" tools="$5" prompt="$6"
  log "$name  (claude · $model)"
  if [ "$HAVE_JQ" = 1 ]; then
    local j="$RUN/$name.json"
    claude -p "$prompt" --model "$model" --append-system-prompt-file "$ROLES/$role" \
      --permission-mode "$perm" --allowedTools "$tools" \
      --max-turns 25 --max-budget-usd "$STEP_BUDGET" \
      --output-format json >"$j" 2>>"$RUN/orchestrate.log" || true
    jq -r '.result // ""' "$j" 2>/dev/null | tee "$RUN/$name.md"
    local c; c="$(jq -r '.total_cost_usd // 0' "$j" 2>/dev/null || echo 0)"
    printf '%s\t%s\n' "$name" "$c" >>"$COSTS"
    { mkdir -p "${COMPASS_HOME:-$HOME/.compass}" && printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REPO" "$TASKTAG" "$model" "$c" \
        >>"${COMPASS_HOME:-$HOME/.compass}/spend.tsv"; } 2>/dev/null || true
    note "step spend: \$$(printf '%.4f' "$c" 2>/dev/null || echo "$c")"
  else
    claude -p "$prompt" --model "$model" --append-system-prompt-file "$ROLES/$role" \
      --permission-mode "$perm" --allowedTools "$tools" \
      --max-turns 25 --max-budget-usd "$STEP_BUDGET" \
      --output-format text 2>>"$RUN/orchestrate.log" | tee "$RUN/$name.md"
  fi
  # Surface a swallowed failure: a step that errored or hit the budget/turn cap leaves
  # an empty output that would otherwise feed the next phase silently.
  [ -s "$RUN/$name.md" ] || note "⚠ $name produced no output — it may have failed or hit the budget/turn cap (see $RUN/orchestrate.log)"
}

echo "compass · SDLC pipeline"
note "task:   $TASK"
note "base:   $BASE   branch: $BRANCH"
note "run:    $RUN   (build perm: $BUILD_PERM)"
# Pre-run estimate (budgeting): each Claude step is hard-capped at $STEP_BUDGET; the run
# can't exceed roughly that × the number of steps. QA is free; the Codex audit isn't tallied.
note "spend:  ceiling ~\$$STEP_BUDGET per Claude step (cap), ~\$$BUDGET total budget hint$([ "$HAVE_JQ" = 1 ] && echo '' || echo '  · install jq for per-step spend analysis')"
git checkout -b "$BRANCH" >/dev/null 2>&1 || { echo "could not create branch $BRANCH"; exit 2; }

# 1 · PLAN (read-only)
claude_step plan planner.md opus plan \
  "Read,Grep,Glob,Bash(git log:*),Bash(git diff:*)" \
  "Task: $TASK
Produce a concrete, minimal implementation plan for this repo. Write nothing but the plan.$SPEC_CLAUSE"

# tools the Builder may use (reused by the converge loop below)
BUILD_TOOLS="Read,Edit,Write,Grep,Glob,Bash(git add:*),Bash(git commit:*),Bash(go build:*),Bash(go test:*),Bash(go vet:*),Bash(cargo build:*),Bash(cargo test:*),Bash(npm:*),Bash(pnpm:*),Bash(npx tsc:*),Bash(pytest:*),Bash(ruff:*),Bash(make:*)"
REVIEW_TOOLS="Read,Grep,Glob,Bash(git diff:*),Bash(git log:*)"
REVIEW_PROMPT="Review the diff of branch $BRANCH against $BASE: run 'git diff $BASE...HEAD'. Report findings grouped Blocking / Should-fix / Nit. ${SDLC_SPEC:+Also read the spec at $SDLC_SPEC and verify the diff satisfies its Acceptance Criteria — treat any unmet criterion or out-of-scope change as Blocking. }End with EXACTLY one line: 'SDLC-VERDICT: BLOCKING' if there is any Blocking finding, else 'SDLC-VERDICT: CLEAN'."

# 2 · BUILD (edits + commits on the feature branch)
claude_step build builder.md "$BUILD_MODEL" "$BUILD_PERM" "$BUILD_TOOLS" \
  "Implement the plan in .sdlc/run-$TS/plan.md for this task: $TASK
Stay on branch $BRANCH. Add tests. Build/test what you touch. Commit your work. Do not push or merge.$SPEC_CLAUSE"
# safety net: capture any uncommitted work so the diff/PR is complete
if ! git diff --quiet || ! git diff --cached --quiet; then
  # shellcheck disable=SC2086  # SIGN_FLAG is intentionally word-split (empty or -S)
  if git add -u && git commit -q $SIGN_FLAG -m "sdlc(builder): $TASK"; then note "committed builder leftovers"
  else note "⚠ could not commit builder leftovers — the review/PR may see a stale tree"; fi
fi

# Diff-size routing (R9): a tiny diff doesn't need sonnet to review it. Pick haiku for
# diffs ≤ SDLC_HAIKU_DIFF_LINES (default 25); sonnet otherwise. Security always stays opus.
REVIEW_MODEL="${SDLC_REVIEW_MODEL:-sonnet}"
if [ -z "${SDLC_REVIEW_MODEL:-}" ]; then
  DIFF_LINES="$(git diff "$BASE"...HEAD --numstat 2>/dev/null | awk '{a+=$1+$2} END{print a+0}')"
  if [ "${DIFF_LINES:-0}" -gt 0 ] && [ "${DIFF_LINES:-0}" -le "${SDLC_HAIKU_DIFF_LINES:-25}" ]; then
    REVIEW_MODEL="haiku"; note "diff-size routing: ${DIFF_LINES}-line diff → haiku review (override: SDLC_REVIEW_MODEL=sonnet)"
  fi
fi

# 3 · REVIEW (Claude, read-only)
claude_step review reviewer.md "$REVIEW_MODEL" plan "$REVIEW_TOOLS" "$REVIEW_PROMPT"

# 3b · CONVERGE (opt-in: SDLC_CONVERGE=1) — address findings and re-review until clean or cap.
# The local mirror of the cloud loop's "review ⇄ fix until green." Humans still merge.
if [ "${SDLC_CONVERGE:-0}" = 1 ]; then
  MAXR="${SDLC_MAX_FIX_ROUNDS:-3}"; r=1
  while grep -qiE '^SDLC-VERDICT: BLOCKING' "$RUN/review.md" 2>/dev/null && [ "$r" -le "$MAXR" ]; do
    log "converge round $r/$MAXR  (fix → re-review)"
    claude_step "fix-$r" builder.md "$BUILD_MODEL" "$BUILD_PERM" "$BUILD_TOOLS" \
      "Address every Blocking and Should-fix item in .sdlc/run-$TS/review.md on branch $BRANCH for task: $TASK.
Edit the code, add/adjust tests, build/test what you touch, commit. Do not push or merge."
    if ! git diff --quiet || ! git diff --cached --quiet; then
      # shellcheck disable=SC2086  # SIGN_FLAG is intentionally word-split (empty or -S)
      git add -u && git commit -q $SIGN_FLAG -m "sdlc(converge $r): $TASK"
    fi
    claude_step review reviewer.md "$REVIEW_MODEL" plan "$REVIEW_TOOLS" "$REVIEW_PROMPT"
    r=$((r + 1))
  done
  if grep -qiE '^SDLC-VERDICT: BLOCKING' "$RUN/review.md" 2>/dev/null; then
    note "converge hit cap ($MAXR) — review still BLOCKING; a human is needed."
  else
    note "converge: review is CLEAN."
  fi
fi

# ── final assessment passes (4·audit, 5·security, 6·QA) ───────────────────────
# Defined as functions so SDLC_PARALLEL=1 can run the three INDEPENDENT, read-only
# passes concurrently (they all operate on the final converged HEAD) for lower
# wall-clock, while the default stays the proven sequential order. Semantics are
# identical either way — only the scheduling changes.

run_audit() {  # 4 · AUDIT (Codex cross-tool, read-only) — independent second opinion
  log "audit  (codex · cross-tool)"
  if command -v codex >/dev/null; then
    codex exec --sandbox read-only -o "$RUN/audit.md" \
      "Independently audit the changes on this branch ('git diff $BASE...HEAD') — a second
opinion to the Claude review. Flag correctness regressions, security, and missed edge
cases. Be concise; lead with anything Blocking." >>"$RUN/orchestrate.log" 2>&1 \
      && cat "$RUN/audit.md" >/dev/null || note "codex audit failed (see $RUN/orchestrate.log)"
  else
    note "codex CLI not found — skipping cross-audit (install it for the Claude↔Codex audit)"
  fi
}

run_security() {  # 5 · SECURITY (Claude opus, read-only)
  claude_step security security.md opus plan \
    "Read,Grep,Glob,Bash(git diff:*)" \
    "Security-audit the diff of $BRANCH against $BASE ('git diff $BASE...HEAD')."
}

run_qa() {  # 6 · QA — deterministic test run; records rc to $RUN/qa.rc
  log "qa  (test suite${SDLC_TEST_IMPACT:+ · impact-scoped})"
  local impact_paths=""
  # Test-impact selection (R9): with SDLC_TEST_IMPACT=1, run only tests affected by the
  # diff for the ecosystems where that's safe; fall back to the full suite otherwise.
  if [ "${SDLC_TEST_IMPACT:-0}" = 1 ]; then
    impact_paths="$(git diff "$BASE"...HEAD --name-only 2>/dev/null)"
  fi
  {
    if [ -f Makefile ] && grep -qE '^test:' Makefile; then make test
    elif [ -f go.mod ]; then
      if [ "${SDLC_TEST_IMPACT:-0}" = 1 ] && [ -n "$impact_paths" ]; then
        dirs="$(printf '%s\n' "$impact_paths" | grep '\.go$' | xargs -r -n1 dirname | sort -u | sed 's#^#./#;s#$#/...#')"
        if [ -n "$dirs" ]; then echo "impact: go test $dirs"; # shellcheck disable=SC2086
          go test $dirs; else go test ./...; fi
      else go test ./...; fi
    elif [ -f Cargo.toml ]; then cargo test
    elif [ -f package.json ]; then
      if [ "${SDLC_TEST_IMPACT:-0}" = 1 ] && [ -n "$impact_paths" ] && npx --no-install jest --version >/dev/null 2>&1; then
        files="$(printf '%s\n' "$impact_paths" | grep -E '\.(t|j)sx?$' | tr '\n' ' ')"
        if [ -n "$files" ]; then echo "impact: jest --findRelatedTests"; # shellcheck disable=SC2086
          npx --no-install jest --findRelatedTests $files --passWithNoTests; else npm test --silent; fi
      else npm test --silent; fi
    elif [ -f pyproject.toml ] || [ -f conftest.py ] || [ -d tests ] \
         || compgen -G 'test_*.py' >/dev/null 2>&1 || compgen -G '*_test.py' >/dev/null 2>&1 \
         || compgen -G 'requirements*.txt' >/dev/null 2>&1; then
      pytest_files=""
      [ "${SDLC_TEST_IMPACT:-0}" = 1 ] && pytest_files="$(printf '%s\n' "$impact_paths" | grep -E '(^|/)(test_.*|.*_test)\.py$' | tr '\n' ' ')"
      if command -v pytest >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        if [ -n "$pytest_files" ]; then echo "impact: pytest $pytest_files"; pytest -q $pytest_files; else pytest -q; fi
      else python3 -m pytest -q; fi
    else echo "no recognized test setup — skipped"; fi
  } >"$RUN/qa.log" 2>&1; printf '%s' "$?" >"$RUN/qa.rc"
}

if [ "${SDLC_PARALLEL:-0}" = 1 ]; then
  log "parallel: running the final independent passes concurrently"
  pids=""
  run_qa & pids="$pids $!"
  if [ "${SDLC_LITE:-0}" = 1 ]; then
    note "SDLC_LITE — skipping Codex audit + security pass (review + QA + human gate remain)."
  else
    run_audit    >"$RUN/audit.console"    2>&1 & pids="$pids $!"
    run_security >"$RUN/security.console" 2>&1 & pids="$pids $!"
  fi
  # shellcheck disable=SC2086
  wait $pids 2>/dev/null || true
  [ -s "$RUN/audit.console" ]    && sed -n '1,6p' "$RUN/audit.console"    | sed 's/^/    /'
  [ -s "$RUN/security.console" ] && sed -n '1,6p' "$RUN/security.console" | sed 's/^/    /'
else
  if [ "${SDLC_LITE:-0}" = 1 ]; then
    note "SDLC_LITE — skipping Codex audit + security pass (review + QA + human gate remain)."
  else
    run_audit
    run_security
  fi
  run_qa
fi
QA_RC="$(cat "$RUN/qa.rc" 2>/dev/null || echo 1)"
note "qa exit=$QA_RC (full log: $RUN/qa.log)"; tail -5 "$RUN/qa.log" 2>/dev/null | sed 's/^/    /'

# 6b · SBOM + dependency audit (R14, opt-in: SDLC_SBOM=1) — provenance on the PR.
# SDLC_SBOM_GATE=1 additionally treats a known vuln as a QA-style failure (draft PR).
SBOM_LINE=""
if [ "${SDLC_SBOM:-0}" = 1 ]; then
  log "sbom  (dependency audit + provenance)"
  SBOM_LINE="$("$SDLC_DIR/../scripts/compass-sbom.sh" --json 2>/dev/null || echo '{}')"
  "$SDLC_DIR/../scripts/compass-sbom.sh" 2>/dev/null | sed 's/^/  /' || true
  if [ "${SDLC_SBOM_GATE:-0}" = 1 ] && ! "$SDLC_DIR/../scripts/compass-sbom.sh" --gate >/dev/null 2>&1; then
    note "SBOM gate: known vulnerabilities present — marking QA failed so the PR opens as a draft."
    QA_RC=1
  fi
fi

# Spend analysis (post-run budgeting): tally the per-step costs captured during the run.
SPEND_LINE="spend not tracked (install jq for per-step analysis)"
if [ "$HAVE_JQ" = 1 ] && [ -f "$COSTS" ]; then
  TOTAL="$(awk -F'\t' '{s+=$2} END{printf "%.4f", s+0}' "$COSTS")"
  STEPS="$(wc -l <"$COSTS" | tr -d ' ')"
  log "spend  (Claude steps; QA free, Codex audit not tallied)"
  awk -F'\t' '{printf "    %-14s $%.4f\n", $1, $2+0}' "$COSTS"
  note "total Claude spend: \$$TOTAL   (budget hint \$$BUDGET, per-step cap \$$STEP_BUDGET)"
  SPEND_LINE="**~\$$TOTAL** across $STEPS Claude steps (budget hint \$$BUDGET; QA free; Codex audit not tallied)"
fi

# 7 · GATE — open a PR for human merge (never auto-merge/deploy)
log "gate  (open PR for human review)"
if [ "${SDLC_NO_PR:-0}" = 1 ]; then
  note "SDLC_NO_PR set — branch $BRANCH ready; PR not opened."
elif command -v gh >/dev/null; then
  git push -u origin "$BRANCH" >>"$RUN/orchestrate.log" 2>&1 || note "push failed (see log)"
  # Gate on QA: a red suite still opens a PR (the human needs to see it) but as a DRAFT
  # with a prominent banner, so a failing build can't be merged by reflex.
  DRAFT_FLAG=""; QA_BANNER="✅ QA passed."
  if [ "${QA_RC:-1}" -ne 0 ]; then
    DRAFT_FLAG="--draft"
    QA_BANNER="> [!CAUTION]\n> **QA FAILED (exit $QA_RC).** Opened as a **draft** — do not merge until the test suite is green. See the QA log below."
    note "QA failed (exit $QA_RC) — opening the PR as a DRAFT."
  fi
  {
    echo "## Autonomous SDLC run — \`$TASK\`"
    printf '%b\n' "$QA_BANNER"
    echo; echo "Pipeline: Plan → Build → Review → Codex audit → Security → QA. **Human merge gate.**"
    echo; echo "### QA"; echo '```'; tail -15 "$RUN/qa.log"; echo '```'
    echo; echo "### Review (Claude)"; sed -n '1,40p' "$RUN/review.md" 2>/dev/null
    echo; echo "### Cross-audit (Codex)"; sed -n '1,40p' "$RUN/audit.md" 2>/dev/null || echo "_skipped_"
    echo; echo "### Security"; sed -n '1,40p' "$RUN/security.md" 2>/dev/null
    echo; echo "### Spend"; echo "$SPEND_LINE"
    [ -n "$SBOM_LINE" ] && { echo; echo "### Provenance (SBOM + dep audit)"; echo '```json'; echo "$SBOM_LINE"; echo '```'; echo "Signed commits: ${SDLC_SIGN:+yes}${SDLC_SIGN:-no}."; }
    echo; echo "<sub>Generated by compass sdlc/orchestrate.sh · artifacts in \`$RUN\` · do not merge without human review.</sub>"
  } >"$RUN/pr-body.md"
  # shellcheck disable=SC2086  # DRAFT_FLAG is intentionally word-split (empty or --draft)
  gh pr create $DRAFT_FLAG --base "$BASE" --head "$BRANCH" --title "sdlc: $TASK" --body-file "$RUN/pr-body.md" \
    && note "PR opened${DRAFT_FLAG:+ (draft — QA red)} — review and merge it yourself." || note "gh pr create failed (see log)"
else
  note "gh not found — branch $BRANCH pushed-pending; open the PR manually."
fi

log "done — artifacts in $RUN  ·  remember: humans merge & deploy, agents don't."
