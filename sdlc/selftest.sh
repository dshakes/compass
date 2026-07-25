#!/usr/bin/env bash
# selftest.sh — unit tests for the SDLC loop's control logic.
#
# The closed loop's correctness hinges on three pure pieces of logic that are
# embedded inline in the workflows (they can't be sourced — the workflows are
# copied standalone into each target repo). This script mirrors those exact
# one-liners and asserts their behavior, so a regression is caught in CI before
# it ships. If you change the logic in a workflow, update the mirror here too.
#
# Run:  bash sdlc/selftest.sh    (exit 0 = all pass; non-zero = failure)
set -uo pipefail

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s — got [%s] want [%s]\n' "$1" "$2" "$3"; }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

# ── 1 · Round-cap logic (mirror of sdlc-fix.yml "Round cap") ──────────────────
# Given the PR's current labels and the cap, decide proceed vs stop, and the round.
round_decision() { # args: <labels-multiline> <max>  → "proceed N" | "stop"
  local labels="$1" max="$2" round=0 n next
  for n in $(seq 1 50); do
    printf '%s\n' "$labels" | grep -qx "sdlc:round-$n" && round=$n
  done
  next=$((round + 1))
  if [ "$next" -gt "$max" ]; then echo "stop"; else echo "proceed $next"; fi
}

echo "round-cap:"
eq "no rounds yet → round 1"            "$(round_decision ''                              3)" "proceed 1"
eq "round-1 present → round 2"          "$(round_decision 'sdlc:round-1'                  3)" "proceed 2"
eq "rounds 1,2 → round 3 (at cap)"      "$(round_decision $'agent:needs-fix\nsdlc:round-1\nsdlc:round-2' 3)" "proceed 3"
eq "rounds 1,2,3 → stop (cap hit)"      "$(round_decision $'sdlc:round-1\nsdlc:round-2\nsdlc:round-3' 3)" "stop"
eq "non-contiguous (round-3 only) → stop at cap 3" "$(round_decision 'sdlc:round-3'       3)" "stop"
eq "cap raised to 5 → round 4 proceeds" "$(round_decision $'sdlc:round-1\nsdlc:round-2\nsdlc:round-3' 5)" "proceed 4"
eq "substring guard: round-10 ≠ round-1" "$(round_decision 'sdlc:round-10'               3)" "stop"

# ── 2 · Self-hosted verdict parse (mirror of sdlc-review.yml self-hosted) ─────
verdict_selfhosted() { # arg: review text on stdin → BLOCKING | CLEAN
  local v; v="$(grep -o 'SDLC-VERDICT: \(BLOCKING\|CLEAN\)' | tail -1 | awk '{print $2}')"
  [ -n "$v" ] && echo "$v" || echo CLEAN
}
echo "verdict (self-hosted / grep):"
eq "ends BLOCKING"        "$(printf 'review…\nSDLC-VERDICT: BLOCKING\n'        | verdict_selfhosted)" "BLOCKING"
eq "ends CLEAN"           "$(printf 'review…\nSDLC-VERDICT: CLEAN\n'           | verdict_selfhosted)" "CLEAN"
eq "no verdict → CLEAN"   "$(printf 'review with no verdict line\n'           | verdict_selfhosted)" "CLEAN"
eq "last wins (B then C)" "$(printf 'SDLC-VERDICT: BLOCKING\nSDLC-VERDICT: CLEAN\n' | verdict_selfhosted)" "CLEAN"

# ── 3 · Hosted verdict parse (mirror of sdlc-review.yml structured_output) ────
if command -v jq >/dev/null; then
  verdict_hosted() { local v; v="$(printf '%s' "$1" | jq -r '.verdict // "CLEAN"' 2>/dev/null || echo CLEAN)"; [ -n "$v" ] && echo "$v" || echo CLEAN; }
  echo "verdict (hosted / jq structured_output):"
  eq "BLOCKING json"        "$(verdict_hosted '{"verdict":"BLOCKING","summary":"x"}')" "BLOCKING"
  eq "CLEAN json"           "$(verdict_hosted '{"verdict":"CLEAN"}')"                   "CLEAN"
  eq "missing field→CLEAN"  "$(verdict_hosted '{"summary":"x"}')"                       "CLEAN"
  eq "garbage→CLEAN"        "$(verdict_hosted 'not json at all')"                       "CLEAN"
  eq "empty→CLEAN"          "$(verdict_hosted '')"                                      "CLEAN"
else
  echo "verdict (hosted / jq): SKIPPED — jq not installed"
fi

