#!/usr/bin/env bash
# bench-live.sh — measure the REAL lift from the Haiku fallback: it spends tokens and is
# NON-deterministic, so it is NOT in CI. Run it by hand to decide whether the cascade pays.
#
#   bench-live.sh [escalate-below]   # default threshold 75 (escalates the no-keyword middle)
#
# Shows the adversarial split (where keyword routing under-serves) BEFORE vs WITH the fallback,
# so you see the accuracy/underserve lift AND the cost it adds (every escalated task = 1 Haiku
# call). Needs the `claude` CLI or ANTHROPIC_API_KEY; skips (exit 77) otherwise.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THRESH="${1:-75}"

if ! command -v claude >/dev/null 2>&1 && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "bench-live: needs the claude CLI or ANTHROPIC_API_KEY — skipping (this is the token-spending, non-CI bench)"; exit 77
fi

printf '\033[1mLIVE router bench\033[0m  — Haiku fallback, escalate-below %s  (spends tokens)\n' "$THRESH"
echo
echo "── baseline: deterministic only ──"
bash "$HERE/bench.sh" 2>/dev/null | sed -n '/^.adversarial/,/efficiency/p'
echo
echo "── with Haiku fallback on the ambiguous middle ──"
bash "$HERE/bench.sh" --route-args "--escalate-below $THRESH --fallback $HERE/fallback-llm.sh" 2>/dev/null \
  | sed -n '/^.adversarial/,/efficiency/p'
echo
echo "Read the adversarial accuracy / underserve delta against the extra Haiku calls (one per"
echo "escalated task). If the under-serve drop is worth the calls, persist it in router.local.json."
