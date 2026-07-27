#!/usr/bin/env bash
# compass-ablate.sh — ablation testing for agent config.
#
# THE PROBLEM. Agent config only ever grows. Every incident adds a rule, every model
# release adds a caveat, and nothing is ever removed — because nobody can prove a rule
# isn't load-bearing. So config accretes into superstition, and it accretes in the
# context window, where it is paid for on every single call. Anthropic removed >80% of
# Claude Code's system prompt for newer models with no measurable loss; almost nobody
# else can attempt that, because they have no way to tell what the 80% was doing.
#
# THE INSTRUMENT. A config rule is a hypothesis: "without me, this system gets worse."
# That hypothesis is testable. Ablate the rule, re-run the deterministic corpora, and
# compare. This is the standard ablation study from ML, pointed at config instead of
# model components — no tokens, no network, no model calls, fully reproducible.
#
# THE HONEST PART. A rule whose removal changes nothing is NOT proven useless. It is
# UNMEASURED: either dead weight, or a real defence your corpus never exercises. Absence
# of evidence is not evidence of absence, and a tool that conflated the two would delete
# your best-written, least-tested guardrail first. So this reports three verdicts and
# recommends a corpus case — never a silent deletion.
#
#   load-bearing  removing it drops a score. It has earned its context. Keep, with a receipt.
#   unmeasured    removing it changes nothing. Add a corpus case, THEN decide. Never auto-delete.
#   broken        removing it IMPROVES a score. The rule is costing you accuracy. Investigate now.
#
# Usage:
#   compass-ablate.sh                    # sweep every detector, print the table
#   compass-ablate.sh --detector NAME    # ablate one detector
#   compass-ablate.sh --json             # machine-readable, for dashboards and CI
#   compass-ablate.sh --gate             # CI mode: fail if unmeasured exceeds the floor
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="$ROOT/claude/hooks/lib/policy.sh"
BENCH="$ROOT/scripts/compass-bench.sh"
REDTEAM="$ROOT/scripts/compass-redteam.sh"
BACKUP="$(mktemp "${TMPDIR:-/tmp}/policy.orig.XXXXXX")"

# Ceiling on rules no corpus exercises. Not zero: a new detector legitimately lands
# before its corpus case does. A RATCHET, not a wall — lower it whenever coverage grows,
# never raise it to make a red build green.
#   38 rules → 25 unmeasured (first study, before content-corpus.tsv existed)
#           →  4 unmeasured (after)  ← the floor tracks this number down
# The 4 that remain are redundancy, not gaps: another detector already matches the same
# corpus case, so removing either one alone leaves recall flat. Splitting them needs a
# case only that rule can catch — worth doing, not worth blocking a build over.
UNMEASURED_FLOOR="${COMPASS_ABLATE_UNMEASURED_FLOOR:-4}"

MODE=table; ONE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json)     MODE=json ;;
    --gate)     MODE=gate ;;
    --detector) ONE="${2:-}"; shift ;;
    -h|--help)  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

[ -f "$POLICY" ] || { echo "no policy at $POLICY" >&2; exit 1; }
[ -x "$BENCH" ] || [ -f "$BENCH" ] || { echo "no bench at $BENCH" >&2; exit 1; }

cp "$POLICY" "$BACKUP"
# The policy file is live config the hooks source. Restore it on ANY exit path —
# success, failure, or interrupt — or an aborted sweep leaves the guardrail degraded.
restore() { cp "$BACKUP" "$POLICY"; rm -f "$BACKUP"; }
trap restore EXIT INT TERM

# compass has TWO disjoint corpora, and a detector is only exercised by one of them.
# Scoring an injection detector against the guardrail corpus reports "unmeasured" for
# every rule — technically true of that corpus, and completely useless as a finding.
# So each detector is scored against the corpus that actually covers it.
#
#   injection                       -> redteam-corpus.tsv  (compass redteam --eval)
#   secret / malware / insecure     -> content-corpus.tsv  (compass bench --content)
#
# The router eval is skipped throughout: no detector can move routing accuracy.
score_content() { bash "$BENCH" --content --json 2>/dev/null; }
score_redteam() { bash "$REDTEAM" --eval --json 2>/dev/null; }

