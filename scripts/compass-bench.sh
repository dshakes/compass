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

# Anthropic list prices ($/Mtok, retrieved 2026-07) — override via env to update rates
HAIKU_IN="${COMPASS_BENCH_HAIKU_IN:-0.80}"
HAIKU_OUT="${COMPASS_BENCH_HAIKU_OUT:-4.00}"
SONNET_IN="${COMPASS_BENCH_SONNET_IN:-3.00}"
SONNET_OUT="${COMPASS_BENCH_SONNET_OUT:-15.00}"
OPUS_IN="${COMPASS_BENCH_OPUS_IN:-15.00}"
OPUS_OUT="${COMPASS_BENCH_OPUS_OUT:-75.00}"
# Fixed token profile per routing decision (assumption — see docs/18-benchmark.md §Cost routing)
BENCH_TOK_IN="${COMPASS_BENCH_TOK_IN:-2000}"
BENCH_TOK_OUT="${COMPASS_BENCH_TOK_OUT:-500}"

WHAT=all; JSON=0; SDLC_DIR=""
for a in "$@"; do case "$a" in
  --guardrail) WHAT=guardrail ;; --content) WHAT=content ;; --router) WHAT=router ;; --cost) WHAT=cost ;; --json) JSON=1 ;;
  --sdlc) WHAT=sdlc ;; -h|--help) echo "usage: compass-bench.sh [--guardrail|--router|--cost|--sdlc <dir>] [--json]"; exit 0 ;;
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

# ── content: secret / malware / insecure findings over the labeled corpus ────────
# These three families had NO eval harness until the first ablation study reported all
# 25 of their rules as "unmeasured". Adding the corpus is the fix ablation asks for:
# write the case, THEN decide about the rule.
#
# The secret rows store credential-shaped fragments as @TOKENS@ (see content-corpus.tsv
# for why) and are materialised here, in memory only. This table is the audit surface —
# every value below is synthetic and non-functional. The PEM header is assembled from
# parts for the same reason the corpus is tokenised: compass's own secret hook refuses
# to commit the literal, and suppressing it with an allowlist marker would also
# neutralise the detector under test.
C_TP=0; C_FP=0; C_TN=0; C_FN=0
CONTENT_CORPUS="$ROOT/scripts/content-corpus.tsv"
_PK="PRIV"; _PK="${_PK}ATE"; _PEM="-----BEGIN RSA ${_PK} KEY-----"
_materialise() {
  printf '%s' "$1" \
    | sed -e 's/@ANT@/sk-ant-/g'                -e 's/@OAI@/sk-proj-/g' \
          -e 's/@AWSID@/AKIA/g'                 -e 's/@AWSSEC@/aws_secret_access_key/g' \
          -e 's/@GCP@/AIza/g'                   -e 's/@GHT@/ghp_/g' \
          -e 's/@GHPAT@/github_pat_/g'          -e 's/@GLPAT@/glpat-/g' \
          -e 's/@SLACK@/xoxb-/g'                -e 's/@STRIPE@/sk_live_/g' \
          -e 's/@NPM@/npm_/g'                   -e "s|@PEMBEGIN@|${_PEM}|g"
}
bench_content() {
  local family label payload text out
  while IFS=$'\t' read -r family label payload; do
    case "$family" in '#'*|'') continue ;; esac
    [ -n "${payload:-}" ] || continue
    text="$(_materialise "$payload")"
    case "$family" in
      secret)   out="$(secret_content_findings "$text")" ;;
      malware)  out="$(malware_intent_findings "$text")" ;;
      insecure) out="$(insecure_code_findings "$text")" ;;
      *) continue ;;
    esac
    if [ "$label" = flag ]; then
      if [ -n "$out" ]; then C_TP=$((C_TP+1)); else C_FN=$((C_FN+1)); printf '  MISS  (%s false negative) %s\n' "$family" "$payload" >&2; fi
    else
      if [ -z "$out" ]; then C_TN=$((C_TN+1)); else C_FP=$((C_FP+1)); printf '  FALSE POSITIVE (%s): %s  → %s\n' "$family" "$payload" "$out" >&2; fi
    fi
  done < "$CONTENT_CORPUS"
}

# ── router: reuse the deterministic accuracy eval ────────────────────────────────
R_ACC=0; R_RC=0
bench_router() {
  local out
  out="$(bash "$ROOT/scripts/compass-route.sh" --eval 2>&1)"; R_RC=$?
  R_ACC="$(printf '%s' "$out" | sed -n 's/^accuracy: \([0-9.]*\)%.*/\1/p' | tail -1)"
  : "${R_ACC:=0}"
}

