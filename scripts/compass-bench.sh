#!/usr/bin/env bash
# compass-bench.sh — compass's reproducible benchmark. Converts the pitch from adjectives
# to numbers: precision/recall for the guardrail, accuracy for the router. Deterministic
# (no model calls, no network) so it runs in CI and gates on a floor — the same discipline
# the router eval already established. The model-dependent SDLC fix-rate bench is a
# documented, locally-runnable harness (needs a CLI + tokens), NOT CI-gated — honest.
#
#   compass-bench.sh                 # full scorecard (guardrail + router), CI-gated
#   compass-bench.sh --guardrail     # just the guardrail precision/recall
#   compass-bench.sh --router        # just the router accuracy
#   compass-bench.sh --json          # machine-readable scorecard
#   compass-bench.sh --sdlc <dir>    # run the SDLC loop on seeded-bug fixtures (needs claude)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../claude/hooks/lib/policy.sh
. "$ROOT/claude/hooks/lib/policy.sh"
CORPUS="$ROOT/scripts/guardrail-corpus.tsv"

# Floors (CI gates). A false positive (blocking a safe command) is the worst UX failure,
# so precision must be perfect; recall must be high. Override via env for experiments.
PREC_FLOOR="${COMPASS_BENCH_PRECISION_FLOOR:-100}"
RECALL_FLOOR="${COMPASS_BENCH_RECALL_FLOOR:-95}"

WHAT=all; JSON=0; SDLC_DIR=""
for a in "$@"; do case "$a" in
  --guardrail) WHAT=guardrail ;; --router) WHAT=router ;; --json) JSON=1 ;;
  --sdlc) WHAT=sdlc ;; -h|--help) echo "usage: compass-bench.sh [--guardrail|--router|--sdlc <dir>] [--json]"; exit 0 ;;
  *) [ "$WHAT" = sdlc ] && SDLC_DIR="$a" || { echo "unknown arg: $a" >&2; exit 2; } ;;
esac; done

# ── guardrail: precision / recall / accuracy over the labeled corpus ─────────────
G_TP=0; G_FP=0; G_TN=0; G_FN=0
bench_guardrail() {
  local label cmd branch reason
  while IFS=$'\t' read -r label cmd branch; do
    case "$label" in '#'*|'') continue ;; esac
    [ -n "$cmd" ] || continue
    if [ -n "${branch:-}" ]; then reason="$(POLICY_CURRENT_BRANCH="$branch" danger_reason "$cmd")"
    else reason="$(danger_reason "$cmd")"; fi
    if [ "$label" = block ]; then
      if [ -n "$reason" ]; then G_TP=$((G_TP+1)); else G_FN=$((G_FN+1)); printf '  MISS  (false negative) %s\n' "$cmd" >&2; fi
    else
      if [ -z "$reason" ]; then G_TN=$((G_TN+1)); else G_FP=$((G_FP+1)); printf '  FALSE POSITIVE: %s  → %s\n' "$cmd" "$reason" >&2; fi
    fi
  done < "$CORPUS"
}

# ── router: reuse the deterministic accuracy eval ────────────────────────────────
R_ACC=0; R_RC=0
bench_router() {
  local out
  out="$(bash "$ROOT/scripts/compass-route.sh" --eval 2>&1)"; R_RC=$?
  R_ACC="$(printf '%s' "$out" | sed -n 's/^accuracy: \([0-9.]*\)%.*/\1/p' | tail -1)"
  : "${R_ACC:=0}"
}

pct() { awk "BEGIN{ d=$2; if(d==0){print \"100.0\"} else printf \"%.1f\", 100*$1/d }"; }

if [ "$WHAT" = sdlc ]; then
  # Model-driven fix-rate harness (NOT CI-gated). Each fixture is a repo dir with a failing
  # seeded bug; we run the loop and check whether QA goes green. Needs the claude CLI.
  [ -n "$SDLC_DIR" ] && [ -d "$SDLC_DIR" ] || { echo "usage: compass-bench.sh --sdlc <fixtures-dir>"; exit 2; }
  command -v claude >/dev/null || { echo "claude CLI required for the SDLC bench (deterministic benches need none)"; exit 2; }
  pass=0; tot=0
  for fx in "$SDLC_DIR"/*/; do
    [ -d "$fx" ] || continue; tot=$((tot+1))
    echo "fixture: $fx"
    ( cd "$fx" && SDLC_NO_PR=1 SDLC_LITE=1 "$ROOT/sdlc/orchestrate.sh" "Fix the failing test" >/dev/null 2>&1 || true )
    if ( cd "$fx" && { [ -f go.mod ] && go test ./... || [ -f package.json ] && npm test --silent || pytest -q; } >/dev/null 2>&1 ); then
      pass=$((pass+1)); echo "  → GREEN"
    else echo "  → still red"; fi
  done
  echo "SDLC fix-rate: $pass/$tot"; exit 0
fi

[ "$WHAT" = router ] || bench_guardrail
[ "$WHAT" = guardrail ] || bench_router

g_total=$((G_TP+G_FP+G_TN+G_FN))
g_prec="$(pct "$G_TP" "$((G_TP+G_FP))")"
g_recall="$(pct "$G_TP" "$((G_TP+G_FN))")"
g_acc="$(pct "$((G_TP+G_TN))" "$g_total")"

if [ "$JSON" = 1 ]; then
  printf '{"guardrail":{"cases":%d,"tp":%d,"fp":%d,"tn":%d,"fn":%d,"precision":%s,"recall":%s,"accuracy":%s},"router":{"accuracy":%s}}\n' \
    "$g_total" "$G_TP" "$G_FP" "$G_TN" "$G_FN" "${g_prec:-0}" "${g_recall:-0}" "${g_acc:-0}" "${R_ACC:-0}"
  exit 0
fi

echo
echo "  🧭 compass · benchmark scorecard  (deterministic — reproducible, CI-gated)"
echo "  ──────────────────────────────────────────────────────────────────────"
if [ "$WHAT" != router ]; then
  printf "  guardrail   %d cases   precision %s%%   recall %s%%   accuracy %s%%\n" "$g_total" "$g_prec" "$g_recall" "$g_acc"
  printf "              TP %d · FP %d · TN %d · FN %d   (floors: precision %s%%, recall %s%%)\n" "$G_TP" "$G_FP" "$G_TN" "$G_FN" "$PREC_FLOOR" "$RECALL_FLOOR"
fi
[ "$WHAT" != guardrail ] && printf "  router      accuracy %s%%   (deterministic tier-picker vs labeled set)\n" "$R_ACC"
echo
echo "  model-driven SDLC fix-rate: compass bench --sdlc <fixtures>  (needs a CLI + tokens; not CI-gated)"
echo

# ── gate ─────────────────────────────────────────────────────────────────────────
rc=0
if [ "$WHAT" != router ]; then
  awk "BEGIN{exit !($g_prec >= $PREC_FLOOR)}"   || { echo "FAIL: guardrail precision $g_prec% < $PREC_FLOOR% (a safe command was blocked)" >&2; rc=1; }
  awk "BEGIN{exit !($g_recall >= $RECALL_FLOOR)}" || { echo "FAIL: guardrail recall $g_recall% < $RECALL_FLOOR% (a footgun slipped through)" >&2; rc=1; }
fi
[ "$WHAT" != guardrail ] && [ "$R_RC" -ne 0 ] && { echo "FAIL: router eval below its accuracy floor" >&2; rc=1; }
[ "$rc" -eq 0 ] && echo "  PASS — all benches meet their floors"
exit "$rc"
