#!/usr/bin/env bash
# budget-gate.sh — PreToolUse live spend ceiling (session + daily).
#
# Halts a session the moment its estimated cost crosses a ceiling you set — the live
# counterpart to `compass spend --max-usd` (which gates the ledger after the fact). Two caps,
# both opt-in and off by default; with neither set this hook exits 0 instantly and changes
# nothing:
#
#   • Session cap — this session's spend.   export COMPASS_MAX_USD=5   (or max_usd=5 in config)
#   • Daily cap   — TODAY's total across     export COMPASS_MAX_USD_DAY=20  (or max_usd_day=20)
#                   this session + every loop/routine that logged to the spend ledger.
#                   The circuit breaker the loop-engineering playbook calls for: set it BEFORE
#                   running unattended loops, so a bug spinning idle overnight can't burn a
#                   whole day's quota across many runs, not just one session.
#
# Persist either in ${COMPASS_HOME:-~/.compass}/config (max_usd= / max_usd_day=) or export it.
#
# How it knows the spend: statusline.sh is the cost oracle — Claude Code hands it
# `.cost.estimated_cost_cents` on every render, and it drops a per-session breadcrumb at
# ${COMPASS_HOME}/sessions/<session_id>.cost. The daily cap adds today's rows of the shared
# ledger ${COMPASS_HOME}/spend.tsv (what loops/routines/orchestrate logged) to this session's
# breadcrumb for a true day total.
#
# Wired in settings.json as a PreToolUse hook. Contract: exit 2 + JSON deny => blocked (model
# is told why; the human can raise the cap or end the session); exit 0 => defer to normal rules.
#
# Fail-open by design: if no cap is set, or spend can't be read yet, it does NOT block — a
# budget ceiling must never wedge a session on missing data. It is a cost guardrail, not a
# security boundary.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

INPUT="$(cat)"
CONFIG="${COMPASS_HOME:-$HOME/.compass}/config"
cfg_val() { [ -f "$CONFIG" ] && grep -E "^$1=" "$CONFIG" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]'; }
is_pos()  { awk -v c="$1" 'BEGIN{exit !(c+0>0)}'; }

# --- Resolve the two ceilings (env wins over config; junk/non-positive → treated as unset).
CAP="${COMPASS_MAX_USD:-}"; [ -z "$CAP" ] && CAP="$(cfg_val max_usd)"
case "$CAP" in ''|*[!0-9.]*) CAP="" ;; esac
[ -n "$CAP" ] && { is_pos "$CAP" || CAP=""; }

DAY_CAP="${COMPASS_MAX_USD_DAY:-}"; [ -z "$DAY_CAP" ] && DAY_CAP="$(cfg_val max_usd_day)"
case "$DAY_CAP" in ''|*[!0-9.]*) DAY_CAP="" ;; esac
[ -n "$DAY_CAP" ] && { is_pos "$DAY_CAP" || DAY_CAP=""; }

# Neither ceiling set → nothing to enforce.
[ -z "$CAP" ] && [ -z "$DAY_CAP" ] && exit 0

# --- This session's spend (USD) from the statusline breadcrumb. Unknown → 0 + fail-open flag.
USD=0; HAVE_SESSION=0
SID="$(json_get "$INPUT" '.session_id')"
if [ -n "$SID" ]; then
  BREADCRUMB="${COMPASS_HOME:-$HOME/.compass}/sessions/${SID}.cost"
  if [ -s "$BREADCRUMB" ]; then
    v="$(tr -cd '0-9.' < "$BREADCRUMB" 2>/dev/null)"
    [ -n "$v" ] && { USD="$v"; HAVE_SESSION=1; }
  fi
fi
DENY_TOOL="$(json_get "$INPUT" '.tool_name')"

# --- Session ceiling: block once THIS session's spend meets/exceeds the cap.
# Only when we actually know the session spend — never wedge on missing data.
if [ -n "$CAP" ] && [ "$HAVE_SESSION" = 1 ] && awk -v s="$USD" -v c="$CAP" 'BEGIN{exit !((s+0) >= (c+0))}'; then
  SPENT="$(awk -v c="$USD" 'BEGIN{printf "%.2f", c}')"
  COMPASS_AUDIT_TOOL="$DENY_TOOL"; COMPASS_AUDIT_RULE="budget-ceiling"
  deny "Budget ceiling reached: this session has spent ~\$$SPENT, at or over your \$$CAP cap (COMPASS_MAX_USD / max_usd). Stopping before it spends more. To continue, raise the cap (e.g. export COMPASS_MAX_USD=$(awk -v c="$CAP" 'BEGIN{printf "%g", c*2}')) or start a fresh session; set it to 0/unset to remove the gate."
fi

# --- Daily ceiling: block once TODAY's total (ledger + this session) meets/exceeds the cap.
# Sums today's rows of the shared spend ledger plus this session's breadcrumb (0 if unknown).
if [ -n "$DAY_CAP" ]; then
  LEDGER="${COMPASS_HOME:-$HOME/.compass}/spend.tsv"
  TODAY="$(date -u +%Y-%m-%d)"
  LEDGER_TODAY=0
  [ -s "$LEDGER" ] && LEDGER_TODAY="$(awk -F'\t' -v d="$TODAY" 'NF>=5 && $0 !~ /^#/ && substr($1,1,10)==d {t+=$5+0} END{printf "%.6f", t}' "$LEDGER" 2>/dev/null)"
  if awk -v l="$LEDGER_TODAY" -v s="$USD" -v c="$DAY_CAP" 'BEGIN{exit !((l+0)+(s+0) >= (c+0))}'; then
    DAYSPENT="$(awk -v l="$LEDGER_TODAY" -v s="$USD" 'BEGIN{printf "%.2f", (l+0)+(s+0)}')"
    COMPASS_AUDIT_TOOL="$DENY_TOOL"; COMPASS_AUDIT_RULE="budget-ceiling-daily"
    deny "Daily budget ceiling reached: ~\$$DAYSPENT spent today (this session + logged loop/routine runs), at or over your \$$DAY_CAP daily cap (COMPASS_MAX_USD_DAY / max_usd_day). Stopping before the day's loops run away. Raise the cap or resume tomorrow; set it to 0/unset to remove the gate."
  fi
fi

exit 0
