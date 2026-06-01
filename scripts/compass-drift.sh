#!/usr/bin/env bash
# compass-drift.sh — does the INSTALLED config still match the repo source?
#
# `doctor` checks that the install EXISTS; drift checks it's still FAITHFUL — a
# clobbered symlink, a stale/hand-edited copy, a dangling link, or a guardrail hook
# that lost its +x bit. The question every dotfile user eventually asks: "is what's
# running actually what I think it is?" — and a tamper check on the safety hooks.
#
#   compass drift            # human report; exit 0 clean, 1 if drifted
#   compass drift --json     # machine-readable findings
#
# Install dirs are overridable for testing: COMPASS_CLAUDE_DIR / COMPASS_CODEX_DIR.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="${COMPASS_CLAUDE_DIR:-$HOME/.claude}"
CODEX_DIR="${COMPASS_CODEX_DIR:-$HOME/.codex}"
JSON=0; [ "${1:-}" = "--json" ] && JSON=1

errors=0; warns=0; rows=""
emit() { rows="$rows$1|$2"$'\n'; }
ok()    { [ "$JSON" = 1 ] || printf '  \033[32m✓\033[0m %s\n' "$1"; emit ok "$1"; }
warn()  { warns=$((warns + 1));  [ "$JSON" = 1 ] || printf '  \033[33m!\033[0m %s\n' "$1"; emit warn "$1"; }
drift() { errors=$((errors + 1)); [ "$JSON" = 1 ] || printf '  \033[31m✗ DRIFT\033[0m %s\n' "$1"; emit drift "$1"; }

# Physical absolute path of an existing file or directory (bash 3.2 / macOS friendly).
abspath() {
  if [ -d "$1" ]; then ( cd "$1" 2>/dev/null && pwd -P )
  elif [ -e "$1" ]; then ( cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")" )
  fi
}

[ "$JSON" = 1 ] || printf '\033[1mInstall drift\033[0m  (source: %s)\n' "${REPO}"

# Each ~/.claude/<name> should mirror $REPO/claude/<name> — symlink to it (link mode)
# or a byte-identical copy (copy mode). Anything else is drift.
for n in settings.json CLAUDE.md statusline.sh agents commands skills workflows hooks output-styles; do
  t="$CLAUDE_DIR/$n"; src="$REPO/claude/$n"
  [ -e "$src" ] || continue   # source doesn't ship this entry → nothing to compare
  if [ -L "$t" ]; then
    tgt="$(readlink "$t")"
    case "$tgt" in /*) ;; *) tgt="$(cd "$(dirname "$t")" 2>/dev/null && cd "$(dirname "$tgt")" 2>/dev/null && pwd -P)/$(basename "$tgt")" ;; esac
    if [ ! -e "$t" ]; then drift "$n: dangling symlink -> $tgt"; continue; fi
    if [ "$(abspath "$tgt")" = "$(abspath "$src")" ]; then ok "$n: linked to source"
    else warn "$n: linked to a DIFFERENT source ($tgt) — not this repo"; fi
  elif [ -e "$t" ]; then
    if diff -r -q "$src" "$t" >/dev/null 2>&1; then ok "$n: copy in sync"
    else drift "$n: differs from source (hand-edited or stale) — re-run 'make install'"; fi
  else
    drift "$n: not installed (run 'make install')"
  fi
done

# Safety hooks must stay executable — a non-+x guardrail silently fails open.
hd="$CLAUDE_DIR/hooks"
if [ -d "$hd" ]; then
  for h in "$hd"/*.sh; do
    [ -e "$h" ] || continue
    [ -x "$h" ] || drift "hook not executable: hooks/$(basename "$h") (guardrail would not run)"
  done
fi

# The compass CLI on PATH (optional — informational only).
cli="$HOME/.local/bin/compass"
if [ -L "$cli" ] && [ -e "$cli" ]; then ok "CLI: ~/.local/bin/compass -> $(readlink "$cli")"
elif [ -e "$cli" ]; then warn "CLI: ~/.local/bin/compass exists but isn't our symlink"
fi

# Codex (light): AGENTS.md should resolve if Codex is wired.
if [ -e "$CODEX_DIR/AGENTS.md" ] || [ -L "$CODEX_DIR/AGENTS.md" ]; then
  if [ -e "$CODEX_DIR/AGENTS.md" ]; then ok "codex: AGENTS.md present"
  else drift "codex: AGENTS.md is a dangling symlink"; fi
fi

if [ "$JSON" = 1 ]; then
  printf '{"errors":%d,"warnings":%d,"findings":[' "$errors" "$warns"
  first=1
  while IFS='|' read -r kind msg; do
    [ -n "$kind" ] || continue
    [ "$first" = 1 ] || printf ','; first=0
    printf '{"level":"%s","message":%s}' "$kind" "$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g; s/.*/"&"/')"
  done <<EOF
$rows
EOF
  printf ']}\n'
fi

[ "$JSON" = 1 ] || {
  echo
  if [ "$errors" -eq 0 ]; then printf '\033[32mNo drift\033[0m — install matches source (%d warning(s)).\n' "$warns"
  else printf '\033[31m%d drift finding(s)\033[0m, %d warning(s) — re-run the installer to repair.\n' "$errors" "$warns"; fi
}
[ "$errors" -eq 0 ]
