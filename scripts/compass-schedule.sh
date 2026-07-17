#!/usr/bin/env bash
# compass-schedule.sh — manage local scheduled compass routines via crontab.
#
# Subcommands:
#   add <routine> [--daily|--weekly|--cron "<expr>"]
#   list
#   remove <routine>
#   run <routine> [DIR]
#
# Routines: dep-refresh  flaky-triage  doc-freshness  pr-babysit  ci-watch
#
# Crontab block is delimited by:
#   # >>> compass schedule >>>
#   # <<< compass schedule <<<
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
REPO_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMPTS_DIR="$REPO_HOME/sdlc/routines/prompts"
DISPATCHER="$REPO_HOME/bin/compass"

COMPASS_HOME="${COMPASS_HOME:-$HOME/.compass}"
SPEND_LEDGER="$COMPASS_HOME/spend.tsv"

BLOCK_OPEN="# >>> compass schedule >>>"
BLOCK_CLOSE="# <<< compass schedule <<<"

# ---------------------------------------------------------------------------
# Valid routines (space-separated; validated by validate_routine)
# ---------------------------------------------------------------------------
VALID_ROUTINES="dep-refresh flaky-triage doc-freshness pr-babysit ci-watch"

# Allowed tools for each routine's claude invocation (read + git + build/test only).
ALLOWED_TOOLS="Read,Grep,Glob,Bash(git log:*),Bash(git diff:*),Bash(git status:*),Bash(git add:*),Bash(git commit:*),Bash(go build:*),Bash(go test:*),Bash(go vet:*),Bash(cargo build:*),Bash(cargo test:*),Bash(npm:*),Bash(pnpm:*),Bash(npx tsc:*),Bash(pytest:*),Bash(ruff:*),Bash(make:*),Bash(gh run list:*),Bash(gh run view:*),Bash(gh issue list:*),Bash(gh issue view:*),Bash(gh issue create:*),Bash(gh issue comment:*),Bash(gh pr list:*),Bash(gh pr view:*),Bash(gh pr comment:*),Bash(gh api:*)"

# ci-watch alone gets edit + branch + PR-opening tools — it exists to FIX failures.
# ponytail: allowedTools can't scope a push to non-default branches; the prompt's hard
# rules + repo branch protection are the guard on the default branch.
CI_WATCH_EXTRA_TOOLS=",Edit,Write,Bash(git checkout:*),Bash(git switch:*),Bash(git push:*),Bash(gh pr checkout:*),Bash(gh pr create:*)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
compass schedule — manage local scheduled routines via crontab

Usage:
  compass schedule add <routine> [--daily|--weekly|--cron "<expr>"]
  compass schedule list
  compass schedule remove <routine>
  compass schedule run <routine> [DIR]
  compass schedule -h|--help

Routines: dep-refresh  flaky-triage  doc-freshness  pr-babysit  ci-watch

Schedule flags:
  --daily             0 6 * * *   (daily at 06:00)
  --weekly            0 6 * * 1   (Mondays at 06:00)  [default]
  --cron "<expr>"     custom 5-field cron expression

The cron job invokes:
  ~/compass/bin/compass schedule run <routine>
and appends output to ~/.compass/schedule.log.

Spend is appended to ${COMPASS_HOME:-~/.compass}/spend.tsv.
EOF
}

