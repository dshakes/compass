#!/usr/bin/env bash
# test-budget-gate.sh — the live budget ceiling's eval.
#
# Drives claude/hooks/budget-gate.sh end-to-end through its PreToolUse JSON
# contract, against an isolated COMPASS_HOME, asserting the two things that
# matter: it BLOCKS (exit 2 + deny JSON) once session spend meets/exceeds the
# cap, and it FAILS OPEN (exit 0) whenever the cap is unset or spend is unknown
# — a cost guardrail must never wedge a session on missing data.
#
# Runs in CI. Mirrors the style of scripts/test-protect-paths.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/claude/hooks/budget-gate.sh"

pass=0; fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

HOME_TMP="$(mktemp -d)"
trap 'rm -rf "$HOME_TMP"' EXIT
export COMPASS_HOME="$HOME_TMP"
SID="sess-eval"
mkdir -p "$COMPASS_HOME/sessions"

# input <session_id> — a minimal PreToolUse payload.
input() { printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"echo hi"}}' "${1:-$SID}"; }
# set_spent <usd> / clear_spent — write or remove the statusline breadcrumb (dollars).
set_spent() { printf '%s' "$1" > "$COMPASS_HOME/sessions/$SID.cost"; }
clear_spent() { rm -f "$COMPASS_HOME/sessions/$SID.cost"; }

# allow "<desc>"  — hook must exit 0 with no deny.
allow() {
  local out rc; out="$(input | bash "$HOOK" 2>/dev/null)"; rc=$?
  if [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
    ok "ALLOW  $1"; else no "should ALLOW ($rc): $1"; fi
}
# block "<desc>"  — hook must exit 2 with a deny verdict.
block() {
  local out rc; out="$(input | bash "$HOOK" 2>/dev/null)"; rc=$?
  if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
    ok "BLOCK  $1"; else no "should BLOCK ($rc): $1"; fi
}

echo "fail-open: no ceiling set → never blocks (zero-config default):"
unset COMPASS_MAX_USD; rm -f "$COMPASS_HOME/config"
set_spent 9999; allow "huge spend but no cap"

echo "fail-open: cap set but spend unknown (no statusline render yet):"
export COMPASS_MAX_USD=5; clear_spent
allow "cap=5, no breadcrumb"

echo "env ceiling (COMPASS_MAX_USD):"
export COMPASS_MAX_USD=5
set_spent 3.50; allow "spent \$3.50 < \$5 cap"
set_spent 4.99; allow "spent \$4.99 < \$5 cap"
set_spent 5.00; block "spent \$5.00 == \$5 cap (at ceiling)"
set_spent 5.20; block "spent \$5.20 > \$5 cap"

echo "config-file ceiling (max_usd=), env unset:"
unset COMPASS_MAX_USD
printf 'max_usd=4\n' > "$COMPASS_HOME/config"
set_spent 3.99; allow "spent \$3.99 < \$4 cap"
set_spent 4.00; block "spent \$4.00 == \$4 cap"
rm -f "$COMPASS_HOME/config"

echo "env wins over config:"
printf 'max_usd=100\n' > "$COMPASS_HOME/config"   # generous config…
export COMPASS_MAX_USD=2                            # …tighter env should win
set_spent 2.50; block "env cap \$2 beats config \$100"
rm -f "$COMPASS_HOME/config"

echo "robustness: malformed / non-positive caps are ignored (no gate):"
export COMPASS_MAX_USD=abc;  set_spent 9999; allow "junk cap → ignored"
export COMPASS_MAX_USD=0;    set_spent 9999; allow "zero cap → gate off"
unset COMPASS_MAX_USD

echo "robustness: missing session_id → can't attribute spend → fail open:"
export COMPASS_MAX_USD=1; set_spent 9999
out="$(printf '{"tool_name":"Bash","tool_input":{"command":"x"}}' | bash "$HOOK" 2>/dev/null)"; rc=$?
{ [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q deny; } && ok "ALLOW  no session_id" || no "should ALLOW: no session_id ($rc)"

# ── Daily ceiling (COMPASS_MAX_USD_DAY): today's ledger rows + this session's breadcrumb. ──
unset COMPASS_MAX_USD; rm -f "$COMPASS_HOME/config"
LEDGER="$COMPASS_HOME/spend.tsv"; TODAY="$(date -u +%Y-%m-%d)"
day_row() { printf '%sT09:00:00Z\tmyrepo\ttask\tsonnet\t%s\n' "$TODAY" "$1" >> "$LEDGER"; }   # today's spend
old_row() { printf '2000-01-01T09:00:00Z\tmyrepo\ttask\tsonnet\t%s\n' "$1" >> "$LEDGER"; }    # a prior day

echo "daily cap: ledger-today + session summed against the ceiling:"
export COMPASS_MAX_USD_DAY=20
: > "$LEDGER"; day_row 8.00;  clear_spent;    allow "ledger \$8 < \$20 day cap (no session render)"
: > "$LEDGER"; day_row 8.00;  set_spent 5.00; allow "ledger \$8 + session \$5 = \$13 < \$20"
: > "$LEDGER"; day_row 18.00; set_spent 2.00; block "ledger \$18 + session \$2 = \$20 == day cap"
: > "$LEDGER"; day_row 25.00; clear_spent;    block "ledger today \$25 > \$20 (ledger alone, no session)"

echo "daily cap counts only TODAY's rows:"
: > "$LEDGER"; old_row 999;   clear_spent;    allow "a \$999 row from another day is not counted"

echo "daily cap fail-open when nothing is known:"
: > "$LEDGER"; clear_spent;                   allow "empty ledger, no session → under day cap"
rm -f "$LEDGER"; clear_spent;                 allow "no ledger file at all → under day cap"
unset COMPASS_MAX_USD_DAY

echo "daily cap via config (max_usd_day=), env unset:"
printf 'max_usd_day=10\n' > "$COMPASS_HOME/config"
: > "$LEDGER"; day_row 12.00; clear_spent;    block "ledger \$12 > \$10 config day cap"
: > "$LEDGER"; day_row 9.00;  clear_spent;    allow "ledger \$9 < \$10 config day cap"
rm -f "$COMPASS_HOME/config" "$LEDGER"

echo "session + daily are independent (session under, day over → blocks):"
export COMPASS_MAX_USD=100 COMPASS_MAX_USD_DAY=15
: > "$LEDGER"; day_row 14.00; set_spent 2.00; block "session \$2<\$100 cap but day \$16>\$15 cap"
unset COMPASS_MAX_USD COMPASS_MAX_USD_DAY; rm -f "$LEDGER"

echo
printf 'budget-gate tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
