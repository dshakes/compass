#!/usr/bin/env bash
# compass-gate.sh — thin wrapper: compass gate [--port N] [--status]
# Forwards all args to compass-gate.py; keeps the CLI surface in bin/compass.
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  printf 'compass gate: python3 is required but not found in PATH\n' >&2
  exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# One policy for every harness: load the effective caps (profile → config → env, tightened by
# this repo's .compass/policy.conf) so Codex/Gemini/SDKs behind the gate get the same ceiling
# the Claude budget hook enforces.
eval "$("$DIR/compass-profile.sh" --env)"
exec python3 "$DIR/compass-gate.py" "$@"
