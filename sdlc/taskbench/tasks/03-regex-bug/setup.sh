#!/usr/bin/env bash
# Setup: email validator regex rejects valid emails with dots, hyphens, or plus signs.
# Usage: setup.sh <dest-dir>
set -uo pipefail
DEST="${1:?usage: setup.sh <dest-dir>}"
cd "$DEST"

git init -q
git config user.email "bench@test.local"
git config user.name "taskbench"

cat > validator.py << 'PYEOF'
import re

def is_valid_email(addr):
    """Return True if addr looks like a valid email address."""
    # BUG: local part only allows [a-zA-Z0-9]; dots, hyphens, and plus are valid too
    pattern = r'^[a-zA-Z0-9]+@[a-zA-Z0-9]+\.[a-zA-Z]{2,}$'
    return bool(re.match(pattern, addr))
PYEOF

cat > test_validator.py << 'PYEOF'
#!/usr/bin/env python3
import sys
from validator import is_valid_email

def check(name, got, want):
    if got != want:
        print("FAIL {}: got {}, want {}".format(name, got, want))
        sys.exit(1)
    print("ok", name)

check("plain",        is_valid_email("user@example.com"),      True)
check("dot-local",    is_valid_email("first.last@example.com"), True)
check("hyphen-local", is_valid_email("user-name@example.com"), True)
check("plus-local",   is_valid_email("user+tag@example.org"),  True)
check("reject-no-at", is_valid_email("notanemail"),            False)
check("reject-no-tld",is_valid_email("user@nodot"),            False)
print("all tests passed")
PYEOF

git add validator.py test_validator.py
git commit -q -m "initial: regex rejects valid emails with dots/hyphens/plus"
