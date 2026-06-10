#!/usr/bin/env bash
# compass-spend.sh — aggregate agent-cost dashboard + budget check.
#
# Reads the spend ledger written by orchestrate.sh / compass onboard / schedule run.
#   Ledger:  ${COMPASS_HOME:-~/.compass}/spend.tsv
#   Columns: timestamp_iso8601<TAB>repo<TAB>task<TAB>model<TAB>cost_usd
#
# Usage:  compass spend [--week|--month|--all] [--json] [--max-usd N]  (default: --month)
# Budget: env COMPASS_BUDGET_USD, else `budget_usd=<n>` in ${COMPASS_HOME}/config.
# Gate:   env COMPASS_MAX_USD (or --max-usd N): exit 2 with OVER_BUDGET if total exceeds cap.
set -euo pipefail

COMPASS_HOME="${COMPASS_HOME:-$HOME/.compass}"
LEDGER="$COMPASS_HOME/spend.tsv"
CONFIG="$COMPASS_HOME/config"

WINDOW="month"; JSON=0; MAX_USD=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --week)  WINDOW="week"  ;;
    --month) WINDOW="month" ;;
    --all)   WINDOW="all"   ;;
    --json)  JSON=1 ;;
    --max-usd)
      if [ "$#" -lt 2 ]; then printf '--max-usd requires a value\n' >&2; exit 2; fi
      MAX_USD="$2"; shift
      ;;
    --max-usd=*) MAX_USD="${1#--max-usd=}" ;;
    -h|--help) printf 'usage: compass spend [--week|--month|--all] [--json] [--max-usd N]\n'; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# --max-usd flag wins over env var; env var wins over empty.
if [ -z "$MAX_USD" ]; then
  MAX_USD="${COMPASS_MAX_USD:-}"
fi

if [ ! -s "$LEDGER" ]; then
  if [ "$JSON" = 1 ]; then printf '{"note":"no spend logged yet"}\n'
  else
    printf '\nNo spend logged yet. Costs are recorded automatically when you run:\n'
    printf '  • ~/compass/sdlc/orchestrate.sh "<task>"\n  • compass onboard\n  • compass schedule run <routine>\n\n'
  fi
  exit 0
fi

# Budget: env > config file > empty.
BUDGET="${COMPASS_BUDGET_USD:-}"
if [ -z "$BUDGET" ] && [ -f "$CONFIG" ]; then
  BUDGET="$(grep -E '^budget_usd=' "$CONFIG" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]' || true)"
fi

# Window cutoff (ISO date prefix; ISO timestamps sort lexicographically).
CUTOFF=""
if [ "$WINDOW" = week ]; then
  CUTOFF="$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d 2>/dev/null || echo 0000-00-00)"
elif [ "$WINDOW" = month ]; then
  CUTOFF="$(date +%Y-%m)"
fi

# Colors only on a TTY in human mode.
if [ -t 1 ] && [ "$JSON" = 0 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RST=$'\033[0m'; GRN=$'\033[38;5;42m'; AMB=$'\033[38;5;214m'; RED=$'\033[38;5;196m'
else BOLD=""; DIM=""; RST=""; GRN=""; AMB=""; RED=""; fi

# Single awk pass: filter → aggregate → format. No shell values interpolated into the program.
# Exit status: 0 = ok (or no cap set), 2 = OVER_BUDGET (cap set and total exceeds it).
awk -F'\t' \
  -v window="$WINDOW" -v cutoff="$CUTOFF" -v budget="$BUDGET" -v json="$JSON" \
  -v max_usd="$MAX_USD" \
  -v bold="$BOLD" -v dim="$DIM" -v rst="$RST" -v grn="$GRN" -v amb="$AMB" -v red="$RED" '
  NF >= 5 && $0 !~ /^#/ {
    ts = $1; repo = $2; model = tolower($4); cost = $5 + 0
    if (cutoff != "" && substr(ts, 1, length(cutoff)) < cutoff) next
    if (model ~ /haiku/) m = "haiku"; else if (model ~ /sonnet/) m = "sonnet"
    else if (model ~ /opus/) m = "opus"; else m = "other"
    total += cost; mc[m] += cost; rc[repo] += cost; runs++
  }
  END {
    cap = (max_usd != "" ? max_usd + 0 : 0)
    over = (cap > 0 && total > cap)
    if (json == 1) {
      printf "{\"window\":\"%s\",\"total\":%.6f,\"runs\":%d,\"by_model\":{", window, total, runs
      sep = ""; for (k in mc) { printf "%s\"%s\":%.6f", sep, k, mc[k]; sep = "," }
      printf "},\"by_repo\":{"; sep = ""
      for (k in rc) { rk = k; gsub(/\\/, "\\\\", rk); gsub(/"/, "\\\"", rk); printf "%s\"%s\":%.6f", sep, rk, rc[k]; sep = "," }
      printf "},\"budget\":%s", (budget == "" ? "null" : budget)
      if (cap > 0) {
        printf ",\"max_usd\":%.6f,\"remaining\":%.6f,\"over_budget\":%s", cap, cap - total, (over ? "true" : "false")
      }
      printf "}\n"
      exit (over ? 2 : 0)
    }
    printf "\n  %scompass · spend%s  %s(%s)%s\n", bold, rst, dim, window, rst
    printf "  %s────────────────────────────────%s\n", dim, rst
    printf "  %sTotal%s  $%.2f   %s(%d runs)%s\n", bold, rst, total, dim, runs, rst
    printf "\n  %sBy model%s\n", bold, rst
    split("opus sonnet haiku other", ord, " ")
    for (i = 1; i <= 4; i++) { k = ord[i]; if (mc[k] > 0)
      printf "    %-8s $%-7.2f %s%.0f%%%s\n", k, mc[k], dim, (total > 0 ? mc[k] / total * 100 : 0), rst }
    printf "\n  %sBy repo%s\n", bold, rst
    for (k in rc) printf "    %-24s $%.2f\n", k, rc[k]
    printf "\n  %sBudget%s  ", bold, rst
    if (budget == "") { printf "%sno budget set — export COMPASS_BUDGET_USD=NN%s\n", dim, rst }
    else {
      ratio = (budget + 0 > 0 ? total / budget : 0)
      col = grn; tag = "OK"
      if (ratio > 1) { col = red; tag = "over budget" } else if (ratio > 0.8) { col = amb; tag = "over 80%" }
      printf "$%.2f / $%.2f  %s%s (%.0f%%)%s\n", total, budget, col, tag, ratio * 100, rst
    }
    if (cap > 0) {
      printf "\n  %sMax-USD gate%s  ", bold, rst
      if (over) {
        printf "%sOVER_BUDGET total=$%.4f cap=$%.4f%s\n", red, total, cap, rst
      } else {
        printf "%sunder cap  remaining=$%.4f (cap=$%.4f)%s\n", grn, cap - total, cap, rst
      }
    }
    print ""
    if (over) exit 2
  }
' "$LEDGER"
