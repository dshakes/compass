#!/usr/bin/env bash
# compass-upgrade.sh — update the compass install in place, whichever way it was installed.
#
# compass is not a pip/pipx/npm package, so `pipx upgrade compass` (a reasonable guess)
# fails with "Package is not installed". There are three real install shapes, and each
# upgrades differently:
#
#   git clone + ./install.sh   git pull --ff-only, then re-run install.sh to refresh symlinks
#   Homebrew                   brew upgrade compass — the tap owns the checkout, not us
#   Claude Code plugin         /plugin marketplace update dshakes/compass, inside the agent
#
# This detects which one you have and does the right thing (or tells you the one command
# that will), so nobody has to remember.
#
# Usage:
#   compass upgrade            # detect, pull, reinstall, report the version change
#   compass upgrade --check    # report only: what's installed, what's latest. Changes nothing.
#   compass upgrade --yes      # skip the confirmation prompt
set -uo pipefail

ROOT="${COMPASS_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CHECK=0; YES=0
for a in "$@"; do case "$a" in
  --check) CHECK=1 ;;
  --yes|-y) YES=1 ;;
  -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'unknown flag: %s\n' "$a" >&2; exit 2 ;;
esac; done

say()  { printf '\033[1;36m▶ %s\033[0m\n' "$1"; }
note() { printf '  %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

current_version() {
  # The plugin manifest is the version of record; fall back to the newest CHANGELOG heading.
  local v=""
  [ -f "$ROOT/plugins/core/.claude-plugin/plugin.json" ] &&
    v="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$ROOT/plugins/core/.claude-plugin/plugin.json" | head -1)"
  [ -n "$v" ] || v="$(sed -n 's/^## \[\([0-9][^]]*\)\].*/\1/p' "$ROOT/CHANGELOG.md" 2>/dev/null | head -1)"
  printf '%s' "${v:-unknown}"
}

latest_version() {
  command -v gh >/dev/null || { printf ''; return; }
  gh release view --repo dshakes/compass --json tagName --jq '.tagName' 2>/dev/null | sed 's/^v//'
}

# ── detect the install shape ─────────────────────────────────────────────────────
# Homebrew first: a brew install sets COMPASS_REPO_ROOT into the Cellar, and the checkout
# there is brew's to manage — pulling in it would fight the package manager.
if [ -n "${HOMEBREW_PREFIX:-}" ] && case "$ROOT" in "$HOMEBREW_PREFIX"/*) true ;; *) false ;; esac; then
  KIND=homebrew
elif command -v brew >/dev/null 2>&1 && brew list compass >/dev/null 2>&1 &&
     case "$ROOT" in *"/Cellar/compass/"*) true ;; *) false ;; esac; then
  KIND=homebrew
elif [ -d "$ROOT/.git" ]; then
  KIND=git
else
  KIND=unknown
fi

cur="$(current_version)"; latest="$(latest_version)"
say "compass upgrade"
note "install:  $KIND"
note "location: $ROOT"
note "version:  $cur${latest:+   latest: $latest}"
[ -n "$latest" ] || warn "could not reach GitHub for the latest version (gh missing or offline)"
if [ -n "$latest" ] && [ "$cur" = "$latest" ]; then note "already up to date."; [ "$CHECK" = 1 ] && exit 0; fi

case "$KIND" in
  homebrew)
    say "Homebrew install"
    note "brew owns this checkout — upgrade with:"
    note "    brew upgrade compass"
    exit 0 ;;
  unknown)
    say "unrecognised install"
    warn "$ROOT is not a git checkout and not under Homebrew."
    note "If you installed the Claude Code plugin, update it from inside the agent:"
    note "    /plugin marketplace update dshakes/compass"
    note "Otherwise re-install:  git clone https://github.com/dshakes/compass ~/compass && cd ~/compass && ./quickstart.sh"
    exit 1 ;;
esac

[ "$CHECK" = 1 ] && exit 0

# ── git install: pull, then re-run install.sh ────────────────────────────────────
# Refuse on a dirty tree. An upgrade that silently stashes or clobbers local edits is a
# worse failure than not upgrading — the whole point of this repo is config you own.
if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
  warn "working tree has uncommitted changes — not touching it."
  note "commit or stash them, then re-run. Nothing was changed."
  exit 1
fi

branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
[ "$branch" = "main" ] || warn "on branch '$branch', not main — pulling that branch."

if [ "$YES" = 0 ]; then
  printf '  pull %s and re-run install.sh? [y/N] ' "$branch"
  read -r reply </dev/tty 2>/dev/null || reply=n
  case "$reply" in y|Y|yes) ;; *) note "aborted — nothing changed."; exit 0 ;; esac
fi

say "1 · pull"
if ! git -C "$ROOT" pull --ff-only 2>&1 | sed 's/^/  /'; then
  warn "pull failed (diverged history, or no network)."
  note "resolve by hand, e.g.  git -C $ROOT pull --rebase"
  exit 1
fi

say "2 · reinstall (refresh symlinks + plugin)"
if [ -x "$ROOT/install.sh" ]; then
  "$ROOT/install.sh" 2>&1 | tail -5 | sed 's/^/  /'
else
  warn "install.sh not found or not executable — symlinks not refreshed."
fi

new="$(current_version)"
say "done"
if [ "$new" = "$cur" ]; then note "already at $new — nothing changed."
else note "$cur → $new"; fi
note "verify the release you're on:  compass verify v$new"
