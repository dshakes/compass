#!/usr/bin/env bash
# validate.sh — CI-safe check of the review benchmark (no tokens): corpus structure,
# line ranges exist in the patched tree, and the scorer's exact P/R under the mock reviewer.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
CASES="$HERE/cases"; MOCK="$HERE/reviewers/mock.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

echo "corpus structure:"
NFLAG=0; NCLEAN=0
for d in "$CASES"/*/; do
  name="$(basename "$d")"
  if [ ! -d "$d/base" ] || [ ! -s "$d/diff.patch" ] || [ ! -f "$d/labels.json" ]; then bad "$name: needs base/ diff.patch labels.json"; continue; fi
  work="$(mktemp -d)"; cp -R "$d/base/." "$work/"
  if ! patch -s -p1 -d "$work" <"$d/diff.patch" >/dev/null 2>&1; then bad "$name: diff.patch does not apply to base/"; rm -rf "$work"; continue; fi
  exp="$(python3 - "$d/labels.json" "$work" <<'PY'
import json, os, sys
l = json.load(open(sys.argv[1]))
if l.get("expect") not in ("flag", "clean"): sys.exit("bad expect")
if (l["expect"] == "flag") != bool(l["bugs"]): sys.exit("flag<->bugs mismatch")
for b in l["bugs"]:
    n = sum(1 for _ in open(os.path.join(sys.argv[2], b["file"])))
    if not (1 <= b["line_start"] <= b["line_end"] <= n): sys.exit("range %s:%s-%s outside %d lines" % (b["file"], b["line_start"], b["line_end"], n))
print(l["expect"])
PY
)" || { bad "$name: labels.json invalid"; rm -rf "$work"; continue; }
  rm -rf "$work"
  case "$exp" in flag) NFLAG=$((NFLAG+1)) ;; clean) NCLEAN=$((NCLEAN+1)) ;; esac
  ok "$name ($exp)"
done
[ "$NFLAG" -ge 7 ] && ok "flag cases: $NFLAG (>=7)" || bad "flag cases: $NFLAG (<7)"
[ "$NCLEAN" -ge 5 ] && ok "clean cases: $NCLEAN (>=5)" || bad "clean cases: $NCLEAN (<5)"

echo "shellcheck:"
for s in "$HERE"/validate.sh "$HERE"/reviewers/*.sh "$ROOT/scripts/compass-reviewbench.sh"; do
  if shellcheck -S error "$s" 2>/dev/null; then ok "shellcheck ${s#"$ROOT"/}"; else bad "shellcheck ${s#"$ROOT"/}"; fi
done

echo "scorer (mock reviewer, exact values):"
# check <label> <env...> -- <expected tp fp fn precision recall>
check() {
  local label="$1" want="$2"; shift 2
  local got
  got="$(env "$@" bash "$ROOT/scripts/compass-reviewbench.sh" --reviewer "$MOCK" --cases "$CASES" --json \
    | python3 -c 'import json,sys; o=json.load(sys.stdin); print(o["tp"],o["fp"],o["fn"],o["precision"],o["recall"])')"
  if [ "$got" = "$want" ]; then ok "$label -> $got"; else bad "$label: got '$got' want '$want'"; fi
}
check "perfect (P=100 R=100)"        "8 0 0 1.0 1.0"        MOCK_NOISE=0 MOCK_MISS=0
check "noise=1 (14 FP, P=8/22)"      "8 14 0 0.3636 1.0"    MOCK_NOISE=1 MOCK_MISS=0
check "miss=2 (2 FN, R=6/8)"         "6 0 2 1.0 0.75"       MOCK_NOISE=0 MOCK_MISS=2

printf 'validate: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
