#!/usr/bin/env bash
# run.sh — the flagship "safe autonomy" walkthrough: an autonomous loop you can
# actually walk away from. Four beats:
#
#   1. A goal-gated loop starts on a small fixture task.
#   2. Mid-loop the agent reaches for something dangerous → the guardrail hook
#      BLOCKS it, visibly, before it can run.
#   3. Spend climbs; the budget gate HALTS the loop at the cap.
#   4. The loop converges — and the human merge gate is the explicit last step.
#      Nothing auto-merges.
#
# What's real vs. narrated:
#   - The guardrail (beat 2) and budget ceiling (beat 3) drive the REAL compass
#     hooks (claude/hooks/protect-paths.sh, budget-gate.sh) with real JSON on
#     stdin. The BLOCKED / HALTED lines you see are those hooks actually firing —
#     not a mockup. The deny reasons printed are the hooks' own words.
#   - The loop turns (plan / build / review) are narrated in place of live model
#     calls, so the demo is deterministic, offline, and safe to run in CI. A live
#     run would swap the narration for `claude -p` turns; the guards are identical.
#
# Non-destructive: all git work happens in a throwaway repo under a mktemp dir,
# removed on exit. No network. No real model calls. Nothing outside the temp dir
# is touched.
#
# Usage:
#   ./run.sh          full pacing, for watching / recording
#   ./run.sh --mock   zero-pause, deterministic — the CI path
set -euo pipefail

# --- locate the repo + the real hooks, relative to this script ---------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD_HOOK="$REPO_ROOT/claude/hooks/protect-paths.sh"
BUDGET_HOOK="$REPO_ROOT/claude/hooks/budget-gate.sh"

for h in "$GUARD_HOOK" "$BUDGET_HOOK"; do
  [ -x "$h" ] || { echo "error: hook not found or not executable: $h" >&2; exit 1; }
done

# --- flags -------------------------------------------------------------------
MOCK=0
for arg in "$@"; do
  case "$arg" in
    --mock) MOCK=1 ;;
    -h|--help) sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $arg (try --help)" >&2; exit 1 ;;
  esac
done

# --- colors (honor NO_COLOR / non-tty) ---------------------------------------
if [ -n "${NO_COLOR:-}" ] || { [ "$MOCK" -eq 0 ] && [ ! -t 1 ]; }; then
  R=''; G=''; Y=''; D=''; B=''; X=''
else
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'
  D=$'\033[90m'; B=$'\033[1m'; X=$'\033[0m'
fi

pause() { [ "$MOCK" -eq 1 ] && return 0; sleep "${1:-0.8}"; }
rule()  { printf "%b%s%b\n" "$D" "────────────────────────────────────────────────────────────" "$X"; }
say()   { printf "%b%s%b\n" "$D" "$1" "$X"; }

# --- throwaway sandbox: a real git repo + a throwaway COMPASS_HOME ------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/compass-safe-autonomy.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

REPO="$TMP/fixture"                       # the (buggy) fixture the loop works on
HOME_DIR="$TMP/compass-home"              # where the budget gate reads spend from
mkdir -p "$REPO" "$HOME_DIR/sessions"
git -c init.defaultBranch=main init -q "$REPO"
git -C "$REPO" -c user.email=demo@compass -c user.name=demo commit -q --allow-empty -m "seed"

# --- drive the REAL guardrail hook; print BLOCKED + its own deny reason -------
reason() {  # extract permissionDecisionReason from single-line hook JSON
  jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null \
    || python3 -c 'import sys,json;print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])' 2>/dev/null \
    || sed -E 's/.*"permissionDecisionReason":"([^"]*)".*/\1/'
}

guard() {  # guard '<pretty label>' '<hook-json>'  -> real BLOCKED/allowed + reason
  local label="$1" json="$2" out rc
  out="$(printf '%s' "$json" | "$GUARD_HOOK" 2>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" -eq 2 ]; then
    printf "    %b%-34s%b %b● BLOCKED%b\n" "$B" "$label" "$X" "$R$B" "$X"
    printf "      %b↳ %s%b\n" "$R" "$(printf '%s' "$out" | reason)" "$X"
  else
    printf "    %b%-34s%b %b● allowed%b\n" "$B" "$label" "$X" "$G" "$X"
  fi
}