# ── 4 · Domain classification parse (mirror of sdlc-classify.yml self-hosted) ─────
domain_parse() { # arg: classifier text on stdin → ui|api|infra|docs|core
  local d; d="$(grep -oE 'SDLC-DOMAIN: (ui|api|infra|docs|core)' | tail -1 | awk '{print $2}')"
  case "${d:-}" in ui|api|infra|docs|core) echo "$d" ;; *) echo core ;; esac
}
echo "domain classification:"
eq "ui"                "$(printf 'looks frontend\nSDLC-DOMAIN: ui\n'   | domain_parse)" "ui"
eq "infra"             "$(printf 'SDLC-DOMAIN: infra\n'                 | domain_parse)" "infra"
eq "no line → core"    "$(printf 'no verdict here\n'                    | domain_parse)" "core"
eq "garbage → core"    "$(printf 'SDLC-DOMAIN: banana\n'                | domain_parse)" "core"

# ── 5 · Diff-size review routing (mirror of orchestrate.sh REVIEW_MODEL) ──────────
# Tiny diffs review on haiku; larger ones on sonnet; an explicit override always wins.
review_model() { # args: <diff-lines> <threshold> [override] → haiku|sonnet
  local lines="$1" thresh="$2" override="${3:-}"
  [ -n "$override" ] && { echo "$override"; return; }
  if [ "$lines" -gt 0 ] && [ "$lines" -le "$thresh" ]; then echo haiku; else echo sonnet; fi
}
echo "diff-size review routing:"
eq "10-line diff → haiku"        "$(review_model 10 25)"        haiku
eq "25-line diff (at cap) → haiku" "$(review_model 25 25)"      haiku
eq "26-line diff → sonnet"       "$(review_model 26 25)"        sonnet
eq "0-line diff → sonnet (safe default)" "$(review_model 0 25)" sonnet
eq "override wins over size"     "$(review_model 5 25 sonnet)"  sonnet

# ── 6 · Per-step budget cap math (mirror of orchestrate.sh STEP_BUDGET) ─────────
# BUDGET/4 via awk; default SDLC_BUDGET=8 → STEP_BUDGET=2.00.
step_budget() { awk "BEGIN{printf \"%.2f\", $1/4}"; }
echo "per-step budget cap (BUDGET/4):"
eq "default budget 8 → 2.00 per step" "$(step_budget 8)"  "2.00"
eq "budget 4 → 1.00 per step"         "$(step_budget 4)"  "1.00"
eq "budget 12 → 3.00 per step"        "$(step_budget 12)" "3.00"
eq "budget 1 → 0.25 per step"         "$(step_budget 1)"  "0.25"
eq "budget 3 → 0.75 per step"         "$(step_budget 3)"  "0.75"

