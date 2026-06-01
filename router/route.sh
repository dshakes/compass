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

# ── load spec (+ optional local overlay: local rules take priority, scalars override) ──
[ -z "$LOCAL" ] && [ -f "$HERE/router.local.json" ] && LOCAL="$HERE/router.local.json"
EFFSPEC="$(mktemp)"; trap 'rm -f "$EFFSPEC"' EXIT
if [ -n "$LOCAL" ] && [ -f "$LOCAL" ]; then
  jq -s '(.[0] * .[1]) | .rules = (((.[1].rules) // []) + ((.[0].rules) // [])) ' "$SPEC" "$LOCAL" 2>/dev/null \
    > "$EFFSPEC" || jq '.' "$SPEC" > "$EFFSPEC"
  # the * merge above loses base.rules ordering ref; recompute cleanly:
  jq -s '.[0] as $b | .[1] as $l | ($b * $l) | .rules = (($l.rules // []) + ($b.rules // []))' "$SPEC" "$LOCAL" > "$EFFSPEC"
else
  cp "$SPEC" "$EFFSPEC"
fi
SPEC="$EFFSPEC"
jqr() { jq -r "$1" "$SPEC"; }

# ── resolve knobs (CLI > env > spec default) ──────────────────────────────────
STRATEGY="${STRATEGY:-$(jqr '.strategy // "first-match"')}"
BIAS="${BIAS:-${COMPASS_ROUTE_BIAS:-$(jqr '.bias // "balanced"')}}"
DEFAULT_TIER="$(jqr '.default')"
[ -n "$FLOOR" ]   || FLOOR="$(jqr '.clamps.floor // empty')"
[ -n "$CEILING" ] || CEILING="$(jqr '.clamps.ceiling // empty')"
[ -n "$ALLOW" ]   || ALLOW="$(jqr '((.clamps.allow // []) | join(","))')"
[ -n "$ESCALATE" ] || ESCALATE="$(jqr '.escalation.threshold // 0')"
[ -n "$FALLBACK" ] || FALLBACK="$(jqr '.escalation.fallback // empty')"
MAXRANK="$(jqr '[.tiers[].rank] | max')"
LOWTIER="$(jq -r '.tiers | to_entries | min_by(.value.rank) | .key' "$SPEC")"

rank_of()      { jq -r --arg t "$1" '.tiers[$t].rank // 0' "$SPEC"; }
tier_of_rank() { jq -r --argjson r "$1" 'first(.tiers | to_entries[] | select(.value.rank==$r) | .key) // empty' "$SPEC"; }
cost_of()      { jq -r --arg t "$1" --arg p "$PROFILE" '(.profiles[$p][$t].cost  // .tiers[$t].cost)'  "$SPEC"; }
model_of()     { jq -r --arg t "$1" --arg p "$PROFILE" '(.profiles[$p][$t].model // .tiers[$t].model)' "$SPEC"; }
tier_pattern() { jq -r --arg t "$1" '[.rules[] | select(.tier==$t) | .pattern] | .[0] // ""' "$SPEC"; }

TIERS_ORDERED="$(jq -r '.tiers | to_entries | sort_by(.value.rank) | .[].key' "$SPEC" | tr '\n' ' ')"
LC="$(printf '%s' "$TASK" | tr '[:upper:]' '[:lower:]')"
DELIM=$'\t'

rules_stream() { jq -r '.rules[] | [.tier, .pattern, (.reason // ""), (.unless // ""), ((.weight // 1)|tostring)] | join("\t")' "$SPEC"; }

# ── stage 1: decide a tier ────────────────────────────────────────────────────
MATCH_TIER=""; MATCH_REASON=""
decide_first_match() {
  local tier pat reason unl w
  while IFS="$DELIM" read -r tier pat reason unl w; do
    [ -n "$tier" ] || continue
    printf '%s' "$LC" | grep -qE -- "$pat" || continue
    [ -n "$unl" ] && printf '%s' "$LC" | grep -qE -- "$unl" && continue
    MATCH_TIER="$tier"; MATCH_REASON="$reason"; return 0
  done < <(rules_stream)
  MATCH_TIER="$DEFAULT_TIER"; MATCH_REASON="no rule matched — default"
}
decide_scored() {  # $1 = hits|weighted
  local mode="$1" cand tier pat reason unl w kh s best="$DEFAULT_TIER" bestscore=0
  for cand in $TIERS_ORDERED; do
    s=0
    while IFS="$DELIM" read -r tier pat reason unl w; do
      [ "$tier" = "$cand" ] || continue
      printf '%s' "$LC" | grep -qE -- "$pat" || continue
      [ -n "$unl" ] && printf '%s' "$LC" | grep -qE -- "$unl" && continue
      kh="$({ printf '%s' "$LC" | grep -oE -- "$pat" | grep -c . ; } 2>/dev/null || echo 0)"  # KEYWORD hits, not rule count
      if [ "$mode" = weighted ]; then s=$((s + kh * w)); else s=$((s + kh)); fi
    done < <(rules_stream)
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
while IFS="$DELIM" read -r minw atleast; do
  [ -n "$minw" ] || continue
  if [ "$WORDS" -ge "$minw" ] && [ "$(rank_of "$MATCH_TIER")" -lt "$(rank_of "$atleast")" ]; then
    MATCH_TIER="$atleast"; MATCH_REASON="$MATCH_REASON; len>=$minw->>=$atleast"
  fi
done < <(jq -r '(.length_rules // [])[] | [((.min_words)|tostring), .at_least] | join("\t")' "$SPEC")

# ── stage 4: bias (nudge only weak picks) ─────────────────────────────────────
if [ "$CONFIDENCE" -lt 55 ]; then
  r="$(rank_of "$MATCH_TIER")"
  case "$BIAS" in
    cheap)   [ "$r" -gt 1 ]        && { MATCH_TIER="$(tier_of_rank $((r-1)))"; MATCH_REASON="$MATCH_REASON; bias=cheap->$MATCH_TIER"; } ;;
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
if [ "$WANT_DOMAIN" = 1 ]; then
  while IFS="$DELIM" read -r d pat; do
    [ -n "$d" ] || continue
    printf '%s' "$LC" | grep -qE -- "$pat" && { DOMAIN="$d"; break; }
  done < <(jq -r '(.domains // [])[] | [.domain, .pattern] | join("\t")' "$SPEC")
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
