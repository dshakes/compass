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
#   compass-policy-synth.sh --routing        # roll up ~/.compass/routing-feedback.tsv (written by
#                                            # sdlc/orchestrate.sh) into a PROPOSED router weight
#                                            # change — printed as a diff, never applied
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIN=3; JSON=0; FROM=""; USE_STDIN=0; ROUTING=0
for a in "$@"; do case "$a" in
  --json) JSON=1 ;; --min) MIN=__next ;; -) USE_STDIN=1 ;;
  --from) FROM=__next ;; --routing) ROUTING=1 ;;
  -h|--help) echo "usage: compass-policy-synth.sh [--from <glob>|-] [--min N] [--json] [--routing]"; exit 0 ;;
  *) if [ "$MIN" = __next ]; then MIN="$a"; elif [ "$FROM" = __next ]; then FROM="$a"; else echo "unknown arg: $a" >&2; exit 2; fi ;;
esac; done
[ "$MIN" = __next ] && MIN=3
[ "$FROM" = __next ] && FROM=""

# ── --routing: eval-driven routing feedback → PROPOSED spec change (roadmap §13) ──
# Reads the per-run records orchestrate.sh appends (ts, task tag, build model, converge
# rounds used, total cost, goal verdict) and rolls them up per model. If the workload
# signals the routing bias is off (models needing many fix rounds → routed too cheap;
# converging with none to spare → room to route cheaper), it PRINTS a proposed edit to
# router/router.json as a diff. It NEVER edits the spec: a human applies it, and only
# after the router eval (compass route --eval) still passes its CI accuracy floor.
if [ "$ROUTING" = 1 ]; then
  FB="${COMPASS_HOME:-$HOME/.compass}/routing-feedback.tsv"
  SPEC="$ROOT/router/router.json"
  [ -s "$FB" ] || { echo "no routing feedback yet ($FB) — run sdlc/orchestrate.sh first"; exit 0; }
  echo
  echo "  🧭 compass · routing feedback roll-up  (PROPOSALS ONLY — never applied)"
  echo "  ──────────────────────────────────────────────────────────────────────"
  awk -F'\t' '{n[$3]++; r[$3]+=$4; c[$3]+=$5; if($6=="MET")met[$3]++; if($6!="-")g[$3]++}
    END{printf "  %-8s %5s %11s %10s %9s\n","model","runs","avg rounds","avg cost","goal-met";
        for(m in n) printf "  %-8s %5d %11.2f %10.4f %9s\n", m, n[m], r[m]/n[m], c[m]/n[m],
          (g[m]?sprintf("%d/%d",met[m]+0,g[m]):"-")}' "$FB"
  AVG_ROUNDS="$(awk -F'\t' '{n++; s+=$4} END{printf "%.2f", (n?s/n:0)}' "$FB")"
  CUR_BIAS="$(sed -n 's/^[[:space:]]*"bias": "\([a-z]*\)",*$/\1/p' "$SPEC" 2>/dev/null | head -1)"
  # ponytail: one coarse knob (bias) from one coarse signal (avg converge rounds);
  # per-rule weight tuning can come when the record volume justifies it.
  PROPOSED="$CUR_BIAS"
  if awk "BEGIN{exit !($AVG_ROUNDS >= 1.5)}"; then PROPOSED="quality"
  elif awk "BEGIN{exit !($AVG_ROUNDS <= 0.5)}"; then PROPOSED="cheap"; fi
  echo
  echo "  avg converge rounds across runs: $AVG_ROUNDS   current bias: ${CUR_BIAS:-unknown}"
  if [ -z "$CUR_BIAS" ] || [ "$PROPOSED" = "$CUR_BIAS" ]; then
    echo "  No weight change proposed — the live workload agrees with the current routing bias."
    echo; exit 0
  fi
  echo
  echo "  Proposed change to router/router.json (NOT applied — review and edit by hand):"
  echo
  echo "  --- a/router/router.json"
  echo "  +++ b/router/router.json"
  echo "  -  \"bias\": \"$CUR_BIAS\","
  echo "  +  \"bias\": \"$PROPOSED\","
  echo
  echo "  ⚠ Applying this requires the router eval to STILL pass its CI accuracy floor:"
  echo "      scripts/compass-route.sh --eval    (floor: COMPASS_ROUTE_MIN_ACCURACY, default 90%)"
  echo "  compass never edits the router spec for you."
  echo; exit 0
fi

# ── theme catalog: keyword regex → (rule it would propose) ───────────────────────
# Tab-separated: id | match-regex | proposed CLAUDE.md rule. Data-driven so it's easy to extend.
# NB: read -r -d '' (not $(cat <<'EOF')) — bash 3.2 (macOS /bin/bash) mis-parses a
# heredoc nested in command substitution when the body contains apostrophes.
IFS= read -r -d '' THEMES <<'EOF' || true
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
