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

echo "escalation fallback (Haiku judge — stubbed, no tokens):"
eq "fallback extracts tier from prose" "$(printf x | ROUTER_FALLBACK_STUB='I would use OPUS for this.' bash "$HERE/fallback-llm.sh")" opus
eq "fallback defaults on garbage"      "$(printf x | ROUTER_FALLBACK_STUB='hmm not sure' bash "$HERE/fallback-llm.sh")" sonnet
AMB="make sure one customer can never see another customer's invoices"
eq "cascade routes ambiguous via fallback" "$(R --escalate-below 75 --fallback "ROUTER_FALLBACK_STUB=opus $HERE/fallback-llm.sh" "$AMB")" opus
eq "confident keyword pick ignores fallback" "$(R --escalate-below 75 --fallback "ROUTER_FALLBACK_STUB=haiku $HERE/fallback-llm.sh" 'redesign the auth trust model')" opus
# bench-live spends tokens, so the suite only verifies its SKIP path (force no provider).
if env -u ANTHROPIC_API_KEY PATH="/usr/bin:/bin" bash "$HERE/bench-live.sh" >/dev/null 2>&1; then no "bench-live should skip without a provider"; else ok "bench-live skips without a provider (exit 77)"; fi

echo "local classifier (toggleable; trained from the evalset — no tokens):"
CM="$TMP/clf.model"
bash "$HERE/train-classifier.sh" "$HERE/evalset.tsv" -o "$CM" 2>/dev/null
eq "trained model exists"      "$( [ -s "$CM" ] && echo yes )" yes
eq "classify typo → haiku"     "$(printf 'fix a typo in the readme'      | ROUTER_CLASSIFIER=on bash "$HERE/classify.sh" --model "$CM")" haiku
eq "classify feature → sonnet" "$(printf 'add a rate limiter with tests' | ROUTER_CLASSIFIER=on bash "$HERE/classify.sh" --model "$CM")" sonnet
eq "classify tenancy → opus"   "$(printf 'fix the cross-tenant data leak' | ROUTER_CLASSIFIER=on bash "$HERE/classify.sh" --model "$CM")" opus
if printf 'fix a typo' | bash "$HERE/classify.sh" --model "$CM" >/dev/null 2>&1; then no "classifier OFF should abstain"; else ok "classifier OFF abstains (exit 3)"; fi
# cascade: OFF (default) → LLM judge (stubbed); ON + model → classifier, no LLM
eq "cascade off → LLM stub" "$(printf 'something ambiguous' | ROUTER_FALLBACK_STUB=sonnet bash "$HERE/fallback-cascade.sh")" sonnet
jq --arg m "$CM" '.classifier.enabled=true | .classifier.model=$m' "$HERE/router.json" > "$TMP/spec-clf.json"
eq "cascade on → classifier (no LLM)" "$(printf 'fix a typo in the readme' | ROUTER_FALLBACK_STUB=opus COMPASS_ROUTER_SPEC="$TMP/spec-clf.json" bash "$HERE/fallback-cascade.sh")" haiku

echo "bench.sh — runs, floors gate, knob passthrough:"
bash "$HERE/bench.sh" >/dev/null 2>&1 && ok "bench passes its floors" || no "bench should pass"
ROUTER_ACC_FLOOR=101 bash "$HERE/bench.sh" >/dev/null 2>&1 && no "acc floor=101 should FAIL" || ok "accuracy floor bites"
bash "$HERE/bench.sh" --route-args "--ceiling sonnet" >/dev/null 2>&1; ok "bench accepts --route-args passthrough"

