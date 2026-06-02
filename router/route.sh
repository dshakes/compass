#!/usr/bin/env bash
# route.sh — reference implementation of the compass cost-tier router (v1.1).
#
# Deterministic, zero network, zero model calls (unless you wire an escalation fallback).
# Pipeline:  decide(tier) -> confidence -> length-rules -> bias -> cache-aware -> escalation -> clamps -> domain.
# With no flags it reproduces v1.0 exactly (strategy first-match, balanced, no escalation, no warm set).
#
#   route.sh "<task>"                      -> haiku | sonnet | opus
#   route.sh --explain "<task>"            -> tier  (+ reason on stderr)
#   route.sh --score "<task>"              -> tier<TAB>confidence
#   route.sh --json "<task>"               -> {tier,confidence,model,cost,ttl,reason[,domain]}
#   route.sh --domain "<task>"             -> tier<TAB>domain
#   route.sh --ttl                         -> 5m | 1h   (cache-write TTL recommendation)
# Knobs (each overrides the spec default):
#   --strategy first-match|max-hits|weighted   --bias cheap|balanced|quality
#   --profile NAME                              --floor TIER  --ceiling TIER  --allow t1,t2
#   --escalate-below N  --fallback "CMD"        --local FILE   --spec FILE   --log FILE
# Env: COMPASS_ROUTE_BIAS, COMPASS_ROUTER_SPEC.  The SPEC (router.json) is the reusable asset.
#
# PERF: the whole spec is read in ONE jq pass into shell vars/arrays; the per-route hot path
# then uses pure-bash lookups + the grep matches that regex routing inherently needs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC="${COMPASS_ROUTER_SPEC:-$HERE/router.json}"; LOCAL=""
EXPLAIN=0; JSON=0; SCORE=0; WANT_DOMAIN=0; TTL_ONLY=0; TASK=""
PROFILE="default"; STRATEGY=""; BIAS=""; FLOOR=""; CEILING=""; ALLOW=""
ESCALATE=""; FALLBACK=""; LOGFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --explain) EXPLAIN=1 ;;
    --json)    JSON=1 ;;
    --score)   SCORE=1 ;;
    --domain)  WANT_DOMAIN=1 ;;
    --ttl)     TTL_ONLY=1 ;;
    --spec)    SPEC="${2:?}"; shift ;;
    --local)   LOCAL="${2:?}"; shift ;;
    --profile) PROFILE="${2:?}"; shift ;;
    --strategy) STRATEGY="${2:?}"; shift ;;
    --bias)    BIAS="${2:?}"; shift ;;
    --floor)   FLOOR="${2:?}"; shift ;;
    --ceiling) CEILING="${2:?}"; shift ;;
    --allow)   ALLOW="${2:?}"; shift ;;
    --escalate-below) ESCALATE="${2:?}"; shift ;;
    --fallback) FALLBACK="${2:?}"; shift ;;
    --log)     LOGFILE="${2:?}"; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        echo "route: unknown flag '$1'" >&2; exit 2 ;;
    *)         TASK="$1" ;;
  esac
  shift
done
# validated integer or default — keeps hostile COMPASS_* env out of arithmetic/awk.
cnum(){ case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }

# Cache-write TTL recommendation: 5m (write 1.25x) pays off inside one window; 1h (write
# 2x) only amortizes when the prefix is reused >=2 times across a gap > 5m (e.g. a converge
# loop with a long QA run between rounds). Reachable on the direct-API path (cache_control.ttl);
# on `claude -p` it's a surfaced recommendation (Claude Code manages a 5m cache itself).
TTL_REC=5m; TTL_WHY=""
recommend_ttl(){
  local reuses gap; reuses="$(cnum "${COMPASS_ROUTE_REUSES:-}" 1)"; gap="$(cnum "${COMPASS_ROUTE_GAP_MIN:-}" 0)"
  if [ "$reuses" -ge 2 ] && [ "$gap" -gt 5 ]; then TTL_REC=1h; TTL_WHY="${reuses} reuses across a >5m gap — 1h write amortizes"
  else TTL_REC=5m; TTL_WHY="write pays off inside one 5m window"; fi
}

# --ttl: standalone recommendation, no task / no spec needed.
if [ "$TTL_ONLY" = 1 ]; then
  recommend_ttl
  [ "$EXPLAIN" = 1 ] && printf 'ttl: %s (%s)\n' "$TTL_REC" "$TTL_WHY" >&2
  printf '%s\n' "$TTL_REC"; exit 0
