#!/usr/bin/env bash
# compass-route.sh — the cheapest-CORRECT model for a task, cache-aware.
#
# A deterministic, client-side, two-stage router. No network, no model call, no proxy —
# the privacy/latency posture Not Diamond charges for, but reproducible and CI-evaluated,
# which a hosted black box can't give you. Consumed by orchestrate.sh (SDLC_AUTOROUTE=1).
#
#   STAGE 1 — QUALITY FLOOR (capability). Keyword classifier picks the minimum *safe* tier.
#             An opus-class task (security/arch/concurrency/tenancy/crypto/migration) is a
#             HARD floor — never downgraded for any cost or cache reason.
#   STAGE 2 — CACHE-AWARE COST-MIN. Among tiers at/above the floor, pick the lowest expected
#             $ using Anthropic cache economics (read 0.1x, write 1.25x@5m / 2x@1h) and the
#             session's WARM set — so a small task on a warm prefix can ride an already-hot
#             tier instead of cold-loading a cheaper one (the prefix/KV-cache-aware pattern).
#
# Usage:
#   compass-route.sh [--explain|--json] "<task>"   # print: haiku | sonnet | opus
#   compass-route.sh --score  "<task>"             # append a TAB confidence 0-100
#   compass-route.sh --eval       [set.tsv]        # score the QUALITY FLOOR vs labels (CI)
#   compass-route.sh --eval-cost  [set.tsv]        # score the CACHE-AWARE decision vs labels (CI)
#
# Cache/cost signals (all optional, validated; absent = today's floor behavior):
#   COMPASS_ROUTE_WARM        comma/space list of tiers whose prompt-cache is warm this session
#   COMPASS_PREFIX_TOKENS     stable cached prefix size P (CLAUDE.md+role+repo ctx); default 8000
#   COMPASS_TASK_TOKENS       variable task delta D (e.g. diff tokens);            default 600
#   COMPASS_OUTPUT_TOKENS     expected output O;                                   default 400
#   COMPASS_ROUTE_TTL         5m (default) | 1h — cache-write multiplier for a COLD tier
#   COMPASS_ROUTE_BUDGET_BIAS low — accept one tier below a *weak* sonnet default to save $
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Stage 1: quality-floor classifier (first match wins) ──────────────────────
# opus  — high-stakes: architecture, security, auth, crypto, concurrency, multi-tenancy,
#         protocol design, threat modelling. (HARD floor.)
# haiku — trivial: typos, renames, formatting, comments, version bumps, one-liners.
# sonnet (default) — features, fixes, tests, refactors, docs.
OPUS_PAT='architect|security|\bauth\b|authn|authz|crypto|encrypt|migration|concurren|race condition|deadlock|tenant|isolation|protocol|threat|redesign|sharding|trust model'
HAIKU_PAT='typo|rename|reformat|format this|formatter|\blint\b|comment|docstring|copyright|trailing whitespace|one.liner|\bbump\b|version in|log statement'

# route_one "<task>" -> sets globals MODEL and REASON. Single source of truth for the
# capability floor, reused by the CLI, --eval, and Stage 2. Call in the CURRENT shell
# (not via $()) so the globals propagate.
route_one() {
  local task_lc; task_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if printf '%s' "$task_lc" | grep -qE "$OPUS_PAT"; then
    MODEL="opus"; REASON="matched opus keyword"
  elif printf '%s' "$task_lc" | grep -qE "$HAIKU_PAT"; then
    MODEL="haiku"; REASON="matched haiku keyword"
  else
    MODEL="sonnet"; REASON="no opus/haiku keyword matched — defaulting to sonnet"
  fi
}

# num <value> <default> -> echo value if it's a non-negative integer, else default.
# Security: every numeric env input is validated before it ever reaches arithmetic/awk,
# so a hostile COMPASS_* value can't inject (no eval, no unchecked $(( )) on user data).
num() { case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }

