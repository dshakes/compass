#!/usr/bin/env bash
# fallback-cascade.sh — the "both" fallback: try the free local classifier first; if it
# ABSTAINS (off / no model / not confident), fall through to the Haiku LLM judge. This is
# the full progression in one hook: heuristic (route.sh) -> classifier -> LLM.
# Reads the task on STDIN, prints one tier. Wire as:
#   route.sh --escalate-below 75 --fallback "/abs/path/router/fallback-cascade.sh" "<task>"
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK="$(cat)"
tier="$(printf '%s' "$TASK" | "$HERE/classify.sh" 2>/dev/null || true)"
if [ -n "$tier" ]; then
  printf '%s\n' "$tier"                       # classifier was confident (free + fast)
else
  printf '%s' "$TASK" | "$HERE/fallback-llm.sh"   # ambiguous for the classifier too -> LLM judge
fi
