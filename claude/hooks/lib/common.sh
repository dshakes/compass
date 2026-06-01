#!/usr/bin/env bash
# common.sh — shared helpers for Claude Code hooks.
# Sourced by every hook. Must never exit non-zero on its own.
#
# Design goals:
#   - Zero hard dependencies. Prefer jq, fall back to python3, then to grep/sed.
#   - Never break a session: helpers degrade gracefully and stay quiet on error.
#   - Fast: hooks run on the hot path of every tool call.

set -o pipefail

# Read a string field from a JSON document.
#   json_get '<json>' '.tool_name'
#   json_get '<json>' '.tool_input.command'
# Prints the value (empty string if missing). Never fails the caller.
json_get() {
  local json="$1" path="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r "$path // empty" 2>/dev/null
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c '
import sys, json
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(0)
path = sys.argv[1].lstrip(".").split(".")
cur = doc
for key in path:
    if isinstance(cur, dict) and key in cur:
        cur = cur[key]
    else:
        sys.exit(0)
if cur is None:
    sys.exit(0)
print(cur if isinstance(cur, str) else json.dumps(cur))
' "$path" 2>/dev/null
    return 0
  fi
  # Last-resort: shallow scalar extraction for top-level keys like .tool_name
  local key="${path##*.}"
  printf '%s' "$json" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}

# Extract the author-written TEXT from a file-writing tool's input — Write(.content),
# Edit(.new_string), and every MultiEdit(.edits[].new_string) — with REAL newlines,
# so a line-oriented content scanner sees true lines (not a jq-collapsed blob where
# one placeholder marker could mask a real secret on another line). Empty if none.
json_write_text() {
  local json="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r '
      [ .tool_input.content, .tool_input.new_string, (.tool_input.edits[]?.new_string) ]
      | map(select(. != null)) | .[]' 2>/dev/null
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin).get("tool_input", {})
except Exception:
    sys.exit(0)
parts = []
for k in ("content", "new_string"):
    v = d.get(k)
    if isinstance(v, str):
        parts.append(v)
for e in (d.get("edits") or []):
    if isinstance(e, dict) and isinstance(e.get("new_string"), str):
        parts.append(e["new_string"])
sys.stdout.write("\n".join(parts))
' 2>/dev/null
    return 0
  fi
  # No JSON parser: fall back to the raw payload (single-line tokens still match).
  printf '%s' "$json"
}

# Emit a PreToolUse deny decision (stdout JSON) and exit 2 (block).
# Usage: deny "human-readable reason"
# Writes BOTH the impact metric (a counter) and a structured audit record (the trail).
# The caller may set COMPASS_AUDIT_TOOL / COMPASS_AUDIT_RULE for richer attribution.
deny() {
  local reason="$1"
  compass_log_metric block "$reason"
  compass_log_audit deny "${COMPASS_AUDIT_TOOL:-?}" "${COMPASS_AUDIT_RULE:-guardrail}" "$reason"
  cat <<JSON
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$(json_string "$reason")}}
JSON
  exit 2
}

# Emit additional context for the model (UserPromptSubmit / SessionStart) and exit 0.
emit_context() {
  local ctx="$1" event="${2:-UserPromptSubmit}"
  cat <<JSON
{"hookSpecificOutput":{"hookEventName":"$event","additionalContext":$(json_string "$ctx")}}
JSON
  exit 0
}

# JSON-encode a string safely (quotes included).
json_string() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -Rs .
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'
  else
    # Minimal escaping fallback.
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"
    printf '"%s"' "$s"
  fi
}

# True if a command exists.
have() { command -v "$1" >/dev/null 2>&1; }

# Append a best-effort usage metric for the `compass impact` dashboard — e.g. a
# footgun blocked or a file auto-formatted. Never fails the caller (hot path).
# Columns: timestamp<TAB>event<TAB>repo<TAB>detail
compass_log_metric() {
  local event="$1" detail="${2:-}" home="${COMPASS_HOME:-$HOME/.compass}" repo
  detail="${detail//$'\t'/ }"; detail="${detail//$'\n'/ }"
  repo="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")")"
  { mkdir -p "$home" 2>/dev/null && printf '%s\t%s\t%s\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "$repo" "$detail" \
      >>"$home/metrics.tsv"; } 2>/dev/null || true
}

# Append a structured security-audit record (one JSON object per line) for a gated or
# blocked action — a queryable, SIEM-exportable trail beyond the impact counters.
# `compass audit-log` reads it. Fields: ts, decision, tool, repo, rule, detail (the
# detail is a redacted reason — never the raw secret/payload). Never fails the caller.
compass_log_audit() {
  local decision="$1" tool="${2:-?}" rule="${3:-?}" detail="${4:-}" home="${COMPASS_HOME:-$HOME/.compass}" repo
  repo="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")")"
  { mkdir -p "$home" 2>/dev/null && printf '{"ts":%s,"decision":%s,"tool":%s,"repo":%s,"rule":%s,"detail":%s}\n' \
      "$(json_string "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" "$(json_string "$decision")" "$(json_string "$tool")" \
      "$(json_string "$repo")" "$(json_string "$rule")" "$(json_string "$detail")" \
      >>"$home/audit.jsonl"; } 2>/dev/null || true
}
