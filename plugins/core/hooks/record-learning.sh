#!/usr/bin/env bash
# record-learning.sh — OPT-IN Stop / SubagentStop hook: persist durable learnings.
#
# The write half of compass's persistent memory (ADR 0001, local v1). It does NOT try to
# auto-summarize the whole transcript (that stores noise and risks leaking context) — it
# records only learnings the agent EXPLICITLY marks, one per line, in its final message:
#
#     LEARNED: the integration suite needs CASS_SEED=42 or it flakes
#     MEMORY:  prod auth tokens live 15m; refresh endpoint is /session/refresh
#
# Each marked line is run through the store's secret-scrubber + trust tiers before it
# lands; secret-looking lines are dropped. OFF by default — wire under hooks.Stop /
# hooks.SubagentStop in settings.json and set COMPASS_MEMORY_TRUST='<repo>:read-write'.
# Self-no-ops (silent exit 0) when memory isn't configured, so it never breaks a turn.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

[ -n "${COMPASS_MEMORY_TRUST:-}" ] || exit 0
have python3 || exit 0

STORE=""
for c in "$DIR/../../mcp/compass-memory/store.py" "${COMPASS_HOME:-$HOME/.compass}/mcp/compass-memory/store.py"; do
  [ -f "$c" ] && { STORE="$c"; break; }
done
[ -n "$STORE" ] || exit 0

INPUT="$(cat)"
TRANSCRIPT="$(json_get "$INPUT" '.transcript_path')"
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0

repo="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")")"

# Pull the assistant text out of the JSONL transcript (best-effort), then keep only the
# explicit LEARNED:/MEMORY: lines. jq when present; a grep fallback otherwise.
extract() {
  if have jq; then
    jq -r 'select(.message.role=="assistant") | (.message.content[]? | if type=="object" then .text else . end) // empty' "$TRANSCRIPT" 2>/dev/null
  else
    cat "$TRANSCRIPT"
  fi
}

recorded=0
while IFS= read -r line; do
  # strip a leading marker + surrounding quotes/markdown
  note="$(printf '%s' "$line" | sed -E 's/.*(LEARNED|MEMORY):[[:space:]]*//; s/^["'\''`]+//; s/["'\''`]+$//')"
  [ -n "$note" ] || continue
  out="$(python3 "$STORE" record --repo "$repo" --tags "session" "$note" 2>/dev/null || true)"
  case "$out" in recorded) recorded=$((recorded+1)); compass_log_metric memory "recorded: ${note:0:60}" ;; esac
done < <(extract | grep -aoE '(LEARNED|MEMORY):[[:space:]]*.+' | sort -u)

# Surface a tiny confirmation in the agent's context (additionalContext is allowed on Stop).
[ "$recorded" -gt 0 ] && emit_context "compass memory: recorded $recorded learning(s) for '$repo'." "Stop"
exit 0
