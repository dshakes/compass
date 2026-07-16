#!/usr/bin/env bash
# Setup: Python repo with an off-by-one bug in triangle().
# Usage: setup.sh <dest-dir>
set -uo pipefail
DEST="${1:?usage: setup.sh <dest-dir>}"
cd "$DEST"

git init -q
git config user.email "bench@test.local"
git config user.name "taskbench"

cat > sums.py << 'PYEOF'
def triangle(n):
    """Return the nth triangle number: 1 + 2 + ... + n."""
    return sum(range(1, n))  # BUG: off-by-one — should be range(1, n+1)
PYEOF

cat > test_sums.py << 'PYEOF'
#!/usr/bin/env python3
import sys
from sums import triangle

def check(name, got, want):
    if got != want:
        print("FAIL {}: got {}, want {}".format(name, got, want))
        sys.exit(1)
    print("ok", name)

check("triangle(1)", triangle(1), 1)
check("triangle(3)", triangle(3), 6)
check("triangle(5)", triangle(5), 15)
check("triangle(10)", triangle(10), 55)
print("all tests passed")
PYEOF

git add sums.py test_sums.py
git commit -q -m "initial: seeded off-by-one bug in triangle()"
