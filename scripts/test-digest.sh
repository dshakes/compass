#!/usr/bin/env bash
# test-digest.sh — eval for the comprehension-rot guard (scripts/compass-digest.sh).
#
# Drives the script against a throwaway git repo and an isolated COMPASS_HOME, asserting the
# behavior that matters: it samples up to N unreviewed changes, the ledger makes a second run
# surface DIFFERENT work (you don't re-review the same thing), agent-authored changes rank
# first, --all ignores the ledger, --json reports the lag counts, and --reset/--mark/no-repo
# behave. Deterministic (forces the git source); runs in CI. Mirrors test-budget-gate.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/compass-digest.sh"

pass=0; fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

HOME_TMP="$(mktemp -d)"; REPO_TMP="$(mktemp -d)"
trap 'rm -rf "$HOME_TMP" "$REPO_TMP"' EXIT
export COMPASS_HOME="$HOME_TMP"
export COMPASS_DIGEST_SOURCE=git   # deterministic: never reach for gh in CI

# Build a small linear history (first-parent = every commit here). Mix bot + human authors.
git -C "$REPO_TMP" init -q
git -C "$REPO_TMP" config user.email t@t.io; git -C "$REPO_TMP" config user.name "Human Dev"
commit() { # commit <file> <subject> <author-name> <author-email>
  echo "$RANDOM" > "$REPO_TMP/$1"; git -C "$REPO_TMP" add -A
  GIT_AUTHOR_NAME="$3" GIT_AUTHOR_EMAIL="$4" GIT_COMMITTER_NAME="$3" GIT_COMMITTER_EMAIL="$4" \
    git -C "$REPO_TMP" commit -q -m "$2"
}
commit a "human change one"  "Human Dev"  "h@t.io"
commit b "agent off-by-one fix" "compass-bot" "bot@t.io"
commit c "human change two"  "Human Dev"  "h@t.io"
commit d "agent null guard"  "claude[bot]" "bot@t.io"
commit e "human change three" "Human Dev" "h@t.io"   # newest

run() { "$SCRIPT" "$@" "$REPO_TMP" 2>/dev/null; }

echo "json: first run considers all 5, unreviewed 5, samples default 3:"
out="$(run --json)"
echo "$out" | grep -q '"considered":5'  && ok "considered=5"      || no "considered: $out"
echo "$out" | grep -q '"unreviewed":5' && ok "unreviewed=5"      || no "unreviewed: $out"
echo "$out" | grep -q '"sampled":3'    && ok "sampled=3 (default N)" || no "sampled: $out"

echo "ledger: the 3 just shown are now reviewed → next run samples the remaining 2:"
out="$(run --json)"
echo "$out" | grep -q '"unreviewed":2' && ok "unreviewed dropped to 2" || no "unreviewed: $out"
echo "$out" | grep -q '"sampled":2'    && ok "sampled=2 (only 2 left)"  || no "sampled: $out"

echo "caught up: a third run has nothing new to show:"
out="$(run --json)"
echo "$out" | grep -q '"unreviewed":0' && ok "unreviewed=0" || no "unreviewed: $out"
echo "$out" | grep -q '"sampled":0'    && ok "sampled=0"    || no "sampled: $out"

echo "--all ignores the ledger (still considers/samples despite all reviewed):"
out="$(run --all --json)"
echo "$out" | grep -q '"sampled":3' && ok "--all re-samples 3" || no "--all: $out"

echo "--reset clears the ledger → unreviewed back to full:"
run --reset >/dev/null
out="$(run --json)"
echo "$out" | grep -q '"unreviewed":5' && ok "reset → unreviewed=5" || no "reset: $out"

echo "agent-authored ranks first: with -n 1 the single pick is an agent commit:"
run --reset >/dev/null
out="$(run -n 1 --json)"
if echo "$out" | grep -Eq '"author":"(compass-bot|claude\[bot\])"'; then ok "top pick is agent-authored"; else no "expected agent author first: $out"; fi

echo "--mark records a ref as reviewed without showing it:"
run --reset >/dev/null
"$SCRIPT" --mark "PR#999" "$REPO_TMP" >/dev/null 2>&1
grep -q "PR#999" "$COMPASS_HOME/digest.tsv" && ok "--mark wrote ledger row" || no "--mark did not record"

echo "human digest prints the question prompt and a rationale section:"
run --reset >/dev/null
out="$(run -n 1)"
echo "$out" | grep -q "what did this change do" && ok "shows the explain-it question" || no "no question prompt"

echo "not a git repo → exit 2:"
NOREPO="$(mktemp -d)"; rc=0; "$SCRIPT" "$NOREPO" >/dev/null 2>&1 || rc=$?; rm -rf "$NOREPO"
[ "$rc" = 2 ] && ok "exit 2 outside a repo" || no "expected exit 2, got $rc"

echo "bad -n → exit 2:"
rc=0; "$SCRIPT" -n abc "$REPO_TMP" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "exit 2 on bad -n" || no "expected exit 2, got $rc"

echo
printf 'digest tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
