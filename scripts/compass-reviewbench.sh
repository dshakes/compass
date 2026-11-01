#!/usr/bin/env bash
# compass-reviewbench.sh — review precision/recall/F1 on a labeled corpus of diffs.
#   compass-reviewbench.sh [--reviewer CMD] [--cases DIR] [--json]
# CMD gets a case dir as $1 and prints JSON lines {"file","line","severity","message"}
# (optionally {"meta":{"cost_usd":N}}). Default reviewer is the real one (spends tokens);
# COMPASS_MAX_USD caps total spend. See docs/34-review-benchmark.md.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH="$HERE/../sdlc/reviewbench"
REVIEWER="$BENCH/reviewers/claude.sh"; CASES="$BENCH/cases"; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --reviewer) REVIEWER="${2:?--reviewer needs a command}"; shift ;;
    --cases)    CASES="${2:?--cases needs a dir}"; shift ;;
    --json)     ARGS+=(--json) ;;
    -h|--help)  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "compass-reviewbench: unknown arg $1" >&2; exit 2 ;;
  esac
  shift
done
[ -d "$CASES" ] || { echo "compass-reviewbench: no such cases dir: $CASES" >&2; exit 2; }
exec python3 "$HERE/reviewbench-score.py" --cases "$CASES" --reviewer "$REVIEWER" ${ARGS[@]+"${ARGS[@]}"}
