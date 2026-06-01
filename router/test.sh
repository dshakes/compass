#!/usr/bin/env bash
# test.sh — unit tests for the router module. Deterministic, no network, no model calls.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }

echo "spec is valid JSON + shape:"
jq -e '.version and .default and (.tiers|type=="object") and (.rules|type=="array")' "$HERE/router.json" >/dev/null \
  && ok "router.json well-formed" || no "router.json malformed"

echo "route.sh — tier decisions:"
eq "trivial → haiku"   "$(bash "$HERE/route.sh" 'fix a typo in the readme')"            haiku
eq "lint (\\b word-boundary) → haiku" "$(bash "$HERE/route.sh" 'fix the lint warnings')" haiku
eq "feature → sonnet"  "$(bash "$HERE/route.sh" 'add a rate limiter with tests')"        sonnet
eq "default → sonnet"  "$(bash "$HERE/route.sh" 'do the thing')"                          sonnet
eq "security → opus"   "$(bash "$HERE/route.sh" 'redesign the auth trust model')"         opus
eq "tenant → opus"     "$(bash "$HERE/route.sh" 'fix the cross-tenant data leak')"        opus

echo "route.sh — interface:"
bash "$HERE/route.sh" --explain 'fix a typo' 2>&1 | grep -q 'route: haiku' && ok "--explain prints reason" || no "--explain"
if bash "$HERE/route.sh" '' >/dev/null 2>&1; then no "empty task should error"; else ok "empty task → exit 2"; fi
eq "spec override routes too" "$(bash "$HERE/route.sh" --spec "$HERE/router.json" 'fix a typo')" haiku

echo "bench.sh — runs + floors gate:"
if bash "$HERE/bench.sh" >/dev/null 2>&1; then ok "bench passes its floors on the real evalset"; else no "bench should pass"; fi
if ROUTER_ACC_FLOOR=101 bash "$HERE/bench.sh" >/dev/null 2>&1; then no "acc floor=101 should FAIL"; else ok "accuracy floor actually bites"; fi
if ROUTER_QUALITY_FLOOR=101 bash "$HERE/bench.sh" >/dev/null 2>&1; then no "quality floor=101 should FAIL"; else ok "quality-retained floor actually bites"; fi

echo
printf 'router module: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