score_for() { # score_for <corpus>
  case "$1" in
    redteam) score_redteam ;;
    *)       score_content ;;
  esac
}

# Pull one number out of a scorecard without needing jq (CI has it; a laptop may not).
field() { # field <json> <group> <key>
  printf '%s' "$1" | sed "s/.*\"$2\":{[^}]*\"$3\":\([0-9.]*\).*/\1/"
}

# Each corpus reports its numbers under a different JSON group.
recall_of()    { case "$1" in redteam) field "$2" eval recall ;;    *) field "$2" content recall ;;    esac; }
precision_of() { case "$1" in redteam) field "$2" eval precision ;; *) field "$2" content precision ;; esac; }

# Every detector is a `name|regex` line inside a POLICY_*_DETECTORS='...' assignment.
# Discovery MUST be scoped to those assignments: a bare /^[a-z0-9-]+\|/ also matches
# `case` branch patterns elsewhere in the file, and ablating one of those deletes a case
# arm, breaks the shell parse, and scores 0 — which the verdict logic would then read as
# "catastrophically load-bearing." The tool would be confidently backwards.
# Emits: <line-number> <detector-name> <corpus>
detectors() {
  awk '
    /^POLICY_[A-Z_]*DETECTORS=./ {
      inblock = 1
      corpus = /^POLICY_INJECTION_/ ? "redteam" : "content"
      # The first detector of each block sits INLINE on the assignment line, right
      # after the opening quote. Emit it too, or the first rule of every family is
      # silently never tested — four invisible rules, and no warning that they were.
      inline = substr($0, index($0, "'"'"'") + 1)
      if (inline ~ /^[a-z0-9-]+\|/) print NR, substr(inline, 1, index(inline, "|") - 1), corpus
      next
    }
    inblock && /^[a-z0-9-]+\|/      { print NR, substr($0, 1, index($0, "|") - 1), corpus }
    inblock && /'"'"'[[:space:]]*$/ { inblock = 0 }           # closing quote ends the block
  ' "$POLICY"
}

# One baseline per corpus, measured once.
BASE_G="$(score_content)";   BG_REC="$(recall_of content "$BASE_G")";   BG_PREC="$(precision_of content "$BASE_G")"
BASE_R="$(score_redteam)";   BR_REC="$(recall_of redteam "$BASE_R")";   BR_PREC="$(precision_of redteam "$BASE_R")"

baseline_recall()    { case "$1" in redteam) printf '%s' "$BR_REC" ;;  *) printf '%s' "$BG_REC" ;;  esac; }
baseline_precision() { case "$1" in redteam) printf '%s' "$BR_PREC" ;; *) printf '%s' "$BG_PREC" ;; esac; }

[ "$MODE" = json ] || {
  printf 'ablation study — every detector removed in turn, scored against the corpus that covers it\n'
  printf 'baseline:  content %s%% P / %s%% R (39 cases)   ·   redteam %s%% P / %s%% R\n' \
    "$BG_PREC" "$BG_REC" "$BR_PREC" "$BR_REC"
  printf '           deterministic — no model calls, no network, no tokens\n\n'
  printf '  %-26s %-10s %8s %8s   %s\n' DETECTOR CORPUS RECALL DELTA VERDICT
  printf '  %-26s %-10s %8s %8s   %s\n' "--------------------------" "---------" "------" "-----" "-------"
}

n_load=0; n_unmeas=0; n_broken=0; rows=""

