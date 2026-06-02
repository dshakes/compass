#!/usr/bin/env bash
# bench.sh — score the router on what actually matters: not "accuracy %" alone, but
# COST-AT-ISO-QUALITY (the metric RouteLLM/RouterBench use) plus a generalization split.
#
# Deterministic, CI-gateable, no model calls, no network. Scores the real route.sh
# against evalset.tsv using the cost weights in router.json.
#
# Metrics (per split + a gated base+holdout aggregate):
#   accuracy           — exact tier match vs label
#   quality-retained   — % where the chosen tier is >= the minimum-adequate (label) tier
#                        (the honest stand-in for "iso-quality": picking a capable-enough tier)
#   underserve         — % routed BELOW the adequate tier (the real quality risk)
#   cost vs all-opus    — what you'd spend vs sending everything to opus  (the savings)
#   cost vs random      — vs a uniform-random tier pick
#   efficiency          — cost-optimal / router-cost  (100% = spent exactly what each task needed)
#
# NOTE on "iso-quality": this is the DETERMINISTIC layer — quality is modeled by the
# labeled minimum-adequate tier. The REAL layer (run each tier on each task, judge the
# outputs, derive the true quality-vs-cost curve) needs tokens + is non-deterministic;
# scaffold a `bench-live.sh` that emits the same TSV (split,expected,got) from real runs
# and this same math applies. See README.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC="$HERE/router.json"; SET="$HERE/evalset.tsv"
ACC_FLOOR="${ROUTER_ACC_FLOOR:-90}"        # accuracy floor on base+holdout
QUAL_FLOOR="${ROUTER_QUALITY_FLOOR:-95}"   # quality-retained floor on base+holdout
ADV_FLOOR="${ROUTER_ADV_FLOOR:-25}"        # adversarial = generalization PROBE, not a quality
                                           # gate; this floor is a regression TRIPWIRE only.
                                           # Don't raise it by overfitting rules to the probe.
ROUTE_ARGS=""   # forwarded to route.sh, e.g. --route-args "--bias cheap --ceiling sonnet"
CACHE=0; CALIB=""; CACHE_SET="$HERE/cache-evalset.tsv"
while [ $# -gt 0 ]; do
  case "$1" in
    --spec) SPEC="${2:?}"; shift ;;
    --set)  SET="${2:?}"; shift ;;
    --route-args) ROUTE_ARGS="${2:-}"; shift ;;
    --cache) CACHE=1 ;;
    --cache-set) CACHE_SET="${2:?}"; shift ;;
    --calibrate) CALIB="${2:?}"; shift ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bench: unknown arg '$1'" >&2; exit 2 ;;
  esac
  shift
done
command -v jq >/dev/null || { echo "bench: jq required" >&2; exit 2; }

# ── --calibrate: summarize cache-decision telemetry (from COMPASS_ROUTE_CACHELOG) ──
if [ -n "$CALIB" ]; then
  [ -f "$CALIB" ] || { echo "calibrate: no telemetry at $CALIB" >&2; exit 2; }
  awk -F'\t' '{ tot++; if($5==1) aff++; if($2!=$3) shift++ }
    END{ printf "cache calibration  (%d logged decisions)\n", tot;
         printf "  cache-affinity:  %d (%.0f%%) rode a warm tier off the pre-cache pick\n", aff+0, (tot?100*aff/tot:0);
         printf "  tier shifts:     %d\n", shift+0; }' "$CALIB"
  exit 0
fi

# ── --cache: cache-aware cost-min savings on a labeled warm/cold set ───────────────
# Columns: expected <TAB> P <TAB> D <TAB> O <TAB> warm(- = none) <TAB> task
# Measures the REAL win: effective $ (cache read/write modeled) of the cache-aware pick
# vs the cold pick (same task, no warm set). Gates accuracy=100% and savings>0.
if [ "$CACHE" = 1 ]; then
  [ -f "$CACHE_SET" ] || { echo "bench --cache: set not found: $CACHE_SET" >&2; exit 2; }
  cr=$(jq -r '.cache.read_mult // 0.1' "$SPEC"); cw=$(jq -r '.cache.write_mult // 1.25' "$SPEC"); cow=$(jq -r '.cache.out_weight // 4' "$SPEC")
  ch=$(jq -r '.tiers.haiku.cost' "$SPEC"); cs=$(jq -r '.tiers.sonnet.cost' "$SPEC"); co=$(jq -r '.tiers.opus.cost' "$SPEC")
  CRES="$(mktemp)"; trap 'rm -f "$CRES"' EXIT
  while IFS=$'\t' read -r expected P D O warm task; do
    case "$expected" in '#'*|'') continue ;; esac
    [ -n "${task:-}" ] || continue
    [ "$warm" = "-" ] && warm=""
    cold="$(bash "$HERE/route.sh" --spec "$SPEC" "$task" 2>/dev/null || echo '?')"
    got="$(COMPASS_ROUTE_WARM="$warm" COMPASS_PREFIX_TOKENS="$P" COMPASS_TASK_TOKENS="$D" COMPASS_OUTPUT_TOKENS="$O" \
           bash "$HERE/route.sh" --spec "$SPEC" "$task" 2>/dev/null || echo '?')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$expected" "$got" "$cold" "$P" "$D" "$O" "$warm" >> "$CRES"
  done < "$CACHE_SET"
  awk -F'\t' -v ch="$ch" -v cs="$cs" -v co="$co" -v cr="$cr" -v cw="$cw" -v ow="$cow" '
    function tc(t){ return t=="haiku"?ch:(t=="sonnet"?cs:co) }
    function eff(t,P,D,O,w){ return (w?cr:cw)*tc(t)*P + tc(t)*D + tc(t)*ow*O }
    { tot++; want=$1; got=$2; cold=$3; P=$4; D=$5; O=$6; warm=$7
      if(got==want) ok++
      w=(warm!=""); chosen_cost += eff(got,P,D,O,w); cold_cost += eff(cold,P,D,O,0) }
    END{
      acc = tot? 100*ok/tot : 0; sav = cold_cost>0 ? 100*(1-chosen_cost/cold_cost) : 0
      printf "\033[1mrouter cache benchmark\033[0m  (read %.2fx write %.2fx)\n", cr, cw
      printf "  cases %d   decision-accuracy %.1f%%   effective $ saved vs cold %.1f%%\n", tot, acc, sav
      fail=0
      if(acc < 100){ printf "  \033[31m✗\033[0m accuracy %.1f%% (floor 100%%)\n", acc; fail=1 } else printf "  \033[32m✓\033[0m accuracy 100%%\n"
      if(sav <= 0){ printf "  \033[31m✗\033[0m savings %.1f%% (must be >0)\n", sav; fail=1 } else printf "  \033[32m✓\033[0m savings %.1f%% > 0\n", sav
      exit fail
    }' "$CRES"
  exit $?
