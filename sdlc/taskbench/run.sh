#!/usr/bin/env bash
# run.sh — task-success benchmark runner.
#
# WARNING: THIS SCRIPT SPENDS TOKENS. Run manually; never in CI.
#
# Usage:
#   bash sdlc/taskbench/run.sh                  (all 5 tasks)
#   bash sdlc/taskbench/run.sh 01-off-by-one    (single task by dir name)
#
# Env:
#   SDLC_BUDGET   total USD budget hint per task (default 4)
#
# Output:
#   sdlc/taskbench/results.tsv  — task / outcome / cost_usd / run_dir
set -uo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDLC_DIR="$(dirname "$BENCH_DIR")"
ORCH="$SDLC_DIR/orchestrate.sh"
TASKS_DIR="$BENCH_DIR/tasks"
RESULTS="$BENCH_DIR/results.tsv"
BUDGET="${SDLC_BUDGET:-4}"

log() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }

[ -f "$ORCH" ] || { echo "orchestrate.sh not found: $ORCH"; exit 2; }
command -v claude >/dev/null || { echo "claude CLI required (this script spends tokens)"; exit 2; }

printf 'task\toutcome\tcost_usd\trun_dir\n' > "$RESULTS"
pass=0
fail=0

run_task() {
    local task_dir="$1" name outcome cost run_dir prompt FIXTURE
    name="$(basename "$task_dir")"
    log "task: $name"

    FIXTURE="$(mktemp -d)"

    # 1. Setup fixture
    if ! bash "$task_dir/setup.sh" "$FIXTURE" 2>&1; then
        printf '%s\tFAIL\t0\tsetup-failed\n' "$name" >> "$RESULTS"
        fail=$((fail + 1))
        rm -rf "$FIXTURE"
        return
    fi

    # 2. Run the SDLC loop (spends tokens).
    #    SDLC_LITE=1 skips the Codex audit + security pass to keep per-task cost lower.
    #    SDLC_NO_PR=1 avoids needing gh CLI or a remote.
    prompt="$(cat "$task_dir/task.md")"
    (
        cd "$FIXTURE"
        SDLC_NO_PR=1 SDLC_LITE=1 SDLC_BUDGET="$BUDGET" bash "$ORCH" "$prompt" || true
    )

    # 3. Find the run dir and read per-step costs.
    run_dir="$(find "$FIXTURE/.sdlc" -maxdepth 1 -name 'run-*' -type d 2>/dev/null \
        | sort -r | head -1 || true)"
    cost=0
    if [ -n "$run_dir" ] && [ -f "$run_dir/costs.tsv" ]; then
        cost="$(awk -F'\t' '{s+=$2} END{printf "%.4f", s+0}' "$run_dir/costs.tsv")"
    fi

    # 4. Oracle check — independent of the loop's own claims.
    outcome=FAIL
    if bash "$task_dir/check.sh" "$FIXTURE" 2>&1; then
        outcome=PASS
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
    fi

    printf '%s\t%s\t%s\t%s\n' \
        "$name" "$outcome" "$cost" "$(basename "${run_dir:-none}")" >> "$RESULTS"
    printf '  result: %s  cost: $%s\n' "$outcome" "$cost"
    rm -rf "$FIXTURE"
}

# Collect tasks: all, or the one matching the optional name arg.
tasks=()
for d in "$TASKS_DIR"/*/; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    if [ -n "${1:-}" ] && [ "$n" != "${1:-}" ]; then continue; fi
    tasks+=("$d")
done

[ "${#tasks[@]}" -gt 0 ] || { echo "no tasks found (arg: ${1:-all})"; exit 2; }

for t in "${tasks[@]}"; do
    run_task "$t"
done

# Summary
total="$(awk -F'\t' 'NR>1 {s+=$3} END{printf "%.4f", s+0}' "$RESULTS")"
log "results — fix-rate: $pass/$((pass + fail))  total spend: \$$total"
awk -F'\t' 'NR==1 {printf "  %-28s %-6s %10s  %s\n", $1, $2, $3, $4}
             NR>1  {printf "  %-28s %-6s %9s  %s\n", $1, $2, "$"$3, $4}' "$RESULTS"
printf '\n  full results: %s\n' "$RESULTS"
