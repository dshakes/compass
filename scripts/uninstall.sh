#!/usr/bin/env bash
# uninstall.sh — remove what compass installed. Leaves backups untouched.
#
#   scripts/uninstall.sh [--dry-run]
#
# With an install record (${COMPASS_HOME:-~/.compass}/install.json, written by install.sh)
# it removes EXACTLY the paths the record lists — a compass symlink, or a copy (backed up first
# if you edited it) — and nothing else. Without a record (or without jq) it falls back to the
# legacy name list below.
set -euo pipefail
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
removed=0
REC="${COMPASS_HOME:-$HOME/.compass}/install.json"

if [ -f "$REC" ] && command -v jq >/dev/null 2>&1; then
  BK="$HOME/.claude/backups/compass-uninstall-$(date +%Y%m%d-%H%M%S)-$$"
  act() { if [ "$DRY" = 1 ]; then echo "[dry-run] $*"; else echo "$*"; fi; }
  while IFS=$'\t' read -r type path src; do
    case "$type" in
      symlink)
        # Only a symlink that still points where we put it; a user-replaced file is left alone.
        if [ -L "$path" ] && [ "$(readlink "$path")" = "$src" ]; then
          act "removed ${path#"$HOME"/}"; [ "$DRY" = 1 ] || rm -f "$path"; removed=$((removed+1))
        elif [ -e "$path" ] || [ -L "$path" ]; then echo "kept ${path#"$HOME"/} (no longer our symlink)"; fi ;;
      copy)
        if [ -e "$path" ]; then
          if ! diff -r -q "$src" "$path" >/dev/null 2>&1; then
            act "backed up modified copy: ${path#"$HOME"/} -> ${BK#"$HOME"/}"
            [ "$DRY" = 1 ] || { mkdir -p "$BK"; cp -R "$path" "$BK/$(basename "$path")"; }
          fi
          act "removed ${path#"$HOME"/}"; [ "$DRY" = 1 ] || rm -rf "$path"; removed=$((removed+1))
        fi ;;
      rcline)
        if [ -f "$path" ] && grep -q '# compass CLI' "$path"; then
          act "stripped compass PATH line from ${path#"$HOME"/}"
          [ "$DRY" = 1 ] || { tmp="$(mktemp)"; sed '/# compass CLI/,+1d' "$path" >"$tmp" && mv "$tmp" "$path"; }
          removed=$((removed+1))
        fi ;;
      block)
        for begin in "# >>> compass profiles >>>:# <<< compass profiles <<<" \
                     "# >>> compass mcp >>>:# <<< compass mcp <<<"; do
          b="${begin%%:*}"; e="${begin##*:}"
          if [ -f "$path" ] && grep -qF "$b" "$path"; then
            act "stripped '$b' block from ${path#"$HOME"/}"
            [ "$DRY" = 1 ] || { tmp="$(mktemp)"; sed "/$b/,/$e/d" "$path" >"$tmp" && mv "$tmp" "$path"; }
            removed=$((removed+1))
          fi
        done ;;
    esac
  done < <(jq -r '.paths[] | [.type, .path, .src] | @tsv' "$REC")
  [ "$DRY" = 1 ] || rm -f "$REC"
  echo "Removed/cleaned $removed item(s) from the install record. Restore prior config from ~/.claude/backups/ if needed."
  echo "(MCP servers added by 'make mcp' are not in the record: claude mcp remove <name> --scope user)"
  exit 0
fi

[ "$DRY" = 1 ] && { echo "no install record — legacy uninstall has no --dry-run; nothing changed."; exit 0; }
for n in settings.json CLAUDE.md statusline.sh agents commands skills workflows hooks output-styles; do
  t="$HOME/.claude/$n"
  if [ -L "$t" ]; then rm -f "$t"; echo "removed ~/.claude/$n"; removed=$((removed+1)); fi
done
if [ -L "$HOME/.codex/AGENTS.md" ]; then rm -f "$HOME/.codex/AGENTS.md"; echo "removed ~/.codex/AGENTS.md"; removed=$((removed+1)); fi
if [ -L "$HOME/.gemini/GEMINI.md" ]; then rm -f "$HOME/.gemini/GEMINI.md"; echo "removed ~/.gemini/GEMINI.md"; removed=$((removed+1)); fi
# compass CLI: the ~/.local/bin symlink + the marker-tagged PATH line in the shell rc.
if [ -L "$HOME/.local/bin/compass" ]; then rm -f "$HOME/.local/bin/compass"; echo "removed ~/.local/bin/compass"; removed=$((removed+1)); fi
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
  [ -f "$rc" ] || continue
  if grep -q '# compass CLI' "$rc"; then
    tmp="$(mktemp)"; sed '/# compass CLI/,+1d' "$rc" >"$tmp" && mv "$tmp" "$rc"
    echo "stripped compass PATH line from ${rc#"$HOME"/}"; removed=$((removed+1))
  fi
done
if [ -L "$HOME/.codex/config.toml" ]; then
  rm -f "$HOME/.codex/config.toml"; echo "removed ~/.codex/config.toml (was our template symlink)"; removed=$((removed+1))
elif [ -f "$HOME/.codex/config.toml" ]; then
  # Strip only our marker-delimited blocks (profiles + mcp); keep the user's config.
  for begin in "# >>> compass profiles >>>:# <<< compass profiles <<<" \
               "# >>> compass mcp >>>:# <<< compass mcp <<<"; do
    b="${begin%%:*}"; e="${begin##*:}"
    if grep -qF "$b" "$HOME/.codex/config.toml"; then
      tmp="$(mktemp)"; sed "/$b/,/$e/d" "$HOME/.codex/config.toml" >"$tmp" && mv "$tmp" "$HOME/.codex/config.toml"
      echo "stripped '$b' block from ~/.codex/config.toml"; removed=$((removed+1))
    fi
  done
fi
# Claude MCP servers we registered (user scope)
for s in context7 fetch git; do
  if claude mcp get "$s" >/dev/null 2>&1; then claude mcp remove "$s" --scope user >/dev/null 2>&1 && echo "removed claude mcp: $s" && removed=$((removed+1)); fi
done
echo "Removed/cleaned $removed item(s). Restore prior config from ~/.claude/backups/ if needed."
