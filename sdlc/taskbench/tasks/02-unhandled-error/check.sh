#!/usr/bin/env bash
# Oracle: exits 0 iff backup() returns nonzero when the copy fails.
# Usage: check.sh <fixture-dir>
set -uo pipefail
FIXTURE="${1:?usage: check.sh <fixture-dir>}"
cd "$FIXTURE"
bash test_backup.sh
