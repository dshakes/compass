#!/usr/bin/env bash
# check-mcp.sh — supply-chain audit for the MCP manifest (mcp/servers.json).
#
# The manifest is executed as commands inside TWO tools (Claude Code + Codex), so it
# is a trust boundary. This gate refuses to ship a manifest that is unpinned or tampered:
#
#   1. PINNING   — every auto-registered, executable server (npx/uvx/pip/…) must declare
#                  a `pin` (version) and carry it in `args`. No `@latest`, no bare floating
#                  spec. A compromised upstream release (tool-poisoning, CVE-2025-54136) is
#                  then not auto-pulled on the next launch.
#   2. INTEGRITY — no shell-injection markers ($( … ), backticks, `| sh`, `; curl …`) in any
#                  command/args/description/note/setup field (manifest-tamper defense).
#   3. TRANSPORT — http/sse servers must be https.
#
# Exit 0 = clean, 1 = finding(s). Runs from setup-mcp.sh (pre-flight), doctor, and CI.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${1:-$REPO/mcp/servers.json}"
command -v jq >/dev/null || { echo "check-mcp: jq required" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "check-mcp: no manifest at $MANIFEST" >&2; exit 1; }

errors=0
err()  { printf '  \033[31m✗\033[0m %s\n' "$1"; errors=$((errors + 1)); }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }

# Commands whose package args resolve a version at run time (so they must be pinned).
is_pkg_runner() { case "$1" in npx|uvx|npm|pnpm|yarn|pip|pip3|pipx) return 0 ;; *) return 1 ;; esac; }

printf '\033[1mMCP manifest audit\033[0m  (%s)\n' "${MANIFEST#"$REPO"/}"

names="$(jq -r '.servers | keys[]' "$MANIFEST")"
for name in $names; do
  auto="$(jq -r ".servers[\"$name\"].autoRegister // false" "$MANIFEST")"
  cmd="$(jq -r ".servers[\"$name\"].command // empty" "$MANIFEST")"
  pin="$(jq -r ".servers[\"$name\"].pin // empty" "$MANIFEST")"
  argsj="$(jq -r ".servers[\"$name\"].args // [] | join(\" \")" "$MANIFEST")"
  url="$(jq -r ".servers[\"$name\"].url // empty" "$MANIFEST")"

  # 2 · INTEGRITY — scan every stringy field for shell-injection markers.
  blob="$(jq -r ".servers[\"$name\"] | [ .command, (.args // [] | join(\" \")), .description, .note, .setup ] | map(select(. != null)) | join(\"\n\")" "$MANIFEST")"
  if printf '%s' "$blob" | grep -Eq '\$\(|`|\|[[:space:]]*(sudo[[:space:]]+)?[a-z]*sh([[:space:]]|$)|;[[:space:]]*(curl|wget|rm|sh|bash|eval)|&&[[:space:]]*(curl|wget)'; then
    err "$name: shell-injection marker in a manifest field"
  fi

  # 3 · TRANSPORT — remote servers must be https.
  case "$url" in http://*) err "$name: remote URL is http (must be https): $url" ;; esac

  # 1 · PINNING — executable package runners.
  if is_pkg_runner "$cmd"; then
    case "$argsj" in *@latest*) err "$name: uses '@latest' (floating) — pin an explicit version" ;; esac
    if [ "$auto" = true ]; then
      if [ -z "$pin" ]; then
        err "$name: auto-registered but no 'pin' (version) declared"
      else
        case "$argsj" in *"$pin"*) ok "$name: pinned @ $pin" ;; *) err "$name: declared pin '$pin' is not present in args" ;; esac
      fi
    elif [ -n "$pin" ]; then
      case "$argsj" in *"$pin"*) ok "$name: pinned @ $pin (opt-in)" ;; *) err "$name: declared pin '$pin' is not present in args" ;; esac
    else
      ok "$name: opt-in, no pin declared"
    fi
  else
    ok "$name: $cmd (local/remote — no package pin needed)"
  fi
done

echo
if [ "$errors" -eq 0 ]; then
  printf '\033[32mMCP manifest clean\033[0m — all executable servers pinned, no injection markers.\n'
  exit 0
fi
printf '\033[31mMCP manifest: %d finding(s).\033[0m\n' "$errors"
exit 1
