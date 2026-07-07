#!/usr/bin/env bash
# verify-release.sh — verify the provenance of a compass release tarball.
#
# Confirms the artifact was built by THIS repo's signing workflow (release-sign.yml)
# via GitHub's keyless SLSA artifact attestations — so a tampered or look-alike tarball
# is rejected. Needs only `gh` (>= 2.49, the `attestation` command); no keys, no cosign.
#
#   compass verify                 # verify the latest release's source tarball
#   compass verify v0.11.0         # a specific tag
#   compass verify ./compass.tar.gz  # a local file you already have
#
# Exit: 0 = verified · 1 = verification FAILED · 77 = skipped (tooling unavailable).
set -uo pipefail

REPO_SLUG="dshakes/compass"
SIGNER_WORKFLOW="$REPO_SLUG/.github/workflows/release-sign.yml"
arg="${1:-}"

note() { printf '  %s\n' "$*"; }
skip() { printf '\033[33mℹ compass verify: skipped — %s\033[0m\n' "$1"; exit 77; }

have() { command -v "$1" >/dev/null 2>&1; }

# gh with the attestation command is the verifier.
have gh || skip "GitHub CLI (gh) not installed — https://cli.github.com, then 'gh auth login'"
gh attestation --help >/dev/null 2>&1 || skip "this gh is too old for 'gh attestation' — upgrade gh (>= 2.49)"

# Resolve the tarball to verify: a local file, or download the tag archive.
cleanup=""; trap '[ -n "$cleanup" ] && rm -rf "$cleanup"' EXIT
tarball=""
case "$arg" in
  "" )
    tag="$(gh release view --repo "$REPO_SLUG" --json tagName --jq .tagName 2>/dev/null)"
    [ -n "$tag" ] || skip "could not resolve the latest release tag (gh auth / network?)"
    ;;
  v[0-9]* ) tag="$arg" ;;
  * )
    if [ -f "$arg" ]; then tarball="$arg"
    else echo "compass verify: '$arg' is not a file or a vX.Y.Z tag" >&2; exit 2; fi
    ;;
esac

if [ -z "$tarball" ]; then
  have curl || skip "curl not installed — cannot download the tarball to verify"
  url="https://github.com/$REPO_SLUG/archive/refs/tags/$tag.tar.gz"
  # mktemp -d so the tarball lives inside a dir we own — no leaked extensionless
  # temp file, and the trap's rm -rf reclaims everything.
  cleanup="$(mktemp -d -t "compass-$tag.XXXXXX")"; tarball="$cleanup/src.tar.gz"
  note "downloading $url"
  curl -fsSL "$url" -o "$tarball" || skip "could not download $url"
fi

printf '\033[1mVerifying provenance\033[0m  %s\n' "${tag:-$tarball}"
note "expected signer: $SIGNER_WORKFLOW"
if gh attestation verify "$tarball" --repo "$REPO_SLUG" --signer-workflow "$SIGNER_WORKFLOW"; then
  printf '\033[32m✓ provenance verified — built by %s\033[0m\n' "$SIGNER_WORKFLOW"
  exit 0
fi
printf '\033[31m✗ provenance verification FAILED — do not trust this tarball\033[0m\n' >&2
exit 1
