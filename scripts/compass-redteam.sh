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
# Intentionally no -e: this aggregator must run every red-team case and tally the
# results; a single case's non-zero exit must not abort the run mid-corpus.
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

usage: compass redteam [--eval | --scan | --attack] [--json]
  (no flags)  run the eval AND scan this repo's untrusted context
  --eval      only score the detectors against the corpus (the CI gate)
  --scan      only scan this repo's CLAUDE.md/AGENTS.md/READMEs/MCP/settings
  --attack    adversarial fuzz: obfuscate the corpus payloads (base64 · zero-width ·
              homoglyph · leetspeak · case) and measure how many the detectors still
              catch (robustness %). Notes garak/promptfoo for live-agent attacks.
  --json      machine-readable summary

Optional managed-guardrail escalation (the hooks use these at runtime):
  COMPASS_GUARDRAIL_BACKEND = none | bedrock | azure | webhook
    bedrock  needs aws CLI + COMPASS_GUARDRAIL_ID (+ _VERSION, AWS_REGION)
    azure    needs COMPASS_GUARDRAIL_URL + COMPASS_GUARDRAIL_KEY (Prompt Shields)
    webhook  POSTs {source,text} to COMPASS_GUARDRAIL_URL; expects {"action":"BLOCK"}
EOF
}
TARGET="$ROOT"   # which repo's context --scan inspects (default: the compass install)
for a in "$@"; do case "$a" in
  --json) JSON=1 ;;
  --eval) MODE=eval ;;
  --scan) MODE=scan ;;
  --attack) MODE=attack ;;
  -h|--help) usage; exit 0 ;;
  --*) echo "compass redteam: unknown arg: $a" >&2; usage; exit 2 ;;
  *) TARGET="$a" ;;   # positional: a directory to scan (for CI / fleet sweeps)
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
    f="$TARGET/$rel"; is_self "$f" && continue; [ -f "$f" ] || continue
    out="$(injection_findings "$(cat "$f" 2>/dev/null)")"
    if [ -n "$out" ]; then
      SCAN_FILES=$((SCAN_FILES + 1))
      [ "$JSON" = 1 ] || { printf '  \033[33m⚠\033[0m %s\n' "$rel"; printf '%s\n' "$out" | sed 's/^/       /'; }
    fi
  done <<EOF
$(cd "$TARGET" 2>/dev/null && { git ls-files 2>/dev/null | grep -Ei '(^|/)(CLAUDE|AGENTS|GEMINI|README([._-][a-z]+)?)\.md$' || true; ls=$(git ls-files 2>/dev/null | grep -Eci '(CLAUDE|AGENTS|GEMINI|README).*\.md$' || true); [ "${ls:-0}" -gt 0 ] || find . -maxdepth 4 -type f 2>/dev/null | sed 's#^\./##' | grep -v '/\.git/' | grep -Ei '(^|/)(CLAUDE|AGENTS|GEMINI|README([._-][a-z]+)?)\.md$'; })
EOF
  # MCP servers: scan description AND command/args/url (tool-poisoning, not just prose).
  if [ -f "$TARGET/mcp/servers.json" ] && have jq; then
    while IFS=$'\t' read -r name blob; do
      [ -n "$name" ] || continue
      out="$(injection_findings "$blob")"
      if [ -n "$out" ]; then SCAN_FILES=$((SCAN_FILES + 1)); [ "$JSON" = 1 ] || printf '  \033[33m⚠\033[0m mcp:%s — %s\n' "$name" "$out"; fi
    done <<EOF2
$(jq -r '.servers | to_entries[] | "\(.key)\t\(.value.description // "") \(.value.command // "") \((.value.args // [])|join(" ")) \(.value.url // "")"' "$TARGET/mcp/servers.json" 2>/dev/null)
EOF2
  fi
  for s in "$TARGET/.claude/settings.json" "$TARGET/.claude/settings.local.json"; do
    [ -f "$s" ] || continue
    out="$(settings_override_reason "$(cat "$s" 2>/dev/null)")"
    if [ -n "$out" ]; then SCAN_FILES=$((SCAN_FILES + 1)); [ "$JSON" = 1 ] || printf '  \033[33m⚠\033[0m %s — %s\n' "${s#"$TARGET"/}" "$out"; fi
  done
}

