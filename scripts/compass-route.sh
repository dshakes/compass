#!/usr/bin/env bash
# compass-route.sh — pick the cheapest-correct model for a task.
#
# Pure function of the input: deterministic, fast, no network, no model calls.
# Consumed by orchestrate.sh when SDLC_AUTOROUTE=1.
#
# Usage:
#   compass-route.sh [--explain] "<task description>"   # print: haiku | sonnet | opus
#   compass-route.sh --eval [evalset.tsv]               # score the router vs the labeled set
#
# --explain writes the matched reason to stderr (stdout stays pipeable).
# --eval scores against scripts/route-evalset.tsv and exits non-zero below the
#        accuracy floor (COMPASS_ROUTE_MIN_ACCURACY, default 90) — this is what
#        turns SDLC_AUTOROUTE from a guess into something CI can defend.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── tier rules — loaded from the router module (THE single source of truth) ──────
#
# The patterns + tiers live in exactly one place: router/router.json. The standalone
# module (router/route.sh, router/bench.sh) and this richer CLI (--eval / --score) both
# read that spec, so they can never drift. jq is a compass dependency; if it or the spec
# is missing we exit non-zero (callers like orchestrate.sh's autoroute fall back to sonnet).
#   opus  — high-stakes (architecture, security/auth/crypto, concurrency, migrations, tenancy)
#   haiku — trivial (typos, renames, formatting, comments, version bumps, one-liners)
#   sonnet (default) — features, fixes, tests, refactors, docs
ROUTER_SPEC="${COMPASS_ROUTER_SPEC:-$HERE/../router/router.json}"
command -v jq >/dev/null 2>&1 || { echo "compass route: jq required (reads router/router.json)" >&2; exit 2; }
[ -f "$ROUTER_SPEC" ] || { echo "compass route: router spec not found: $ROUTER_SPEC" >&2; exit 2; }
# jq -r (not @tsv) so backslashes in patterns like \bauth\b survive intact.
OPUS_PAT="$(jq -r '[.rules[] | select(.tier=="opus")  | .pattern] | .[0] // empty' "$ROUTER_SPEC")"
HAIKU_PAT="$(jq -r '[.rules[] | select(.tier=="haiku") | .pattern] | .[0] // empty' "$ROUTER_SPEC")"
ROUTER_DEFAULT="$(jq -r '.default' "$ROUTER_SPEC")"
[ -n "$OPUS_PAT" ] && [ -n "$HAIKU_PAT" ] && [ -n "$ROUTER_DEFAULT" ] \
  || { echo "compass route: spec missing opus/haiku rules or default — $ROUTER_SPEC" >&2; exit 2; }

# route_one "<task>" -> sets globals MODEL and REASON (prints nothing). Single source
# of truth for the tiering, reused by both the CLI path and --eval. Callers must invoke
# it in the CURRENT shell (not `$(route_one …)`) so the globals propagate — a command
# substitution would run it in a subshell and the assignments would be lost.
route_one() {
  local task_lc; task_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if printf '%s' "$task_lc" | grep -qE "$OPUS_PAT"; then
    MODEL="opus"; REASON="matched opus keyword"
  elif printf '%s' "$task_lc" | grep -qE "$HAIKU_PAT"; then
    MODEL="haiku"; REASON="matched haiku keyword"
  else
    MODEL="$ROUTER_DEFAULT"; REASON="no opus/haiku keyword matched — defaulting to $ROUTER_DEFAULT"
  fi
}

