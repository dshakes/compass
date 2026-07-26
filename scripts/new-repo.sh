#!/usr/bin/env bash
# new-repo.sh — drop agent config into a repo (new or existing).
#
# The user-global ~/.claude/CLAUDE.md + ~/.codex/AGENTS.md already apply to EVERY
# repo automatically. This adds the *committed, per-repo* pieces that can't be
# global: a starter CLAUDE.md, the AGENTS.md symlink (one source for both tools),
# and optionally the team plugin pin.
#
#   new-repo.sh [dir]            # scaffold in dir (created + git-init'd if missing)
#   new-repo.sh [dir] --team     # also pin compass@compass in .claude/settings.json
#   new-repo.sh --team           # scaffold in the current directory
set -euo pipefail

REPO_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="."; TEAM=0
for a in "$@"; do case "$a" in --team) TEAM=1 ;; *) DIR="$a" ;; esac; done

[ -d "$DIR" ] || { mkdir -p "$DIR"; echo "created $DIR"; }
cd "$DIR"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { git init -q && echo "git init"; }

# 1) Starter CLAUDE.md (only if absent — never clobber a hand-written one).
if [ ! -e CLAUDE.md ]; then
  cp "$REPO_HOME/templates/CLAUDE.md.tmpl" CLAUDE.md
  echo "created CLAUDE.md (starter — fill the {{PLACEHOLDERS}}, or run the"
  echo "  bootstrap-agent-config skill / Claude's /init to generate it from the code)"
else
  echo "CLAUDE.md exists — left as-is"
fi

# 2) AGENTS.md -> CLAUDE.md symlink (one source for Claude + Codex + others).
# Test -L too: a DANGLING symlink fails -e (target missing), so the old check would
# try `ln -s` over it, hit "File exists", and abort under set -e. Treat any existing
# path or symlink as present and leave it untouched.
if [ -L AGENTS.md ] || [ -e AGENTS.md ]; then echo "AGENTS.md exists — left as-is"
else ln -s CLAUDE.md AGENTS.md && echo "linked AGENTS.md -> CLAUDE.md"; fi

# 2b) GEMINI.md -> CLAUDE.md symlink (Gemini CLI reads GEMINI.md by default; same
# one-source rule and the same dangling-symlink-safe check as AGENTS.md above).
if [ -L GEMINI.md ] || [ -e GEMINI.md ]; then echo "GEMINI.md exists — left as-is"
else ln -s CLAUDE.md GEMINI.md && echo "linked GEMINI.md -> CLAUDE.md"; fi

# 3) Optional team plugin pin (committed project settings).
if [ "$TEAM" = 1 ]; then
  mkdir -p .claude
  if [ -e .claude/settings.json ]; then
    echo ".claude/settings.json exists — add the pin manually (see docs/08-defaults.md)"
  else
    PIN="$(git -C "$REPO_HOME" describe --tags --abbrev=0 2>/dev/null || echo main)"   # pin the team to the current release, not a stale literal
    cat > .claude/settings.json <<JSON
{
  "extraKnownMarketplaces": {
    "compass": { "source": { "source": "github", "repo": "dshakes/compass", "ref": "$PIN" } }
  },
  "enabledPlugins": { "compass@compass": true }
}
JSON
    echo "wrote .claude/settings.json (pins compass@compass @ $PIN for the team)"
  fi
fi

echo "done. Next: open the repo in Claude Code and run /init (or the"
echo "  bootstrap-agent-config skill) to fill CLAUDE.md from the actual code."