while read -r lineno name corpus; do
  [ -n "$name" ] || continue
  [ -z "$ONE" ] || [ "$ONE" = "$name" ] || continue
  B_REC="$(baseline_recall "$corpus")"; B_PREC="$(baseline_precision "$corpus")"

  # Ablate by NEUTRALISING the rule in place, not by deleting its line: keep the name and
  # any trailing quote, and swap the regex for one that cannot match. Deleting the line
  # would remove the terminator of the enclosing '...' assignment whenever the rule is the
  # last in its block, corrupting the file instead of measuring the rule.
  awk -v ln="$lineno" '
    NR == ln {
      name = substr($0, 1, index($0, "|") - 1)
      tail = ($0 ~ /'"'"'[[:space:]]*$/) ? "'"'"'" : ""
      print name "|zzABLATEDzz" tail
      next
    }
    { print }
  ' "$BACKUP" > "$POLICY"

  # Belt and braces: if the edit made the policy unparseable, the bench may still emit a
  # score — a 0 that the verdict logic below would read as "catastrophically load-bearing."
  # Never let a broken file masquerade as a finding.
  if ! bash -n "$POLICY" 2>/dev/null; then
    verdict=inconclusive; delta="n/a"; A_REC=""; A_PREC=""
  else
    A="$(score_for "$corpus")"
    A_PREC="$(precision_of "$corpus" "$A")"
    A_REC="$(recall_of "$corpus" "$A")"
  fi

  if [ -z "$A_REC" ]; then
    verdict=inconclusive; delta="n/a"
  else
    delta="$(awk -v a="$A_REC" -v b="$B_REC" 'BEGIN{printf "%+.1f", a-b}')"
    if awk -v a="$A_REC" -v b="$B_REC" -v ap="$A_PREC" -v bp="$B_PREC" \
         'BEGIN{exit !(a < b || ap < bp)}'; then
      verdict=load-bearing; n_load=$((n_load + 1))
    elif awk -v a="$A_REC" -v b="$B_REC" 'BEGIN{exit !(a > b)}'; then
      verdict=broken; n_broken=$((n_broken + 1))
    else
      verdict=unmeasured; n_unmeas=$((n_unmeas + 1))
    fi
  fi

  cp "$BACKUP" "$POLICY"   # restore before the next iteration measures

  case "$MODE" in
    json) rows="$rows{\"detector\":\"$name\",\"corpus\":\"$corpus\",\"recall\":${A_REC:-null},\"delta\":\"$delta\",\"verdict\":\"$verdict\"}," ;;
    *)    printf '  %-26s %-10s %7s%% %8s   %s\n' "$name" "$corpus" "${A_REC:-?}" "$delta" "$verdict" ;;
  esac
done <<EOF
$(detectors)
EOF

if [ "$MODE" = json ]; then
  printf '{"baseline":{"guardrail":{"precision":%s,"recall":%s},"redteam":{"precision":%s,"recall":%s}},"ablations":[%s],"summary":{"load_bearing":%d,"unmeasured":%d,"broken":%d}}\n' \
    "$BG_PREC" "$BG_REC" "$BR_PREC" "$BR_REC" "${rows%,}" "$n_load" "$n_unmeas" "$n_broken"
  exit 0
fi

printf '\n  load-bearing %d   unmeasured %d   broken %d\n' "$n_load" "$n_unmeas" "$n_broken"
[ "$n_unmeas" -eq 0 ] || printf '  → unmeasured rules need a case in the corpus that covers them, not deletion.\n\n'
[ "$n_broken" -eq 0 ] || printf '  → a BROKEN rule is costing accuracy right now. Fix or remove it.\n'

if [ "$MODE" = gate ]; then
  [ "$n_broken" -eq 0 ] || { printf '\nFAIL: %d rule(s) actively hurt the score.\n' "$n_broken"; exit 1; }
  [ "$n_unmeas" -le "$UNMEASURED_FLOOR" ] || {
    printf '\nFAIL: %d unmeasured rules exceeds the floor of %d.\n' "$n_unmeas" "$UNMEASURED_FLOOR"; exit 1; }
  printf '\nablation gate: pass\n'
fi
