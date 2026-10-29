#!/usr/bin/env bash
# install-remote.sh — one-line, provenance-verified install.
#
#   curl -fsSL https://raw.githubusercontent.com/dshakes/compass/main/install-remote.sh | bash
#   curl -fsSL .../install-remote.sh | COMPASS_VERSION=v0.12.0 bash -s -- --copy
#
# Downloads the release tarball, VERIFIES its SLSA attestation (the same `gh attestation
# verify` + signer-workflow pin as `compass verify`) BEFORE extracting or running anything,
# unpacks to ~/.compass/src and runs its install.sh. Fails closed: no verifier, no install —
# unless you pass --no-verify. Other flags go to install.sh.
#
# Test seams (no network): COMPASS_TARBALL=<file> skips the download, COMPASS_VERIFIER=<exe>
# replaces `gh attestation verify` (called with the tarball path; exit 0 = verified).
set -euo pipefail

SLUG="dshakes/compass"
SIGNER="$SLUG/.github/workflows/release-sign.yml"
DEST="${COMPASS_HOME:-$HOME/.compass}/src"
VERIFY=1; ARGS=()
for a in "$@"; do
  case "$a" in
    --no-verify) VERIFY=0 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ARGS+=("$a") ;;
  esac
done

say() { printf '  %s\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
tag="${COMPASS_VERSION:-}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
tarball="${COMPASS_TARBALL:-$TMP/src.tar.gz}"

if [ -z "${COMPASS_TARBALL:-}" ]; then
  command -v curl >/dev/null 2>&1 || die "curl is required"
  if [ -z "$tag" ]; then
    tag="$(curl -fsSL "https://api.github.com/repos/$SLUG/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$tag" ] || die "could not resolve the latest release (set COMPASS_VERSION=vX.Y.Z)"
  fi
  case "$tag" in v[0-9]*) ;; *) die "COMPASS_VERSION must look like vX.Y.Z (got '$tag')" ;; esac
  say "downloading $SLUG $tag"
  curl -fsSL "https://github.com/$SLUG/archive/refs/tags/$tag.tar.gz" -o "$tarball" || die "download failed"
fi
[ -f "$tarball" ] || die "no tarball at $tarball"

# --- Verify BEFORE anything from the tarball is extracted or executed. ---
if [ "$VERIFY" = 1 ]; then
  if [ -n "${COMPASS_VERIFIER:-}" ]; then
    "$COMPASS_VERIFIER" "$tarball" || die "provenance verification FAILED — nothing was installed"
  elif command -v gh >/dev/null 2>&1 && gh attestation --help >/dev/null 2>&1; then
    gh attestation verify "$tarball" --repo "$SLUG" --signer-workflow "$SIGNER" \
      || die "provenance verification FAILED — nothing was installed"
  else
    cp "$tarball" "./compass-${tag:-release}.tar.gz" 2>/dev/null || true
    printf '\033[31m✗ cannot verify: GitHub CLI >= 2.49 (gh attestation) is missing — refusing to install unverified code.\033[0m\n' >&2
    say "install gh (https://cli.github.com), then verify by hand:" >&2
    say "  gh attestation verify ./compass-${tag:-release}.tar.gz --repo $SLUG --signer-workflow $SIGNER" >&2
    say "or accept the risk explicitly:  ... | bash -s -- --no-verify" >&2
    exit 1
  fi
  say "provenance verified ✓"
else
  printf '\033[33m! --no-verify: installing WITHOUT provenance verification\033[0m\n' >&2
fi

mkdir -p "$TMP/x"
tar -xzf "$tarball" -C "$TMP/x" --strip-components=1
[ -x "$TMP/x/install.sh" ] || [ -f "$TMP/x/install.sh" ] || die "tarball has no install.sh — not a compass release"

mkdir -p "$(dirname "$DEST")"
[ -e "$DEST" ] && mv "$DEST" "$DEST.old.$$"
mv "$TMP/x" "$DEST"
rm -rf "$DEST.old.$$"
say "unpacked to $DEST"
COMPASS_INSTALL_SHA="${tag:-}" exec bash "$DEST/install.sh" "${ARGS[@]+"${ARGS[@]}"}"
