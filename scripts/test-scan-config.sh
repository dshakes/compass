#!/usr/bin/env bash
# test-scan-config.sh — `compass scan --config` against fixtures (scripts/fixtures/scan-config).
#
# risky/ carries one instance of every finding the audit promises; clean/ carries the
# safe spelling of each (pinned MCP, $VAR env refs, timed hooks that exist). Asserts the
# verdict, the exit code, and that a secret's VALUE never reaches the output.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN="$ROOT/scripts/compass-scan.sh"
FX="$ROOT/scripts/fixtures/scan-config"

pass=0; fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

command -v jq >/dev/null 2>&1 || { echo "test-scan-config: jq required"; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp -R "$FX/risky" "$FX/clean" "$TMP/"
chmod 0777 "$TMP/risky/home/.claude/hooks/ww.sh"   # git can't carry o+w; make it here

run() { "$SCAN" --config "$@"; }

echo "risky config:"
human="$(run --home "$TMP/risky/home" --project "$TMP/risky/project" 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "exits 1 on HIGH" || no "exit $rc, want 1"
json="$(run --json --home "$TMP/risky/home" --project "$TMP/risky/project" 2>/dev/null)"
has() { # sev rule file-suffix
  if printf '%s' "$json" | jq -e --arg s "$1" --arg r "$2" --arg f "$3" \
      '.findings | any(.severity == $s and .rule == $r and (.file | endswith($f)))' >/dev/null; then
    ok "$1 $2 ($3)"; else no "missing: $1 $2 in $3"; fi
}
has HIGH bypass-permissions  .claude/settings.json
has HIGH wildcard-bash       .claude/settings.json
has HIGH plaintext-secret    .claude/settings.json
has HIGH hook-world-writable .claude/settings.json
has MED  hook-missing        .claude/settings.json
has LOW  hook-no-timeout     .claude/settings.json
has HIGH mcp-unpinned        .mcp.json
has HIGH mcp-unpinned        .claude.json
has MED  mcp-unpinned        .mcp.json
has HIGH plaintext-secret    .mcp.json
has HIGH bypass-permissions  .codex/config.toml
has MED  no-approvals        .codex/config.toml
has HIGH mcp-unpinned        .codex/config.toml
has HIGH plaintext-secret    .codex/config.toml
has HIGH bypass-permissions  .gemini/settings.json
has HIGH mcp-fetch-exec      .gemini/settings.json
case "$human$json" in *FIXTUREVALUE*) no "a secret VALUE leaked into the output" ;; *) ok "secret values never printed (names only)" ;; esac
case "$json" in *OPENAI_API_KEY*) ok "secret reported by key name" ;; *) no "secret key name not reported" ;; esac
case "$json" in *MAX_MCP_OUTPUT_TOKENS*|*SAFE_REF*) no "false positive on a non-secret env key" ;; *) ok "no false positive on *_TOKENS / \$VAR refs" ;; esac
case "$json" in *"'pinned'"*) no "pinned MCP server flagged" ;; *) ok "pinned MCP servers pass" ;; esac
[ "$(printf '%s' "$json" | jq '.high')" = "$(printf '%s' "$json" | jq '[.findings[] | select(.severity == "HIGH")] | length')" ] \
  && ok "--json high count matches findings" || no "--json high count mismatch"

echo "clean config:"
out="$(run --home "$TMP/clean/home" --project "$TMP/clean/project" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "exits 0" || no "exit $rc, want 0: $out"
case "$out" in *clean*) ok "reports clean" ;; *) no "not clean: $out" ;; esac

echo "usage:"
run --bogus >/dev/null 2>&1; [ "$?" = 2 ] && ok "unknown flag exits 2" || no "unknown flag exit code"

echo
printf 'scan-config: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
