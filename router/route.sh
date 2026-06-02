#!/usr/bin/env bash
# route.sh — reference implementation of the compass cost-tier router (v1.1).
#
# Deterministic, zero network, zero model calls (unless you wire an escalation fallback).
# Pipeline:  decide(tier) -> confidence -> length-rules -> bias -> escalation -> clamps -> domain.
# With no flags it reproduces v1.0 exactly (strategy first-match, balanced, no escalation).
#
#   route.sh "<task>"                      -> haiku | sonnet | opus
#   route.sh --explain "<task>"            -> tier  (+ reason on stderr)
#   route.sh --score "<task>"              -> tier<TAB>confidence
#   route.sh --json "<task>"               -> {tier,confidence,model,cost,reason[,domain]}
#   route.sh --domain "<task>"             -> tier<TAB>domain
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
EXPLAIN=0; JSON=0; SCORE=0; WANT_DOMAIN=0; TASK=""
PROFILE="default"; STRATEGY=""; BIAS=""; FLOOR=""; CEILING=""; ALLOW=""
ESCALATE=""; FALLBACK=""; LOGFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --explain) EXPLAIN=1 ;;
    --json)    JSON=1 ;;
    --score)   SCORE=1 ;;
    --domain)  WANT_DOMAIN=1 ;;
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
       ["S","maxrank",(([.tiers[].rank]|max)|tostring)] ]
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
TIER_META=(); TIERS_ORDERED=""; RULES=(); LENGTHS=(); DOMAINS=()
while IFS=$'\t' read -r typ f1 f2 f3 f4 f5; do
  case "$typ" in
    S) case "$f1" in
         strategy) S_strategy="$f2" ;; bias) S_bias="$f2" ;; default) S_default="$f2" ;;
         floor) S_floor="$f2" ;; ceiling) S_ceiling="$f2" ;; allow) S_allow="$f2" ;;
         escalate) S_escalate="$f2" ;; fallback) S_fallback="$f2" ;; maxrank) S_maxrank="$f2" ;;
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

if [ "$JSON" = 1 ]; then
  jq -n --arg tier "$MATCH_TIER" --arg reason "$MATCH_REASON" --argjson conf "$CONFIDENCE" \
        --arg model "$(model_of "$MATCH_TIER")" --argjson cost "$(cost_of "$MATCH_TIER")" --arg domain "$DOMAIN" \
        '{tier:$tier, confidence:$conf, model:$model, cost:$cost, reason:$reason} + (if $domain=="" then {} else {domain:$domain} end)'
elif [ "$SCORE" = 1 ]; then
  printf '%s\t%s\n' "$MATCH_TIER" "$CONFIDENCE"
else
  [ "$EXPLAIN" = 1 ] && printf 'route: %s (%s)\n' "$MATCH_TIER" "$MATCH_REASON" >&2
  if [ "$WANT_DOMAIN" = 1 ]; then printf '%s\t%s\n' "$MATCH_TIER" "${DOMAIN:-core}"; else printf '%s\n' "$MATCH_TIER"; fi
fi
