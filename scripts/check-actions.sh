#!/usr/bin/env bash
# check-actions.sh — drift + least-privilege + injection guard for GitHub Actions.
#
# Four checks, all CI-gated (mirrors the router-eval / plugin-sync convention):
#   1. MIRROR DRIFT — .github/workflows/sdlc-*.yml must be byte-identical to the
#      sdlc/workflows/*.yml template they're dogfooded from. (The competitive audit's
#      DRIFT/Medium finding: there was a sync check for the plugin but not for these.)
#   2. LEAST PRIVILEGE — every workflow declares a top-level `permissions:` block
#      (so it doesn't inherit the repo-wide default token scope).
#   3. ACTION PINNING — every `uses:` is pinned to a 40-char commit SHA (not a
#      moving tag), the supply-chain-safe form.
#   4. SCRIPT INJECTION — no untrusted `${{ github.event.*.{body,title,ref} }}` /
#      `${{ github.head_ref }}` interpolated *inside a `run:` shell block* (the
#      classic Actions RCE). Passing them via `env:` and referencing "$VAR" is safe.
#
# Usage:
#   check-actions.sh                 # full repo audit (CI)
#   check-actions.sh --lint <file…>  # per-file lint only (used by fixtures to prove the gate bites)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
trap 'rm -f /tmp/_inj.$$' EXIT
pass=0; fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

# Per-file lint: permissions + pinning + injection. Pure (no repo assumptions).
lint_file() {
  local f="$1" rel="${1#"$ROOT"/}"
  grep -Eq '^permissions:' "$f" || no "$rel: no top-level 'permissions:' block (least privilege)"
  # pinning: real `uses:` steps (word-boundary, skip 'statuses:' etc and local ./paths)
  while IFS= read -r line; do
    case "$line" in *'./'*|*'docker://'*) continue ;; esac
    printf '%s' "$line" | grep -Eq '@[0-9a-f]{40}( |$|#)' || no "$rel: unpinned action (pin to a SHA): $(printf '%s' "$line" | sed 's/^ *//')"
  done < <(grep -E '^[[:space:]]*-?[[:space:]]*uses:' "$f")
  # injection: untrusted expression inside a run: block.
  awk '
    function untrusted(s) {
      return (s ~ /\$\{\{[[:space:]]*github\.event\.[a-zA-Z_.]*\.(body|title|ref)/ ||
              s ~ /\$\{\{[[:space:]]*github\.head_ref/ ||
              s ~ /\$\{\{[[:space:]]*github\.event\.(issue|pull_request|comment|review)\.(body|title)/)
    }
    {
      indent = match($0, /[^ ]/) - 1
      if ($0 ~ /^[[:space:]]*-?[[:space:]]*run:[[:space:]]*[|>]/) { inrun=1; runindent=indent; next }
      if (inrun && $0 !~ /^[[:space:]]*$/ && indent <= runindent) inrun=0
      if (inrun && untrusted($0)) { print NR": "$0; found=1 }
    }
    END { exit found?1:0 }
  ' "$f" >/tmp/_inj.$$ 2>/dev/null || {
    while IFS= read -r hit; do no "$rel: untrusted \${{ github.event… }} inside a run: block — pass via env: instead ($hit)"; done <"/tmp/_inj.$$"
  }
  rm -f "/tmp/_inj.$$"
}

# --lint mode: just lint the given files (for fixtures / ad-hoc use).
if [ "${1:-}" = "--lint" ]; then
  shift
  for f in "$@"; do [ -f "$f" ] && lint_file "$f"; done
  printf '\nactions lint: %d passed, %d failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]; exit $?
fi

echo "mirror drift — .github/workflows/sdlc-*.yml must match sdlc/workflows/ templates:"
for tmpl in "$ROOT"/sdlc/workflows/*.yml; do
  base="$(basename "$tmpl")"
  live="$ROOT/.github/workflows/$base"
  if [ ! -f "$live" ]; then no "missing dogfood copy: .github/workflows/$base"; continue; fi
  if diff -q "$tmpl" "$live" >/dev/null 2>&1; then ok "in sync: $base"
  else no "DRIFT: .github/workflows/$base != sdlc/workflows/$base (run: cp sdlc/workflows/$base .github/workflows/)"; fi
done

echo "least-privilege + pinning + injection — all workflows:"
n_before=$fail
for f in "$ROOT"/.github/workflows/*.yml "$ROOT"/sdlc/workflows/*.yml "$ROOT"/sdlc/selfhosted/*.yml "$ROOT"/sdlc/routines/*.yml "$ROOT"/sdlc/fleet/*.yml; do
  [ -f "$f" ] || continue
  lint_file "$f"
done
[ "$fail" -eq "$n_before" ] && ok "all workflows: permissions + SHA-pinned + no run-block injection"

echo
printf 'actions audit: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