# ── cost routing: routed vs all-opus cost on the evalset ─────────────────────
# Calls the router script per case (no model calls; uses router.json heuristic).
# See docs/18-benchmark.md §"Cost routing benchmark" for full methodology.
COST_EVALSET="$ROOT/scripts/route-evalset.tsv"
C_ROUTED="0"; C_OPUS_TOT="0"; C_NC=0
bench_cost() {
  local expected task tier _tmp
  [ -f "$COST_EVALSET" ] || { printf 'cost bench: evalset not found: %s\n' "$COST_EVALSET" >&2; return 1; }
  while IFS=$'\t' read -r expected task; do
    case "$expected" in '#'*|'') continue ;; esac
    [ -n "${task:-}" ] || continue
    tier="$(bash "$ROOT/scripts/compass-route.sh" "$task" 2>/dev/null)" || tier="sonnet"
    C_NC=$((C_NC + 1))
    _tmp="$(awk \
      -v tier="$tier" -v r="$C_ROUTED" -v o="$C_OPUS_TOT" \
      -v hi="$HAIKU_IN"  -v ho="$HAIKU_OUT" \
      -v si="$SONNET_IN" -v so="$SONNET_OUT" \
      -v oi="$OPUS_IN"   -v oo="$OPUS_OUT" \
      -v ti="$BENCH_TOK_IN" -v to="$BENCH_TOK_OUT" \
      'BEGIN{
        if (tier == "haiku")       c = hi*ti/1e6 + ho*to/1e6
        else if (tier == "sonnet") c = si*ti/1e6 + so*to/1e6
        else                       c = oi*ti/1e6 + oo*to/1e6
        printf "%.10f %.10f", r + c, o + oi*ti/1e6 + oo*to/1e6
      }')"
    C_ROUTED="${_tmp%% *}"
    C_OPUS_TOT="${_tmp##* }"
  done < "$COST_EVALSET"
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
    if ( cd "$fx" && { if [ -f go.mod ]; then go test ./...; elif [ -f package.json ]; then npm test --silent; else pytest -q; fi; } >/dev/null 2>&1 ); then
      pass=$((pass+1)); echo "  → GREEN"
    else echo "  → still red"; fi
  done
  echo "SDLC fix-rate: $pass/$tot"; exit 0
fi

case "$WHAT" in
  guardrail) bench_guardrail ;;
  content)   bench_content ;;
  router)    bench_router ;;
  cost)      bench_router; bench_cost ;;
  all)       bench_guardrail; bench_content; bench_router; bench_cost ;;
esac

g_total=$((G_TP+G_FP+G_TN+G_FN))
g_prec="$(pct "$G_TP" "$((G_TP+G_FP))")"
g_recall="$(pct "$G_TP" "$((G_TP+G_FN))")"
g_acc="$(pct "$((G_TP+G_TN))" "$g_total")"
c_total=$((C_TP+C_FP+C_TN+C_FN))
c_prec="$(pct "$C_TP" "$((C_TP+C_FP))")"
c_recall="$(pct "$C_TP" "$((C_TP+C_FN))")"

if [ "$JSON" = 1 ]; then
  printf '{"guardrail":{"cases":%d,"tp":%d,"fp":%d,"tn":%d,"fn":%d,"precision":%s,"recall":%s,"accuracy":%s},"content":{"cases":%d,"tp":%d,"fp":%d,"tn":%d,"fn":%d,"precision":%s,"recall":%s},"router":{"accuracy":%s}}\n' \
    "$g_total" "$G_TP" "$G_FP" "$G_TN" "$G_FN" "${g_prec:-0}" "${g_recall:-0}" "${g_acc:-0}" \
    "$c_total" "$C_TP" "$C_FP" "$C_TN" "$C_FN" "${c_prec:-0}" "${c_recall:-0}" "${R_ACC:-0}"
  exit 0
fi

echo
echo "  🧭 compass · benchmark scorecard  (deterministic — reproducible, CI-gated)"
echo "  ──────────────────────────────────────────────────────────────────────"
if [ "$WHAT" != router ] && [ "$WHAT" != cost ]; then
  printf "  guardrail   %d cases   precision %s%%   recall %s%%   accuracy %s%%\n" "$g_total" "$g_prec" "$g_recall" "$g_acc"
  printf "              TP %d · FP %d · TN %d · FN %d   (floors: precision %s%%, recall %s%%)\n" "$G_TP" "$G_FP" "$G_TN" "$G_FN" "$PREC_FLOOR" "$RECALL_FLOOR"
fi
[ "$WHAT" != guardrail ] && [ "$WHAT" != cost ] && printf "  router      accuracy %s%%   (deterministic tier-picker vs labeled set)\n" "$R_ACC"
if [ "$WHAT" = all ] || [ "$WHAT" = cost ]; then
  awk \
    -v r="$C_ROUTED" -v o="$C_OPUS_TOT" -v n="$C_NC" \
    -v racc="$R_ACC" \
    -v ti="$BENCH_TOK_IN" -v to="$BENCH_TOK_OUT" \
    'BEGIN{
      pct = (o > 0 ? 100*(o - r)/o : 0)
      printf "  cost routing  %d-case evalset   routed $%.4f vs all-opus $%.4f → %.1f%% cheaper\n", n, r, o, pct
      printf "                at %.1f%% routing accuracy\n", racc
      printf "                (assumption: %d tok in / %d tok out per task; Anthropic list prices 2026-07)\n", ti, to
    }'
fi
echo
echo "  model-driven SDLC fix-rate: compass bench --sdlc <fixtures>  (needs a CLI + tokens; not CI-gated)"
echo

# ── gate ─────────────────────────────────────────────────────────────────────────
rc=0
if [ "$WHAT" != router ] && [ "$WHAT" != cost ]; then
  awk "BEGIN{exit !($g_prec >= $PREC_FLOOR)}"   || { echo "FAIL: guardrail precision $g_prec% < $PREC_FLOOR% (a safe command was blocked)" >&2; rc=1; }
  awk "BEGIN{exit !($g_recall >= $RECALL_FLOOR)}" || { echo "FAIL: guardrail recall $g_recall% < $RECALL_FLOOR% (a footgun slipped through)" >&2; rc=1; }
fi
[ "$WHAT" != guardrail ] && [ "$R_RC" -ne 0 ] && { echo "FAIL: router eval below its accuracy floor" >&2; rc=1; }
[ "$rc" -eq 0 ] && echo "  PASS — all benches meet their floors"
exit "$rc"
