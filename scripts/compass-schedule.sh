#!/usr/bin/env bash
# compass-schedule.sh — manage local scheduled compass routines.
#
# Subcommands:
#   add <routine> [--daily|--twice-daily|--weekly|--cron "<expr>"] [--dir DIR]
#   list
#   remove <routine> [--dir DIR]
#   run <routine> [DIR]
#
# Routines: dep-refresh  flaky-triage  doc-freshness  pr-babysit  ci-watch  pr-shepherd
#
# Backend: launchd user agents on macOS (sleep-missed runs fire once on wake);
# crontab on Linux and for --cron expressions (cron skips sleep-missed slots).
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

OS="$(uname)"
DRYRUN="${COMPASS_SCHEDULE_DRYRUN:-0}"

# launchd user-agent plists live here (dry-run redirects under $COMPASS_HOME so
# tests never install real agents).
if [ "$DRYRUN" = "1" ]; then
  LAUNCH_DIR="$COMPASS_HOME/dryrun-launchagents"
  DRYRUN_CRONTAB="$COMPASS_HOME/dryrun-crontab"
else
  LAUNCH_DIR="$HOME/Library/LaunchAgents"
fi

# ---------------------------------------------------------------------------
# Valid routines (space-separated; validated by validate_routine)
# ---------------------------------------------------------------------------
VALID_ROUTINES="dep-refresh flaky-triage doc-freshness pr-babysit ci-watch pr-shepherd"

# Allowed tools for each routine's claude invocation (read + git + build/test only).
ALLOWED_TOOLS="Read,Grep,Glob,Bash(git log:*),Bash(git diff:*),Bash(git status:*),Bash(git add:*),Bash(git commit:*),Bash(go build:*),Bash(go test:*),Bash(go vet:*),Bash(cargo build:*),Bash(cargo test:*),Bash(npm:*),Bash(pnpm:*),Bash(npx tsc:*),Bash(pytest:*),Bash(ruff:*),Bash(make:*),Bash(gh run list:*),Bash(gh run view:*),Bash(gh issue list:*),Bash(gh issue view:*),Bash(gh issue create:*),Bash(gh issue comment:*),Bash(gh pr list:*),Bash(gh pr view:*),Bash(gh pr comment:*),Bash(gh api:*)"

# ci-watch alone gets edit + branch + PR-opening tools — it exists to FIX failures.
# ponytail: allowedTools can't scope a push to non-default branches; the prompt's hard
# rules + repo branch protection are the guard on the default branch.
CI_WATCH_EXTRA_TOOLS=",Edit,Write,Bash(git checkout:*),Bash(git switch:*),Bash(git push:*),Bash(gh pr checkout:*),Bash(gh pr create:*)"

# pr-shepherd is the full-authority scheduled loop: everything ci-watch has, plus
# worktrees (fix on the PR branch in isolation), check reading, label edits, and —
# uniquely — merge. Merge safety is layered: the prompt requires all checks green,
# and the branch ruleset enforces required checks server-side regardless.
PR_SHEPHERD_EXTRA_TOOLS="${CI_WATCH_EXTRA_TOOLS},Bash(git worktree:*),Bash(gh pr checks:*),Bash(gh pr diff:*),Bash(gh pr edit:*),Bash(gh pr merge --squash:*)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
compass schedule — manage local scheduled routines (launchd on macOS, crontab on Linux)

Usage:
  compass schedule add <routine> [--daily|--twice-daily|--weekly|--cron "<expr>"] [--dir DIR]
  compass schedule list
  compass schedule remove <routine> [--dir DIR]
  compass schedule run <routine> [DIR]
  compass schedule -h|--help

Routines: dep-refresh  flaky-triage  doc-freshness  pr-babysit  ci-watch  pr-shepherd

Schedule flags:
  --daily             daily at 06:00
  --twice-daily       09:07 + 17:07 (off-minute on purpose)
  --weekly            Mondays at 06:00  [default]
  --cron "<expr>"     custom 5-field cron expression (always crontab — cron only
                      fires while the machine is awake; missed slots are skipped)
  --dir DIR           repo the routine runs in (default: current directory).
                      The same routine can be scheduled for several repos; each
                      gets its own entry. `remove <routine> --dir DIR` removes
                      only that repo's entry; without --dir, all of them.

