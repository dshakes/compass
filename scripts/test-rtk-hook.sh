#!/usr/bin/env bash
# test-rtk-hook.sh — eval for the RTK command-rewrite hook (claude/hooks/rtk-rewrite.sh).
#
# RTK is an OPTIONAL, external token-optimizer: the hook rewrites Bash commands to cheaper
# equivalents when `rtk` is installed, and is a silent no-op otherwise. This test validates the
# hook's own logic deterministically — WITHOUT the real binary — by stubbing `rtk` on PATH:
#   • no `rtk` on PATH            → safe no-op (exit 0, no JSON emitted)
#   • rtk rewrites the command    → emits PreToolUse JSON with updatedInput.command = rewrite
#   • rtk returns it unchanged    → no-op (don't churn an identical command)
#   • empty command               → no-op
#   • it NEVER emits a "deny"      → the guardrail (protect-paths) owns deny; the rewriter only
#                                     allows/rewrites, and deny-precedence means it can't bypass it
#   • the shipped .sha256 matches the hook (tamper check)
#
# What it does NOT cover (needs a live session + the real binary, see docs/21-rtk.md): the actual
# Claude Code application of updatedInput, and rtk's real rewrites. Those are the operator's
# empirical validation step. Runs in CI. Mirrors the style of scripts/test-digest.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/claude/hooks/rtk-rewrite.sh"

pass=0; fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

INPUT='{"tool_name":"Bash","tool_input":{"command":"git status"}}'
run() { printf '%s' "$INPUT" | PATH="$1" bash "$HOOK" 2>/dev/null; }

if ! command -v jq >/dev/null 2>&1; then
  echo "jq not installed — skipping rtk-hook tests (hook + test both require jq)"; exit 0
fi

# Stub dir with a fake `rtk` we can reprogram per test, plus the real tools the hook needs.
STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"' EXIT
REALPATH_ENV="$PATH"
# rtk stub modes: REWRITE (prefix with 'rtk '), SAME (echo unchanged). Version always 0.23.0.
make_rtk() { # $1 = REWRITE|SAME
  cat > "$STUB/rtk" <<STUBEOF
#!/usr/bin/env bash
case "\$1" in
  --version) echo "rtk 0.23.0" ;;
  rewrite) shift; [ "$1" = REWRITE ] && echo "rtk \$1" || echo "\$1" ;;
  *) exit 0 ;;
esac
STUBEOF
  chmod +x "$STUB/rtk"
}

echo "safe no-op when rtk is absent:"
if command -v rtk >/dev/null 2>&1; then
  echo "  (rtk is installed on this machine — skipping the absent-path assertion)"
else
  out="$(run "$REALPATH_ENV")"; rc=$?
  { [ "$rc" = 0 ] && [ -z "$out" ]; } && ok "no rtk → exit 0, no JSON (silent no-op)" || no "rtk-absent should no-op (rc=$rc, out='$out')"
fi

echo "rewrite path (stubbed rtk that rewrites):"
make_rtk REWRITE
out="$(run "$STUB:$REALPATH_ENV")"; rc=$?
[ "$rc" = 0 ] && ok "exit 0 on rewrite" || no "rewrite should exit 0 (rc=$rc)"
if echo "$out" | jq -e '.hookSpecificOutput.permissionDecision=="allow"' >/dev/null 2>&1; then ok "emits permissionDecision allow"; else no "missing allow decision: $out"; fi
got="$(echo "$out" | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null)"
[ "$got" = "rtk git status" ] && ok "updatedInput.command = the rewrite" || no "updatedInput wrong: '$got'"
if echo "$out" | grep -q '"deny"'; then no "rewriter must NEVER emit deny"; else ok "never emits deny (guardrail owns deny)"; fi

echo "no-op when rtk returns the command unchanged:"
make_rtk SAME
out="$(run "$STUB:$REALPATH_ENV")"; rc=$?
{ [ "$rc" = 0 ] && [ -z "$out" ]; } && ok "unchanged command → no JSON churn" || no "should no-op on unchanged (rc=$rc, out='$out')"

echo "empty command → no-op:"
out="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":""}}' | PATH="$STUB:$REALPATH_ENV" bash "$HOOK" 2>/dev/null)"; rc=$?
{ [ "$rc" = 0 ] && [ -z "$out" ]; } && ok "empty command → exit 0, no JSON" || no "empty should no-op (rc=$rc)"

echo "tamper check: shipped sha256 matches the hook:"
if ( cd "$ROOT/claude/hooks" && shasum -a 256 -c .rtk-hook.sha256 >/dev/null 2>&1 ); then ok ".rtk-hook.sha256 matches rtk-rewrite.sh"; else no "sha256 mismatch — hook changed without updating .rtk-hook.sha256"; fi

echo
printf 'rtk-hook tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
