#!/usr/bin/env bash
# Setup: backup() always returns 0 even when cp fails — swallowed error path.
# Usage: setup.sh <dest-dir>
set -uo pipefail
DEST="${1:?usage: setup.sh <dest-dir>}"
cd "$DEST"

git init -q
git config user.email "bench@test.local"
git config user.name "taskbench"

cat > backup.sh << 'SHEOF'
#!/usr/bin/env bash
# backup <src> <dst-dir>: copy src into dst-dir.
backup() {
    local src="$1" dst="$2"
    mkdir -p "$dst"
    cp "$src" "$dst"
    echo "Backup complete: $(basename "$src")"  # BUG: echo is last cmd; always returns 0
}
SHEOF

cat > test_backup.sh << 'SHEOF'
#!/usr/bin/env bash
# shellcheck source=./backup.sh
set -uo pipefail
. ./backup.sh

BENCH_BK="/tmp/bench-bk-$$"
backup /no/such/file.txt "$BENCH_BK/" 2>/dev/null
rc=$?
rm -rf "$BENCH_BK"

if [ "$rc" -eq 0 ]; then
    echo "FAIL: backup of nonexistent file returned 0 (must return nonzero)"
    exit 1
fi
echo "ok: backup() correctly returned nonzero ($rc) on failure"
SHEOF

git add backup.sh test_backup.sh
git commit -q -m "initial: backup() swallows cp failure via trailing echo"
