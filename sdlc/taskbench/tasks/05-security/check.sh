#!/usr/bin/env bash
# Oracle: exits 0 iff check_user() blocks shell injection and still accepts valid input.
# Usage: check.sh <fixture-dir>
set -uo pipefail
FIXTURE="${1:?usage: check.sh <fixture-dir>}"
cd "$FIXTURE"
python3 test_security.py