fi

[ -n "$TASK" ] || { echo "route: empty task" >&2; exit 2; }
command -v jq >/dev/null || { echo "route: jq required (other languages parse router.json natively)" >&2; exit 2; }
[ -f "$SPEC" ] || { echo "route: spec not found: $SPEC" >&2; exit 2; }

# ── load spec (+ optional local overlay) and dump EVERYTHING in ONE jq pass ───────
[ -z "$LOCAL" ] && [ -f "$HERE/router.local.json" ] && LOCAL="$HERE/router.local.json"
if [ -n "$LOCAL" ] && [ -f "$LOCAL" ]; then
  MERGED="$(jq -s '.[0] as $b | .[1] as $l | ($b * $l) | .rules = (($l.rules // []) + ($b.rules // []))' "$SPEC" "$LOCAL")"
else
  MERGED="$(cat "$SPEC")"
fi
# Single jq pass → tab-joined typed rows. join("\t") (NOT @tsv) keeps backslashes in
# patterns intact (\bauth\b). Tiers/rules emitted in rank order.
DUMP="$(printf '%s' "$MERGED" | jq -r --arg p "$PROFILE" '
  . as $root
  | ([ ["S","strategy",(.strategy // "first-match")],
       ["S","bias",(.bias // "balanced")],
       ["S","default",.default],
       ["S","floor",(.clamps.floor // "")],
       ["S","ceiling",(.clamps.ceiling // "")],
       ["S","allow",((.clamps.allow // []) | join(","))],
       ["S","escalate",((.escalation.threshold // 0)|tostring)],
       ["S","fallback",(.escalation.fallback // "")],
       ["S","maxrank",(([.tiers[].rank]|max)|tostring)],
       ["S","cread",((.cache.read_mult // 0.1)|tostring)],
       ["S","cwrite",((.cache.write_mult // 1.25)|tostring)],
       ["S","cwritelong",((.cache.write_mult_long // 2.0)|tostring)],
       ["S","cP",((.cache.prefix_tokens // 8000)|tostring)],
       ["S","cD",((.cache.task_tokens // 600)|tostring)],
       ["S","cO",((.cache.output_tokens // 400)|tostring)],
       ["S","cow",((.cache.out_weight // 4)|tostring)] ]
     + (.tiers | to_entries | sort_by(.value.rank)
        | map(["T", .key, (.value.rank|tostring),
               (($root.profiles[$p][.key].cost  // .value.cost)|tostring),
               ($root.profiles[$p][.key].model // .value.model)]))
     + (.rules | map(["R", .tier, .pattern, (.reason // ""), (.unless // ""), ((.weight // 1)|tostring)]))
     + ((.length_rules // []) | map(["L", (.min_words|tostring), .at_least]))
     + ((.domains // []) | map(["D", .domain, .pattern])) )
  | .[] | join("\t")
')"

# ── parse the dump into shell state (pure bash, no further subprocesses) ──────────
S_strategy=""; S_bias=""; S_default=""; S_floor=""; S_ceiling=""; S_allow=""; S_escalate="0"; S_fallback=""; S_maxrank="0"
S_cr="0.1"; S_cw="1.25"; S_cwl="2.0"; S_cP="8000"; S_cD="600"; S_cO="400"; S_cow="4"
TIER_META=(); TIERS_ORDERED=""; RULES=(); LENGTHS=(); DOMAINS=()
while IFS=$'\t' read -r typ f1 f2 f3 f4 f5; do
  case "$typ" in
    S) case "$f1" in
         strategy) S_strategy="$f2" ;; bias) S_bias="$f2" ;; default) S_default="$f2" ;;
         floor) S_floor="$f2" ;; ceiling) S_ceiling="$f2" ;; allow) S_allow="$f2" ;;
         escalate) S_escalate="$f2" ;; fallback) S_fallback="$f2" ;; maxrank) S_maxrank="$f2" ;;
         cread) S_cr="$f2" ;; cwrite) S_cw="$f2" ;; cwritelong) S_cwl="$f2" ;;
         cP) S_cP="$f2" ;; cD) S_cD="$f2" ;; cO) S_cO="$f2" ;; cow) S_cow="$f2" ;;
       esac ;;
    T) TIER_META+=("$f1 $f2 $f3 $f4"); TIERS_ORDERED="$TIERS_ORDERED $f1" ;;
    R) RULES+=("$f1"$'\t'"$f2"$'\t'"$f3"$'\t'"$f4"$'\t'"$f5") ;;
    L) LENGTHS+=("$f1 $f2") ;;
    D) DOMAINS+=("$f1"$'\t'"$f2") ;;
  esac
done <<EOF
$DUMP
EOF
TIERS_ORDERED="${TIERS_ORDERED# }"
LOWTIER="${TIERS_ORDERED%% *}"

# resolve knobs: CLI flag > env > spec default
STRATEGY="${STRATEGY:-$S_strategy}"
BIAS="${BIAS:-${COMPASS_ROUTE_BIAS:-$S_bias}}"
DEFAULT_TIER="$S_default"
[ -n "$FLOOR" ]    || FLOOR="$S_floor"
[ -n "$CEILING" ]  || CEILING="$S_ceiling"
[ -n "$ALLOW" ]    || ALLOW="$S_allow"
[ -n "$ESCALATE" ] || ESCALATE="$S_escalate"
[ -n "$FALLBACK" ] || FALLBACK="$S_fallback"
MAXRANK="$S_maxrank"

# pure-bash metadata lookups over TIER_META ("tier rank cost model")
rank_of()      { local t="$1" e; for e in "${TIER_META[@]}"; do case "$e" in "$t "*) set -- $e; printf '%s' "$2"; return;; esac; done; printf '0'; }
cost_of()      { local t="$1" e; for e in "${TIER_META[@]}"; do case "$e" in "$t "*) set -- $e; printf '%s' "$3"; return;; esac; done; }
model_of()     { local t="$1" e; for e in "${TIER_META[@]}"; do case "$e" in "$t "*) set -- $e; printf '%s' "$4"; return;; esac; done; }
tier_of_rank() { local n="$1" e; for e in "${TIER_META[@]}"; do set -- $e; [ "$2" = "$n" ] && { printf '%s' "$1"; return; }; done; }
tier_pattern() { local t="$1" r rest; for r in "${RULES[@]}"; do case "$r" in "$t"$'\t'*) rest="${r#*$'\t'}"; printf '%s' "${rest%%$'\t'*}"; return;; esac; done; }

LC="$(printf '%s' "$TASK" | tr '[:upper:]' '[:lower:]')"

# ── stage 1: decide a tier ────────────────────────────────────────────────────
MATCH_TIER=""; MATCH_REASON=""
decide_first_match() {
  local r tier pat reason unl
  for r in "${RULES[@]}"; do
    IFS=$'\t' read -r tier pat reason unl _ <<EOF
$r
EOF
    [ -n "$tier" ] || continue
    printf '%s' "$LC" | grep -qE -- "$pat" || continue
    [ -n "$unl" ] && printf '%s' "$LC" | grep -qE -- "$unl" && continue
    MATCH_TIER="$tier"; MATCH_REASON="$reason"; return 0
  done
  MATCH_TIER="$DEFAULT_TIER"; MATCH_REASON="no rule matched — default"
}
decide_scored() {  # $1 = hits|weighted
  local mode="$1" cand r tier pat unl w kh s best="$DEFAULT_TIER" bestscore=0
  for cand in $TIERS_ORDERED; do
    s=0
    for r in "${RULES[@]}"; do
      IFS=$'\t' read -r tier pat _ unl w <<EOF
$r
EOF
      [ "$tier" = "$cand" ] || continue
      printf '%s' "$LC" | grep -qE -- "$pat" || continue
      [ -n "$unl" ] && printf '%s' "$LC" | grep -qE -- "$unl" && continue
      kh="$({ printf '%s' "$LC" | grep -oE -- "$pat" | grep -c . ; } 2>/dev/null || echo 0)"
      if [ "$mode" = weighted ]; then s=$((s + kh * w)); else s=$((s + kh)); fi
    done
    if [ "$s" -gt "$bestscore" ]; then best="$cand"; bestscore="$s"
    elif [ "$s" -eq "$bestscore" ] && [ "$s" -gt 0 ] && [ "$(rank_of "$cand")" -gt "$(rank_of "$best")" ]; then best="$cand"; fi
  done
  MATCH_TIER="$best"
  if [ "$bestscore" -gt 0 ]; then MATCH_REASON="$mode: $bestscore hit(s)"; else MATCH_REASON="no rule matched — default"; fi
}
case "$STRATEGY" in
  max-hits) decide_scored hits ;;
  weighted) decide_scored weighted ;;
  *)        decide_first_match ;;
esac

# ── stage 2: confidence ───────────────────────────────────────────────────────
WORDS="$(printf '%s' "$TASK" | wc -w | tr -d ' ')"; : "${WORDS:=0}"
CONFIDENCE=70
if [ "$MATCH_TIER" = "$DEFAULT_TIER" ]; then
  if [ "$WORDS" -le 4 ]; then CONFIDENCE=45; else CONFIDENCE=70; fi
else
  pat="$(tier_pattern "$MATCH_TIER")"
  hits="$({ printf '%s' "$LC" | grep -oE -- "$pat" | grep -c . ; } 2>/dev/null || echo 0)"
  CONFIDENCE=$(( 60 + hits * 15 ))
  [ "$MATCH_TIER" = "$LOWTIER" ] && [ "$WORDS" -le 5 ] && CONFIDENCE=$(( CONFIDENCE + 10 ))
fi
[ "$CONFIDENCE" -gt 99 ] && CONFIDENCE=99

# ── stage 3: length rules (raise the floor for long tasks) ────────────────────
if [ "${#LENGTHS[@]}" -gt 0 ]; then
  for lr in "${LENGTHS[@]}"; do
    set -- $lr; minw="$1"; atleast="$2"
    if [ "$WORDS" -ge "$minw" ] && [ "$(rank_of "$MATCH_TIER")" -lt "$(rank_of "$atleast")" ]; then
      MATCH_TIER="$atleast"; MATCH_REASON="$MATCH_REASON; len>=$minw->>=$atleast"
    fi
  done
fi

# ── stage 4: bias (nudge only weak picks) ─────────────────────────────────────
if [ "$CONFIDENCE" -lt 55 ]; then
  r="$(rank_of "$MATCH_TIER")"
  case "$BIAS" in
    cheap)   [ "$r" -gt 1 ]          && { MATCH_TIER="$(tier_of_rank $((r-1)))"; MATCH_REASON="$MATCH_REASON; bias=cheap->$MATCH_TIER"; } ;;
    quality) [ "$r" -lt "$MAXRANK" ] && { MATCH_TIER="$(tier_of_rank $((r+1)))"; MATCH_REASON="$MATCH_REASON; bias=quality->$MATCH_TIER"; } ;;
  esac
fi

# ── stage 4.5: cache-aware cost-min (OFF unless a warm tier is supplied) ───────
# When COMPASS_ROUTE_WARM names tiers whose prompt-cache prefix is already hot, ride a
# warm pricier tier in [pick..maxrank] if its EXPECTED cost (cache read on the prefix)
# beats cold-loading the current pick. UPGRADE-ONLY (never below the pick → no quality
# loss); the clamps stage still bounds the result. Reuses each tier's relative `cost`.
if [ -n "${COMPASS_ROUTE_WARM:-}" ]; then
  cP="$(cnum "${COMPASS_PREFIX_TOKENS:-}" "$S_cP")"; cD="$(cnum "${COMPASS_TASK_TOKENS:-}" "$S_cD")"; cO="$(cnum "${COMPASS_OUTPUT_TOKENS:-}" "$S_cO")"
  case "${COMPASS_ROUTE_TTL:-5m}" in 1h) cwrm="$S_cwl" ;; *) cwrm="$S_cw" ;; esac
  TC=""; for e in "${TIER_META[@]}"; do set -- $e; TC="$TC$1:$2:$3 "; done
  cbest="$(awk -v pr="$(rank_of "$MATCH_TIER")" -v warm="$COMPASS_ROUTE_WARM" \
              -v P="$cP" -v D="$cD" -v O="$cO" -v rd="$S_cr" -v wr="$cwrm" -v ow="$S_cow" -v tc="$TC" '
    BEGIN{
      n=split(tc, a, " "); m=split(warm, wl, /[, ]+/); for(i=1;i<=m;i++) if(wl[i]!="") iswarm[wl[i]]=1;
      best=""; bestc=0;
      for(i=1;i<=n;i++){ if(a[i]=="") continue; split(a[i], f, ":"); t=f[1]; rk=f[2]+0; c=f[3]+0;
        if(rk < pr) continue;                                   # upgrade-only
        w=(t in iswarm)?1:0; cost=(w?rd:wr)*c*P + c*D + c*ow*O;
        if(best=="" || cost < bestc-1e-9){ best=t; bestc=cost } }
      printf "%s", best;
    }')"
  if [ -n "$cbest" ] && [ "$cbest" != "$MATCH_TIER" ]; then
    MATCH_REASON="$MATCH_REASON; cache-aware: warm $cbest cheaper than cold $MATCH_TIER"; MATCH_TIER="$cbest"
  fi
fi

# ── stage 5: escalation (cascade) ─────────────────────────────────────────────
if [ "${ESCALATE:-0}" -gt 0 ] && [ "$CONFIDENCE" -lt "$ESCALATE" ]; then
  if [ -n "$FALLBACK" ]; then
    out="$(printf '%s\n' "$TASK" | eval "$FALLBACK" 2>/dev/null || true)"   # fallback: trusted config; reads task on stdin, prints a tier
    case " $TIERS_ORDERED " in *" $out "*) MATCH_TIER="$out"; MATCH_REASON="$MATCH_REASON; escalate->fallback($out)" ;; esac
  else
    r="$(rank_of "$MATCH_TIER")"; [ "$r" -lt "$MAXRANK" ] && { MATCH_TIER="$(tier_of_rank $((r+1)))"; MATCH_REASON="$MATCH_REASON; escalate(bump)->$MATCH_TIER"; }
  fi
fi

# ── stage 6: clamps (hard bounds, applied LAST) ───────────────────────────────
if [ -n "$ALLOW" ]; then
  case ",$ALLOW," in
    *",$MATCH_TIER,"*) : ;;
    *) cur="$(rank_of "$MATCH_TIER")"; best=""; bestrank=-1
       for t in $TIERS_ORDERED; do case ",$ALLOW," in *",$t,"*) r="$(rank_of "$t")"; [ "$r" -le "$cur" ] && [ "$r" -gt "$bestrank" ] && { best="$t"; bestrank="$r"; } ;; esac; done
       [ -z "$best" ] && for t in $TIERS_ORDERED; do case ",$ALLOW," in *",$t,"*) best="$t"; break ;; esac; done
       [ -n "$best" ] && { MATCH_REASON="$MATCH_REASON; clamp allow->$best"; MATCH_TIER="$best"; } ;;
  esac
else
  [ -n "$FLOOR" ]   && [ "$(rank_of "$MATCH_TIER")" -lt "$(rank_of "$FLOOR")" ]   && { MATCH_TIER="$FLOOR";   MATCH_REASON="$MATCH_REASON; clamp floor->$FLOOR"; }
  [ -n "$CEILING" ] && [ "$(rank_of "$MATCH_TIER")" -gt "$(rank_of "$CEILING")" ] && { MATCH_TIER="$CEILING"; MATCH_REASON="$MATCH_REASON; clamp ceiling->$CEILING"; }
fi

# ── stage 7: domain (optional second axis) ────────────────────────────────────
DOMAIN=""
if [ "$WANT_DOMAIN" = 1 ] && [ "${#DOMAINS[@]}" -gt 0 ]; then
  for d in "${DOMAINS[@]}"; do
    IFS=$'\t' read -r dom pat <<EOF
$d
EOF
    [ -n "$dom" ] || continue
    printf '%s' "$LC" | grep -qE -- "$pat" && { DOMAIN="$dom"; break; }
  done
fi

# ── telemetry + output ────────────────────────────────────────────────────────
[ -n "$LOGFILE" ] && { printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MATCH_TIER" "$CONFIDENCE" "$TASK" >>"$LOGFILE" 2>/dev/null || true; }
recommend_ttl

if [ "$JSON" = 1 ]; then
  jq -n --arg tier "$MATCH_TIER" --arg reason "$MATCH_REASON" --argjson conf "$CONFIDENCE" \
        --arg model "$(model_of "$MATCH_TIER")" --argjson cost "$(cost_of "$MATCH_TIER")" --arg ttl "$TTL_REC" --arg domain "$DOMAIN" \
        '{tier:$tier, confidence:$conf, model:$model, cost:$cost, ttl:$ttl, reason:$reason} + (if $domain=="" then {} else {domain:$domain} end)'
elif [ "$SCORE" = 1 ]; then
  printf '%s\t%s\n' "$MATCH_TIER" "$CONFIDENCE"
else
  [ "$EXPLAIN" = 1 ] && printf 'route: %s (%s)\n' "$MATCH_TIER" "$MATCH_REASON" >&2
  if [ "$WANT_DOMAIN" = 1 ]; then printf '%s\t%s\n' "$MATCH_TIER" "${DOMAIN:-core}"; else printf '%s\n' "$MATCH_TIER"; fi
fi