# route_score "<task>" -> sets MODEL, REASON, CONFIDENCE (0-100). The capability floor plus
# a weighted-signal confidence; COMPASS_ROUTE_BUDGET_BIAS=low downgrades a *weak* sonnet
# default to haiku. opus is never touched. (Kept for the --score surface.)
route_score() {
  route_one "$1"
  local lc; lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  local words; words="$(printf '%s' "$1" | wc -w | tr -d ' ')"
  local opus_hits haiku_hits
  opus_hits="$( { printf '%s' "$lc" | grep -oE "$OPUS_PAT" | wc -l | tr -d ' '; } || true )"
  haiku_hits="$( { printf '%s' "$lc" | grep -oE "$HAIKU_PAT" | wc -l | tr -d ' '; } || true )"
  : "${opus_hits:=0}" "${haiku_hits:=0}"
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

# ── Stage 2: cache-aware cost-min ─────────────────────────────────────────────
# route_decide "<task>" -> sets DECISION and DREASON. Equals the floor when no cache
# signals are present (so default behaviour and the accuracy eval are unchanged), and
# only ever moves the choice UP to an already-warm, cheaper-in-expectation tier — never
# below the floor (except the explicit budget-bias knob on a weak sonnet default).
route_decide() {
  route_one "$1"
  local floor="$MODEL"
  DREASON="$REASON"
  # Hard floor: opus-class work is returned as-is and never enters Stage 2. Reason text is
  # kept identical to route_one so the --explain contract stays stable.
  if [ "$floor" = opus ]; then DECISION="opus"; DREASON="$REASON"; return; fi

  local P D O ttl warm bias out
  P="$(num "${COMPASS_PREFIX_TOKENS:-}" 8000)"
  D="$(num "${COMPASS_TASK_TOKENS:-}" 600)"
  O="$(num "${COMPASS_OUTPUT_TOKENS:-}" 400)"
  case "${COMPASS_ROUTE_TTL:-5m}" in 1h) ttl=1h ;; *) ttl=5m ;; esac
  warm="${COMPASS_ROUTE_WARM:-}"
  bias="${COMPASS_ROUTE_BUDGET_BIAS:-}"

  # The whole decision is one awk pass over the candidate tiers — pure arithmetic on
  # validated numbers; the task text never enters awk, only the floor label does.
  out="$(awk -v floor="$floor" -v warm="$warm" -v P="$P" -v D="$D" -v O="$O" -v ttl="$ttl" -v bias="$bias" '
    function price(t){ return t=="haiku"?1.0 : t=="sonnet"?3.6 : 18.0 }   # input $ relative to Opus (Haiku≈1/18, Sonnet≈1/5)
    function rank(t){  return t=="haiku"?1   : t=="sonnet"?2   : 3 }
    function cost(t, w,   pm){ pm = w ? READ : WRITE; return pm*price(t)*P + price(t)*D + price(t)*OUTF*O }
    BEGIN{
      READ=0.1; WRITE=(ttl=="1h"?2.0:1.25); OUTF=4.0;
      fr=rank(floor);
      n=split(warm, wa, /[ ,]+/); for(i=1;i<=n;i++) if(wa[i]!="") iswarm[wa[i]]=1;
      ncand=0; split("haiku sonnet opus", ts, " ");
      for(i=1;i<=3;i++){ t=ts[i];
        ok=(rank(t)>=fr);
        if(bias=="low" && floor=="sonnet" && t=="haiku") ok=1;   # explicit cost-quality knob
        if(ok){ cand[++ncand]=t } }
      best=""; bestc=0; bestw=0;
      for(i=1;i<=ncand;i++){ t=cand[i]; w=(t in iswarm)?1:0; c=cost(t,w);
        if(best=="" || c<bestc-1e-9){ best=t; bestc=c; bestw=w } }
      if(best==floor && !bestw)            r="cost-min: floor "best" is cheapest capable (no warm gain)";
      else if(bestw && rank(best)>fr)      r="cache-affinity: warm "best" beats cold "floor" (small task on a hot prefix)";
      else if(rank(best)<fr)               r="budget-bias=low: "best" (accept a lower tier to save)";
      else if(bestw)                       r="warm "best" reused (cache hit)";
      else                                 r="cost-min: "best;
      printf "%s\t%s", best, r;
    }' )"
  local tab; tab="$(printf '\t')"
  DECISION="${out%%"${tab}"*}"; DREASON="${out#*"${tab}"}"
  [ -n "$DECISION" ] || { DECISION="$floor"; DREASON="cost-min unavailable — floor $floor"; }
}

