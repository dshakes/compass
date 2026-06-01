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

echo
printf 'selftest: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
