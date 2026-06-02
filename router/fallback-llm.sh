#!/usr/bin/env bash
# fallback-llm.sh — escalation fallback: classify an AMBIGUOUS task into a tier with a small
# LLM (Claude Haiku). The heuristic handles the confident majority; this is the smart call
# for the low-confidence middle (where keyword routing under-serves — e.g. plain-language
# high-stakes prompts). Reads the task on STDIN, prints exactly one tier.
#
# Wire it (opt-in — default routing makes NO network calls):
#   route.sh --escalate-below 75 --fallback "/abs/path/router/fallback-llm.sh" "<task>"
# or persist it in router.local.json: {"escalation":{"threshold":75,"fallback":"…fallback-llm.sh"}}
#
# Provider: the `claude` CLI if present, else the Anthropic API (needs ANTHROPIC_API_KEY).
# It is FAIL-SAFE: any error, missing provider, or unrecognized output → prints the spec
# default tier, so it can never block or break routing. Tier names come from router.json.
#
# Test seam: set ROUTER_FALLBACK_STUB to canned model output to exercise parsing offline.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC="${COMPASS_ROUTER_SPEC:-$HERE/router.json}"
TASK="$(cat)"

default="$(jq -r '.default // "sonnet"' "$SPEC" 2>/dev/null || echo sonnet)"
tiernames="$(jq -r '.tiers | keys_unsorted | join("|")' "$SPEC" 2>/dev/null || echo 'haiku|sonnet|opus')"
tierdesc="$(jq -r '.tiers | to_entries[] | "- \(.key): \(.value.use)"' "$SPEC" 2>/dev/null || echo '')"
model="$(jq -r '.tiers.haiku.model // "claude-haiku-4-5"' "$SPEC" 2>/dev/null || echo claude-haiku-4-5)"

PROMPT="You are a model-tier router. Choose the CHEAPEST tier that can do the task WELL.
Tiers (cheapest first):
$tierdesc
Reply with EXACTLY one lowercase word — one of: $tiernames. No punctuation, no explanation.

Task: $TASK"

raw=""
if [ -n "${ROUTER_FALLBACK_STUB+x}" ]; then
  raw="$ROUTER_FALLBACK_STUB"                                   # test seam: skip the real call
elif command -v claude >/dev/null 2>&1; then
  raw="$(printf '%s' "$PROMPT" | claude -p --model haiku --max-turns 1 2>/dev/null || true)"
elif [ -n "${ANTHROPIC_API_KEY:-}" ] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  body="$(jq -n --arg m "$model" --arg p "$PROMPT" '{model:$m, max_tokens:8, temperature:0, messages:[{role:"user",content:$p}]}')"
  resp="$(curl -sS https://api.anthropic.com/v1/messages \
           -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
           -d "$body" 2>/dev/null || true)"
  raw="$(printf '%s' "$resp" | jq -r '.content[0].text // empty' 2>/dev/null || true)"
fi

# Extract the first recognized tier from the model output; fall back to the spec default.
pick="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | grep -oE -- "$tiernames" | head -1 || true)"
[ -n "$pick" ] && printf '%s\n' "$pick" || printf '%s\n' "$default"
