#!/usr/bin/env bash
# context-pack.sh — compact context pack for SDLC review: changed symbols + call sites.
#
# Usage: context-pack.sh [<diff-range>]
#   diff-range: any two- or three-dot git diff range, e.g. "main...HEAD" or "abc123..HEAD"
#               default: HEAD vs merge-base with main (falls back to HEAD~1..HEAD)
#
# Prints a compact "context pack": each touched symbol, its definition location, and up
# to 5 call/use sites found across the repo.  Designed to feed the SDLC reviewer so it
# sees ripple effects beyond the raw diff.
#
# Dependency-free: uses ctags when available (better symbol extraction); falls back to
# grep on the changed file contents otherwise.  Bounded: ≤20 symbols, ≤5 sites each,
# total output typically <200 lines.  Should complete in <2s on a normal repo.
#
# ponytail: grep changed-file contents (not just diff + lines) so body-only changes
# (e.g. only the return statement changed) still surface the enclosing function name.
set -uo pipefail

have() { command -v "$1" >/dev/null 2>&1; }

# ── diff range ───────────────────────────────────────────────────────────────────
RANGE="${1:-}"
if [ -z "$RANGE" ]; then
  MBASE="$(git merge-base HEAD main 2>/dev/null \
         || git merge-base HEAD origin/main 2>/dev/null \
         || echo '')"
  if [ -n "$MBASE" ]; then RANGE="${MBASE}..HEAD"
  else RANGE="HEAD~1..HEAD"; fi
fi

# ── changed files ─────────────────────────────────────────────────────────────────
CHANGED_FILES="$(git diff --name-only "$RANGE" 2>/dev/null | grep -v '^$' || true)"
if [ -z "$CHANGED_FILES" ]; then
  printf '(no changed files in range %s)\n' "$RANGE"; exit 0
fi

printf '## Context pack — %s\n\n' "$RANGE"

# ── symbol extraction ─────────────────────────────────────────────────────────────
# Strategy: ctags on changed files (works on both BSD and universal ctags; column 1 is
# the symbol name in both flavours).  Fall back to grepping the file contents directly —
# not the diff lines — so a body-only change still surfaces the enclosing function name.
TMPF="$(mktemp)"; trap 'rm -f "$TMPF"' EXIT
SYMBOLS=""
if have ctags; then
  # shellcheck disable=SC2086  # word-split CHANGED_FILES into separate file arguments
  ctags -f "$TMPF" $CHANGED_FILES 2>/dev/null || true
  SYMBOLS="$(awk -F'\t' '!/^!/{print $1}' "$TMPF" 2>/dev/null | sort -u || true)"
fi
if [ -z "$SYMBOLS" ]; then
  # Grep definition keywords from the current content of changed files.
  # Covers Go (func/type), Rust (fn/struct/enum), Python (def/class), JS/TS (function/class).
  SYMBOLS="$(while IFS= read -r f; do
    [ -f "$f" ] && grep -oE '\b(func|def|class|fn|struct|enum|interface|type|function) [A-Za-z_][A-Za-z0-9_]+' "$f" 2>/dev/null || true
  done <<< "$CHANGED_FILES" | awk '{print $2}' | sort -u || true)"
fi

if [ -z "$SYMBOLS" ]; then
  FCOUNT="$(printf '%s\n' "$CHANGED_FILES" | grep -c . 2>/dev/null || echo 0)"
  printf '(no recognizable symbols extracted — %s file(s) changed)\n' "$FCOUNT"
  exit 0
fi

# ── call/use site lookup, bounded ────────────────────────────────────────────────
MAX_SYMBOLS=20  # ponytail: 20 symbols covers nearly all feature diffs; raise when needed
MAX_SITES=5     # per-symbol call-site cap

n=0
while IFS= read -r sym; do
  [ -z "$sym" ] && continue
  n=$((n + 1)); [ "$n" -gt "$MAX_SYMBOLS" ] && break

  # Definition: first line in the changed files that looks like a definition of this symbol.
  DEF="$(while IFS= read -r f; do
    [ -f "$f" ] && git grep -n "$sym" -- "$f" 2>/dev/null || true
  done <<< "$CHANGED_FILES" \
    | grep -E "(func|def|class|fn |struct|enum|interface|type|function) ${sym}\b" \
    | head -1 || true)"

  # Call/use sites: all occurrences across the whole repo, bounded.
  SITES="$(git grep -n "$sym" 2>/dev/null | grep -v '^Binary' | head -n "$MAX_SITES" || true)"
  SCOUNT="$(printf '%s\n' "$SITES" | grep -c . 2>/dev/null || echo 0)"
  [ "${SCOUNT:-0}" -eq 0 ] && continue  # symbol not found anywhere → skip

  printf '### %s\n' "$sym"
  [ -n "$DEF" ] && printf '  defined: %s\n' "$DEF"
  printf '  sites (%s shown):\n' "$SCOUNT"
  printf '%s\n' "$SITES" | sed 's/^/    /'
  printf '\n'
done <<< "$SYMBOLS"
