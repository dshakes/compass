#!/usr/bin/env bash
# test-scan-tool-output.sh — behavior tests for scan-tool-output.sh (PostToolUse indirect-
# injection scan over WebFetch / WebSearch / Bash / MCP results). Pins: injected content is
# flagged for every tool_response shape (string, object, content-block array), clean content
# and local Bash output stay silent, malformed input never breaks the turn.
#
# Hermetic: COMPASS_HOME is a temp dir, the remote guardrail backend is forced off, no
# network. Payloads come from scripts/redteam-corpus.tsv so the test tracks the detector.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/claude/hooks/scan-tool-output.sh"
CORPUS="$ROOT/scripts/redteam-corpus.tsv"

pass=0; fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3')" ;; esac; }
lacks() { case "$2" in *"$3"*) no "$1 (unexpectedly contains '$3')" ;; *) ok "$1" ;; esac; }

command -v jq >/dev/null 2>&1 || { echo "jq required for scan-tool-output tests" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/compass-scan.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# First injection payload in the corpus that survives a JSON round-trip on one line.
INJ="$(awk -F'\t' '$1=="inject" && $2 !~ /[\\"]/ {print $2; exit}' "$CORPUS")"
[ -n "$INJ" ] || { echo "no usable inject payload in $CORPUS" >&2; exit 1; }
CLEAN="The build finished in 12s and all 48 tests passed."

# run <json> — sets OUT (stdout) and RC; hermetic env. stdin comes from a file, not a pipe:
# the hook exits before reading when a policy switch is off, and under pipefail a builtin
# printf that hits the closed pipe returns 1 — which would be the writer's status, not the hook's.
run() {
  RC=0; printf '%s' "$1" >"$TMP/in.json"
  OUT="$(COMPASS_HOME="$TMP/home" COMPASS_GUARDRAIL_BACKEND=none \
    COMPASS_REDTEAM= COMPASS_REDTEAM_TOOL_OUTPUT= bash "$HOOK" <"$TMP/in.json" 2>/dev/null)" || RC=$?
}
# mk <tool> <tool_input-json> <tool_response-json>
mk() { jq -cn --arg t "$1" --argjson i "$2" --argjson r "$3" '{tool_name:$t,tool_input:$i,tool_response:$r}'; }

CURL='{"command":"curl -s https://example.com/page"}'
LOCAL='{"command":"ls -la"}'

echo "scan-tool-output.sh"

run "$(mk Bash "$CURL" "$(jq -cn --arg s "$INJ" '$s')")"
has "Bash curl + injection -> warns" "$OUT" "UNTRUSTED"; [ "$RC" = 0 ] && ok "Bash curl + injection -> exit 0" || no "exit $RC"

run "$(mk Bash "$CURL" "$(jq -cn --arg s "$CLEAN" '$s')")"
eq_silent() { if [ -z "$OUT" ] && [ "$RC" = 0 ]; then ok "$1"; else no "$1 (rc=$RC out='$OUT')"; fi; }
eq_silent "Bash curl + clean -> silent"

run "$(mk Bash "$LOCAL" "$(jq -cn --arg s "$INJ" '$s')")"
eq_silent "Bash local command (no fetch) + injection -> silent (precision)"

run "$(mk WebFetch '{"url":"https://example.com"}' "$(jq -cn --arg s "$INJ" '$s')")"
has "WebFetch + injection -> warns" "$OUT" "UNTRUSTED"
has "warning names the tool" "$OUT" "WebFetch"

run "$(mk WebFetch '{"url":"https://example.com"}' "$(jq -cn --arg s "$CLEAN" '$s')")"
eq_silent "WebFetch clean -> silent"

run "$(mk mcp__github__get_issue '{"number":1}' "$(jq -cn --arg s "$INJ" '{title:"bug",body:$s}')")"
has "MCP object response + injection -> warns" "$OUT" "UNTRUSTED"
has "MCP warning names the tool" "$OUT" "mcp__github__get_issue"

run "$(mk mcp__github__get_issue '{"number":1}' "$(jq -cn --arg s "$INJ" '[{type:"text",text:"hello"},{type:"text",text:$s}]')")"
has "MCP content-block array + injection -> warns" "$OUT" "UNTRUSTED"

run "$(mk mcp__github__get_issue '{"number":1}' "$(jq -cn --arg s "$INJ" '$s')")"
has "MCP string response + injection -> warns" "$OUT" "UNTRUSTED"

run "$(mk mcp__github__get_issue '{"number":1}' "$(jq -cn --arg s "$CLEAN" '{title:"ok",body:$s}')")"
eq_silent "MCP clean object -> silent"

run "$(mk mcp__github__get_issue '{"number":1}' "$(jq -cn --arg s "$CLEAN" '[{type:"text",text:$s}]')")"
eq_silent "MCP clean array -> silent"

run 'not json {{{'
eq_silent "malformed JSON -> exit 0, silent"

run ''
eq_silent "empty input -> exit 0, silent"

RC=0; mk WebFetch '{}' "$(jq -cn --arg s "$INJ" '$s')" >"$TMP/in.json"
OUT="$(COMPASS_HOME="$TMP/home" COMPASS_REDTEAM= COMPASS_REDTEAM_TOOL_OUTPUT=0 \
  COMPASS_GUARDRAIL_BACKEND=none bash "$HOOK" <"$TMP/in.json" 2>/dev/null)" || RC=$?
eq_silent "COMPASS_REDTEAM_TOOL_OUTPUT=0 -> silent"
lacks "kill switch emits nothing" "$OUT" "UNTRUSTED"

printf 'scan-tool-output corpus: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
