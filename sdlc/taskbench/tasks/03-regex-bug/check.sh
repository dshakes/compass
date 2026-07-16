#!/usr/bin/env bash
# Oracle: exits 0 iff is_valid_email handles dots/hyphens/plus in the local part.
# Usage: check.sh <fixture-dir>
set -uo pipefail
FIXTURE="${1:?usage: check.sh <fixture-dir>}"
cd "$FIXTURE"
python3 test_validator.py
