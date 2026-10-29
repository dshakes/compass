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
is_pos()  { awk -v c="$1" 'BEGIN{exit !(c+0>0)}'; }

# --- Resolve the two ceilings (env > config > profile; a repo policy may only lower them —
# compass_policy in lib/common.sh). Junk/non-positive → treated as unset.
CAP="$(compass_policy max_usd)"
case "$CAP" in ''|*[!0-9.]*) CAP="" ;; esac
[ -n "$CAP" ] && { is_pos "$CAP" || CAP=""; }

DAY_CAP="$(compass_policy max_usd_day)"
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
# Rates: USD per token (in, out, cache-write-5m, cache-read), platform.claude.com/docs/en/
# about-claude/pricing, 2026-10. Exact version first; an id that matches no version is priced
# at its FAMILY'S MAX, and an unknown family at the overall max — a spend cap must over-count,
# never under-count. Haiku 5.5 uses its >100k-prompt tier (conservative).
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
      (if   ($m|test("opus-5-5")) then [4,20,5,0.2]
       elif ($m|test("opus-(5|4-[5-8])")) then [5,25,6.25,0.5]
       elif ($m|test("opus")) then [15,75,18.75,1.5]
       elif ($m|test("sonnet-5-5")) then [2,10,2.5,0.1]
       elif ($m|test("sonnet-5")) then [2,10,2.5,0.2]
       elif ($m|test("sonnet")) then [3,15,3.75,0.3]
       elif ($m|test("haiku-5-5")) then [0.5,2.5,0.625,0.05]
       elif ($m|test("haiku")) then [1,5,1.25,0.1]
       elif ($m|test("(fable|mythos)-5-1")) then [10,50,12.5,0.25]
       elif ($m|test("fable|mythos")) then [10,50,12.5,1]
       else [15,75,18.75,1.5] end) as $r |
      ($in*$r[0] + $out*$r[1] + $cw*$r[2] + $cr*$r[3]) / 1000000
    ' "$TPATH" 2>/dev/null | awk '{t+=$1} END{printf "%.6f",t+0}' 2>/dev/null)" || TUSD=""
  elif have python3; then
    TUSD="$(python3 -c '
import sys,json
import re
P=[("opus-5-5",(4,20,5,.2)),("opus-(5|4-[5-8])",(5,25,6.25,.5)),("opus",(15,75,18.75,1.5)),("sonnet-5-5",(2,10,2.5,.1)),("sonnet-5",(2,10,2.5,.2)),("sonnet",(3,15,3.75,.3)),("haiku-5-5",(.5,2.5,.625,.05)),("haiku",(1,5,1.25,.1)),("(fable|mythos)-5-1",(10,50,12.5,.25)),("fable|mythos",(10,50,12.5,1)),("",(15,75,18.75,1.5))]
t=0.0
try:
 with open(sys.argv[1]) as f:
  for line in f:
   try: obj=json.loads(line)
   except: continue
   if obj.get("type")!="assistant": continue
   msg=obj.get("message") or {}
   m=(msg.get("model") or "").lower()
   r=next(v for k,v in P if re.search(k,m))
   u=msg.get("usage") or {}
   t+=(u.get("input_tokens",0)*r[0]+u.get("output_tokens",0)*r[1]+u.get("cache_creation_input_tokens",0)*r[2]+u.get("cache_read_input_tokens",0)*r[3])/1e6
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