# ── 1b · Auto-approve eligibility policy (mirror of sdlc-autoapprove.yml) ────────
# The allowlist's pure decisions: trusted author, fail-closed paths, path allowlist,
# size cap, tests-present. Each mirrors the exact case/test in the workflow.
aa_author()  { case ",$1," in *",$2,"*) echo trusted ;; *) echo deny ;; esac; }
aa_path()    { # args: <file> <allow-csv> → "deny-closed" | "allow" | "deny-scope"
  case "$1" in .github/*|*/secrets/*|*.tf|*Formula/*|*/migrations/*) echo deny-closed; return ;; esac
  local ok=0 pat; for pat in ${2//,/ }; do case "$1" in *"$pat"*) ok=1 ;; esac; done
  [ "$ok" = 1 ] && echo allow || echo deny-scope
}
aa_size()    { [ "$(($1 + $2))" -le "$3" ] && echo ok || echo deny; }
aa_tests()   { # args: <src-count> <tests-present 0|1> → eligible/deny
  [ "$1" -eq 0 ] || [ "$2" = 1 ] && echo ok || echo deny
}
echo "auto-approve policy:"
eq "bot author in trusted set"          "$(aa_author 'claude[bot],compass-agent' 'claude[bot]')" "trusted"
eq "human author denied"                "$(aa_author 'claude[bot],compass-agent' 'shakes')"      "deny"
eq "workflow file is fail-closed"       "$(aa_path '.github/workflows/x.yml' 'docs/,.md')"       "deny-closed"
eq "terraform is fail-closed"           "$(aa_path 'infra/prod.tf' 'docs/,.md,.tf')"             "deny-closed"
eq "docs path allowed"                  "$(aa_path 'docs/guide.md' 'docs/,.md')"                 "allow"
eq "source path outside scope denied"   "$(aa_path 'src/main.go' 'docs/,.md')"                   "deny-scope"
eq "within size cap"                    "$(aa_size 80 40 150)"  "ok"
eq "over size cap"                      "$(aa_size 120 40 150)" "deny"
eq "docs-only diff needs no tests"      "$(aa_tests 0 0)" "ok"
eq "source diff with tests ok"          "$(aa_tests 3 1)" "ok"
eq "source diff without tests denied"   "$(aa_tests 3 0)" "deny"

# ── 6b · Cumulative budget ceiling (mirror of orchestrate.sh claude_step guard) ──
# BUDGET is a hard total: spent >= BUDGET halts (exit 3); a step's cap is
# min(STEP_BUDGET, BUDGET - spent) so the last step can't overshoot the total.
budget_gate() { # args: <spent> <budget> <step_budget> → "halt" | "cap X.XX"
  local spent="$1" budget="$2" step="$3"
  if awk "BEGIN{exit !($spent >= $budget)}"; then echo halt; return; fi
  awk "BEGIN{r=$budget-$spent; printf \"cap %.2f\", (r<$step)?r:$step}"
}
echo "cumulative budget ceiling:"
eq "nothing spent → full step cap"      "$(budget_gate 0 8 2.00)"      "cap 2.00"
eq "mid-run, plenty left → step cap"    "$(budget_gate 3.10 8 2.00)"   "cap 2.00"
eq "last dollar → capped to remainder"  "$(budget_gate 7.50 8 2.00)"   "cap 0.50"
eq "spent == budget → halt"             "$(budget_gate 8.00 8 2.00)"   "halt"
eq "overshoot → halt"                   "$(budget_gate 9.25 8 2.00)"   "halt"

# ── 7 · SDLC_LITE mode skips the right stages ────────────────────────────────────
# SDLC_LITE=1 emits a note saying audit+security are skipped; review+QA+gate remain.
# We mirror the exact logic branch rather than calling orchestrate.sh itself.
lite_note() {
  local lite="${1:-0}"
  if [ "$lite" = 1 ]; then
    printf 'SDLC_LITE — skipping Codex audit + security pass (review + QA + human gate remain).'
  else
    printf 'full pipeline'
  fi
}
echo "SDLC_LITE mode:"
eq "LITE=1 skips audit+security"         "$(lite_note 1)" "SDLC_LITE — skipping Codex audit + security pass (review + QA + human gate remain)."
eq "LITE=0 runs full pipeline"           "$(lite_note 0)" "full pipeline"
eq "LITE unset behaves like 0"           "$(lite_note)"   "full pipeline"

# ── 8 · CONVERGE loop — bounded by round cap (mirror of orchestrate.sh converge) ──
# The while condition: grep BLOCKING in review.md AND r <= MAXR.
# We test: default MAXR=3; loop stops when r>MAXR; loop stops when verdict is CLEAN.
# No real git or claude calls — we use a tmp dir with a synthetic review.md.
converge_rounds() { # args: <verdict: BLOCKING|CLEAN> <maxr> → N (rounds actually run)
  local verdict="$1" maxr="${2:-3}"
  local TMPD; TMPD="$(mktemp -d)"
  # write an initial review.md with the given verdict
  printf 'SDLC-VERDICT: %s\n' "$verdict" > "$TMPD/review.md"
  local r=1 rounds=0
  while grep -qiE '^SDLC-VERDICT: BLOCKING' "$TMPD/review.md" 2>/dev/null && [ "$r" -le "$maxr" ]; do
    rounds=$((rounds + 1))
    # simulate a fix round: after each round the verdict stays BLOCKING (worst case)
    # so the loop hits the cap.  We re-write the same BLOCKING verdict so the only
    # exit is the counter, which is the bound we're testing.
    printf 'SDLC-VERDICT: BLOCKING\n' > "$TMPD/review.md"
    r=$((r + 1))
  done
  rm -rf "$TMPD"
  echo "$rounds"
}
converge_stops_on_clean() { # arg: <maxr> → 0 (never enters the loop when already CLEAN)
  converge_rounds CLEAN "$1"
}
echo "CONVERGE loop bound:"
eq "BLOCKING + cap 3 → exactly 3 rounds" "$(converge_rounds BLOCKING 3)" "3"
eq "BLOCKING + cap 1 → exactly 1 round"  "$(converge_rounds BLOCKING 1)" "1"
eq "BLOCKING + cap 5 → exactly 5 rounds" "$(converge_rounds BLOCKING 5)" "5"
eq "CLEAN verdict → 0 rounds (never enters)" "$(converge_stops_on_clean 3)" "0"
# default MAXR is 3 (SDLC_MAX_FIX_ROUNDS default)
MAXR_DEFAULT="${SDLC_MAX_FIX_ROUNDS:-3}"
eq "SDLC_MAX_FIX_ROUNDS default is 3" "$MAXR_DEFAULT" "3"

# ── 8b · GOAL-GATE — fresh-model stop condition (mirror of orchestrate.sh goal_check) ─────────
# A run-until-condition primitive: a fresh model judges an explicit stop condition by RUNNING
# the checks, and its verdict (with the reviewer's) drives the converge loop. Default-to-doubt:
# anything but a clear MET is UNMET, so the loop keeps going (bounded by the cap) until proven done.
goal_verdict() { # goal-judge text on stdin → MET | UNMET
  local v; v="$(grep -oE 'SDLC-GOAL: (MET|UNMET)' | tail -1 | awk '{print $2}')"
  case "${v:-}" in MET) echo MET ;; *) echo UNMET ;; esac
}
echo "goal-gate verdict (default-to-doubt):"
eq "ends MET → MET"           "$(printf 'ran tests, all green\nSDLC-GOAL: MET\n'   | goal_verdict)" "MET"
eq "ends UNMET → UNMET"       "$(printf 'a test failed\nSDLC-GOAL: UNMET\n'        | goal_verdict)" "UNMET"
eq "no line → UNMET (doubt)"  "$(printf 'judge said nothing useful\n'             | goal_verdict)" "UNMET"
eq "last wins (MET→UNMET)"    "$(printf 'SDLC-GOAL: MET\nSDLC-GOAL: UNMET\n'        | goal_verdict)" "UNMET"
eq "garbage → UNMET"          "$(printf 'SDLC-GOAL: maybe\n'                       | goal_verdict)" "UNMET"

# Combined converge condition: continue while (review BLOCKING) OR (goal set AND not MET), capped.
converge_rounds_combined() { # args: <review B|C> <goal-set 0|1> <goal MET|UNMET> <maxr> → rounds run
  local rv="$1" gset="$2" gv="$3" maxr="$4" r=1 rounds=0
  while { [ "$rv" = BLOCKING ] || { [ "$gset" = 1 ] && [ "$gv" != MET ]; }; } && [ "$r" -le "$maxr" ]; do
    rounds=$((rounds + 1)); r=$((r + 1))
  done
  echo "$rounds"
}
echo "goal-gated converge loop:"
eq "CLEAN review but goal UNMET → loops to cap (3)" "$(converge_rounds_combined CLEAN 1 UNMET 3)" "3"
eq "CLEAN review and goal MET → 0 rounds (done)"    "$(converge_rounds_combined CLEAN 1 MET 3)"   "0"
eq "CLEAN review, no goal set → 0 rounds"           "$(converge_rounds_combined CLEAN 0 UNMET 3)" "0"
eq "BLOCKING review, goal MET → still loops (cap 2)" "$(converge_rounds_combined BLOCKING 1 MET 2)" "2"
eq "BLOCKING + goal UNMET → loops to cap 3"         "$(converge_rounds_combined BLOCKING 1 UNMET 3)" "3"

# ── 9 · Spec-kit discovery candidate paths ───────────────────────────────────────
# orchestrate.sh iterates: .specify/specs/*/spec.md specs/*/spec.md specs/spec.md
# spec.md SPEC.md docs/spec.md — first match wins. We test first-match priority.
# The original loop runs in the target repo's CWD; we mirror it by cd-ing into the
# test fixture directory so the glob expansion works identically.
spec_discover() { # arg: <tmpdir> → discovered path or empty
  ( cd "$1" && for cand in .specify/specs/*/spec.md specs/*/spec.md specs/spec.md spec.md SPEC.md docs/spec.md; do
      [ -f "$cand" ] && echo "$cand" && return 0
    done )
}
echo "spec-kit discovery:"
# each case uses an isolated tmp dir to avoid cross-test contamination
SD1="$(mktemp -d)"
eq "no spec → empty discovery"  "$(spec_discover "$SD1")" ""
rm -rf "$SD1"

SD2="$(mktemp -d)"
printf 'spec\n' > "$SD2/spec.md"
eq "spec.md discovered" "$(spec_discover "$SD2")" "spec.md"
rm -rf "$SD2"

SD3="$(mktemp -d)"
mkdir -p "$SD3/.specify/specs/myspec"; printf 'spec\n' > "$SD3/.specify/specs/myspec/spec.md"
printf 'spec\n' > "$SD3/spec.md"     # lower-priority candidate also present
eq ".specify/specs/*/spec.md wins (first candidate)" "$(spec_discover "$SD3")" ".specify/specs/myspec/spec.md"
rm -rf "$SD3"

SD4="$(mktemp -d)"
mkdir -p "$SD4/docs"; printf 'spec\n' > "$SD4/docs/spec.md"
eq "docs/spec.md discovered as last candidate" "$(spec_discover "$SD4")" "docs/spec.md"
rm -rf "$SD4"

SD5="$(mktemp -d)"
mkdir -p "$SD5/specs/feat"; printf 'spec\n' > "$SD5/specs/feat/spec.md"
eq "specs/*/spec.md priority over specs/spec.md" "$(spec_discover "$SD5")" "specs/feat/spec.md"
rm -rf "$SD5"

# ── 10 · Source anchors — tie the mirrors above to the REAL orchestrate.sh ────────
# Sections 5–9 mirror inline logic that can't be sourced (orchestrate.sh runs the
# pipeline on load). A mirror alone is tautological — it would still pass if the real
# script drifted. These anchors assert the exact expressions still exist in the source,
# so changing BUDGET/4, the round cap, the diff threshold, the LITE text, or the spec
# search order in orchestrate.sh fails this test until the mirror above is updated too.
ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/orchestrate.sh"
src_has() { if grep -Fq -- "$2" "$ORCH"; then ok "$1"; else bad "$1" "absent from orchestrate.sh" "$2"; fi; }
echo "source anchors (mirrors must match orchestrate.sh):"
src_has "per-step budget is BUDGET/4"               'BUDGET/4}'
src_has "cumulative ceiling halts the run"          'exit !($spent >= $BUDGET)'
src_has "step cap is min(step, remaining)"          '(r<$STEP_BUDGET)?r:$STEP_BUDGET'
src_has "ceiling halt is exit 3"                    'halting before'
src_has "fix-round cap default is 3"                'SDLC_MAX_FIX_ROUNDS:-3'
src_has "diff-size haiku threshold default is 25"   'SDLC_HAIKU_DIFF_LINES:-25'
src_has "tiny diff routes review to haiku"          'REVIEW_MODEL="haiku"'
src_has "SDLC_LITE note text matches"               'SDLC_LITE — skipping Codex audit + security pass (review + QA + human gate remain).'
src_has "spec-kit discovery order matches"          '.specify/specs/*/spec.md specs/*/spec.md specs/spec.md spec.md SPEC.md docs/spec.md'
src_has "1h prompt-cache TTL wired (opt-out)"       'ENABLE_PROMPT_CACHING_1H=1'
src_has "goal-gate uses a fresh judge role"         'goal-judge.md'
src_has "goal-judge model defaults to haiku"        'SDLC_GOAL_MODEL:-haiku'
src_has "goal-judge emits the MET/UNMET contract"   'SDLC-GOAL: MET'
src_has "goal verdict defaults to doubt (UNMET)"    'MET) echo MET ;; *) echo UNMET'
src_has "off by default (no goal → MET, no call)"   '[ -n "$GOAL" ] || { echo MET; return; }'
src_has "converge gates on the goal verdict"        '[ "$GOAL_V" != MET ]'
src_has "goal implies the converge loop"            '[ -n "$GOAL" ]; then'

# Anchors for OTHER copies of duplicated logic (the audit's DRIFT finding): the
# selfhosted runner and the auto-approve policy each carry the same expressions.
SDLC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
file_has() { if grep -Fq -- "$3" "$SDLC_DIR/$2"; then ok "$1"; else bad "$1" "absent from $2" "$3"; fi; }
echo "cross-copy anchors (selfhosted + auto-approve carry the same logic):"
file_has "selfhosted fix mirrors the round scan"       "selfhosted/sdlc-fix.yml"      'sdlc:round-$n'
file_has "selfhosted fix mirrors the round cap"        "selfhosted/sdlc-fix.yml"      'SDLC_MAX_FIX_ROUNDS || 3'
file_has "workflow fix mirrors the round scan"         "workflows/sdlc-fix.yml"       'sdlc:round-$n'
file_has "autoapprove fail-closed globs match mirror"  "workflows/sdlc-autoapprove.yml" '.github/*|*/secrets/*|*.tf|*Formula/*|*/migrations/*'
file_has "autoapprove author check matches mirror"     "workflows/sdlc-autoapprove.yml" ',$TRUSTED_AUTHORS,'
file_has "autoapprove never approves or merges"        "workflows/sdlc-autoapprove.yml" 'NEVER `gh pr review --approve`; NEVER merge'

echo
printf 'selftest: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
