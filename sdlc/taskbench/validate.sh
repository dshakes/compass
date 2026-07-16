#!/usr/bin/env bash
# validate.sh — CI-safe structural check + pre-fix oracle for the task benchmark.
#
# What this does (NO tokens, NO network):
#   1. Verifies each task dir contains the required 3 files.
#   2. Runs shellcheck -S error on all scripts in this directory tree.
#   3. For each task: runs setup.sh then check.sh — expects check.sh to EXIT NONZERO,
#      proving the seeded bug genuinely fails its oracle before the loop runs.
#
# Exit 0 = all checks pass.  Called from CI; does NOT invoke run.sh.
set -uo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKS_DIR="$BENCH_DIR/tasks"

command -v shellcheck >/dev/null || { echo "shellcheck required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# ── 1. Structure: every task dir must have setup.sh, task.md, check.sh ────────
echo "structure:"
for task_dir in "$TASKS_DIR"/*/; do
    [ -d "$task_dir" ] || continue
    name="$(basename "$task_dir")"
    for f in setup.sh task.md check.sh; do
        if [ -f "$task_dir/$f" ]; then
            ok "$name/$f"
        else
            bad "$name/$f — MISSING"
        fi
    done
done

# ── 2. Shellcheck all scripts in this tree ─────────────────────────────────────
echo "shellcheck:"
while IFS= read -r -d '' script; do
    rel="${script#"$BENCH_DIR/"}"
    if shellcheck -S error "$script" 2>/dev/null; then
        ok "shellcheck $rel"
    else
        bad "shellcheck $rel"
        shellcheck -S error "$script" 2>&1 | sed 's/^/    /' || true
    fi
done < <(find "$BENCH_DIR" -name "*.sh" -print0 | sort -z)

# ── 3. Pre-fix oracle: check.sh must FAIL before the loop touches the code ────
echo "oracle pre-fix (each seeded bug must genuinely fail check.sh):"
for task_dir in "$TASKS_DIR"/*/; do
    [ -d "$task_dir" ] || continue
    name="$(basename "$task_dir")"
    [ -f "$task_dir/setup.sh" ] || continue
    [ -f "$task_dir/check.sh" ] || continue

    TMPD="$(mktemp -d)"
    if bash "$task_dir/setup.sh" "$TMPD" >/dev/null 2>&1; then
        if bash "$task_dir/check.sh" "$TMPD" >/dev/null 2>&1; then
            bad "$name: check.sh passed pre-fix — bug is not real!"
        else
            ok "$name: check.sh correctly fails pre-fix"
        fi
    else
        bad "$name: setup.sh failed"
    fi
    rm -rf "$TMPD"
done

echo
printf 'validate: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
