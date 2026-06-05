#!/usr/bin/env bash
# doctor.sh — validate the config repo and the installed result.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ok=0; warn=0; err=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; ok=$((ok+1)); }
note() { printf '  \033[33m!\033[0m %s\n' "$*"; warn=$((warn+1)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; err=$((err+1)); }

echo "Validating $REPO"

# JSON
if command -v jq >/dev/null 2>&1; then
  for f in "$REPO"/claude/settings.json \
           "$REPO"/.claude-plugin/marketplace.json \
           "$REPO"/plugins/core/.claude-plugin/plugin.json \
           "$REPO"/plugins/core/hooks/hooks.json \
           "$REPO"/plugins/core/.mcp.json \
           "$REPO"/plugins/core-lsp/.claude-plugin/plugin.json \
           "$REPO"/plugins/core-lsp/.lsp.json \
           "$REPO"/mcp/servers.json; do
    [ -e "$f" ] || continue
    jq empty "$f" 2>/dev/null && pass "valid JSON: ${f#$REPO/}" || fail "invalid JSON: ${f#$REPO/}"
  done
else note "jq not installed — skipping JSON validation"; fi

# Plugin freshness (must mirror claude/ source)
if "$REPO"/scripts/sync-plugin.sh --check >/dev/null 2>&1; then pass "plugin in sync with claude/"
else note "plugin out of date — run: make sync-plugin"; fi

# Hook + script executability and shellcheck
while IFS= read -r s; do
  [ -x "$s" ] && pass "executable: ${s#$REPO/}" || note "not +x (installer will fix): ${s#$REPO/}"
done < <(find "$REPO/claude/hooks" "$REPO/scripts" "$REPO/sdlc" "$REPO/claude/statusline.sh" "$REPO"/claude/skills -name '*.sh' 2>/dev/null)
[ -x "$REPO/bin/compass" ] && pass "executable: bin/compass" || note "not +x (installer will fix): bin/compass"

if command -v shellcheck >/dev/null 2>&1; then
  if find "$REPO/claude/hooks" -name '*.sh' -exec shellcheck -S warning {} + >/dev/null 2>&1; then
    pass "shellcheck clean (hooks)"
  else note "shellcheck reported issues — run: shellcheck claude/hooks/*.sh"; fi
else note "shellcheck not installed — skipping lint"; fi

# Frontmatter sanity for agents/commands/skills
for d in agents commands; do
  for f in "$REPO"/claude/$d/*.md; do
    [ -e "$f" ] || continue
    head -1 "$f" | grep -q '^---' && pass "frontmatter: ${f#$REPO/}" || fail "missing frontmatter: ${f#$REPO/}"
  done
done
[ -f "$REPO"/claude/skills/bootstrap-agent-config/SKILL.md ] && pass "skill present: bootstrap-agent-config"

# Dynamic-workflow scripts (research preview): validate shape + JS syntax.
if [ -d "$REPO"/claude/workflows ]; then
  if "$REPO"/scripts/check-workflows.sh >/dev/null 2>&1; then pass "workflow scripts valid (claude/workflows)"
  else fail "workflow scripts invalid — run: scripts/check-workflows.sh"; fi
fi

# GitHub Actions: mirror drift + least-privilege + SHA-pinning + run-block injection.
if "$REPO"/scripts/check-actions.sh >/dev/null 2>&1; then pass "actions audit clean (drift · permissions · pinning · injection)"
else fail "actions audit failed — run: scripts/check-actions.sh"; fi

# MCP supply chain: every executable server pinned, no injection markers in the manifest.
if "$REPO"/scripts/check-mcp.sh >/dev/null 2>&1; then pass "MCP manifest clean (version-pinned · no injection markers)"
else fail "MCP manifest audit failed — run: scripts/check-mcp.sh"; fi

# Guardrail policy: the bypass corpus must pass (the safety-critical eval).
if "$REPO"/scripts/test-protect-paths.sh >/dev/null 2>&1; then pass "guardrail bypass corpus passes (protect-paths policy)"
else fail "guardrail corpus failed — run: scripts/test-protect-paths.sh"; fi

# Red-team policy: the prompt-injection / config-override / malware / insecure-code eval.
if "$REPO"/scripts/test-redteam.sh >/dev/null 2>&1; then pass "red-team corpus passes (injection · override · malware · insecure-code)"
else fail "red-team corpus failed — run: scripts/test-redteam.sh"; fi

# Router module: spec schema + ReDoS lint must pass (the routing config is a copied asset).
if [ -f "$REPO"/router/validate.sh ]; then
  if "$REPO"/router/validate.sh >/dev/null 2>&1; then pass "router spec valid (schema + ReDoS lint)"
  else fail "router spec invalid — run: router/validate.sh"; fi
fi

# Fleet / mobile: notify smoke + the listener's command parser.
if printf '%s' "$(COMPASS_NOTIFY_SLACK='https://hooks.test/x' "$REPO"/scripts/compass-notify.sh --dry-run 'doctor smoke' 2>&1)" | grep -q 'slack: POST'; then
  pass "compass notify dry-run works (channel-agnostic)"
else fail "compass notify smoke failed"; fi
if command -v node >/dev/null 2>&1; then
  if node --check "$REPO"/scripts/compass-listen.mjs 2>/dev/null && node "$REPO"/scripts/test-listen.mjs >/dev/null 2>&1; then
    pass "compass listen valid + command parser passes"
  else fail "compass listen invalid or parser test failed"; fi
else note "node not installed — skipping listener checks"; fi

# Installed symlinks
echo "Installed state (~/.claude):"
for n in settings.json CLAUDE.md statusline.sh agents commands skills workflows hooks output-styles; do
  t="$HOME/.claude/$n"
  if [ -L "$t" ]; then pass "linked: ~/.claude/$n -> $(readlink "$t")"
  elif [ -e "$t" ]; then note "exists but not our symlink: ~/.claude/$n"
  else note "not installed: ~/.claude/$n (run make install)"; fi
done
if command -v compass >/dev/null 2>&1; then pass "compass CLI on PATH: $(command -v compass)"
elif [ -L "$HOME/.local/bin/compass" ]; then note "compass CLI installed but ~/.local/bin not on PATH — add it or open a new shell"
else note "compass CLI not on PATH (run make install, then open a new shell)"; fi

echo
printf 'Result: \033[32m%d ok\033[0m, \033[33m%d warn\033[0m, \033[31m%d error\033[0m\n' "$ok" "$warn" "$err"
[ "$err" -eq 0 ]
