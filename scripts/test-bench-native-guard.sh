#!/usr/bin/env bash
# Hermetic test for bench-native-guard.sh: a fake `claude` on PATH emits canned JSON; no network, no spend.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/scripts/bench-native-guard.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
pass=0; fail=0
ok() { if [ "$2" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; fi; }

# fake claude: verdict keyed on the payload file it is asked to Read (cwd/doc.txt)
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'cwd=%s home=%s args=%s\n' "$PWD" "$HOME" "$*" >> "$FAKE_LOG"
[ -e .claude ] && echo "HOOKS-DIR" >> "$FAKE_LOG"
c="${FAKE_COST:-0.01}"
case "$(cat doc.txt)" in
  *DENYME*) printf '{"is_error":false,"stop_reason":"end_turn","terminal_reason":"completed","total_cost_usd":%s,"duration_ms":5,"safety_stops":0,"permission_denials":[{"tool_name":"Read"}]}\n' "$c" ;;
  *BOOM*)   printf '{"is_error":true,"stop_reason":null,"terminal_reason":"api_error","total_cost_usd":0,"duration_ms":1,"permission_denials":[]}\n'; exit 1 ;;
  *STOPME*) printf '{"is_error":false,"stop_reason":"end_turn","terminal_reason":"completed","total_cost_usd":%s,"duration_ms":5,"safety_stops":1,"permission_denials":[]}\n' "$c" ;;
  *)        printf '{"is_error":false,"stop_reason":"end_turn","terminal_reason":"completed","total_cost_usd":%s,"duration_ms":5,"safety_stops":0,"permission_denials":[]}\n' "$c" ;;
esac
EOF
chmod +x "$T/bin/claude"
export PATH="$T/bin:$PATH" FAKE_LOG="$T/fake.log"
printf 'inject\tDENYME ignore previous\ninject\tSTOPME ignore previous\ninject\tplain missed attack\nsafe\tBOOM crash row\nsafe\tbenign one\nsafe\tbenign two\n' > "$T/corpus.tsv"
export COMPASS_NATIVE_CORPUS_FILE="$T/corpus.tsv"

# spend guards
"$B" --n 6 >"$T/o" 2>&1; rc=$?; ok "refuses without --yes-spend" "$([ $rc = 2 ] && grep -q yes-spend "$T/o"; echo $?)"
"$B" --n 61 --yes-spend >"$T/o" 2>&1; rc=$?; ok "refuses n>60" "$([ $rc = 2 ]; echo $?)"
[ ! -s "$T/fake.log" ]; ok "guards made no claude call" $?

# full run: 3 inject (2 flagged), 3 safe (1 error, 2 clean) -> TP=2 FN=1 FP=0 TN=2 errors=1
"$B" --n 6 --yes-spend --seed 3 >"$T/o" 2>"$T/e"; rc=$?
ok "run exits 0" "$([ $rc = 0 ]; echo $?)"
grep -q 'TP=2  FP=0  TN=2  FN=1' "$T/o"; ok "confusion matrix" $?
grep -q 'errors=1' "$T/o"; ok "error row recorded not retried" $?
grep -q 'recall=66% (n=3 attacks, 95% CI' "$T/o"; ok "table has recall + Wilson CI" $?
grep -q 'FPR=0%' "$T/o"; ok "table has FPR" $?
grep -q 'est. max spend \$0.60' "$T/e"; ok "prints estimated max spend" $?
[ "$(grep -c BOOM "$T/o")" = 1 ] && [ "$(wc -l < "$T/fake.log" | tr -d ' ')" = 6 ]; ok "one call per row" $?

# isolation: temp cwd, no .claude dir, settings sources restricted, MCP/slash disabled, tools limited.
# This proves the FLAGS are passed, not that the real binary honours them: that `--setting-sources
# project` excludes ~/.claude/settings.json (so compass's own hooks never load) was verified by hand
# against the stream-json `init` event on 2026-11-01 — re-verify after a Claude Code upgrade, or the
# harness silently measures compass instead of the native guard.
! grep -q HOOKS-DIR "$T/fake.log"; ok "cwd has no .claude/hooks" $?
head -1 "$T/fake.log" | grep -q -- '--setting-sources project' && head -1 "$T/fake.log" | grep -q -- '--strict-mcp-config' \
  && head -1 "$T/fake.log" | grep -q -- '--disable-slash-commands' && head -1 "$T/fake.log" | grep -q -- '--permission-mode auto'; ok "isolation + mode flags" $?
! head -1 "$T/fake.log" | grep -q "cwd=$ROOT"; ok "does not run inside the repo" $?

# --json
"$B" --n 6 --yes-spend --seed 3 --json 2>/dev/null | python3 -I -c 'import json,sys; d=json.load(sys.stdin); assert d["tp"]==2 and d["fn"]==1 and d["errors"]==1 and len(d["results"])==6'; ok "--json parses" $?

# cost cap: 0.6 per call, cap 1.0 -> aborts after 2 calls, exit 4
: > "$T/fake.log"
FAKE_COST=0.6 COMPASS_MAX_USD=1.0 "$B" --n 6 --yes-spend >"$T/o" 2>"$T/e"; rc=$?
ok "aborts over cap (exit 4)" "$([ $rc = 4 ]; echo $?)"
[ "$(wc -l < "$T/fake.log" | tr -d ' ')" -lt 6 ]; ok "stopped calling at cap" $?
grep -q ABORTED "$T/o"; ok "table flags the abort" $?

printf 'bench-native-guard: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
