#!/usr/bin/env bash
# Setup: check_user() builds a shell command via string concat — injection risk.
# Usage: setup.sh <dest-dir>
set -uo pipefail
DEST="${1:?usage: setup.sh <dest-dir>}"
cd "$DEST"

git init -q
git config user.email "bench@test.local"
git config user.name "taskbench"

cat > run_cmd.py << 'PYEOF'
import subprocess

def check_user(username):
    """Return True if username exists on this system."""
    # BUG: shell=True with user-controlled input allows command injection
    result = subprocess.run(
        "id " + username,
        shell=True,
        capture_output=True,
        text=True,
    )
    return result.returncode == 0
PYEOF

cat > test_security.py << 'PYEOF'
#!/usr/bin/env python3
"""Oracle: shell injection must NOT be possible through check_user()."""
import os
import sys
import tempfile
from run_cmd import check_user

tmpf = os.path.join(tempfile.gettempdir(), "bench-inject-{}.txt".format(os.getpid()))
# Clean up any leftover from a prior run
if os.path.exists(tmpf):
    os.unlink(tmpf)

# Attempt injection: a real shell would execute "touch <tmpf>" as a side-effect
injected = "root; touch {}".format(tmpf)
try:
    check_user(injected)
except Exception:
    pass  # raising on bad input is also an acceptable fix

if os.path.exists(tmpf):
    os.unlink(tmpf)
    print("FAIL: shell injection succeeded — use argv list, not shell=True")
    sys.exit(1)
print("ok: injection blocked")

# Legitimate use must still work
if not check_user("root"):
    print("FAIL: check_user('root') should return True")
    sys.exit(1)
print("ok: check_user('root') works")
print("all security tests passed")
PYEOF

git add run_cmd.py test_security.py
git commit -q -m "initial: check_user() uses shell=True with user-controlled input"
