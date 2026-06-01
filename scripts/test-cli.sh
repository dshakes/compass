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

echo
printf 'cli tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
