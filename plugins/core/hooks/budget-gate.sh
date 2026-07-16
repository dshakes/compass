#!/usr/bin/env bash
# shellcheck disable=SC2034  # COMPASS_AUDIT_TOOL/RULE are consumed by deny()/compass_log_audit in the sourced lib/common.sh
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

# --- Fallback: compute session cost from transcript JSONL when breadcrumb is absent or lower.
# Headless runs (claude -p, CI) never render the statusline so the breadcrumb is never written;
# the transcript is the ground truth. PreToolUse payloads always include transcript_path.
# Single pass, jq-first with python3 fallback; neither available → skip (fail-open, no change).
# ponytail: pricing table is a local copy — no shared table in the repo yet.
# Rates (USD/token): haiku-4-5 $0.80/$4 MTok, sonnet/fable $3/$15 MTok, opus $15/$75 MTok.
# Cache-write/read (per MTok): haiku $1.00/$0.08, sonnet $3.75/$0.30, opus $18.75/$1.50.
TPATH="$(json_get "$INPUT" '.transcript_path')"
TUSD=""
if [ -n "$TPATH" ] && [ -f "$TPATH" ]; then
  if have jq; then
    TUSD="$(jq -r '
      select(.type == "assistant") | .message |
      ((.model // "") | ascii_downcase) as $m |
      (.usage.input_tokens // 0) as $in |
      (.usage.output_tokens // 0) as $out |
      (.usage.cache_creation_input_tokens // 0) as $cw |
      (.usage.cache_read_input_tokens // 0) as $cr |
      if ($m | contains("haiku")) then
        $in*0.0000008 + $out*0.000004 + $cw*0.000001 + $cr*0.00000008
      elif ($m | contains("opus")) then
        $in*0.000015 + $out*0.000075 + $cw*0.00001875 + $cr*0.0000015
      else
        $in*0.000003 + $out*0.000015 + $cw*0.000003750 + $cr*0.0000003
      end
    ' "$TPATH" 2>/dev/null | awk '{t+=$1} END{printf "%.6f",t+0}' 2>/dev/null)" || TUSD=""
  elif have python3; then
    TUSD="$(python3 -c '
import sys,json
P={"haiku":(8e-7,4e-6,1e-6,8e-8),"opus":(1.5e-5,7.5e-5,1.875e-5,1.5e-6),"sonnet":(3e-6,1.5e-5,3.75e-6,3e-7)}
t=0.0
try:
 with open(sys.argv[1]) as f:
  for line in f:
   try: obj=json.loads(line)
   except: continue
   if obj.get("type")!="assistant": continue
   msg=obj.get("message") or {}
   m=(msg.get("model") or "").lower()
   k="opus" if "opus" in m else ("haiku" if "haiku" in m else "sonnet")
   u=msg.get("usage") or {}
   r=P[k]
   t+=u.get("input_tokens",0)*r[0]+u.get("output_tokens",0)*r[1]+u.get("cache_creation_input_tokens",0)*r[2]+u.get("cache_read_input_tokens",0)*r[3]
except: pass
print("%.6f"%t)
' "$TPATH" 2>/dev/null)" || TUSD=""
  fi
  case "$TUSD" in ''|*[!0-9.]*) TUSD="" ;; esac
  # prefer the larger: transcript may be more current than the breadcrumb; never under-count
  if [ -n "$TUSD" ]; then
    if [ "$HAVE_SESSION" = 0 ] || awk -v t="$TUSD" -v b="$USD" 'BEGIN{exit!(t+0>b+0)}'; then
      USD="$TUSD"; HAVE_SESSION=1
    fi
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
