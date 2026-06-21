#!/usr/bin/env bash
# budget-gate.sh — PreToolUse live spend ceiling.
#
# Halts an interactive session the moment its estimated cost crosses a ceiling
# you set — the live counterpart to `compass spend --max-usd` (which gates the
# ledger after the fact). Opt-in and off by default: with no ceiling set this
# hook exits 0 instantly and changes nothing.
#
# Set a ceiling either way:
#   export COMPASS_MAX_USD=5            # this shell / session
#   echo 'max_usd=5' >> ~/.compass/config   # persistent default
#
# How it knows the spend: statusline.sh is the cost oracle — Claude Code hands it
# `.cost.estimated_cost_cents` on every render, and it drops a per-session
# breadcrumb at ${COMPASS_HOME}/sessions/<session_id>.cost. This hook reads that
# breadcrumb (fresh to the last render) and blocks once it meets/exceeds the cap.
#
# Wired in settings.json as a PreToolUse hook. Contract: exit 2 + JSON deny =>
# blocked (model is told why; the human can raise the cap or end the session);
# exit 0 => defer to normal rules.
#
# Fail-open by design: if the cap is unset, or spend can't be read yet (no render
# has happened), it does NOT block — a budget ceiling must never wedge a session
# on missing data. It is a cost guardrail, not a security boundary.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

INPUT="$(cat)"

# --- Resolve the ceiling: env wins, else config `max_usd=`, else unset (no gate).
CAP="${COMPASS_MAX_USD:-}"
if [ -z "$CAP" ]; then
  CONFIG="${COMPASS_HOME:-$HOME/.compass}/config"
  [ -f "$CONFIG" ] && CAP="$(grep -E '^max_usd=' "$CONFIG" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')"
fi
# No ceiling set, or not a positive number → nothing to enforce.
case "$CAP" in
  ''|*[!0-9.]*) exit 0 ;;
esac
awk -v c="$CAP" 'BEGIN{exit !(c+0>0)}' || exit 0

# --- Read this session's spend breadcrumb (USD) written by statusline.sh.
SID="$(json_get "$INPUT" '.session_id')"
[ -z "$SID" ] && exit 0   # can't attribute spend to a session → don't block
BREADCRUMB="${COMPASS_HOME:-$HOME/.compass}/sessions/${SID}.cost"
[ -s "$BREADCRUMB" ] || exit 0   # no render yet → unknown spend → fail open
USD="$(tr -cd '0-9.' < "$BREADCRUMB" 2>/dev/null)"
[ -z "$USD" ] && exit 0

# --- Over the ceiling? (breadcrumb is already in dollars; one awk, no float surprises)
SPENT="$(awk -v c="$USD" 'BEGIN{printf "%.2f", c}')"
if awk -v s="$USD" -v cap="$CAP" 'BEGIN{exit !((s+0) >= (cap+0))}'; then
  COMPASS_AUDIT_TOOL="$(json_get "$INPUT" '.tool_name')"
  COMPASS_AUDIT_RULE="budget-ceiling"
  deny "Budget ceiling reached: this session has spent ~\$$SPENT, at or over your \$$CAP cap (COMPASS_MAX_USD / max_usd). Stopping before it spends more. To continue, raise the cap (e.g. export COMPASS_MAX_USD=$(awk -v c="$CAP" 'BEGIN{printf "%g", c*2}')) or start a fresh session; set it to 0/unset to remove the gate."
fi

exit 0