# ── adversarial fuzz: obfuscate each corpus payload and re-test the detectors ───
ATTACK_TOTAL=0; ATTACK_CAUGHT=0
ROBUST_FLOOR="${COMPASS_REDTEAM_ROBUST_FLOOR:-80}"
_mutate() { # <transform> <payload>
  local t="$1" p="$2" zwsp; zwsp="$(printf '\342\200\213')"
  case "$t" in
    identity)  printf '%s' "$p" ;;
    base64)    printf 'data blob: %s' "$(printf '%s' "$p" | base64 | tr -d '\n')" ;;
    zerowidth) printf '%s' "$p" | LC_ALL=C sed "s/./&${zwsp}/g" ;;
    leet)      printf '%s' "$p" | LC_ALL=C tr 'ioeasIOEAS' '1034510345' ;;
    homoglyph) command -v perl >/dev/null 2>&1 \
                 && printf '%s' "$p" | perl -CSAD -pe 'tr/ioea/\x{0456}\x{043e}\x{0435}\x{0430}/' 2>/dev/null \
                 || printf '%s' "$p" ;;
  esac
}
run_attack() {
  local label payload t mut
  while IFS=$'\t' read -r label payload; do
    case "$label" in inject) ;; *) continue ;; esac
    [ -n "$payload" ] || continue
    for t in identity base64 zerowidth leet homoglyph; do
      mut="$(_mutate "$t" "$payload")"
      ATTACK_TOTAL=$((ATTACK_TOTAL + 1))
      if [ -n "$(injection_findings "$mut")" ]; then
        ATTACK_CAUGHT=$((ATTACK_CAUGHT + 1))
      else
        [ "$JSON" = 1 ] || printf '  \033[31mEVADED\033[0m [%-9s] %s\n' "$t" "$(printf '%s' "$payload" | cut -c1-52)"
      fi
    done
  done < "${COMPASS_REDTEAM_CORPUS:-$ROOT/scripts/redteam-corpus.tsv}"
}

if [ "$MODE" = attack ]; then
  [ "$JSON" = 1 ] || echo "adversarial fuzz — obfuscating corpus payloads (base64 · zero-width · leetspeak · homoglyph):"
  run_attack
  robust=100; [ "$ATTACK_TOTAL" -gt 0 ] && robust=$(( ATTACK_CAUGHT * 100 / ATTACK_TOTAL ))
  if [ "$JSON" = 1 ]; then
    printf '{"attack":{"total":%d,"caught":%d,"robustness":%d,"floor":%d},"garak":%s,"promptfoo":%s}\n' \
      "$ATTACK_TOTAL" "$ATTACK_CAUGHT" "$robust" "$ROBUST_FLOOR" \
      "$(command -v garak >/dev/null 2>&1 && echo true || echo false)" \
      "$(command -v promptfoo >/dev/null 2>&1 && echo true || echo false)"
  else
    echo
    printf 'adversarial robustness: %d%% (%d/%d caught after obfuscation; floor %d%%)\n' "$robust" "$ATTACK_CAUGHT" "$ATTACK_TOTAL" "$ROBUST_FLOOR"
    echo "live-agent attacks (against a RUNNING endpoint): $(command -v garak >/dev/null 2>&1 && echo 'garak found — run: garak --model.type ...' || echo 'install garak') · $(command -v promptfoo >/dev/null 2>&1 && echo 'promptfoo found — run: promptfoo redteam' || echo 'install promptfoo')"
  fi
  [ "$robust" -ge "$ROBUST_FLOOR" ]
  exit $?
fi

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
  echo "guardrail backend: ${COMPASS_GUARDRAIL_BACKEND:-none}  ·  adversarial fuzz: compass redteam --attack  ·  live-agent: garak / promptfoo"
fi

[ "$EVAL_PASS" = true ]
