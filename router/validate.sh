#!/usr/bin/env bash
# validate.sh — schema + safety validation for a router spec (router.json).
#
# The spec is the reusable, copied-around asset (#6 spec hardening), so a malformed or
# unsafe spec should fail loudly and deterministically — in CI, in `doctor`, and before any
# app embeds it. Checks structure (required keys, tier refs resolve, patterns compile) AND
# lints rule patterns for catastrophic-backtracking (ReDoS) shapes. No network, no model.
#
#   validate.sh [spec.json]      # default: ./router.json next to this script
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC="${1:-$HERE/router.json}"
command -v jq >/dev/null || { echo "validate: jq required" >&2; exit 2; }
[ -f "$SPEC" ] || { echo "validate: spec not found: $SPEC" >&2; exit 2; }

pass=0; fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
# jchk <desc> <jq-bool-filter> — ok if the filter is truthy (and the spec parses).
jchk() { if jq -e "$2" "$SPEC" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi; }

jq -e . "$SPEC" >/dev/null 2>&1 || { no "valid JSON"; printf 'router spec: %d passed, %d failed\n' "$pass" "$((fail+1))"; exit 1; }
ok "valid JSON"

# ── structure: required keys + every tier reference resolves ──────────────────────
jchk "has version"                 '.version'
jchk "tiers is an object"          '(.tiers|type)=="object"'
jchk "rules is an array"           '(.rules|type)=="array"'
jchk "default ∈ tiers"             '(.tiers|keys) as $t | (.default) as $d | ($t|index($d)) != null'
jchk "every tier has rank/cost/model" 'all(.tiers[]; (.rank|type=="number") and (.cost|type=="number") and (.model|type=="string") and (.model|length>0))'
jchk "clamps.floor ∈ tiers"        '(.tiers|keys) as $t | (.clamps.floor//"") as $f | ($f=="") or (($t|index($f))!=null)'
jchk "clamps.ceiling ∈ tiers"      '(.tiers|keys) as $t | (.clamps.ceiling//"") as $c | ($c=="") or (($t|index($c))!=null)'
jchk "budget.cap_ceiling ∈ tiers"  '(.tiers|keys) as $t | (.budget.cap_ceiling//"") as $b | ($b=="") or (($t|index($b))!=null)'
jchk "length_rules.at_least ∈ tiers" '(.tiers|keys) as $t | all((.length_rules//[])[]; (.at_least) as $a | ($t|index($a))!=null)'
jchk "domain_floors values ∈ tiers"  '(.tiers|keys) as $t | all((.domain_floors//{})|to_entries[]; (.value) as $v | ($t|index($v))!=null)'
jchk "every rule.tier ∈ tiers"     '(.tiers|keys) as $t | all((.rules//[])[]; (.tier) as $rt | ($t|index($rt))!=null)'
jchk "every rule.pattern non-empty" 'all((.rules//[])[]; (.pattern|type=="string") and (.pattern|length>0))'

# ── every regex compiles (ERE) + ReDoS lint ───────────────────────────────────────
mapfile -t PATTERNS < <(jq -r '[ (.rules//[])[].pattern, (.rules//[])[].unless//empty, (.domains//[])[].pattern ] | .[]' "$SPEC" 2>/dev/null)
bad_compile=0; redos=0
for p in "${PATTERNS[@]}"; do
  [ -n "$p" ] || continue
  printf '' | grep -E -- "$p" >/dev/null 2>&1; [ "$?" = 2 ] && { no "pattern does not compile: $p"; bad_compile=1; }
  # ReDoS tripwire: a quantified token nested inside a group that is itself quantified by * or +
  #   (a+)+  (a*)*  (.*)+  (\d+)*  (x{2,})+  — classic catastrophic-backtracking shapes.
  if printf '%s' "$p" | grep -Eq '\([^)]*([*+?]|\{[0-9]*,[0-9]*\})[^)]*\)[*+]'; then
    no "ReDoS-risk pattern (nested quantifier): $p"; redos=1
  fi
done
[ "${#PATTERNS[@]}" -gt 0 ] && [ "$bad_compile" = 0 ] && ok "all ${#PATTERNS[@]} patterns compile as ERE"
[ "${#PATTERNS[@]}" -eq 0 ] && no "no patterns extracted (spec has no rules/domains?)"
[ "$redos" = 0 ] && ok "no catastrophic-backtracking (ReDoS) pattern shapes"

echo
printf 'router spec: %d passed, %d failed  (%s)\n' "$pass" "$fail" "${SPEC##*/}"
[ "$fail" -eq 0 ]
