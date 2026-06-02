#!/usr/bin/env bash
# setup-mcp.sh — register the curated MCP servers in BOTH Claude Code and Codex
# from one manifest (mcp/servers.json). Idempotent, conflict-aware, secret-free.
#
#   ./scripts/setup-mcp.sh            # register autoRegister servers in both tools
#   ./scripts/setup-mcp.sh --dry-run  # show what would happen
#
# - Claude: `claude mcp add-json <name> '<json>' --scope user` (skips if present).
# - Codex:  appends [mcp_servers.<name>] to ~/.codex/config.toml under a marker
#           (skips if the block already exists, and skips any server whose name
#           collides with an existing Codex plugin).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO/mcp/servers.json"
CODEX="$HOME/.codex/config.toml"
MARK="# >>> compass mcp >>>"
MARK_END="# <<< compass mcp <<<"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

command -v jq >/dev/null || { echo "jq required for setup-mcp.sh" >&2; exit 1; }
say() { printf '  %s\n' "$*"; }

# Supply-chain pre-flight: never register an unpinned or tampered manifest.
if [ -x "$REPO/scripts/check-mcp.sh" ]; then
  "$REPO/scripts/check-mcp.sh" "$MANIFEST" \
    || { echo "setup-mcp: manifest failed the supply-chain audit (above) — refusing to register." >&2; exit 1; }
  echo
fi

# Existing Codex plugin keywords, to avoid duplicating (e.g. "github").
codex_plugins=""
[ -f "$CODEX" ] && codex_plugins="$(grep -oE '\[plugins\."[a-z0-9-]+' "$CODEX" 2>/dev/null | sed 's/.*"//' | tr '\n' ' ')"

printf '\033[1mMCP setup from %s\033[0m\n' "${MANIFEST#$REPO/}"
[ -n "$codex_plugins" ] && say "existing Codex plugins (will not duplicate): $codex_plugins"

names="$(jq -r '.servers | to_entries[] | select(.value.autoRegister==true) | .key' "$MANIFEST")"

# ---- Claude ----
printf '\n\033[1mClaude Code\033[0m\n'
for name in $names; do
  if jq -e ".servers[\"$name\"].claude==true" "$MANIFEST" >/dev/null; then
    if claude mcp get "$name" >/dev/null 2>&1; then say "already registered: $name"; continue; fi
    cfg="$(jq -c ".servers[\"$name\"] | {type, command, args, env}" "$MANIFEST")"
    _tmp="$(mktemp)"
    printf '%s' "$cfg" >"$_tmp"
    if [ "$DRY" = 1 ]; then
      echo "  [dry-run] claude mcp add-json '$name' <cfg> --scope user"
      rm -f "$_tmp"
    else
      claude mcp add-json "$name" "$(cat "$_tmp")" --scope user
      rm -f "$_tmp"
      say "registered: $name"
    fi
  fi
done

# ---- Codex ----
printf '\n\033[1mCodex\033[0m\n'
if [ -f "$CODEX" ] && grep -qF "$MARK" "$CODEX"; then
  say "MCP block already present in ~/.codex/config.toml (skipping)"
else
  block="$MARK"$'\n'"# MCP servers — parity with Claude. Managed by compass."$'\n'
  added=0
  for name in $names; do
    jq -e ".servers[\"$name\"].codex==true" "$MANIFEST" >/dev/null || continue
    case " $codex_plugins " in *" $name "*) say "skip $name (Codex plugin exists)"; continue;; esac
    cmd="$(jq -r ".servers[\"$name\"].command" "$MANIFEST")"
    args="$(jq -r ".servers[\"$name\"].args | map(\"\\\"\"+.+\"\\\"\") | join(\", \")" "$MANIFEST")"
    block+="[mcp_servers.$name]"$'\n'"command = \"$cmd\""$'\n'"args = [$args]"$'\n'$'\n'
    added=$((added+1)); say "queued: $name"
  done
  block+="$MARK_END"$'\n'
  if [ "$added" -gt 0 ]; then
    if [ "$DRY" = 1 ]; then echo "  [dry-run] append $added server(s) to $CODEX"; else mkdir -p "$(dirname "$CODEX")"; printf '\n%s\n' "$block" >>"$CODEX"; say "appended $added server(s) to ~/.codex/config.toml"; fi
  fi
fi

printf '\n\033[1mDone.\033[0m Verify with:  claude mcp list\n'
say "Opt-in servers (github, postgres) — see docs/04-mcp.md for exact commands."