Backends:
  macOS   add writes a launchd user agent
          (~/Library/LaunchAgents/com.compass.schedule.<routine>.<dir-slug>.plist).
          launchd runs a missed StartCalendarInterval job once on wake, so
          sleep-missed slots are caught up. --cron falls back to crontab.
  Linux   crontab, managed inside the compass block markers.

The job invokes:
  cd DIR && <repo>/bin/compass schedule run <routine> DIR
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

# Filesystem-safe slug of a directory path (for launchd labels/filenames).
dir_slug() {
  printf '%s' "$1" | tr -cs 'a-zA-Z0-9' '-'
}

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# ---------------------------------------------------------------------------
# Crontab block management
# ---------------------------------------------------------------------------

# Read the current crontab (tolerate missing/empty). Dry-run reads a file.
read_crontab() {
  if [ "$DRYRUN" = "1" ]; then
    cat "$DRYRUN_CRONTAB" 2>/dev/null || true
  else
    crontab -l 2>/dev/null || true
  fi
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

# Filter OUT managed entries for a routine. $2 empty = every entry for the
# routine (dir-scoped and legacy dir-less); $2 set = only that exact dir.
# Exact fixed-string suffix match — no regex, so paths can't over-match.
strip_entries() {
  local routine="$1" dir="${2:-}"
  awk -v r="$routine" -v d="$dir" '
    {
      if (d == "") {
        if (index($0, "# compass:" r ":") > 0) next
        legacy = "# compass:" r
        if (length($0) >= length(legacy) && substr($0, length($0)-length(legacy)+1) == legacy) next
      } else {
        key = "# compass:" r ":" d
        if (length($0) >= length(key) && substr($0, length($0)-length(key)+1) == key) next
      }
      print
    }'
}

# Rebuild and install the crontab. Dry-run writes a file instead.
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

  if [ "$DRYRUN" = "1" ]; then
    if [ -z "${new_tab//[[:space:]]/}" ]; then
      rm -f "$DRYRUN_CRONTAB"
    else
      mkdir -p "$COMPASS_HOME"
      printf '%s\n' "$new_tab" > "$DRYRUN_CRONTAB"
    fi
    return 0
  fi

  if [ -z "${new_tab//[[:space:]]/}" ]; then
    crontab -r 2>/dev/null || true   # nothing left to schedule — leave no stray crontab
  else
    printf '%s\n' "$new_tab" | crontab -
  fi
}

# --- pure generators (no side effects; tests call these directly) -----------

# Build a cron entry line for a routine + cron expression + target dir.
# NOTE: $DISPATCHER is expanded now (script author's path).
# The cron log path uses a literal $HOME so cron expands it per-user at runtime.
make_entry() {
  local expr="$1" routine="$2" dir="$3"
  # shellcheck disable=SC2016  # $HOME intentionally not expanded here
  printf '%s cd "%s" && "%s" schedule run "%s" "%s" >> "$HOME/.compass/schedule.log" 2>&1  # compass:%s:%s' \
    "$expr" "$dir" "$DISPATCHER" "$routine" "$dir" "$routine" "$dir"
}

plist_label() {
  local routine="$1" dir="$2"
  printf 'com.compass.schedule.%s.%s' "$routine" "$(dir_slug "$dir")"
}

# Emit the launchd user-agent plist XML for a routine + dir + cadence.
make_plist() {
  local routine="$1" dir="$2" cadence="$3"
  local label intervals cmd
  label="$(plist_label "$routine" "$dir")"
  cmd="cd \"$dir\" && \"$DISPATCHER\" schedule run $routine \"$dir\" >> ~/.compass/schedule.log 2>&1"
  case "$cadence" in
    daily)       intervals='    <dict><key>Hour</key><integer>6</integer><key>Minute</key><integer>0</integer></dict>' ;;
    twice-daily) intervals='    <dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>7</integer></dict>
    <dict><key>Hour</key><integer>17</integer><key>Minute</key><integer>7</integer></dict>' ;;
    weekly)      intervals='    <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>6</integer><key>Minute</key><integer>0</integer></dict>' ;;
    *) die "no launchd mapping for cadence '$cadence'" ;;
  esac
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>bash</string>
    <string>-lc</string>
    <string>$(xml_escape "$cmd")</string>
  </array>
  <key>StartCalendarInterval</key>
  <array>