# ── --eval: score the QUALITY FLOOR (capability) against labels ───────────────
run_eval() {
  local set="${1:-$HERE/route-evalset.tsv}"
  [ -f "$set" ] || { printf 'eval set not found: %s\n' "$set" >&2; exit 2; }
  local total=0 correct=0 expected task got
  local h_t=0 h_h=0 s_t=0 s_h=0 o_t=0 o_h=0
  printf 'compass route — quality-floor eval vs %s\n\n' "${set##*/}" >&2
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

# ── --eval-cost: score the CACHE-AWARE decision against labels ────────────────
# Columns: expected <TAB> P <TAB> D <TAB> O <TAB> warm <TAB> task
run_eval_cost() {
  local set="${1:-$HERE/route-cost-evalset.tsv}"
  [ -f "$set" ] || { printf 'cost eval set not found: %s\n' "$set" >&2; exit 2; }
  local total=0 correct=0 expected P D O warm task
  printf 'compass route — cache-aware cost eval vs %s\n\n' "${set##*/}" >&2
  while IFS=$'\t' read -r expected P D O warm task; do
    case "$expected" in '#'*|'') continue ;; esac
    [ -n "${task:-}" ] || continue
    [ "$warm" = "-" ] && warm=""   # '-' sentinel = no warm tier (tab-IFS collapses an empty field)
    COMPASS_PREFIX_TOKENS="$P" COMPASS_TASK_TOKENS="$D" COMPASS_OUTPUT_TOKENS="$O" \
      COMPASS_ROUTE_WARM="$warm" route_decide "$task"
    total=$((total + 1))
    if [ "$DECISION" = "$expected" ]; then correct=$((correct + 1))
    else printf '  \033[31mmiss\033[0m  want %-6s got %-6s  P=%s D=%s O=%s warm=%-7s %s\n' \
           "$expected" "$DECISION" "$P" "$D" "$O" "${warm:-–}" "$task" >&2; fi
  done < "$set"
  [ "$total" -gt 0 ] || { printf 'cost eval set has no cases\n' >&2; exit 2; }
  local acc; acc="$(awk "BEGIN{printf \"%.1f\", 100*$correct/$total}")"
  local floor="${COMPASS_ROUTE_COST_MIN_ACCURACY:-100}"
  printf '\ncost-decision accuracy: %s%% (%d/%d)   floor: %s%%\n' "$acc" "$correct" "$total" "$floor" >&2
  if awk "BEGIN{exit !($acc >= $floor)}"; then
    printf '\033[32mPASS\033[0m cache-aware router matches the labeled cost decisions\n' >&2; return 0
  else
    printf '\033[31mFAIL\033[0m cost decisions drifted — fix the cost model or relabel a case\n' >&2; return 1
  fi
}

# ── arg parsing ───────────────────────────────────────────────────────────────
EXPLAIN=0; TASK=""; EVAL=0; EVALCOST=0; EVALSET=""; SCORE=0; JSON=0
for a in "$@"; do
  case "$a" in
    --explain)   EXPLAIN=1 ;;
    --json)      JSON=1 ;;
    --eval)      EVAL=1 ;;
    --eval-cost) EVALCOST=1 ;;
    --score)     SCORE=1 ;;
    --help|-h)
      printf 'usage: compass-route.sh [--explain|--json|--score] "<task>"\n'
      printf '       compass-route.sh --eval [set.tsv]        # quality-floor accuracy (CI)\n'
      printf '       compass-route.sh --eval-cost [set.tsv]   # cache-aware cost decisions (CI)\n'
      printf 'Prints: haiku | sonnet | opus.  Cache signals via COMPASS_ROUTE_WARM /\n'
      printf 'COMPASS_PREFIX_TOKENS / COMPASS_TASK_TOKENS / COMPASS_OUTPUT_TOKENS / COMPASS_ROUTE_TTL.\n'; exit 0 ;;
    -*) printf 'unknown option: %s\n' "$a" >&2; exit 2 ;;
    *)  if [ "$EVAL" = 1 ] || [ "$EVALCOST" = 1 ]; then EVALSET="$a"; else TASK="$a"; fi ;;
  esac
done

if [ "$EVAL" = 1 ];     then run_eval "$EVALSET";      exit $?; fi
if [ "$EVALCOST" = 1 ]; then run_eval_cost "$EVALSET"; exit $?; fi

if [ -z "$TASK" ]; then
  printf 'usage: compass-route.sh [--explain|--json|--score] "<task description>"\n' >&2
  exit 2
fi

# Call in the current shell so globals propagate (see route_one's note).
if [ "$SCORE" = 1 ]; then
  CONFIDENCE=0; route_score "$TASK"
  [ "$EXPLAIN" = 1 ] && printf 'route: %s (%s) confidence=%s%%\n' "$MODEL" "$REASON" "$CONFIDENCE" >&2
  printf '%s\t%s\n' "$MODEL" "$CONFIDENCE"
else
  DECISION=""; DREASON=""; route_decide "$TASK"
  if [ "$JSON" = 1 ]; then
    route_one "$TASK"   # floor for the json detail
    printf '{"model":"%s","floor":"%s","reason":"%s","warm":"%s"}\n' \
      "$DECISION" "$MODEL" "$DREASON" "${COMPASS_ROUTE_WARM:-}"
  else
    [ "$EXPLAIN" = 1 ] && printf 'route: %s (%s)\n' "$DECISION" "$DREASON" >&2
    printf '%s\n' "$DECISION"
  fi
fi
