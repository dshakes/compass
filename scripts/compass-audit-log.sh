#!/usr/bin/env bash
# compass-audit-log.sh — read the structured security-audit trail.
#
# Every gated/blocked action (a secret write, a dangerous command, a scan hit) is
# appended as one JSON object per line to $COMPASS_HOME/audit.jsonl by the hooks.
# This turns "compass blocked N footguns" into evidence you can show a security team
# or pipe into a SIEM.
#
#   compass audit-log                 # the recent trail, as a table
#   compass audit-log -n 200          # more rows
#   compass audit-log --since 2026-06-01   # only on/after a date
#   compass audit-log --json          # raw JSONL (SIEM/jq export)
set -uo pipefail

HOME_DIR="${COMPASS_HOME:-$HOME/.compass}"
LOG="$HOME_DIR/audit.jsonl"
N=50; SINCE=""; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--limit) N="${2:-50}"; shift ;;
    --since)    SINCE="${2:-}"; shift ;;
    --json)     JSON=1 ;;
    -h|--help)  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "compass audit-log: unknown arg '$1'" >&2; exit 2 ;;
  esac
  shift
done

if [ ! -s "$LOG" ]; then
  echo "no audit events yet — the trail fills as the guardrail blocks footguns ($LOG)"
  exit 0
fi

# Filter by --since (string compare works on ISO-8601 timestamps).
filtered() {
  if [ -n "$SINCE" ]; then
    awk -v s="$SINCE" 'index($0,"\"ts\":\"")>0 { t=$0; sub(/.*"ts":"/,"",t); sub(/".*/,"",t); if (t >= s) print }' "$LOG"
  else
    cat "$LOG"
  fi
}

if [ "$JSON" = 1 ]; then
  filtered | tail -n "$N"
  exit 0
fi

if command -v jq >/dev/null 2>&1; then
  printf '\033[1m%-20s  %-7s  %-7s  %-16s  %s\033[0m\n' TIME DECISION TOOL RULE DETAIL
  filtered | tail -n "$N" | jq -r '[.ts, .decision, .tool, .rule, (.detail|.[0:80])] | @tsv' 2>/dev/null \
    | while IFS=$'\t' read -r ts dec tool rule detail; do
        printf '%-20s  %-7s  %-7s  %-16s  %s\n' "${ts%Z}" "$dec" "$tool" "$rule" "$detail"
      done
else
  filtered | tail -n "$N"
fi

total="$(filtered | grep -c . || true)"
printf '\n%s event(s)%s\n' "$total" "$([ -n "$SINCE" ] && printf ' since %s' "$SINCE")"
