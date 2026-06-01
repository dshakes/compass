#!/usr/bin/env bash
# compass-sandbox.sh — run a command in a REAL OS sandbox: no network by default and
# writes confined to the working dir + temp. This is the actual containment boundary —
# unlike protect-paths, which only *reduces footguns* (a regex can't stop a determined
# or obfuscated payload). Reach for it when an agent (or you) must run untrusted code:
# a downloaded build, a script you didn't write, repro of a sketchy repo.
#
#   compass sandbox -- npm test
#   compass sandbox --net allow -- ./build.sh      # permit network
#   compass sandbox --rw /data -- ./tool           # extra writable dir
#
# Backends, best first: bubblewrap (bwrap), firejail, macOS sandbox-exec. If NONE is
# available it REFUSES rather than run unconfined — no fake sandboxing. Exit = the
# command's exit; 2 = usage error or no backend.
set -uo pipefail

net=none; rw=()
while [ $# -gt 0 ]; do
  case "$1" in
    --net)     net="${2:-none}"; shift ;;
    --rw)      rw+=("${2:?--rw needs a DIR}"); shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --)        shift; break ;;
    -*)        echo "compass sandbox: unknown flag '$1'" >&2; exit 2 ;;
    *)         echo "compass sandbox: unexpected arg '$1' (put the command after '--')" >&2; exit 2 ;;
  esac
  shift
done
[ "$#" -gt 0 ] || { echo "compass sandbox: nothing to run — usage: compass sandbox [--net allow] [--rw DIR] -- CMD..." >&2; exit 2; }

have() { command -v "$1" >/dev/null 2>&1; }
CWD="$(pwd -P)"; TMP="${TMPDIR:-/tmp}"; TMP="${TMP%/}"

if have bwrap; then
  args=(--ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --bind "$CWD" "$CWD")
  [ "$net" = none ] && args+=(--unshare-net)
  if [ "${#rw[@]}" -gt 0 ]; then for d in "${rw[@]}"; do args+=(--bind "$d" "$d"); done; fi
  exec bwrap "${args[@]}" -- "$@"
elif have firejail; then
  args=(--quiet --private-cwd)
  [ "$net" = none ] && args+=(--net=none)
  exec firejail "${args[@]}" -- "$@"
elif have sandbox-exec; then
  prof="$(mktemp -t compass-sb.XXXXXX)"
  {
    echo '(version 1)'
    echo '(allow default)'
    [ "$net" = none ] && echo '(deny network*)'
    echo '(deny file-write*)'
    printf '(allow file-write* (subpath "%s") (subpath "%s")' "$CWD" "$TMP"
    if [ "${#rw[@]}" -gt 0 ]; then for d in "${rw[@]}"; do printf ' (subpath "%s")' "$d"; done; fi
    echo ' (subpath "/dev") (subpath "/private/tmp") (subpath "/private/var/folders"))'
  } >"$prof"
  sandbox-exec -f "$prof" "$@"; rc=$?
  rm -f "$prof"
  exit "$rc"
else
  cat >&2 <<'MSG'
compass sandbox: no sandbox backend available — refusing to run unconfined.
Install one and retry:
  Linux:  sudo apt install bubblewrap      (or: firejail)
  macOS:  sandbox-exec is built in (no install needed)
MSG
  exit 2
fi
