#!/usr/bin/env bash
# test-guardrail-remote.sh — contract tests for the optional managed-guardrail adapters.
# It exercises the RESPONSE-PARSING (_gr_verdict) against fixtures shaped like each
# service's real API output, so the parse logic is verified. It does NOT call the live
# services (that needs your AWS/Azure creds) — see docs/17 for that honest boundary.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/claude/hooks/lib/common.sh"
. "$ROOT/claude/hooks/lib/guardrail-remote.sh"

pass=0; fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
blk()  { [ "$(_gr_verdict "$1" "$2")" = BLOCK ] && ok "$1 BLOCK: $3" || no "$1 should BLOCK: $3"; }
none() { [ -z "$(_gr_verdict "$1" "$2")" ] && ok "$1 allow: $3" || no "$1 should allow: $3"; }

echo "bedrock (ApplyGuardrail) response shapes:"
blk  bedrock '{"action":"GUARDRAIL_INTERVENED","outputs":[{"text":"blocked"}]}'      "intervened"
none bedrock '{"action":"NONE","outputs":[]}'                                         "clean"

echo "azure (Prompt Shields) response shapes:"
blk  azure '{"userPromptAnalysis":{"attackDetected":true}}'                           "attack detected"
blk  azure '{"userPromptAnalysis":{"attackDetected": true}}'                          "attack detected (spaced)"
none azure '{"userPromptAnalysis":{"attackDetected":false}}'                          "clean"

echo "webhook (neutral) response shapes:"
blk  webhook '{"action":"BLOCK","reason":"injection"}'                                "block"
blk  webhook '{"action": "BLOCK"}'                                                    "block (spaced)"
none webhook '{"action":"NONE"}'                                                      "allow"

echo "backend dispatch + fail-safe:"
COMPASS_GUARDRAIL_BACKEND=none none_out="$(remote_guardrail_action prompt 'x')"; [ -z "${none_out:-}" ] && ok "backend=none is a no-op" || no "backend=none should no-op"

echo
printf 'guardrail-remote contract: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
