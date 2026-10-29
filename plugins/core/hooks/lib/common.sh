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

# ── Effective policy: profile → user config → env, then repo override (tighten-only) ──
# One resolver for every guardrail knob, so the hooks, `compass profile` and `compass gate`
# all read the same answer. Layers, lowest to highest:
#   1. profile  — ${COMPASS_HOME}/profile names a data file in hooks/profiles/<name>.conf
#                 (unset/unknown → standard, which sets nothing = today's behavior)
#   2. user     — ${COMPASS_HOME}/config (key=value), the file budget-gate always read
#   3. env      — COMPASS_<KEY> (the user's own shell; wins, as it always did)
#   4. repo     — <project>/.compass/policy.conf. Untrusted: it may only TIGHTEN. A value
#                 that would loosen (disable a scan, raise or clear a cap) or a key we don't
#                 know is dropped and the stricter value wins. "A project cannot grant
#                 itself a safety exception."
COMPASS_PROFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../profiles" 2>/dev/null && pwd)"
COMPASS_POLICY_DEFAULTS="redteam=1 redteam_prompt=1 redteam_tool_output=1 redteam_context=1 redteam_enforce=0 max_usd= max_usd_day= fail_closed=0"

_compass_kv() { # file key → value of the first key= line (whitespace stripped)
  [ -f "$1" ] && grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]'
}
compass_profile_name() {
  local p="" f="${COMPASS_HOME:-$HOME/.compass}/profile"
  [ -f "$f" ] && p="$(tr -cd 'a-z0-9_-' <"$f" 2>/dev/null)"
  [ -n "$p" ] && [ -f "$COMPASS_PROFILES_DIR/$p.conf" ] && { printf '%s' "$p"; return; }
  printf standard
}
compass_repo_root() {
  git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --show-toplevel 2>/dev/null || printf '%s' "${CLAUDE_PROJECT_DIR:-$PWD}"
}
_compass_is_pos() { case "$1" in ''|*[!0-9.]*) return 1 ;; esac; awk -v c="$1" 'BEGIN{exit !(c+0>0)}'; }

# _compass_tighter KEY CURRENT REPO → the stricter of the two (rc 1 if REPO was rejected).
_compass_tighter() {
  case "$1" in
    max_usd|max_usd_day) # a cap: lower wins; setting one where none exists is tighter
      if _compass_is_pos "$3" && { ! _compass_is_pos "$2" || awk -v r="$3" -v c="$2" 'BEGIN{exit !(r+0<c+0)}'; }; then
        printf '%s' "$3"; return 0; fi ;;
    redteam|redteam_prompt|redteam_tool_output|redteam_context|redteam_enforce) # on wins
      [ "$3" = 1 ] && { printf 1; return 0; } ;;
  esac
  printf '%s' "$2"
  # same value as current = a no-op, not a loosening attempt
  [ "$3" = "$2" ] && return 0
  return 1
}

# compass_policy KEY → the effective value (env > user config > profile > default, then
# tightened by the repo). The env var is COMPASS_<KEY>, uppercased.
compass_policy() {
  local key="$1" envv v def home="${COMPASS_HOME:-$HOME/.compass}" rv
  envv="COMPASS_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
  v="${!envv:-}"
  [ -z "$v" ] && v="$(_compass_kv "$home/config" "$key")"
  [ -z "$v" ] && v="$(_compass_kv "$COMPASS_PROFILES_DIR/$(compass_profile_name).conf" "$key")"
  if [ -z "$v" ]; then def=" $COMPASS_POLICY_DEFAULTS "; def="${def#* "$key"=}"; v="${def%% *}"; fi
  [ "$key" = fail_closed ] && { printf '%s' "$v"; return 0; }   # install-time only, see below
  # ponytail: callers use $(compass_policy …), a subshell, so this cache rarely survives —
  # one `git rev-parse` per lookup (~ms). Set _COMPASS_ROOT in the hook if it ever shows up.
  [ -z "${_COMPASS_ROOT+x}" ] && _COMPASS_ROOT="$(compass_repo_root)"
  rv="$(_compass_kv "$_COMPASS_ROOT/.compass/policy.conf" "$key")"
  [ -n "$rv" ] && v="$(_compass_tighter "$key" "$v" "$rv")"
  printf '%s' "$v"
}

# compass_repo_policy_rejections [ROOT] → one line per repo-override line that was refused
# (unknown key, install-time key, or a value that would loosen). Empty = all accepted.
compass_repo_policy_rejections() {
  local root="${1:-$(compass_repo_root)}" f line k rv cur
  f="$root/.compass/policy.conf"; [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    case "$line" in ''|'#'*) continue ;; esac
    k="${line%%=*}"; rv="${line#*=}"
    case " $COMPASS_POLICY_DEFAULTS " in
      *" $k="*) ;;
      *) printf '%s: unknown key — a repo may only tighten known guardrails; ignored\n' "$k"; continue ;;
    esac
    [ "$k" = fail_closed ] && { printf 'fail_closed: install-time setting — choose it with `compass profile strict`, not per repo; ignored\n'; continue; }
    cur="$(_COMPASS_ROOT=/nonexistent compass_policy "$k")"
    _compass_tighter "$k" "$cur" "$rv" >/dev/null \
      || printf '%s=%s would loosen your profile (%s=%s) — rejected; the stricter value wins\n' "$k" "$rv" "$k" "${cur:-unset}"
  done <"$f"
}

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
