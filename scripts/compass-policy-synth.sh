#!/usr/bin/env bash
# compass-policy-synth.sh — the "fleet brain": turn recurring review findings into
# PROPOSED governance, never applied automatically.
#
# Autonomy compounds when the system learns its own guardrails. This reads a corpus of
# past review/security findings (SDLC run artifacts + the compass-memory store), clusters
# them into known themes, and — for any theme that recurs ≥ threshold — emits a PROPOSED
# CLAUDE.md rule (and, where applicable, a guardrail/policy note). It edits nothing: the
# output is a proposal a human reviews and merges, so the self-improving loop stays
# auditable and human-gated, exactly like every other compass loop.
#
#   compass-policy-synth.sh                  # scan .sdlc/run-*/ + memory, print proposals
#   compass-policy-synth.sh --from <glob>    # scan specific finding files (or stdin with -)
#   compass-policy-synth.sh --min N          # recurrence threshold (default 3)
#   compass-policy-synth.sh --json           # machine-readable proposals
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIN=3; JSON=0; FROM=""; USE_STDIN=0
for a in "$@"; do case "$a" in
  --json) JSON=1 ;; --min) MIN=__next ;; -) USE_STDIN=1 ;;
  --from) FROM=__next ;;
  -h|--help) echo "usage: compass-policy-synth.sh [--from <glob>|-] [--min N] [--json]"; exit 0 ;;
  *) if [ "$MIN" = __next ]; then MIN="$a"; elif [ "$FROM" = __next ]; then FROM="$a"; else echo "unknown arg: $a" >&2; exit 2; fi ;;
esac; done
[ "$MIN" = __next ] && MIN=3
[ "$FROM" = __next ] && FROM=""

# ── theme catalog: keyword regex → (rule it would propose) ───────────────────────
# Tab-separated: id | match-regex | proposed CLAUDE.md rule. Data-driven so it's easy to extend.
THEMES="$(cat <<'EOF'
error-handling	(missing|no|unchecked|swallow).{0,20}(error|err)|ignore[sd]? (the )?error|err != nil	Always check and wrap errors with context (Go: %w); never silently swallow an error path.
tests	(no|missing|lacks?|untested).{0,20}test|add (a )?test|test coverage|failing.path	New behavior ships with a test for it — including the failure path — before it's called done.
input-validation	(unvalidated|unsanitized|missing).{0,20}(input|validation)|validate (the )?input	Validate/parse untrusted input at the boundary (zod/pydantic/typed structs) before use.
secrets	(secret|credential|api[_-]?key|token).{0,20}(log|expos|leak|hardcod)|hardcoded	Never log, hardcode, or commit secrets; read them from the environment/secret store.
injection	(sql|command|shell|template).{0,20}injection|string.concat.*query|f-string.*sql	Use parameterized queries / argv arrays — never build SQL or shell from string concatenation.
nil-safety	(nil|null|undefined|none).{0,20}(deref|pointer|access)|possible nil|optional.*unwrap	Guard nil/undefined before dereference; prefer typed optionals over implicit nulls.
concurrency	(race condition|data race|deadlock|unsynchronized|not thread.safe)	Protect shared state (mutex/channel) and document the concurrency invariant; add a race test.
perf	(n\+1|unbounded|o\(n\^?2\)|hot path.*alloc|blocking i/o)	Avoid N+1 queries and unbounded growth on hot paths; measure before/after.
rust-unwrap	\.unwrap\(\)|\.expect\(	No unwrap()/expect() on fallible production paths — propagate with ? and typed errors.
EOF
)"

# ── gather the finding corpus ────────────────────────────────────────────────────
gather() {
  if [ "$USE_STDIN" = 1 ]; then cat; return; fi
  if [ -n "$FROM" ]; then
    # shellcheck disable=SC2086
    for f in $FROM; do [ -f "$f" ] && cat "$f"; done
    return
  fi
  shopt -s nullglob
  for f in .sdlc/run-*/review.md .sdlc/run-*/security.md .sdlc/run-*/audit.md; do cat "$f"; done
  # plus durable learnings tagged from reviews, if memory is configured
  if command -v python3 >/dev/null 2>&1 && [ -n "${COMPASS_MEMORY_TRUST:-}" ] && [ -f "$ROOT/mcp/compass-memory/store.py" ]; then
    python3 "$ROOT/mcp/compass-memory/store.py" search '' --limit 200 2>/dev/null || true
  fi
}

CORPUS="$(gather | tr 'A-Z' 'a-z')"
[ -n "$CORPUS" ] || { [ "$JSON" = 1 ] && echo '{"proposals":[]}' || echo "no finding corpus found (.sdlc/run-*/ empty; pass --from <glob> or pipe with -)"; exit 0; }

# ── count recurrence per theme ────────────────────────────────────────────────────
proposals=""; n=0
while IFS=$'\t' read -r id rx rule; do
  case "$id" in '#'*|'') continue ;; esac
  count="$(printf '%s' "$CORPUS" | grep -aoiE "$rx" | wc -l | tr -d ' ')"
  : "${count:=0}"
  if [ "$count" -ge "$MIN" ]; then
    n=$((n+1))
    proposals="$proposals$id	$count	$rule
"
  fi
done <<EOF
$THEMES
EOF

if [ "$JSON" = 1 ]; then
  printf '{"min":%s,"proposals":[' "$MIN"
  first=1
  printf '%s' "$proposals" | while IFS=$'\t' read -r id count rule; do
    [ -n "$id" ] || continue
    [ "$first" = 1 ] || printf ','; first=0
    printf '{"theme":"%s","occurrences":%s,"proposed_rule":%s}' "$id" "$count" "$(printf '%s' "$rule" | sed 's/\\/\\\\/g;s/"/\\"/g;s/^/"/;s/$/"/')"
  done
  printf ']}\n'
  exit 0
fi

echo
echo "  🧭 compass · policy synthesis  (PROPOSALS ONLY — a human reviews & merges)"
echo "  ──────────────────────────────────────────────────────────────────────"
if [ "$n" -eq 0 ]; then
  echo "  No theme recurred ≥ $MIN times. Nothing to propose — the playbook is holding."
  echo; exit 0
fi
echo "  $n recurring theme(s) cleared the ≥$MIN threshold. Consider adding to CLAUDE.md:"
echo
printf '%s' "$proposals" | while IFS=$'\t' read -r id count rule; do
  [ -n "$id" ] || continue
  printf '  • [%s, seen %sx]\n    %s\n' "$id" "$count" "$rule"
done
echo
echo "  Next: paste the ones you agree with into your project CLAUDE.md (or run with --json"
echo "  in a fleet routine to file an issue). compass never edits your manual for you."
echo