${intervals}
  </array>
  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
EOF
}

# --- launchd install/remove (no-ops under dry-run) --------------------------

launchd_bootstrap() {
  [ "$DRYRUN" = "1" ] && return 0
  launchctl bootout "gui/$(id -u)" "$1" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$1" >/dev/null 2>&1 \
    || launchctl load "$1" >/dev/null 2>&1 || true
}

launchd_remove() {
  if [ "$DRYRUN" != "1" ]; then
    launchctl bootout "gui/$(id -u)" "$1" >/dev/null 2>&1 || true
  fi
  rm -f "$1"
}

# ---------------------------------------------------------------------------
# Subcommand: add
# ---------------------------------------------------------------------------
cmd_add() {
  local routine="" cadence="weekly" cron_expr="0 6 * * 1" dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --daily)  cadence="daily";  cron_expr="0 6 * * *";  shift ;;
      --twice-daily) cadence="twice-daily"; cron_expr="7 9,17 * * *"; shift ;;   # off-minute on purpose (thundering-herd kindness)
      --weekly) cadence="weekly"; cron_expr="0 6 * * 1";  shift ;;
      --cron)
        [ $# -ge 2 ] || die "--cron requires an expression argument"
        cadence="cron"; cron_expr="$2"; shift 2
        ;;
      --dir)
        [ $# -ge 2 ] || die "--dir requires a directory argument"
        dir="$2"; shift 2
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

  # Resolve target dir (default: where the user ran `add`), absolute.
  [ -n "$dir" ] || dir="$PWD"
  [ -d "$dir" ] || die "directory not found: $dir"
  dir="$(cd "$dir" && pwd)"

  if [ "$OS" = "Darwin" ] && [ "$cadence" != "cron" ]; then
    # launchd user agent — unlike cron, launchd runs a missed
    # StartCalendarInterval job once on wake, so sleep doesn't drop runs.
    mkdir -p "$LAUNCH_DIR"
    local label plist
    label="$(plist_label "$routine" "$dir")"
    plist="$LAUNCH_DIR/$label.plist"
    make_plist "$routine" "$dir" "$cadence" > "$plist"
    launchd_bootstrap "$plist"
    # Drop any crontab entry for the same routine+dir (e.g. from an earlier --cron add).
    local tab outer inner
    tab="$(read_crontab)"
    outer="$(outside_block "$tab")"
    inner="$(inside_block "$tab" | strip_entries "$routine" "$dir")"
    install_crontab "$outer" "$inner"
    printf 'scheduled (launchd): %s  [%s]  %s\n' "$routine" "$cadence" "$dir"
    note "agent: $plist"
    note "launchd runs a missed StartCalendarInterval job once on wake — sleep-missed slots are caught up."
    return 0
  fi

  if [ "$OS" = "Darwin" ]; then
    printf 'warning: --cron uses crontab — cron skips sleep-missed slots (they are not caught up on wake)\n' >&2
    # Drop any launchd agent for the same routine+dir so the two backends don't double-fire.
    local old_plist
    old_plist="$LAUNCH_DIR/$(plist_label "$routine" "$dir").plist"
    [ -f "$old_plist" ] && launchd_remove "$old_plist"
  fi

  local tab; tab="$(read_crontab)"
  local outer; outer="$(outside_block "$tab")"
  local inner; inner="$(inside_block "$tab")"

  # Remove any existing entry for this routine+dir, then append the new one.
  inner="$(printf '%s\n' "$inner" | strip_entries "$routine" "$dir")"
  local new_line; new_line="$(make_entry "$cron_expr" "$routine" "$dir")"
  if [ -n "$inner" ]; then
    inner="${inner}
${new_line}"
  else
    inner="$new_line"
  fi

  install_crontab "$outer" "$inner"
  printf 'scheduled (cron): %s  [%s]  %s\n' "$routine" "$cron_expr" "$dir"
}

