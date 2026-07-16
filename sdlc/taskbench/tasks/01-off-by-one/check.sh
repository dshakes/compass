#!/usr/bin/env bash
# Oracle: exits 0 iff triangle() returns correct values for all test cases.
# Usage: check.sh <fixture-dir>
set -uo pipefail
FIXTURE="${1:?usage: check.sh <fixture-dir>}"
cd "$FIXTURE"
python3 test_sums.py