die()  { printf 'compass-schedule: error: %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }

validate_routine() {
  local name="$1" r
  for r in $VALID_ROUTINES; do
    [ "$r" = "$name" ] && return 0
  done
  die "unknown routine '$name' (valid: $VALID_ROUTINES)"
}

prompt_file() {
  local name="$1"
  printf '%s/%s.md' "$PROMPTS_DIR" "$name"
}

# ---------------------------------------------------------------------------
# Crontab block management
# ---------------------------------------------------------------------------

# Read the current crontab (tolerate missing/empty).
read_crontab() {
  crontab -l 2>/dev/null || true
}

# Extract lines OUTSIDE the managed block.
outside_block() {
  local tab="$1"
  printf '%s\n' "$tab" | awk -v bo="$BLOCK_OPEN" -v bc="$BLOCK_CLOSE" '
    $0 == bo { skip=1; next }
    $0 == bc { skip=0; next }
    !skip    { print }
  '
}

# Extract lines INSIDE the managed block (just the cron entries, no markers).
inside_block() {
  local tab="$1"
  printf '%s\n' "$tab" | awk -v bo="$BLOCK_OPEN" -v bc="$BLOCK_CLOSE" '
    $0 == bo { skip=1; next }
    $0 == bc { skip=0; next }
    skip     { print }
  '
}

# Rebuild and install the crontab.
install_crontab() {
  local outside="$1"   # lines outside our block
  local entries="$2"   # lines inside our block (may be empty)
  local new_tab

  # Strip trailing blank lines from outside section.
  outside="$(printf '%s' "$outside" | sed -e 's/[[:space:]]*$//')"

  if [ -n "$entries" ]; then
    # Prepend a blank line before block if outside is non-empty.
    if [ -n "$outside" ]; then
      new_tab="${outside}

${BLOCK_OPEN}
${entries}
${BLOCK_CLOSE}"
    else
      new_tab="${BLOCK_OPEN}
${entries}
${BLOCK_CLOSE}"
    fi
  else
    # No managed entries — drop the block entirely.
    new_tab="$outside"
  fi

  if [ -z "${new_tab//[[:space:]]/}" ]; then
    crontab -r 2>/dev/null || true   # nothing left to schedule — leave no stray crontab
  else
    printf '%s\n' "$new_tab" | crontab -
  fi
}

# Build a cron entry line for a given routine and cron expression.
# NOTE: $REPO_HOME and $DISPATCHER are expanded now (script author's paths).
# The cron log path uses a literal $HOME so cron expands it per-user at runtime.
make_entry() {
  local expr="$1" routine="$2"
  # shellcheck disable=SC2016  # $HOME intentionally not expanded here
  printf '%s cd "%s" && "%s" schedule run "%s" >> "$HOME/.compass/schedule.log" 2>&1  # compass:%s' \
    "$expr" "$REPO_HOME" "$DISPATCHER" "$routine" "$routine"
}

# ---------------------------------------------------------------------------
# Subcommand: add
# ---------------------------------------------------------------------------
cmd_add() {
  local routine="" cron_expr="0 6 * * 1"   # default: weekly Monday 06:00

  while [ $# -gt 0 ]; do
    case "$1" in
      --daily)  cron_expr="0 6 * * *";  shift ;;
      --weekly) cron_expr="0 6 * * 1";  shift ;;
      --cron)
        [ $# -ge 2 ] || die "--cron requires an expression argument"
        cron_expr="$2"; shift 2
        ;;
      -*)  die "unknown flag '$1'" ;;
      *)
        [ -z "$routine" ] || die "unexpected argument '$1'"
        routine="$1"; shift
        ;;
    esac
  done

  [ -n "$routine" ] || die "add requires a routine name"
  validate_routine "$routine"

  local pf; pf="$(prompt_file "$routine")"
  [ -f "$pf" ] || die "prompt file not found: $pf"

  local tab; tab="$(read_crontab)"
  local outer; outer="$(outside_block "$tab")"
  local inner; inner="$(inside_block "$tab")"

  # Remove any existing entry for this routine, then append the new one.
  inner="$(printf '%s\n' "$inner" | grep -v "# compass:${routine}$" || true)"
  local new_line; new_line="$(make_entry "$cron_expr" "$routine")"
  if [ -n "$inner" ]; then
    inner="${inner}
${new_line}"
  else
    inner="$new_line"
  fi

  install_crontab "$outer" "$inner"
  printf 'scheduled: %s  [%s]\n' "$routine" "$cron_expr"
}

# ---------------------------------------------------------------------------
# Subcommand: list
# ---------------------------------------------------------------------------
cmd_list() {
  local tab; tab="$(read_crontab)"
  local inner; inner="$(inside_block "$tab")"
  if [ -z "$inner" ]; then
    printf 'no compass-managed schedule entries\n'
  else
    printf 'compass-managed schedule:\n'
    printf '%s\n' "$inner"
  fi
}

