#!/usr/bin/env bash
# test-ci-watch.sh — the CI auto-fix feature's eval.
#
# Asserts the pieces that make "no CI failure goes unhandled" safe to ship:
#   1. ci-watch is a registered routine with a prompt file on disk.
#   2. The prompt carries the hard safety rails (never merge / never push default).
#   3. ci-watch — and ONLY ci-watch — gets the widened edit/push/PR toolset.
#   4. The sdlc-ci-fix workflow has its dogfood copy in sync and keeps its own
#      rails: kill switch, self-guard, round-cap-aware skip labels, flake rerun.
#
# Runs in CI. Mirrors the style of scripts/test-budget-gate.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHED="$ROOT/scripts/compass-schedule.sh"
PROMPT="$ROOT/sdlc/routines/prompts/ci-watch.md"
WF="$ROOT/sdlc/workflows/sdlc-ci-fix.yml"

pass=0; fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

echo "routine registration:"
if bash -c "source /dev/stdin <<<\"\$(sed -n '/^VALID_ROUTINES=/p' '$SCHED')\"; case \" \$VALID_ROUTINES \" in *' ci-watch '*) exit 0;; *) exit 1;; esac"; then
  ok "ci-watch ∈ VALID_ROUTINES"
else
  no "ci-watch missing from VALID_ROUTINES in compass-schedule.sh"
fi
[ -f "$PROMPT" ] && ok "prompt file exists: sdlc/routines/prompts/ci-watch.md" \
                 || no "prompt file missing: $PROMPT"
reject_out="$(bash "$SCHED" run no-such-routine 2>&1 || true)"
if printf '%s' "$reject_out" | grep -q "unknown routine"; then
  ok "unknown routine is rejected"
else
  no "unknown routine was not rejected"
fi

echo "prompt safety rails:"
for rail in "NEVER push to the default branch" "NEVER merge" "NEVER force-push" \
            "untrusted" "Flaky"; do
  grep -qi "$rail" "$PROMPT" && ok "prompt: '$rail'" || no "prompt lost its rail: '$rail'"
done

echo "tool widening is ci-watch-only:"
# The widened tools must come from CI_WATCH_EXTRA_TOOLS, gated on routine name —
# never be baked into the base ALLOWED_TOOLS every routine gets.
base_tools="$(sed -n 's/^ALLOWED_TOOLS="\(.*\)"$/\1/p' "$SCHED")"
extra_tools="$(sed -n 's/^CI_WATCH_EXTRA_TOOLS="\(.*\)"$/\1/p' "$SCHED")"
for t in "git push" "gh pr create" "Edit"; do
  case "$base_tools" in *"$t"*) no "base ALLOWED_TOOLS leaks '$t' to every routine" ;; \
                        *) ok "base tools do not include '$t'" ;; esac
done
case "$extra_tools" in *"git push"*) ok "CI_WATCH_EXTRA_TOOLS grants push (to ci-watch only)" ;; \
                       *) no "CI_WATCH_EXTRA_TOOLS missing git push" ;; esac
grep -q 'routine" = "ci-watch" ] && tools=' "$SCHED" \
  && ok "widening is gated on routine == ci-watch" \
  || no "widening gate not found in cmd_run"

echo "workflow rails:"
if diff -q "$WF" "$ROOT/.github/workflows/sdlc-ci-fix.yml" >/dev/null 2>&1; then
  ok "dogfood copy in sync"
else
  no "DRIFT: .github/workflows/sdlc-ci-fix.yml != sdlc/workflows/sdlc-ci-fix.yml"
fi
for rail in "SDLC_CI_FIX != 'off'" 'sdlc ·"\*)' "sdlc:needs-human" "gh run rerun" "ci-fix/"; do
  grep -qF "${rail//\\/}" "$WF" && ok "workflow: ${rail//\\/}" || no "workflow lost its rail: ${rail//\\/}"
done
grep -q "check_suite" "$WF" && ok "workflow: check_suite trigger" || no "workflow: trigger changed"

echo
printf 'ci-watch eval: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