echo "cache-aware cost-min (stage 4.5 — OFF unless COMPASS_ROUTE_WARM is set):"
eq "no warm → parity (unchanged)"            "$(R 'fix a typo in the readme')" haiku
eq "warm sonnet + tiny task rides sonnet"    "$(COMPASS_ROUTE_WARM=sonnet COMPASS_PREFIX_TOKENS=8000 COMPASS_TASK_TOKENS=100 COMPASS_OUTPUT_TOKENS=200 R 'fix a typo in the readme')" sonnet
eq "warm sonnet + big task stays haiku"      "$(COMPASS_ROUTE_WARM=sonnet COMPASS_PREFIX_TOKENS=8000 COMPASS_TASK_TOKENS=5000 COMPASS_OUTPUT_TOKENS=400 R 'fix a typo in the readme')" haiku
eq "warm opus + huge prefix/tiny rides opus" "$(COMPASS_ROUTE_WARM=opus COMPASS_PREFIX_TOKENS=12000 COMPASS_TASK_TOKENS=80 COMPASS_OUTPUT_TOKENS=150 R 'apply a tiny fix')" opus
eq "opus pick + warm haiku → opus (upgrade-only)" "$(COMPASS_ROUTE_WARM=haiku R 'redesign the auth trust model')" opus
eq "cache upgrade still bounded by ceiling"  "$(COMPASS_ROUTE_WARM=opus COMPASS_PREFIX_TOKENS=12000 COMPASS_TASK_TOKENS=80 R --ceiling sonnet 'apply a tiny fix')" sonnet

echo "ttl recommender (cache-write TTL: 5m default; 1h when reused ≥2× across a >5m gap):"
eq "default → 5m"                      "$(R --ttl)" 5m
eq "converge (3 reuses, 8m gap) → 1h"  "$(COMPASS_ROUTE_REUSES=3 COMPASS_ROUTE_GAP_MIN=8 R --ttl)" 1h
eq "2 reuses but no gap → 5m"          "$(COMPASS_ROUTE_REUSES=2 COMPASS_ROUTE_GAP_MIN=0 R --ttl)" 5m
eq "json carries ttl"                  "$(R --json 'fix a typo' | jq -r .ttl)" 5m

echo "budget governor (OFF unless COMPASS_ROUTE_BUDGET_USD set):"
eq "cap ≥95% caps opus→sonnet"        "$(COMPASS_ROUTE_BUDGET_USD=10 COMPASS_ROUTE_SPENT_USD=9.6 R 'redesign the auth trust model')" sonnet
eq "warn ≥80% cheap-biases weak pick" "$(COMPASS_ROUTE_BUDGET_USD=10 COMPASS_ROUTE_SPENT_USD=8.5 R 'update it')" haiku
eq "under budget → unchanged"         "$(COMPASS_ROUTE_BUDGET_USD=10 COMPASS_ROUTE_SPENT_USD=1 R 'redesign the auth trust model')" opus
eq "no budget signal → parity"        "$(R 'redesign the auth trust model')" opus

echo "latency ceiling (--max-latency / COMPASS_ROUTE_MAX_LATENCY):"
eq "max-latency 2 caps opus→sonnet"   "$(R --max-latency 2 'redesign the auth trust model')" sonnet
eq "max-latency 1 caps →haiku"        "$(R --max-latency 1 'redesign the auth trust model')" haiku
eq "max-latency 4 leaves opus"        "$(R --max-latency 4 'redesign the auth trust model')" opus
eq "no latency signal → parity"       "$(R 'redesign the auth trust model')" opus

echo "cache savings bench + telemetry calibrate:"
bash "$HERE/bench.sh" --cache >/dev/null 2>&1 && ok "bench --cache passes (100% accuracy + savings>0)" || no "bench --cache should pass"
CL="$TMP/cachelog.tsv"
COMPASS_ROUTE_CACHELOG="$CL" COMPASS_ROUTE_WARM=sonnet COMPASS_PREFIX_TOKENS=8000 COMPASS_TASK_TOKENS=100 COMPASS_OUTPUT_TOKENS=200 R 'fix a typo in the readme' >/dev/null
case "$(cat "$CL")" in *"$(printf 'haiku\tsonnet\tsonnet\t1')"*) ok "cachelog records an affinity upgrade" ;; *) no "cachelog affinity row missing" ;; esac
case "$(bash "$HERE/bench.sh" --calibrate "$CL" 2>&1)" in *"cache-affinity:"*) ok "calibrate summarizes affinity" ;; *) no "calibrate missing affinity" ;; esac

echo
printf 'router module: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
