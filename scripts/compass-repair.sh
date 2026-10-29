#!/usr/bin/env bash
# compass-repair.sh — re-create what the install record says should exist but doesn't.
#
#   compass repair             # fix missing/dangling symlinks + missing copies, then re-check
#   compass repair --dry-run   # report what it would fix, change nothing
#
# Works from ${COMPASS_HOME:-~/.compass}/install.json (written by install.sh). It only restores
# entries compass itself recorded, never touches a path that now holds something else (a symlink
# pointing elsewhere, or a real file the user put there) — it names those instead. Detection of
# the "is it still faithful" kind stays in `compass drift`, which runs at the end.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REC="${COMPASS_HOME:-$HOME/.compass}/install.json"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

command -v jq >/dev/null 2>&1 || { echo "compass repair: jq required" >&2; exit 1; }
[ -f "$REC" ] || { echo "compass repair: no install record at $REC — run ./install.sh (or compass quickstart) first" >&2; exit 1; }

fixed=0; left=0
do_() { if [ "$DRY" = 1 ]; then echo "  [dry-run] $*"; else echo "  fixed: $*"; fi; }
repo="$(jq -r .repo "$REC")"

while IFS=$'\t' read -r type path src; do
  case "$type" in symlink|copy) ;; *) continue ;; esac
  # Rendered settings live in the repo and are gitignored — regenerate if gone.
  if [ ! -e "$src" ] && [ "$(basename "$src")" = settings.merged.json ] && [ "$DRY" = 0 ]; then
    COMPASS_REPO_ROOT="$repo" "$HERE/compass-profile.sh" --settings-file >/dev/null 2>&1 || true
  fi
  [ -e "$src" ] || { echo "  cannot fix ${path#"$HOME"/}: source missing ($src)"; left=$((left+1)); continue; }
  if [ -L "$path" ] && [ ! -e "$path" ]; then            # dangling
    do_ "${path#"$HOME"/} (dangling)"
    [ "$DRY" = 1 ] || { rm -f "$path"; ln -s "$src" "$path"; }; fixed=$((fixed+1))
  elif [ ! -e "$path" ] && [ ! -L "$path" ]; then         # gone
    do_ "${path#"$HOME"/} (missing)"
    if [ "$DRY" = 0 ]; then
      mkdir -p "$(dirname "$path")"
      if [ "$type" = symlink ]; then ln -s "$src" "$path"; else cp -R "$src" "$path"; fi
    fi
    fixed=$((fixed+1))
  elif [ "$type" = symlink ] && { [ ! -L "$path" ] || [ "$(readlink "$path")" != "$src" ]; }; then
    echo "  left alone: ${path#"$HOME"/} is no longer our symlink (re-run ./install.sh to replace, with backup)"; left=$((left+1))
  fi
done < <(jq -r '.paths[] | [.type, .path, .src] | @tsv' "$REC")

echo "repair: $fixed fixed, $left need attention$([ "$DRY" = 1 ] && printf ' (dry-run)')"
[ "$DRY" = 1 ] || { "$HERE/compass-drift.sh" >/dev/null 2>&1 && echo "drift: clean" || echo "drift: findings remain — run: compass drift"; }
[ "$left" -eq 0 ]
