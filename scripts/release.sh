#!/usr/bin/env bash
# release.sh — finish cutting a compass release in one command: push the tag, pin the
# Homebrew formula to the new tarball sha, and publish the GitHub Release (notes pulled
# from CHANGELOG.md). Idempotent — safe to re-run; it only does the steps still missing.
#
# Run from the repo, on main, AFTER the CHANGELOG has the version's section:
#   scripts/release.sh            # version = newest [X.Y.Z] heading in CHANGELOG
#   scripts/release.sh v0.10.0    # or name it explicitly
#   scripts/release.sh --dry-run  # show the plan + release notes, touch nothing
#
# Needs: git (push), curl + sha256sum/shasum (formula sha), gh (the Release). Each missing
# tool degrades to a printed next-step rather than failing the whole run.
set -euo pipefail

REPO_SLUG="dshakes/compass"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

DRY=0; [ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }
say() { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
do_or_show() { if [ "$DRY" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else printf '  + %s\n' "$*"; eval "$@"; fi; }

# ── version: arg, else the newest semver heading in the CHANGELOG ────────────────
VER="${1:-}"
if [ -z "$VER" ]; then
  VER="$(grep -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md | head -1 | tr -dc '0-9.')"
  [ -n "$VER" ] && VER="v$VER"
fi
[ -n "$VER" ] || { echo "could not determine version — pass it, e.g. scripts/release.sh v0.10.0"; exit 2; }
case "$VER" in v*) ;; *) VER="v$VER" ;; esac
NUM="${VER#v}"
TARBALL="https://github.com/$REPO_SLUG/archive/refs/tags/$VER.tar.gz"
say "Releasing $VER  (dry-run=$DRY)"

# ── preflight ────────────────────────────────────────────────────────────────────
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
[ "$branch" = main ] || echo "  ! not on main (on '$branch') — releases normally cut from main"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "  ! working tree is dirty — commit or stash before releasing"; [ "$DRY" = 0 ] && exit 1
fi

# ── release notes from the CHANGELOG section ──────────────────────────────────────
notes="$(awk -v v="$NUM" '
  $0 ~ ("^## \\[" v "\\]") { f=1; next }
  f && /^## \[/ { exit }
  f { print }
' CHANGELOG.md)"
[ -n "$notes" ] || echo "  ! no CHANGELOG section for [$NUM] — the Release notes will be sparse"

# ── 1 · tag + push ────────────────────────────────────────────────────────────────
say "1 · tag"
if git rev-parse -q --verify "refs/tags/$VER" >/dev/null; then echo "  tag $VER exists locally"
else do_or_show "git tag -a '$VER' -m 'compass $VER'"; fi
if [ -n "$(git ls-remote --tags origin "$VER" 2>/dev/null)" ]; then echo "  tag $VER already on origin"
else do_or_show "git push origin '$VER'"; fi

# ── 2 · Homebrew formula: bump url + tarball sha ──────────────────────────────────
say "2 · Homebrew formula"
if ! command -v curl >/dev/null; then echo "  ! curl missing — bump Formula/compass.rb by hand"
else
  sha=""
  if [ "$DRY" = 0 ] && [ -n "$(git ls-remote --tags origin "$VER" 2>/dev/null)" ]; then
    hasher="shasum -a 256"; command -v sha256sum >/dev/null && hasher="sha256sum"
    sha="$(curl -fsSL "$TARBALL" | $hasher | cut -d' ' -f1 || true)"
  fi
  if [ -n "$sha" ]; then
    tmp="$(mktemp)"
    sed -E -e "s#archive/refs/tags/v[0-9.]+\.tar\.gz#archive/refs/tags/$VER.tar.gz#" \
           -e "s/^([[:space:]]*sha256 )\"[a-f0-9]*\"/\1\"$sha\"/" Formula/compass.rb >"$tmp" && mv "$tmp" Formula/compass.rb
    if git diff --quiet Formula/compass.rb; then echo "  formula already at $VER / $sha"
    else
      do_or_show "git commit -q -m 'chore(release): pin $VER + tarball sha in the Homebrew formula' Formula/compass.rb"
      do_or_show "git push origin main"
      echo "  formula → $VER  sha256 $sha"
    fi
  else
    echo "  (dry-run or tag not yet on remote) — sha computed from $TARBALL after the tag is pushed"
  fi
fi

# ── 3 · GitHub Release (marks it Latest) ──────────────────────────────────────────
say "3 · GitHub Release"
if ! command -v gh >/dev/null; then
  echo "  ! gh not installed — publish the Release manually (or 'brew install gh'). Notes below:"; echo; printf '%s\n' "$notes"
elif gh release view "$VER" >/dev/null 2>&1; then
  echo "  release $VER already exists — refreshing notes"
  if [ "$DRY" = 1 ]; then echo "  [dry-run] gh release edit $VER --notes-file -"; else printf '%s\n' "$notes" | gh release edit "$VER" --notes-file -; fi
else
  if [ "$DRY" = 1 ]; then echo "  [dry-run] gh release create $VER --latest --title '$VER — compass' --notes-file -"
  else printf '%s\n' "$notes" | gh release create "$VER" --latest --title "$VER — compass" --notes-file -; fi
fi

say "done — $VER"
[ "$DRY" = 1 ] && { echo; echo "── release notes preview ──"; printf '%s\n' "$notes"; }
exit 0