fi

ch=$(jq -r '.tiers.haiku.cost' "$SPEC"); cs=$(jq -r '.tiers.sonnet.cost' "$SPEC"); co=$(jq -r '.tiers.opus.cost' "$SPEC")
rh=$(jq -r '.tiers.haiku.rank' "$SPEC"); rs=$(jq -r '.tiers.sonnet.rank' "$SPEC"); ro=$(jq -r '.tiers.opus.rank' "$SPEC")

# Route every case once (scores the REAL implementation, not a copy).
RES="$(mktemp)"; trap 'rm -f "$RES"' EXIT
while IFS=$'\t' read -r split expected task; do
  case "$split" in '#'*|'') continue ;; esac
  [ -n "${task:-}" ] || continue
  # shellcheck disable=SC2086  # ROUTE_ARGS is intentionally word-split
  got="$(bash "$HERE/route.sh" --spec "$SPEC" $ROUTE_ARGS "$task" 2>/dev/null || echo '?')"
  printf '%s\t%s\t%s\n' "$split" "$expected" "$got" >> "$RES"
done < "$SET"

# awk metric engine over the routed results, filtered to a split-name regex.
calc() { # <split-regex> <mode: human|nums>
  awk -F'\t' -v want="$1" -v mode="$2" \
      -v ch="$ch" -v cs="$cs" -v co="$co" -v rh="$rh" -v rs="$rs" -v ro="$ro" '
    function cost(t){ return t=="haiku"?ch:(t=="sonnet"?cs:co) }
    function rnk(t){  return t=="haiku"?rh:(t=="sonnet"?rs:ro) }
    $1 ~ want {
      tot++; e=$2; g=$3
      if(g==e) correct++
      cr+=cost(g); copt+=cost(e); call+=co; crand+=(ch+cs+co)/3.0
      if(rnk(g)>=rnk(e)) qok++; else under++
    }
    END{
      if(tot==0){ if(mode=="nums") print "0 0 0"; else print "  (no cases)"; exit }
      acc=100*correct/tot; qual=100*qok/tot; udr=100*under/tot
      sav=100*(1-cr/call); pct_opus=100*cr/call; pct_rand=100*cr/crand; eff=100*copt/cr
      if(mode=="nums"){ printf "%.1f %.1f %.1f\n", acc, qual, sav; exit }
      printf "  acc %.1f%%   quality-retained %.1f%%   underserve %.1f%%\n", acc, qual, udr
      printf "  cost: %.0f%% of all-opus  (saves %.1f%%)   ·  %.0f%% of random   ·  efficiency %.0f%%\n", pct_opus, sav, pct_rand, eff
    }' "$RES"
}

printf '\033[1mrouter benchmark\033[0m  (spec v%s — cost weights haiku:%s sonnet:%s opus:%s)\n' \
  "$(jq -r .version "$SPEC")" "$ch" "$cs" "$co"

for s in base holdout adversarial; do
  printf '\n\033[1m%s\033[0m\n' "$s"
  calc "^$s\$" human
done

printf '\n\033[1mgated aggregate — base + holdout (the fair distribution)\033[0m\n'
calc '^(base|holdout)$' human

# ── floors ────────────────────────────────────────────────────────────────────
read g_acc g_qual g_sav <<EOF
$(calc '^(base|holdout)$' nums)
EOF
read a_acc _a_q _a_s <<EOF
$(calc '^adversarial$' nums)
EOF

echo
fail=0
chk() { # <label> <value> <floor> <op: ge|gt>
  if awk "BEGIN{exit !($2 $( [ "$4" = gt ] && echo '>' || echo '>=' ) $3)}"; then
    printf '  \033[32m✓\033[0m %s %s (floor %s)\n' "$1" "$2" "$3"
  else printf '  \033[31m✗\033[0m %s %s (floor %s)\n' "$1" "$2" "$3"; fail=1; fi
}
chk "gated accuracy"          "$g_acc"  "$ACC_FLOOR"  ge
chk "gated quality-retained"  "$g_qual" "$QUAL_FLOOR" ge
chk "savings vs all-opus >0"  "$g_sav"  "0"           gt
chk "adversarial acc (tripwire)" "$a_acc" "$ADV_FLOOR" ge

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mPASS\033[0m router meets cost-at-iso-quality + generalization floors\n'; exit 0
else printf '\033[31mFAIL\033[0m a floor was missed — tune rules, relabel, or adjust floors with intent\n'; exit 1; fi
