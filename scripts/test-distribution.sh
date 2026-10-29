#!/usr/bin/env bash
# test-distribution.sh — install record · repair · record-driven uninstall · verified remote
# install · standalone budget cap. Fake HOME, local fixture tarball, stubbed verifier: no network.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d"; fi; }

command -v jq >/dev/null 2>&1 || { echo "test-distribution: jq required" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
unset COMPASS_HOME COMPASS_REPO_ROOT
REC="$HOME/.compass/install.json"

echo "install record"
"$REPO/install.sh" --claude-only >/dev/null 2>&1
chk "record written" test -f "$REC"
chk "record has version + mode + paths" jq -e '.version != "" and .mode == "symlink" and (.paths | length) > 5' "$REC"
chk "record lists ~/.claude/hooks symlink" jq -e --arg p "$HOME/.claude/hooks" '.paths[] | select(.path == $p and .type == "symlink")' "$REC"
n1="$(jq '.paths | length' "$REC")"
"$REPO/install.sh" --claude-only >/dev/null 2>&1
chk "re-install is idempotent (same path count)" test "$(jq '.paths | length' "$REC")" = "$n1"

echo "repair"
rm "$HOME/.claude/hooks" "$HOME/.claude/skills"; ln -s "$T/nowhere" "$HOME/.claude/skills"      # missing + dangling
rm "$HOME/.claude/agents"; mkdir "$HOME/.claude/agents"                  # user's own dir now
out="$("$REPO/scripts/compass-repair.sh" --dry-run 2>&1)"
echo "$out" | grep -q 'hooks (missing)' && ok "dry-run reports missing link" || no "dry-run reports missing link"
test ! -e "$HOME/.claude/hooks" && ok "dry-run changes nothing" || no "dry-run changes nothing"
out="$("$REPO/scripts/compass-repair.sh" 2>&1)"; rc=$?
test -L "$HOME/.claude/hooks" && test -e "$HOME/.claude/skills" && ok "repair re-creates missing + dangling links" || no "repair re-creates missing + dangling links"
test -d "$HOME/.claude/agents" && test ! -L "$HOME/.claude/agents" && ok "repair leaves a user-replaced path alone" || no "repair leaves a user-replaced path alone"
test "$rc" -ne 0 && ok "repair exits non-zero while something needs attention" || no "repair exit code"
rmdir "$HOME/.claude/agents"; ln -s "$REPO/claude/agents" "$HOME/.claude/agents"

echo "uninstall from record"
echo mine >"$HOME/.claude/my-notes.txt"
rm "$HOME/.claude/commands"; mkdir "$HOME/.claude/commands"; echo mine >"$HOME/.claude/commands/x.md"
"$REPO/scripts/uninstall.sh" --dry-run >/dev/null 2>&1
test -L "$HOME/.claude/hooks" && test -f "$REC" && ok "uninstall --dry-run changes nothing" || no "uninstall --dry-run changes nothing"
"$REPO/scripts/uninstall.sh" >/dev/null 2>&1
test ! -e "$HOME/.claude/hooks" && test ! -e "$HOME/.local/bin/compass" && ok "recorded links removed" || no "recorded links removed"
test -f "$HOME/.claude/my-notes.txt" && test -f "$HOME/.claude/commands/x.md" && ok "user files + replaced dirs untouched" || no "user files + replaced dirs untouched"
test ! -e "$REC" && ok "record removed" || no "record removed"
chmod -R u+w "$HOME" 2>/dev/null; rm -rf "$HOME/.claude" "$HOME/.local" "$HOME/.compass"

echo "uninstall: copy mode backs up edited copies"
"$REPO/install.sh" --claude-only --copy --no-cli >/dev/null 2>&1
echo "# mine" >>"$HOME/.claude/CLAUDE.md"
"$REPO/scripts/uninstall.sh" >/dev/null 2>&1
test ! -e "$HOME/.claude/CLAUDE.md" && ok "copy removed" || no "copy removed"
grep -rq '^# mine' "$HOME/.claude/backups"/compass-uninstall-*/CLAUDE.md 2>/dev/null && ok "edited copy backed up first" || no "edited copy backed up first"
chmod -R u+w "$HOME" 2>/dev/null; rm -rf "$HOME/.claude" "$HOME/.compass"

echo "uninstall: no record → legacy fallback"
mkdir -p "$HOME/.claude"; ln -s "$REPO/claude/hooks" "$HOME/.claude/hooks"
"$REPO/scripts/uninstall.sh" >/dev/null 2>&1
test ! -e "$HOME/.claude/hooks" && ok "legacy removal still works" || no "legacy removal still works"

echo "remote install: verify gate"
F="$T/fx/compass-v9.9.9"; mkdir -p "$F"
printf '#!/usr/bin/env bash\ntouch "$HOME/ran-install"\n' >"$F/install.sh"
tar -czf "$T/fx.tar.gz" -C "$T/fx" compass-v9.9.9
printf '#!/bin/sh\nexit 0\n' >"$T/pass"; printf '#!/bin/sh\nexit 1\n' >"$T/bad"; chmod +x "$T/pass" "$T/bad"
mkdir "$T/bin"; printf '#!/bin/sh\nexit 1\n' >"$T/bin/gh"; chmod +x "$T/bin/gh"   # gh present but no attestation
cd "$T" || exit 1
R="$REPO/install-remote.sh"
COMPASS_TARBALL="$T/fx.tar.gz" COMPASS_VERIFIER="$T/bad" bash "$R" >/dev/null 2>&1; rc=$?
test "$rc" -ne 0 && test ! -e "$HOME/ran-install" && test ! -e "$HOME/.compass/src" && ok "failed verification → nothing extracted or run" || no "failed verification → nothing extracted or run"
out="$(PATH="$T/bin:$PATH" COMPASS_TARBALL="$T/fx.tar.gz" bash "$R" 2>&1)"; rc=$?
test "$rc" -ne 0 && test ! -e "$HOME/ran-install" && echo "$out" | grep -q 'gh attestation verify' && ok "no verifier → fail closed, prints manual command" || no "no verifier → fail closed, prints manual command"
COMPASS_TARBALL="$T/fx.tar.gz" COMPASS_VERIFIER="$T/pass" bash "$R" >/dev/null 2>&1
test -f "$HOME/ran-install" && test -f "$HOME/.compass/src/install.sh" && ok "verified → unpacked to ~/.compass/src and install.sh ran" || no "verified → unpacked and ran"
rm -rf "$HOME/ran-install" "$HOME/.compass"
PATH="$T/bin:$PATH" COMPASS_TARBALL="$T/fx.tar.gz" bash "$R" --no-verify >/dev/null 2>&1
test -f "$HOME/ran-install" && ok "--no-verify proceeds without a verifier" || no "--no-verify proceeds"
bash -n "$R" && ok "install-remote.sh parses" || no "install-remote.sh parses"
cd "$REPO" || exit 1
rm -rf "$HOME/.compass"

echo "standalone budget cap (--only budget)"
"$REPO/install.sh" --only budget >/dev/null 2>&1
G="$HOME/.compass/budget/budget-gate.sh"
chk "gate installed, nothing in ~/.claude" test -x "$G" -a ! -e "$HOME/.claude/settings.json"
chk "record lists the gate" jq -e '.paths[] | select(.path | endswith("budget/budget-gate.sh"))' "$REC"
mkdir -p "$HOME/.compass/sessions"; echo 9 >"$HOME/.compass/sessions/s1.cost"
in='{"session_id":"s1","tool_name":"Bash"}'
printf '%s' "$in" | COMPASS_MAX_USD=5 "$G" >/dev/null 2>&1; rc=$?
test "$rc" = 2 && ok "over the cap → blocked (exit 2)" || no "over the cap → blocked (got $rc)"
printf '%s' "$in" | COMPASS_MAX_USD=50 "$G" >/dev/null 2>&1; rc=$?
test "$rc" = 0 && ok "under the cap → allowed" || no "under the cap → allowed (got $rc)"

echo "marketplace manifests"
if command -v claude >/dev/null 2>&1 && claude plugin validate --help >/dev/null 2>&1; then
  chk "claude plugin validate plugins/core" claude plugin validate "$REPO/plugins/core"
else echo "  skip claude plugin validate (CLI unavailable)"; fi
chk "marketplace plugin names match plugin.json" test "$(jq -r '.plugins[0].name' "$REPO/.claude-plugin/marketplace.json")" = "$(jq -r .name "$REPO/plugins/core/.claude-plugin/plugin.json")"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
