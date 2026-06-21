#!/usr/bin/env bash
# Helpers for demo.tape so the *recorded* commands stay short, clean, and COLORFUL
# (no raw JSON on screen). Sourced from the repo root in the tape's hidden setup.
H="claude/hooks/protect-paths.sh"
R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; P=$'\033[35m'; D=$'\033[90m'; B=$'\033[1m'; X=$'\033[0m'

guard() {  # guard '<command>' -> red BLOCKED / green allowed (no JSON)
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" | "$H" >/dev/null 2>&1
  if [ $? -eq 2 ]; then printf "  %b%-18s%b  %b●  BLOCKED%b\n" "$B" "$1" "$X" "$R" "$X"
  else printf "  %b%-18s%b  %b●  allowed%b\n" "$B" "$1" "$X" "$G" "$X"; fi
}

# Live budget ceiling — drives the REAL budget-gate.sh hook against a throwaway
# COMPASS_HOME, so the HALT you see is the actual gate firing, not a mockup.
BG="claude/hooks/budget-gate.sh"
budget() {  # budget <usd-spent> <cap-usd> -> green running / red HALTED at the cap
  local usd="$1" cap="$2" sid="demo" home rc spent
  home="$(mktemp -d)"; mkdir -p "$home/sessions"; printf '%s' "$usd" >"$home/sessions/$sid.cost"
  spent="$(awk -v c="$usd" 'BEGIN{printf "%.2f", c}')"
  printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"x"}}' "$sid" \
    | COMPASS_HOME="$home" COMPASS_MAX_USD="$cap" "$BG" >/dev/null 2>&1
  rc=$?; rm -rf "$home"
  if [ "$rc" -eq 2 ]; then
    printf "  next action @ %b\$%s%b / \$%s cap   %b●  HALTED — agent stopped%b\n" "$B" "$spent" "$X" "$cap" "$R$B" "$X"
  else
    printf "  next action @ %b\$%s%b / \$%s cap   %b●  allowed%b\n" "$B" "$spent" "$X" "$cap" "$G" "$X"
  fi
}

statusline() {
  printf '{"model":{"display_name":"Claude Opus 4.7"},"workspace":{"current_dir":"/Users/you/myrepo"},"permission_mode":"acceptEdits","cost":{"estimated_cost_cents":37,"total_input_tokens":42000}}' \
    | claude/statusline.sh; echo
}

# The autonomous PR loop, as a quick colored sequence.
loop() {
  printf "  %byou open a PR%b\n" "$D" "$X"
  sleep 0.5; printf "    review · security · tests · %bCodex audit%b\n" "$P" "$X"
  sleep 0.6; printf "    %b●  BLOCKING%b  → Builder fixes on the branch ↻ re-review\n" "$R" "$X"
  sleep 0.7; printf "    %b●  CLEAN%b     → checks green\n" "$G" "$X"
  sleep 0.5; printf "  %b✓ you merge%b   %b(humans own merge & deploy — always)%b\n" "$G$B" "$X" "$D" "$X"
}

crew() {
  printf "  %b9 subagents%b  architect·reviewer·%bsecurity%b·debugger·go/rust·k8s·qa·docs\n" "$B" "$X" "$P" "$X"
  printf "  %b11 commands%b  /ship /review /tdd /spec /pr /adr /triage /scaffold /cost\n" "$B" "$X"
}