# --- drive the REAL budget hook against the throwaway COMPASS_HOME ------------
budget() {  # budget <usd-spent> <cap> <turn-label> -> real running/HALTED + reason
  local usd="$1" cap="$2" turn="$3" sid="loop" out rc spent
  printf '%s' "$usd" >"$HOME_DIR/sessions/$sid.cost"
  spent="$(awk -v c="$usd" 'BEGIN{printf "%.2f", c}')"
  out="$(printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"x"}}' "$sid" \
        | COMPASS_HOME="$HOME_DIR" COMPASS_MAX_USD="$cap" "$BUDGET_HOOK" 2>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" -eq 2 ]; then
    printf "    %-22s %b\$%s%b / \$%s cap   %b● HALTED%b\n" "$turn" "$B" "$spent" "$X" "$cap" "$R$B" "$X"
    printf "      %b↳ %s%b\n" "$R" "$(printf '%s' "$out" | reason)" "$X"
    return 2
  fi
  printf "    %-22s %b\$%s%b / \$%s cap   %b● running%b\n" "$turn" "$B" "$spent" "$X" "$cap" "$G" "$X"
}

# ============================================================================
printf "\n%bcompass · safe autonomy%b   %ban autonomous loop you can walk away from%b\n" "$B" "$X" "$D" "$X"
rule

# --- BEAT 1 : a goal-gated loop starts on a fixture task ---------------------
printf "\n%b1 · GOAL-GATED LOOP%b\n" "$B$Y" "$X"
say   "  task     fix the failing Subtract() test in the fixture repo"
say   "  goal     stop condition = tests green AND a fresh judge signs off"
say   "  guards   \$0.40 spend cap · protected paths · human owns merge"
pause
printf "  %b↻ loop start%b  %b(you close the laptop here)%b\n" "$G$B" "$X" "$D" "$X"
pause 0.6
printf "    turn 1  plan    %b● ok%b    root-cause: Subtract returns a+b\n"      "$G" "$X"
pause 0.5
printf "    turn 1  build   %b● ok%b    patch on feature branch fix/subtract\n"  "$G" "$X"
git -C "$REPO" checkout -q -b fix/subtract
pause 0.5
printf "    turn 1  review  %b● fail%b  BLOCKING — no regression test\n"         "$R" "$X"
pause 0.5
printf "    turn 2  build   %b● ok%b    adds table test, re-runs\n"              "$G" "$X"
pause

# --- BEAT 2 : mid-loop, a dangerous action is BLOCKED (real hook) -----------
printf "\n%b2 · THE GUARDRAIL HOLDS%b  %bmid-loop, the agent reaches past the line%b\n" "$B$Y" "$X" "$D" "$X"
say   "  these run against the REAL protect-paths.sh hook — the deny is live:"
pause 0.4
guard "git push --force origin main"      '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'
pause 0.5
guard "write ~/.aws/credentials"          '{"tool_name":"Write","tool_input":{"file_path":"/home/dev/.aws/credentials","content":"x"}}'
pause 0.5
guard "write .env (secret)"               '{"tool_name":"Write","tool_input":{"file_path":".env","content":"KEY=x"}}'
pause 0.4
printf "  %b→ blocked before execution. the loop stays on its feature branch.%b\n" "$D" "$X"
pause

# --- BEAT 3 : the budget gate caps spend (real hook) ------------------------
printf "\n%b3 · THE BUDGET GATE CAPS SPEND%b  %breal budget-gate.sh, \$0.40 cap%b\n" "$B$Y" "$X" "$D" "$X"
pause 0.4
budget 0.12 0.40 "turn 3  review"  || true
pause 0.5
budget 0.28 0.40 "turn 4  build"   || true
pause 0.5
budget 0.41 0.40 "turn 5  next"    || true
pause 0.4
printf "  %b→ the loop stops itself at the ceiling. no runaway spend overnight.%b\n" "$D" "$X"
pause

# --- BEAT 4 : converge → the human merge gate is the last step --------------
printf "\n%b4 · CONVERGE → HUMAN MERGE GATE%b\n" "$B$Y" "$X"
say   "  (cap raised for the demo; the loop finishes the fix)"
pause 0.5
printf "    turn 6  build   %b● ok%b    Subtract returns a-b\n"                  "$G" "$X"
pause 0.4
printf "    turn 6  qa      %b● ok%b    TestSubtract green\n"                    "$G" "$X"
pause 0.4
printf "    turn 6  judge   %b● CLEAN%b goal met — fresh judge signs off\n"      "$G$B" "$X"
pause 0.6
printf "  %b↳ loop hands you a PR on fix/subtract and stops.%b\n" "$D" "$X"
printf "  %b✓ you merge%b   %b— nothing auto-merges. humans own merge & deploy, always.%b\n" "$G$B" "$X" "$D" "$X"
rule
printf "%bwalked away at beat 1. the guards did the sitting-there.%b\n\n" "$D" "$X"