# ---------------------------------------------------------------------------
# Subcommand: remove
# ---------------------------------------------------------------------------
cmd_remove() {
  local routine="${1:-}"
  [ -n "$routine" ] || die "remove requires a routine name"
  validate_routine "$routine"

  local tab; tab="$(read_crontab)"
  local outer; outer="$(outside_block "$tab")"
  local inner; inner="$(inside_block "$tab")"
  local new_inner; new_inner="$(printf '%s\n' "$inner" | grep -v "# compass:${routine}$" || true)"

  if [ "$inner" = "$new_inner" ]; then
    printf 'no entry found for routine: %s\n' "$routine"
    return 0
  fi

  install_crontab "$outer" "$new_inner"
  printf 'removed: %s\n' "$routine"
}

# ---------------------------------------------------------------------------
# Subcommand: run
# ---------------------------------------------------------------------------
cmd_run() {
  local routine="${1:-}" dir="${2:-.}"

  [ -n "$routine" ] || die "run requires a routine name"
  validate_routine "$routine"

  local pf; pf="$(prompt_file "$routine")"
  [ -f "$pf" ] || die "prompt file not found: $pf"

  command -v claude >/dev/null 2>&1 || die "'claude' not found on PATH"

  # Resolve directory.
  [ -d "$dir" ] || die "directory not found: $dir"
  dir="$(cd "$dir" && pwd)"

  printf 'compass-schedule: running routine "%s" in %s\n' "$routine" "$dir"

  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Run claude — BOUNDED. This is unattended on a cron, so cap turns + budget and
  # wrap in `timeout`; a runaway/hung routine must not spin unbounded cost or wall-clock.
  # Capture the exit code (|| rc=...) so a failure/cap still logs partial spend below
  # instead of aborting under set -e.
  local maxturns="${COMPASS_ROUTINE_MAX_TURNS:-30}" budget="${COMPASS_ROUTINE_BUDGET:-1.00}"
  local tmo="${COMPASS_ROUTINE_TIMEOUT:-30m}" rc=0 out
  local tools="$ALLOWED_TOOLS"
  [ "$routine" = "ci-watch" ] && tools="${ALLOWED_TOOLS}${CI_WATCH_EXTRA_TOOLS}"
  out="$(
    cd "$dir" || exit 1
    if command -v timeout >/dev/null 2>&1; then to() { timeout "$tmo" "$@"; }; else to() { "$@"; }; fi
    to claude -p "$(cat "$pf")" \
      --model sonnet \
      --permission-mode acceptEdits \
      --max-turns "$maxturns" \
      --max-budget-usd "$budget" \
      --output-format json \
      --allowedTools "$tools"
  )" || rc=$?
  [ "$rc" -ne 0 ] && printf 'compass-schedule: claude exited %s (turn/budget cap, timeout, or error) — recording partial spend\n' "$rc" >&2

  # Parse cost from JSON output (jq preferred, python3 fallback, else 0).
  local cost_usd="0"
  if command -v jq >/dev/null 2>&1; then
    cost_usd="$(printf '%s' "$out" | jq -r '.total_cost_usd // 0' 2>/dev/null || printf '0')"
  elif command -v python3 >/dev/null 2>&1; then
    cost_usd="$(printf '%s' "$out" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get("total_cost_usd", 0))
except Exception:
    print(0)
' 2>/dev/null || printf '0')"
  fi

  # Append to spend ledger.
  mkdir -p "$COMPASS_HOME"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$ts" \
    "$(basename "$dir")" \
    "routine:${routine}" \
    "sonnet" \
    "$cost_usd" \
    >> "$SPEND_LEDGER"

  # Print the agent result to stdout.
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$out" | jq -r '.result // ""' 2>/dev/null || printf '%s\n' "$out"
  else
    printf '%s\n' "$out"
  fi

  note "spend: \$${cost_usd}  (logged to ${SPEND_LEDGER})"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
CMD="${1:-}"
[ $# -gt 0 ] && shift

case "$CMD" in
  add)       cmd_add    "$@" ;;
  list)      cmd_list   "$@" ;;
  remove)    cmd_remove "$@" ;;
  run)       cmd_run    "$@" ;;
  -h|--help) usage ;;
  "")        usage; exit 1 ;;
  *)         die "unknown subcommand '$CMD' (try --help)" ;;
esac
