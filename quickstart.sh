#!/usr/bin/env bash
# quickstart.sh — the one command. Install compass, validate it, and print the
# 60-second on-ramp. Idempotent: safe to re-run to repair or re-verify.
#
#   ./quickstart.sh                 # preview → install → doctor → next steps
#   ./quickstart.sh --yes           # skip the preview/confirm, just do it
#   ./quickstart.sh --mcp           # also register the curated MCP servers (needs network)
#   ./quickstart.sh --gemini --yes  # pass any install.sh flag straight through
#
# Also reachable post-install from any repo as: compass quickstart
set -euo pipefail
# COMPASS_REPO_ROOT lets a packaged install (Homebrew) pin the repo root to a stable
# path that survives upgrades. Unset → resolve from our own location (git clone).
REPO="${COMPASS_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
cd "$REPO"

YES=0; DO_MCP=0; PASS=()
for a in "$@"; do
  case "$a" in
    --yes|-y) YES=1 ;;
    --mcp)    DO_MCP=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) PASS+=("$a") ;;     # forwarded to install.sh (--copy, --gemini, --dry-run, …)
  esac
done

step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }

printf '\033[1m🧭 compass quickstart\033[0m  —  one config, every repo, measured-safety defaults\n'
printf '   repo: %s\n' "$REPO"

# 1 · Preview, unless waved through. Honesty first: show exactly what will change.
if [ "$YES" = 0 ]; then
  step "Preview (no changes yet)"
  ./install.sh --dry-run "${PASS[@]+"${PASS[@]}"}" || true
  printf '\n  This symlinks config into ~/.claude (+ ~/.codex), backs up anything it replaces,\n'
  printf '  and puts the `compass` CLI on your PATH. Nothing runs without your say-so.\n'
  printf '\n  Proceed? [y/N] '
  read -r reply || reply=""
  case "$reply" in y|Y|yes|YES) ;; *) echo "aborted — nothing changed."; exit 0 ;; esac
fi

# 2 · Install (idempotent; backs up first).
step "Install"
./install.sh "${PASS[@]+"${PASS[@]}"}"

# 3 · MCP servers (opt-in; needs network for npx/uvx).
if [ "$DO_MCP" = 1 ]; then
  step "MCP servers (context7 · fetch · git)"
  ./scripts/setup-mcp.sh || printf '  (skipped/failed — context7 version-correct docs, url→markdown fetch, and structured git tools stay unavailable; re-run later with: make mcp)\n'
fi

# 4 · Validate.
step "Validate"
./scripts/doctor.sh || true

# 5 · The on-ramp.
step "You're set — next 60 seconds"
ok 'Open Claude Code in any repo: guardrails, 9 subagents, commands + status line are live.'
ok 'In a new repo, get productive fast:   compass onboard .'
ok 'See what compass saved you:           compass impact'
ok 'Review a branch with the crew:        /review     (or the parallel /compass-review *)'
ok 'Audit deeper / plan from N angles:    /compass-audit *   /compass-plan "<task>" *'
printf '\n  \033[2m* dynamic-workflow commands — research preview, need Claude Code v2.1.154+ (claude --version).\n'
printf '    Not on your build yet? Everything else works regardless.\033[0m\n'
printf '\n  Full walkthrough: docs/11-using-compass.md   ·   Validate anytime: make doctor\n'
