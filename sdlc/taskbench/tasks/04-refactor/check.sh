#!/usr/bin/env bash
# Oracle: exits 0 iff calculate_stats() exists and returns correct (total, average) tuples.
# Usage: check.sh <fixture-dir>
set -uo pipefail
FIXTURE="${1:?usage: check.sh <fixture-dir>}"
cd "$FIXTURE"
python3 test_report.py
