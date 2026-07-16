#!/usr/bin/env bash
# Setup: report.py mixes calculation and I/O; tests expect calculate_stats() to be
# extracted as a separate, pure function — which does not exist yet.
# Usage: setup.sh <dest-dir>
set -uo pipefail
DEST="${1:?usage: setup.sh <dest-dir>}"
cd "$DEST"

git init -q
git config user.email "bench@test.local"
git config user.name "taskbench"

cat > report.py << 'PYEOF'
def generate_report(data):
    """Print a summary of data to stdout."""
    total = sum(data)
    average = total / len(data)
    print("Total: {}, Average: {:.2f}".format(total, average))
PYEOF

cat > test_report.py << 'PYEOF'
#!/usr/bin/env python3
"""Tests for the refactored report module.

calculate_stats(data) must exist and return (total, average) without printing.
"""
import sys
from report import calculate_stats  # ImportError pre-refactor

def check(name, got, want):
    if got != want:
        print("FAIL {}: got {!r}, want {!r}".format(name, got, want))
        sys.exit(1)
    print("ok", name)

total, avg = calculate_stats([1, 2, 3, 4, 5])
check("total", total, 15)
check("average", avg, 3.0)

total2, avg2 = calculate_stats([10, 20, 30])
check("total2", total2, 60)
check("average2", avg2, 20.0)

print("all tests passed")
PYEOF

git add report.py test_report.py
git commit -q -m "initial: calculate_stats not yet extracted from generate_report"
