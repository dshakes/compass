#!/usr/bin/env bash
# check-vendor.sh — keep the cross-vendor packaging honest and wired to ONE source.
# Validates gemini-extension.json against the real compass sources (no mocks):
#   • valid JSON, name "compass"
#   • version == the plugin manifest version (plugins/core)
#   • contextFileName GEMINI.md, present, and resolving to the operating manual
#   • mcpServers == exactly the auto-registered stdio servers in mcp/servers.json,
#     with identical command + args (the real pinned servers, not a copy that can drift)
# Runs in CI via doctor. Exit 0 = clean, 1 = drift/invalid.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT="$ROOT/gemini-extension.json"
SRV="$ROOT/mcp/servers.json"
PLUGIN="$ROOT/plugins/core/.claude-plugin/plugin.json"
fail=0
no() { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }
ok() { printf '  \033[32mok\033[0m %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "check-vendor: jq required"; exit 0; }
[ -f "$EXT" ] || { no "missing gemini-extension.json"; exit 1; }
jq empty "$EXT" 2>/dev/null && ok "gemini-extension.json is valid JSON" || no "gemini-extension.json invalid JSON"

[ "$(jq -r '.name' "$EXT")" = "compass" ] && ok "name = compass" || no "name must be 'compass'"

vext="$(jq -r '.version' "$EXT")"; vplug="$(jq -r '.version' "$PLUGIN")"
[ "$vext" = "$vplug" ] && ok "version $vext matches plugin manifest" || no "version drift: ext=$vext plugin=$vplug"

cf="$(jq -r '.contextFileName' "$EXT")"
if [ "$cf" = "GEMINI.md" ] && [ -e "$ROOT/GEMINI.md" ]; then
  tgt="$(readlink "$ROOT/GEMINI.md" 2>/dev/null || echo)"
  if [ "$tgt" = "claude/CLAUDE.md" ] || diff -q "$ROOT/GEMINI.md" "$ROOT/claude/CLAUDE.md" >/dev/null 2>&1; then
    ok "contextFileName GEMINI.md resolves to the operating manual"
  else no "GEMINI.md does not match the operating manual (claude/CLAUDE.md)"; fi
else no "contextFileName must be GEMINI.md and the file must exist"; fi

# mcpServers must equal the auto-registered stdio servers, byte-for-byte on command+args.
want="$(jq -r '[.servers|to_entries[]|select(.value.autoRegister==true and .value.type=="stdio")|.key]|sort|join(",")' "$SRV")"
have="$(jq -r '[.mcpServers|keys[]]|sort|join(",")' "$EXT")"
if [ "$want" = "$have" ]; then ok "mcpServers = auto-registered stdio servers ($have)"
else no "mcpServers drift: extension=[$have] vs servers.json auto-reg stdio=[$want]"; fi

IFS=','; for k in $want; do
  [ -n "$k" ] || continue
  a="$(jq -Sc --arg k "$k" '.mcpServers[$k]|{command,args}' "$EXT" 2>/dev/null)"
  b="$(jq -Sc --arg k "$k" '.servers[$k]|{command,args}' "$SRV" 2>/dev/null)"
  [ "$a" = "$b" ] && ok "mcp '$k' command+args match servers.json" || no "mcp '$k' drift: ext=$a src=$b"
done; unset IFS

# ── Codex plugin + marketplace (mirrors the Claude plugin; same single source) ──
CXP="$ROOT/plugins/core/.codex-plugin/plugin.json"
MKT="$ROOT/.agents/plugins/marketplace.json"
if [ -f "$CXP" ]; then
  jq empty "$CXP" 2>/dev/null && ok "codex plugin.json is valid JSON" || no "codex plugin.json invalid JSON"
  [ "$(jq -r '.name' "$CXP")" = "core" ] && ok "codex plugin name = core" || no "codex plugin name must be 'core'"
  [ "$(jq -r '.version' "$CXP")" = "$vplug" ] && ok "codex plugin version matches ($vplug)" || no "codex plugin version drift"
  # component pointers must resolve inside the plugin dir
  for ptr in skills mcpServers hooks; do
    p="$(jq -r --arg k "$ptr" '.[$k] // empty' "$CXP")"
    [ -n "$p" ] || continue
    [ -e "$ROOT/plugins/core/${p#./}" ] && ok "codex pointer $ptr → $p resolves" || no "codex pointer $ptr → $p missing"
  done
else no "missing plugins/core/.codex-plugin/plugin.json"; fi

if [ -f "$MKT" ]; then
  jq empty "$MKT" 2>/dev/null && ok "codex marketplace.json is valid JSON" || no "codex marketplace.json invalid JSON"
  [ "$(jq -r '.plugins[0].name' "$MKT")" = "core" ] && ok "marketplace lists core" || no "marketplace must list plugin 'core'"
  sp="$(jq -r '.plugins[0].source.path' "$MKT")"
  if [ "$sp" = "./plugins/core" ] && [ -d "$ROOT/plugins/core" ]; then ok "marketplace source.path → ./plugins/core resolves"
  else no "marketplace source.path must be ./plugins/core and exist"; fi
else no "missing .agents/plugins/marketplace.json"; fi

[ "$fail" -eq 0 ]
