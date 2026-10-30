#!/usr/bin/env bash
# sync-plugin.sh — regenerate the self-contained plugin from the canonical claude/ source.
#
# The plugin must ship REAL files (cross-repo symlinks aren't reliably followed by
# the plugin loader), so we copy from claude/ into plugins/core/.
# Authored, plugin-only files (hooks/hooks.json, .mcp.json, .claude-plugin/) are
# preserved. Run via `make sync-plugin`. `--check` exits non-zero if out of date.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/claude"
DST="$REPO/plugins/core"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1

# Gitignored paths under claude/$1 (e.g. skills/synced/, machine-local skill caches),
# relative to claude/. They are never part of the plugin: copying them would ship
# local-only content, and diffing them reports drift that is not in git.
ignored_under() {
  git -C "$REPO" ls-files --others --ignored --exclude-standard --directory -- "claude/$1" 2>/dev/null \
    | sed 's#^claude/##; s#/$##'
}

sync_one() { # copy SRC/$1 -> DST/$1 (full replace)
  local rel="$1" ign p
  ign="$(ignored_under "$rel")"
  if [ "$CHECK" = 1 ]; then
    # diff -rq on directories also reports files present in only one side, so a
    # deleted/added agent/command/skill is caught here.
    local d; d="$(diff -rq "$SRC/$rel" "$DST/$rel" 2>&1)" || true
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      d="$(printf '%s\n' "$d" | grep -vF -e "$SRC/$p" -e "Only in $SRC/$(dirname "$p"): $(basename "$p")" || true)"
    done <<EOF
$ign
EOF
    [ -z "$d" ] || { echo "out-of-date: plugins/core/$rel"; return 1; }
  else
    rm -rf "$DST/$rel"; cp -R "$SRC/$rel" "$DST/$rel"
    while IFS= read -r p; do if [ -n "$p" ]; then rm -rf "${DST:?}/$p"; fi; done <<EOF
$ign
EOF
    echo "synced: $rel"
  fi
}

rc=0
for d in agents commands skills output-styles; do sync_one "$d" || rc=1; done

# Hooks: copy scripts + lib, but never touch the authored hooks.json.
if [ "$CHECK" = 1 ]; then
  # forward: every source hook must match the plugin copy
  for f in "$SRC"/hooks/*.sh "$SRC"/hooks/lib/*.sh "$SRC"/hooks/profiles/*.conf; do
    rel="hooks/${f#"$SRC"/hooks/}"
    diff -q "$f" "$DST/$rel" >/dev/null 2>&1 || { echo "out-of-date: plugins/core/$rel"; rc=1; }
  done
  # reverse: a hook DELETED from source must not linger in the plugin (else --check
  # reports "in sync" while the plugin ships a stale script). hooks.json is authored — skip it.
  for f in "$DST"/hooks/*.sh "$DST"/hooks/lib/*.sh "$DST"/hooks/profiles/*.conf; do
    [ -e "$f" ] || continue
    rel="hooks/${f#"$DST"/hooks/}"
    [ -e "$SRC/$rel" ] || { echo "stale (deleted from source): plugins/core/$rel"; rc=1; }
  done
else
  mkdir -p "$DST/hooks/lib" "$DST/hooks/profiles"
  cp "$SRC"/hooks/*.sh "$DST/hooks/"
  cp "$SRC"/hooks/lib/*.sh "$DST/hooks/lib/"
  cp "$SRC"/hooks/profiles/*.conf "$DST/hooks/profiles/"   # profile data the hooks resolve
  chmod +x "$DST"/hooks/*.sh "$DST"/hooks/lib/*.sh "$DST"/skills/*/*.sh 2>/dev/null || true
  echo "synced: hooks scripts (+lib), preserved hooks.json"
fi

[ "$CHECK" = 1 ] && { [ "$rc" = 0 ] && echo "plugin is in sync with claude/"; exit "$rc"; }
echo "Plugin regenerated at plugins/core/"
