#!/usr/bin/env bash
# protect-paths.sh — PreToolUse guardrail.
#
# Blocks the small set of actions that are almost never intended and are
# expensive to undo: writing secrets, catastrophic shell commands, and
# force-pushing/hard-resetting shared branches. Everything else is allowed
# to flow through to normal permission rules.
#
# The actual policy lives in lib/policy.sh as two pure, corpus-tested functions
# (secret_file_reason / danger_reason); this hook just adapts the Claude Code
# PreToolUse JSON contract to them. Edit the policy there; the bypass corpus in
# scripts/test-protect-paths.sh proves what is and isn't covered (CI-gated).
#
# Wired in settings.json as a PreToolUse hook matching "Bash|Edit|Write|NotebookEdit".
# Contract: exit 2 + JSON deny  => blocked. exit 0 => defer to normal rules.
#
# NOTE: this is BEST-EFFORT footgun-prevention, NOT a security boundary. It catches common
# accidents, not a determined attacker or a cleverly-obfuscated command. Keep least-privilege
# credentials and review diffs. (See SECURITY.md.)

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"
# shellcheck source=lib/policy.sh
. "$DIR/lib/policy.sh"

INPUT="$(cat)"
TOOL="$(json_get "$INPUT" '.tool_name')"

# --- File-writing tools: protect secrets and credential stores ----------------
case "$TOOL" in
  Edit|Write|NotebookEdit|MultiEdit)
    FILE="$(json_get "$INPUT" '.tool_input.file_path')"
    [ -z "$FILE" ] && FILE="$(json_get "$INPUT" '.tool_input.notebook_path')"
    [ -z "$FILE" ] && exit 0
    reason="$(secret_file_reason "$FILE")"
    [ -n "$reason" ] && deny "$reason"
    exit 0 ;;
esac

# --- Bash: block catastrophic / hard-to-reverse commands -----------------------
if [ "$TOOL" = "Bash" ]; then
  CMD="$(json_get "$INPUT" '.tool_input.command')"
  # Fail safe: only when NEITHER jq NOR python3 exists can json_get's grep fallback
  # truncate the command at an escaped quote (hiding a footgun after it). In that rare
  # case, also fold in the raw payload so the danger checks see the whole string —
  # erring toward a block (the safe direction), never toward a silent allow.
  if ! have jq && ! have python3; then CMD="$CMD $INPUT"; fi

  # Tell the policy which branch we're on, so it can block a force-push / hard-reset
  # of the *current* protected branch even when the command doesn't name it.
  POLICY_CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  export POLICY_CURRENT_BRANCH

  reason="$(danger_reason "$CMD")"
  [ -n "$reason" ] && deny "$reason"
fi

exit 0