# ---------------------------------------------------------------------------
# Subcommand: list
# ---------------------------------------------------------------------------
cmd_list() {
  local found=0
  local tab; tab="$(read_crontab)"
  local inner; inner="$(inside_block "$tab")"
  if [ -n "$inner" ]; then
    found=1
    printf 'compass-managed schedule (crontab):\n'
    printf '%s\n' "$inner"
  fi

  if [ "$OS" = "Darwin" ] && [ -d "$LAUNCH_DIR" ]; then
    local f label dir sched header=0
    for f in "$LAUNCH_DIR"/com.compass.schedule.*.plist; do
      [ -f "$f" ] || continue
      found=1
      [ "$header" = 1 ] || { printf 'compass-managed schedule (launchd):\n'; header=1; }
      label="$(basename "$f" .plist)"
      dir="$(sed -n 's/.*cd &quot;\([^&]*\)&quot;.*/\1/p; s/.*cd "\([^"]*\)".*/\1/p' "$f" | head -1)"
      sched="$(grep -o '<dict>.*</dict>' "$f" | sed -e 's/<[^>]*>/ /g' -e 's/   */ /g' -e 's/^ //' -e 's/ $//' | tr '\n' ';' | sed 's/;$//')"
      printf '%s  [%s]  %s\n' "$label" "$sched" "$dir"
    done
  fi

  [ "$found" = 1 ] || printf 'no compass-managed schedule entries\n'
}

# ---------------------------------------------------------------------------
# Subcommand: remove
# ---------------------------------------------------------------------------
cmd_remove() {
  local routine="" dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)
        [ $# -ge 2 ] || die "--dir requires a directory argument"
        dir="$2"; shift 2
        ;;
      -*)  die "unknown flag '$1'" ;;
      *)
        [ -z "$routine" ] || die "unexpected argument '$1'"
        routine="$1"; shift
        ;;
    esac
  done
  [ -n "$routine" ] || die "remove requires a routine name"
  validate_routine "$routine"
  # Resolve like add did, so the key matches (tolerate a since-deleted dir).
  if [ -n "$dir" ] && [ -d "$dir" ]; then dir="$(cd "$dir" && pwd)"; fi

  local removed=0

  # crontab entries
  local tab; tab="$(read_crontab)"
  local outer; outer="$(outside_block "$tab")"
  local inner; inner="$(inside_block "$tab")"
  local new_inner; new_inner="$(printf '%s\n' "$inner" | strip_entries "$routine" "$dir")"
  if [ "$inner" != "$new_inner" ]; then
    install_crontab "$outer" "$new_inner"
    printf 'removed (cron): %s%s\n' "$routine" "${dir:+  $dir}"
    removed=1
  fi

  # launchd agents (darwin)
  if [ "$OS" = "Darwin" ] && [ -d "$LAUNCH_DIR" ]; then
    local f
    if [ -n "$dir" ]; then
      f="$LAUNCH_DIR/$(plist_label "$routine" "$dir").plist"
      if [ -f "$f" ]; then
        launchd_remove "$f"
        printf 'removed (launchd): %s  %s\n' "$routine" "$dir"
        removed=1
      fi
    else
      for f in "$LAUNCH_DIR/com.compass.schedule.$routine".*.plist; do
        [ -f "$f" ] || continue
        launchd_remove "$f"
        printf 'removed (launchd): %s\n' "$(basename "$f" .plist)"
        removed=1
      done
    fi
  fi

  if [ "$removed" = 0 ]; then
    printf 'no entry found for routine: %s%s\n' "$routine" "${dir:+ (dir: $dir)}"
    return 0
  fi
  [ -z "$dir" ] && note "no --dir given — removed ALL entries for '$routine' (use --dir DIR to remove just one repo's)"
  return 0
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
  if [ "$routine" = "pr-shepherd" ]; then
    # Compose WITHOUT the base list's Bash(gh api:*): with merge authority granted,
    # gh api is an escape hatch to the merge/ref REST endpoints that would defeat
    # the squash-only enforcement below (audit finding on #83).
    tools="${ALLOWED_TOOLS/,Bash(gh api:*)/}${PR_SHEPHERD_EXTRA_TOOLS}"
    # Fixing + testing + merging needs more room than a comment-only routine.
    maxturns="${COMPASS_ROUTINE_MAX_TURNS:-60}" budget="${COMPASS_ROUTINE_BUDGET:-3.00}" tmo="${COMPASS_ROUTINE_TIMEOUT:-45m}"
  fi
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
# Entry point (skipped when sourced — tests call the pure generators directly)
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
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
fi
