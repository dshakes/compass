#!/usr/bin/env bash
# route.sh — reference implementation of the compass cost-tier router.
#
# Deterministic, zero network, zero model calls. Pure function of the task string and
# the spec (router.json): lowercase the task, walk rules in order, first ERE match wins,
# else the default tier. Needs jq (to read the spec) + grep (the matcher).
#
#   route.sh "<task>"            -> haiku | sonnet | opus
#   route.sh --explain "<task>"  -> tier  (matched-rule reason on stderr)
#   route.sh --spec FILE "<task>"
#
# The SPEC is the reusable, language-agnostic asset — a Go/Rust/TS/Python app loads the
# same router.json and reimplements this matcher (see README). This impl + that spec are
# the single source of truth; bench.sh scores any implementation against evalset.tsv.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC="$HERE/router.json"; EXPLAIN=0; TASK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --explain) EXPLAIN=1 ;;
    --spec)    SPEC="${2:?--spec needs a file}"; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        echo "route: unknown flag '$1'" >&2; exit 2 ;;
    *)         TASK="$1" ;;
  esac
  shift
done
[ -n "$TASK" ] || { echo "route: empty task (usage: route.sh [--explain] \"<task>\")" >&2; exit 2; }
command -v jq >/dev/null || { echo "route: jq required for the bash reference impl (other languages parse router.json natively)" >&2; exit 2; }
[ -f "$SPEC" ] || { echo "route: spec not found: $SPEC" >&2; exit 2; }

# tier_for "<task>" -> prints "<tier>\t<reason>"; the whole routing decision.
tier_for() {
  local lc; lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  local tier pat reason
  while IFS=$'\t' read -r tier pat reason; do
    [ -n "$tier" ] || continue
    if printf '%s' "$lc" | grep -qE -- "$pat"; then printf '%s\t%s' "$tier" "$reason"; return 0; fi
  done < <(jq -r '.rules[] | [.tier, .pattern, .reason] | join("\t")' "$SPEC")
  # NB: join("\t"), NOT @tsv — @tsv escapes backslashes, which would break word-boundary
  # patterns like \blint\b. join concatenates the raw string values.
  printf '%s\tno rule matched — default tier' "$(jq -r '.default' "$SPEC")"
}

res="$(tier_for "$TASK")"
tier="${res%%$'\t'*}"; reason="${res#*$'\t'}"
[ "$EXPLAIN" = 1 ] && printf 'route: %s (%s)\n' "$tier" "$reason" >&2
printf '%s\n' "$tier"
