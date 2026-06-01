#!/usr/bin/env bash
# test.sh — unit tests for the router module (v1.1). Deterministic, no network, no model calls.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
R() { bash "$HERE/route.sh" "$@"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "spec + defaults (parity with v1.0):"
jq -e '.version and .default and (.tiers|type=="object") and (.rules|type=="array")' "$HERE/router.json" >/dev/null && ok "router.json well-formed" || no "router.json malformed"
eq "trivial → haiku"   "$(R 'fix a typo in the readme')"        haiku
eq "lint \\b → haiku"  "$(R 'fix the lint warnings')"           haiku
eq "feature → sonnet"  "$(R 'add a rate limiter with tests')"   sonnet
eq "default → sonnet"  "$(R 'do the thing')"                     sonnet
eq "security → opus"   "$(R 'redesign the auth trust model')"    opus

echo "clamps:"
eq "ceiling caps opus→sonnet"  "$(R --ceiling sonnet 'redesign the auth trust model')" sonnet
eq "floor lifts haiku→sonnet"  "$(R --floor sonnet 'fix a typo')"                       sonnet
eq "allow snaps sonnet→haiku"  "$(R --allow haiku,opus 'add a rate limiter with tests')" haiku

echo "bias (weak 'update it', confidence<55):"
eq "balanced keeps sonnet" "$(R 'update it')"               sonnet
eq "cheap → haiku"         "$(R --bias cheap 'update it')"   haiku
eq "quality → opus"        "$(R --bias quality 'update it')" opus
eq "bias leaves CONFIDENT picks alone" "$(R --bias cheap 'redesign the auth trust model')" opus

echo "escalation (cascade):"
eq "bump weak below 60"        "$(R --escalate-below 60 'update it')" opus
eq "fallback stub wins"        "$(R --escalate-below 60 --fallback 'cat>/dev/null;echo haiku' 'update it')" haiku
eq "no escalation when confident" "$(R --escalate-below 60 'redesign the auth trust model')" opus

echo "strategy max-hits (task matching BOTH opus + haiku; haiku has more hits):"
eq "first-match → opus" "$(R 'rename the typo in the auth comment')"               opus
eq "max-hits  → haiku"  "$(R --strategy max-hits 'rename the typo in the auth comment')" haiku

echo "unless exclusion (custom spec):"
jq '.rules = [{"tier":"opus","pattern":"auth","reason":"x","unless":"typo"},{"tier":"haiku","pattern":"typo","reason":"y"}]' "$HERE/router.json" > "$TMP/unless.json"
eq "auth alone → opus"          "$(R --spec "$TMP/unless.json" 'fix the auth flow')" opus
eq "auth+typo vetoes opus→haiku" "$(R --spec "$TMP/unless.json" 'fix the auth typo')" haiku

echo "length rule (long 'comment' task lifted haiku→sonnet):"
LONG="add a comment to the parser module explaining in detail how it handles each one of the seventeen distinct token kinds and why the lookahead window is strictly bounded and what exactly happens on malformed or truncated input near the very end of a long source line"
eq "short comment → haiku" "$(R 'add a comment')"  haiku
eq "long comment → sonnet" "$(R "$LONG")"          sonnet

echo "profiles (cost/model override):"
eq "default haiku cost"  "$(R --json 'fix a typo' | jq -r .cost)"                 1
eq "local haiku cost 0"  "$(R --json --profile local 'fix a typo' | jq -r .cost)" 0

echo "local overlay (prepended rule wins):"
printf '{"rules":[{"tier":"opus","pattern":"deploy","reason":"overlay"}]}\n' > "$TMP/router.local.json"
eq "base: deploy → sonnet"      "$(R 'deploy the service')" sonnet
eq "overlay: deploy → opus"     "$(R --local "$TMP/router.local.json" 'deploy the service')" opus

echo "output shapes:"
R --json 'fix the cross-tenant data leak' | jq -e '.tier=="opus" and (.confidence|type=="number") and .model and (.cost|type=="number")' >/dev/null && ok "--json shape" || no "--json shape"
eq "--score appends confidence" "$(R --score 'fix a typo' | cut -f1)" haiku
eq "--domain second axis"       "$(R --domain 'deploy the helm chart to the cluster' | cut -f2)" infra
if R '' >/dev/null 2>&1; then no "empty task should error"; else ok "empty task → exit 2"; fi

echo "telemetry (--log):"
R --log "$TMP/audit.tsv" 'fix a typo' >/dev/null
grep -q 'haiku' "$TMP/audit.tsv" && ok "--log appends a routed line" || no "--log did not write"

echo "bench.sh — runs, floors gate, knob passthrough:"
bash "$HERE/bench.sh" >/dev/null 2>&1 && ok "bench passes its floors" || no "bench should pass"
ROUTER_ACC_FLOOR=101 bash "$HERE/bench.sh" >/dev/null 2>&1 && no "acc floor=101 should FAIL" || ok "accuracy floor bites"
bash "$HERE/bench.sh" --route-args "--ceiling sonnet" >/dev/null 2>&1; ok "bench accepts --route-args passthrough"

echo
printf 'router module: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