# route_score "<task>" -> sets MODEL, REASON, and CONFIDENCE (0–100). Cost-aware tier
# on top of route_one: the deterministic keyword decision is the FLOOR (high-stakes work
# is never downgraded), and a weighted signal count yields a confidence. When the caller
# expresses a budget preference (COMPASS_ROUTE_BUDGET_BIAS=low) and a *sonnet default* is
# only weakly held, it downgrades to haiku to save spend — opus is never touched.
# Experimental, opt-in; the default `compass route` stays the proven keyword picker.
route_score() {
  route_one "$1"                                   # floor: sets MODEL/REASON
  local lc; lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  local words; words="$(printf '%s' "$1" | wc -w | tr -d ' ')"
  local opus_hits haiku_hits
  # `|| true`: grep exits 1 on no-match, which under `set -e -o pipefail` would abort.
  opus_hits="$( { printf '%s' "$lc" | grep -oE "$OPUS_PAT" | wc -l | tr -d ' '; } || true )"
  haiku_hits="$( { printf '%s' "$lc" | grep -oE "$HAIKU_PAT" | wc -l | tr -d ' '; } || true )"
  : "${opus_hits:=0}" "${haiku_hits:=0}"
  # Clamp with arithmetic (ternary) — a bare `[ … ] && x=…` returns 1 when false and
  # would abort under `set -e`. Confidence rises with corroborating keyword hits.
  case "$MODEL" in
    opus)   CONFIDENCE=$(( 60 + opus_hits * 15 )) ;;
    haiku)  CONFIDENCE=$(( 60 + haiku_hits * 15 ))
            if [ "${words:-0}" -le 5 ]; then CONFIDENCE=$(( CONFIDENCE + 10 )); fi ;;
    sonnet) if [ "${words:-0}" -le 4 ]; then CONFIDENCE=45; else CONFIDENCE=70; fi
            if [ "${COMPASS_ROUTE_BUDGET_BIAS:-}" = low ] && [ "$CONFIDENCE" -lt 55 ]; then
              MODEL="haiku"; REASON="$REASON; weak sonnet signal + budget-bias=low → haiku"
            fi ;;
  esac
  CONFIDENCE=$(( CONFIDENCE > 99 ? 99 : CONFIDENCE ))
}

# ── --eval: score the router against the labeled ground truth ─────────────────
run_eval() {
  local set="${1:-$HERE/route-evalset.tsv}"
  [ -f "$set" ] || { printf 'eval set not found: %s\n' "$set" >&2; exit 2; }
  # Fixed per-tier counters (bash 3.2 on macOS has no associative arrays).
  local total=0 correct=0 expected task got
  local h_t=0 h_h=0 s_t=0 s_h=0 o_t=0 o_h=0
  printf 'compass route — eval vs %s\n\n' "${set##*/}" >&2
  while IFS=$'\t' read -r expected task; do
    case "$expected" in '#'*|'') continue ;; esac
    [ -n "${task:-}" ] || continue
    route_one "$task"; got="$MODEL"
    total=$((total + 1))
    case "$expected" in haiku) h_t=$((h_t+1)) ;; sonnet) s_t=$((s_t+1)) ;; opus) o_t=$((o_t+1)) ;; esac
    if [ "$got" = "$expected" ]; then
      correct=$((correct + 1))
      case "$expected" in haiku) h_h=$((h_h+1)) ;; sonnet) s_h=$((s_h+1)) ;; opus) o_h=$((o_h+1)) ;; esac
    else
      printf '  \033[31mmiss\033[0m  want %-6s got %-6s  %s\n' "$expected" "$got" "$task" >&2
    fi
  done < "$set"

  [ "$total" -gt 0 ] || { printf 'eval set has no cases\n' >&2; exit 2; }
  local acc; acc="$(awk "BEGIN{printf \"%.1f\", 100*$correct/$total}")"
  printf '\nper-tier recall:\n' >&2
  [ "$h_t" -gt 0 ] && printf '  %-6s %d/%d\n' haiku  "$h_h" "$h_t" >&2
  [ "$s_t" -gt 0 ] && printf '  %-6s %d/%d\n' sonnet "$s_h" "$s_t" >&2
  [ "$o_t" -gt 0 ] && printf '  %-6s %d/%d\n' opus   "$o_h" "$o_t" >&2
  local floor="${COMPASS_ROUTE_MIN_ACCURACY:-90}"
  printf '\naccuracy: %s%% (%d/%d)   floor: %s%%\n' "$acc" "$correct" "$total" "$floor" >&2
  if awk "BEGIN{exit !($acc >= $floor)}"; then
    printf '\033[32mPASS\033[0m router meets the accuracy floor\n' >&2; return 0
  else
    printf '\033[31mFAIL\033[0m router below the accuracy floor — fix the rules or relabel a case\n' >&2; return 1
  fi
}

