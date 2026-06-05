#!/usr/bin/env bash
# compass-redteam.sh — measure resistance to prompt-injection / context-poisoning,
# the way `compass bench` measures the guardrail. Two parts:
#   eval — score the injection / config-override / malware detectors against the
#          labeled corpus (precision/recall), reproducible + offline (CI-gated).
#   scan — check THIS repo's untrusted-context files (CLAUDE.md / AGENTS.md / READMEs,
#          MCP server descriptions, project .claude/settings.json) for live patterns.
#
# Defense-in-depth + honest: pattern detection is the offline floor, NOT model-level
# immunity. For a model-grade ceiling, set COMPASS_GUARDRAIL_BACKEND (see below) and
# the hooks escalate to your guardrails service.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../claude/hooks/lib/common.sh
. "$ROOT/claude/hooks/lib/common.sh"
# shellcheck source=../claude/hooks/lib/policy.sh
. "$ROOT/claude/hooks/lib/policy.sh"

JSON=0; MODE=all
usage() {
  cat <<'EOF'
compass redteam — measure prompt-injection resistance (eval + repo scan)

usage: compass redteam [--eval | --scan] [--json]
  (no flags)  run the eval AND scan this repo's untrusted context
  --eval      only score the detectors against the corpus (the CI gate)
  --scan      only scan this repo's CLAUDE.md/AGENTS.md/READMEs/MCP/settings
  --json      machine-readable summary

Optional managed-guardrail escalation (the hooks use these at runtime):
  COMPASS_GUARDRAIL_BACKEND = none | bedrock | azure | webhook
    bedrock  needs aws CLI + COMPASS_GUARDRAIL_ID (+ _VERSION, AWS_REGION)
    azure    needs COMPASS_GUARDRAIL_URL + COMPASS_GUARDRAIL_KEY (Prompt Shields)
    webhook  POSTs {source,text} to COMPASS_GUARDRAIL_URL; expects {"action":"BLOCK"}
EOF
}
for a in "$@"; do case "$a" in
  --json) JSON=1 ;;
  --eval) MODE=eval ;;
  --scan) MODE=scan ;;
  -h|--help) usage; exit 0 ;;
  *) echo "compass redteam: unknown arg: $a" >&2; usage; exit 2 ;;
esac; done

# Files that legitimately contain the patterns (the policy, the corpus, the docs) —
# never flag our own machinery when scanning the compass repo itself.
is_self() { case "$1" in
  */scripts/redteam-corpus.tsv|*/scripts/test-redteam.sh|*/scripts/compass-redteam.sh|\
*/claude/hooks/lib/policy.sh|*/claude/hooks/lib/guardrail-remote.sh|\
*/claude/hooks/scan-prompt.sh|*/claude/hooks/scan-tool-output.sh|*/claude/hooks/scan-untrusted-context.sh|\
*/docs/17-red-team.md) return 0 ;;
esac; return 1; }

EVAL_PREC=""; EVAL_REC=""; EVAL_PASS=true
run_eval() {
  local out rc
  out="$(bash "$ROOT/scripts/test-redteam.sh" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] || EVAL_PASS=false
  EVAL_PREC="$(printf '%s\n' "$out" | sed -n 's/.*precision=\([0-9]*\)%.*/\1/p' | head -1)"
  EVAL_REC="$(printf '%s\n' "$out"  | sed -n 's/.*recall=\([0-9]*\)%.*/\1/p'    | head -1)"
  [ "$JSON" = 1 ] || printf '%s\n' "$out"
}

SCAN_FILES=0
scan_repo() {
  local rel f out s name desc
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    f="$ROOT/$rel"; is_self "$f" && continue; [ -f "$f" ] || continue
    out="$(injection_findings "$(cat "$f" 2>/dev/null)")"
    if [ -n "$out" ]; then
      SCAN_FILES=$((SCAN_FILES + 1))
      [ "$JSON" = 1 ] || { printf '  \033[33m⚠\033[0m %s\n' "$rel"; printf '%s\n' "$out" | sed 's/^/       /'; }
    fi
  done <<EOF
$(cd "$ROOT" && git ls-files 2>/dev/null | grep -Ei '(^|/)(CLAUDE|AGENTS|GEMINI|README([._-][a-z]+)?)\.md$')
EOF
  if [ -f "$ROOT/mcp/servers.json" ] && have jq; then
    while IFS=$'\t' read -r name desc; do
      [ -n "$name" ] || continue
      out="$(injection_findings "$desc")"
      if [ -n "$out" ]; then SCAN_FILES=$((SCAN_FILES + 1)); [ "$JSON" = 1 ] || printf '  \033[33m⚠\033[0m mcp:%s — %s\n' "$name" "$out"; fi
    done <<EOF2
$(jq -r '.servers | to_entries[] | "\(.key)\t\(.value.description // "")"' "$ROOT/mcp/servers.json" 2>/dev/null)
EOF2
  fi
  for s in "$ROOT/.claude/settings.json" "$ROOT/.claude/settings.local.json"; do
    [ -f "$s" ] || continue
    out="$(settings_override_reason "$(cat "$s" 2>/dev/null)")"
    if [ -n "$out" ]; then SCAN_FILES=$((SCAN_FILES + 1)); [ "$JSON" = 1 ] || printf '  \033[33m⚠\033[0m %s — %s\n' "${s#"$ROOT"/}" "$out"; fi
  done
}

[ "$MODE" = scan ] || run_eval
if [ "$MODE" != eval ]; then
  [ "$JSON" = 1 ] || { echo; echo "repo scan — untrusted context (CLAUDE.md/AGENTS.md/READMEs · MCP · settings):"; }
  scan_repo
  [ "$JSON" = 1 ] || { [ "$SCAN_FILES" -eq 0 ] && printf '  \033[32mclean\033[0m — no injection/override patterns in this repo'\''s context\n'; }
fi

if [ "$JSON" = 1 ]; then
  printf '{"eval":{"precision":%s,"recall":%s,"pass":%s},"scan":{"flagged":%d},"backend":%s}\n' \
    "${EVAL_PREC:-null}" "${EVAL_REC:-null}" "$EVAL_PASS" "$SCAN_FILES" "$(json_string "${COMPASS_GUARDRAIL_BACKEND:-none}")"
else
  echo
  echo "guardrail backend: ${COMPASS_GUARDRAIL_BACKEND:-none}  ·  optional deep red-team: garak / promptfoo (run separately if installed)"
fi

[ "$EVAL_PASS" = true ]
