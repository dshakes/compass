#!/usr/bin/env bash
# test-audit-plugin.sh — exercise compass-audit-plugin against the fixture dirs.
#
# Asserts:
#   1. malicious-plugin exits 1 and contains one finding per class (a–e)
#   2. clean-plugin exits 0
#   3. --json output is valid JSON (jq or python3)
#
# Mirrors the style of scripts/test-protect-paths.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER="$ROOT/scripts/compass-audit-plugin.sh"
FIXTURES="$ROOT/scripts/fixtures/audit-plugin"
MAL="$FIXTURES/malicious-plugin"
CLEAN="$FIXTURES/clean-plugin"

pass=0; fail=0

ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

# Run scanner and capture output + exit code; never abort on scanner failure.
run_scanner() {
  local dir="$1"; shift
  out="$(bash "$SCANNER" "$@" "$dir" 2>&1)"
  rc=$?
  return 0
}

# ── 1. malicious-plugin: must exit 1 with expected finding classes ──────────
echo "malicious-plugin — expect findings in every class:"

run_scanner "$MAL"
[ "$rc" -eq 1 ] && ok "exits 1 (findings present)" || no "expected exit 1, got $rc"

# a. injection in .md
printf '%s\n' "$out" | grep -qi 'instruction-override\|tool-poisoning\|data-exfil' \
  && ok "class a: injection pattern detected" \
  || no "class a: injection pattern not found in output"

# b. unpinned MCP
printf '%s\n' "$out" | grep -qi 'unpinned-mcp' \
  && ok "class b: unpinned MCP server detected" \
  || no "class b: unpinned MCP finding not found"

# c. hook remote-exec (curl|sh)
printf '%s\n' "$out" | grep -qi 'hook-remote-exec' \
  && ok "class c: fetch+execute pattern detected" \
  || no "class c: hook-remote-exec finding not found"

# d. settings manipulation
printf '%s\n' "$out" | grep -qi 'settings-manipulation\|sessionstart-hook' \
  && ok "class d: settings/SessionStart finding detected" \
  || no "class d: settings-manipulation or sessionstart-hook finding not found"

# e. executable payload (base64 or eval-download)
printf '%s\n' "$out" | grep -qi 'exec-payload\|hook-eval-download' \
  && ok "class e: executable payload detected" \
  || no "class e: exec-payload or hook-eval-download finding not found"

echo
echo "clean-plugin — expect exit 0:"

run_scanner "$CLEAN"
[ "$rc" -eq 0 ] && ok "exits 0 (clean)" || {
  no "expected exit 0, got $rc — output:"
  printf '%s\n' "$out" | sed 's/^/    /'
}

echo
echo "--json output — expect valid JSON:"

run_scanner "$MAL" --json
if command -v jq >/dev/null 2>&1; then
  printf '%s\n' "$out" | jq . >/dev/null 2>&1 \
    && ok "--json (malicious) is valid JSON (jq)" \
    || no "--json output is not valid JSON: $(printf '%s' "$out" | head -1)"
else
  printf '%s\n' "$out" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null \
    && ok "--json (malicious) is valid JSON (python3)" \
    || no "--json output is not valid JSON (python3 fallback)"
fi

run_scanner "$CLEAN" --json
[ "$rc" -eq 0 ] && ok "--json (clean) exits 0" || no "--json (clean) expected exit 0, got $rc"
if command -v jq >/dev/null 2>&1; then
  printf '%s\n' "$out" | jq . >/dev/null 2>&1 \
    && ok "--json (clean) is valid JSON (jq)" \
    || no "--json (clean) is not valid JSON"
else
  printf '%s\n' "$out" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null \
    && ok "--json (clean) is valid JSON (python3)" \
    || no "--json (clean) is not valid JSON (python3 fallback)"
fi

# ── 2. Baseline tests ───────────────────────────────────────────────────────
echo
echo "baseline — suppression and non-leakage:"
BASELINE_F="$FIXTURES/compass-core.baseline"
CORE="$ROOT/plugins/core"

if [ -d "$CORE" ]; then
  # (a) baseline suppresses the named finding; with only INFO remaining, exit flips to 0
  run_scanner "$CORE" --baseline "$BASELINE_F"
  [ "$rc" -eq 0 ] \
    && ok "baseline (a): plugins/core exits 0 after suppressing permission-escalation HIGH" \
    || { no "baseline (a): expected exit 0, got $rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
  printf '%s\n' "$out" | grep -qi 'sessionstart-hook' \
    && ok "baseline (a): SessionStart INFO remains visible" \
    || no "baseline (a): SessionStart INFO not visible in output"
  printf '%s\n' "$out" | grep -qi 'accepted.*baseline\|baseline.*accepted' \
    && ok "baseline (a): accepted finding shown in output" \
    || no "baseline (a): accepted finding not shown in output"

  # (b) baseline for SKILL.md/permission-escalation does NOT suppress unrelated findings
  run_scanner "$MAL" --baseline "$BASELINE_F"
  [ "$rc" -eq 1 ] \
    && ok "baseline (b): malicious-plugin still exits 1 (different paths/rules not suppressed)" \
    || no "baseline (b): expected exit 1, got $rc (baseline leaked to unrelated plugin)"
  printf '%s\n' "$out" | grep -qi 'hook-remote-exec' \
    && ok "baseline (b): hook-remote-exec finding still present (not suppressed)" \
    || no "baseline (b): hook-remote-exec should not be suppressed"
else
  ok "plugins/core not found — skipping baseline tests"
fi

# ── 3. Smoke test against the repo's own plugins/core ───────────────────────
echo
echo "smoke — plugins/core with compass-core.baseline (expect exit 0, INFO visible):"
if [ -d "$CORE" ]; then
  run_scanner "$CORE" --baseline "$BASELINE_F"
  # (c) the full scenario: baselined HIGH gone, INFO stays, exit 0
  [ "$rc" -eq 0 ] \
    && ok "smoke (c): plugins/core exits 0 with baseline applied" \
    || { no "smoke (c): expected exit 0, got $rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
  printf '%s\n' "$out" | grep -qi 'sessionstart-hook' \
    && ok "smoke (c): SessionStart INFO still visible (INFO does not drive exit)" \
    || no "smoke (c): SessionStart INFO not visible"
  printf '%s\n' "$out" | grep -qi 'permission-escalation.*baseline\|baseline.*permission-escalation\|accepted.*baseline' \
    && ok "smoke (c): permission-escalation shown as accepted (baseline)" \
    || no "smoke (c): permission-escalation baseline annotation not found"
  # raw output for the report
  printf '  raw output:\n'
  printf '%s\n' "$out" | sed 's/^/    /'
else
  ok "plugins/core not found — skipping smoke"
fi

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32m✓ all %d checks passed\033[0m\n' "$pass"
  exit 0
else
  printf '\033[31m✗ %d/%d checks failed\033[0m\n' "$fail" "$((pass + fail))"
  exit 1
fi