# ── arg parsing ───────────────────────────────────────────────────────────────
EXPLAIN=0; TASK=""; EVAL=0; EVALSET=""; SCORE=0
ENGINE="${COMPASS_ROUTE_ENGINE:-keyword}"   # keyword (default) | advanced
NEXT_ENGINE=0
for a in "$@"; do
  if [ "$NEXT_ENGINE" = 1 ]; then ENGINE="$a"; NEXT_ENGINE=0; continue; fi
  case "$a" in
    --explain)      EXPLAIN=1 ;;
    --eval)         EVAL=1 ;;
    --score)        SCORE=1 ;;
    --engine)       NEXT_ENGINE=1 ;;
    --help|-h)
      printf 'usage: compass-route.sh [--explain|--score] [--engine keyword|advanced] "<task>"\n'
      printf '       compass-route.sh --eval [--engine advanced] [set.tsv]\n'
      printf 'Prints: haiku | sonnet | opus   (--score appends a TAB confidence 0–100)\n'
      printf 'Engines: keyword (default, CI-gated, 96.9%%) | advanced (router/route.sh, 9-stage pipeline)\n'
      printf 'Env: COMPASS_ROUTE_ENGINE=advanced  COMPASS_ROUTE_BUDGET_BIAS=low\n'; exit 0 ;;
    -*) printf 'unknown option: %s\n' "$a" >&2; exit 2 ;;
    *)  if [ "$EVAL" = 1 ]; then EVALSET="$a"; else TASK="$a"; fi ;;
  esac
done

case "$ENGINE" in
  keyword|advanced) ;;
  *) printf 'compass route: unknown engine "%s" — want: keyword | advanced\n' "$ENGINE" >&2; exit 2 ;;
esac

if [ "$EVAL" = 1 ]; then
  if [ "$ENGINE" = "advanced" ]; then
    BENCHSH="$HERE/../router/bench.sh"
    [ -f "$BENCHSH" ] || { printf 'compass route: router/bench.sh not found: %s\n' "$BENCHSH" >&2; exit 2; }
    exec bash "$BENCHSH"
  fi
  run_eval "$EVALSET"; exit $?
fi

if [ -z "$TASK" ]; then
  printf 'usage: compass-route.sh [--explain|--score] [--engine keyword|advanced] "<task description>"\n' >&2
  exit 2
fi

# Advanced engine: delegate to router/route.sh (9-stage pipeline). Output format is
# identical — a single tier name on stdout, reason on stderr with --explain.
if [ "$ENGINE" = "advanced" ]; then
  ROUTESH="$HERE/../router/route.sh"
  [ -f "$ROUTESH" ] || { printf 'compass route: router/route.sh not found: %s\n' "$ROUTESH" >&2; exit 2; }
  # ponytail: unquoted empty strings expand to zero words — intentional flag-omission.
  _exp=""; _scr=""
  [ "$EXPLAIN" = 1 ] && _exp="--explain"
  [ "$SCORE" = 1 ]   && _scr="--score"
  exec bash "$ROUTESH" $_exp $_scr "$TASK"
fi

# Call in the current shell so MODEL/REASON propagate (see route_one's note).
if [ "$SCORE" = 1 ]; then
  CONFIDENCE=0; route_score "$TASK"
  [ "$EXPLAIN" = 1 ] && printf 'route: %s (%s) confidence=%s%%\n' "$MODEL" "$REASON" "$CONFIDENCE" >&2
  printf '%s\t%s\n' "$MODEL" "$CONFIDENCE"
else
  route_one "$TASK"
  [ "$EXPLAIN" = 1 ] && printf 'route: %s (%s)\n' "$MODEL" "$REASON" >&2
  printf '%s\n' "$MODEL"
fi
