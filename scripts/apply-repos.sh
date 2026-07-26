#!/usr/bin/env bash
# apply-repos.sh — apply compass's per-repo config to MANY repos in one command.
#
# After `make install`, the global config (~/.claude + ~/.codex) already applies to EVERY repo.
# This adds the *committed, per-repo* pieces (starter CLAUDE.md + AGENTS.md symlink, and
# optionally the team plugin pin) to a whole set of repos at once.
#
#   scripts/apply-repos.sh ~/work/repo-a ~/work/repo-b   # explicit list
#   scripts/apply-repos.sh ~/work/*                       # a glob (your shell expands it)
#   scripts/apply-repos.sh --team ~/work/*                # + pin compass@compass for the team
#   scripts/apply-repos.sh --git-only ~/code/*            # only directories that are git repos
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TEAM=""; GIT_ONLY=0; dirs=()
for a in "$@"; do
  case "$a" in
    --team) TEAM="--team" ;;
    --git-only) GIT_ONLY=1 ;;
    -*) echo "unknown flag: $a"; exit 2 ;;
    *) dirs+=("$a") ;;
  esac
done
[ "${#dirs[@]}" -gt 0 ] || { echo "usage: apply-repos.sh [--team] [--git-only] <dir|glob> ..."; exit 2; }

ok=0; skip=0; fail=0
for d in "${dirs[@]}"; do
  if [ ! -d "$d" ]; then echo "· skip (not a directory): $d"; skip=$((skip + 1)); continue; fi
  if [ "$GIT_ONLY" = 1 ] && ! git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "· skip (not a git repo): $d"; skip=$((skip + 1)); continue
  fi
  echo "==> $d"
  if "$HERE/new-repo.sh" "$d" $TEAM; then ok=$((ok + 1)); else echo "  ! failed: $d"; fail=$((fail + 1)); fi
done

echo
echo "applied: $ok · skipped: $skip · failed: $fail"
[ "$fail" -eq 0 ]
