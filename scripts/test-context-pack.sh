#!/usr/bin/env bash
# test-context-pack.sh — fixture tests for context-pack.sh.
#
# Creates a minimal git repo with a function definition + caller, modifies the function,
# then asserts that the context pack lists the touched symbol and its call site.
# No network, no external tools required beyond git and bash.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACK="$ROOT/scripts/context-pack.sh"

pass=0; fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in output)"; esac; }

command -v git >/dev/null 2>&1 || { echo "git required" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
G="$TMP/repo"
export GIT_AUTHOR_DATE="2026-01-02T03:04:05Z" GIT_COMMITTER_DATE="2026-01-02T03:04:05Z"
git init -q "$G"
git -C "$G" config user.email t@t
git -C "$G" config user.name t

# Commit 1: a function definition (computeTotal) and a caller in the same repo.
cat > "$G/math.go" <<'EOF'
package main

func computeTotal(n int) int {
	return n * 2
}
EOF
cat > "$G/main.go" <<'EOF'
package main

func main() {
	x := computeTotal(5)
	_ = x
}
EOF
git -C "$G" add math.go main.go
git -C "$G" commit -qm "initial: add computeTotal and caller"
C1="$(git -C "$G" rev-parse HEAD)"

# Commit 2: modify the function body (computeTotal is the touched symbol).
printf 'package main\n\nfunc computeTotal(n int) int {\n\treturn n * 3\n}\n' > "$G/math.go"
git -C "$G" add math.go
git -C "$G" commit -qm "change computeTotal multiplier"
C2="$(git -C "$G" rev-parse HEAD)"

echo "context-pack — symbol extraction + call-site lookup:"

# Run context-pack on the explicit range C1..C2.
OUT="$(cd "$G" && bash "$PACK" "${C1}..${C2}" 2>/dev/null)"
has "detects computeTotal in output"     "$OUT" "computeTotal"
has "shows call site in main.go"         "$OUT" "main.go"
has "shows definition in math.go"        "$OUT" "math.go"

# Empty range: should exit 0 with a note, not crash.
EMPTY_OUT="$(cd "$G" && bash "$PACK" "${C2}..${C2}" 2>/dev/null)"; EMPTY_RC=$?
eq()  { [ "$2" = "$3" ] && ok "$1" || no "$1 (got '$2', want '$3')"; }
eq "empty range exits 0"  "$EMPTY_RC" 0

# Default invocation (no args): no 'main' branch in fixture → falls back to HEAD~1..HEAD = C1..C2.
OUT2="$(cd "$G" && bash "$PACK" 2>/dev/null)"
has "default range finds computeTotal" "$OUT2" "computeTotal"

echo
printf 'context-pack tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
