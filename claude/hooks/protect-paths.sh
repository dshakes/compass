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

# Fail-open by design: deliberately no `set -euo pipefail`. This hook must never
# abort the user's tool call on its own error — an unset var or failed command
# degrades to "defer to normal rules" (exit 0), never a spurious block.
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
    COMPASS_AUDIT_TOOL="$TOOL"
    FILE="$(json_get "$INPUT" '.tool_input.file_path')"
    [ -z "$FILE" ] && FILE="$(json_get "$INPUT" '.tool_input.notebook_path')"
    [ -z "$FILE" ] && exit 0
    reason="$(secret_file_reason "$FILE")"
    [ -n "$reason" ] && { COMPASS_AUDIT_RULE="secret-file-write"; deny "$reason"; }
    # Self-protection: never let the agent edit its own installed guardrails/config.
    reason="$(agent_config_reason "$FILE")"
    [ -n "$reason" ] && { COMPASS_AUDIT_RULE="agent-config-write"; deny "$reason"; }
    # Inline-secret scan of the content being written (high-precision). Pulls the
    # real author text (Write.content / Edit.new_string / MultiEdit.edits) with true
    # newlines, so the per-line allowlist is honest: a placeholder line ('allowlist
    # secret', EXAMPLE, <...>) is exempt; a real-looking credential elsewhere is still
    # blocked before it reaches the file.
    findings="$(secret_content_findings "$(json_write_text "$INPUT")")"
    if [ -n "$findings" ]; then
      summary="$(printf '%s' "$findings" | tr '\n' ' ')"
      COMPASS_AUDIT_RULE="secret-in-content"
      deny "Refusing to write a file that contains what looks like a live secret — $summary. If it's a placeholder, add an 'allowlist secret' marker on that line; if it's real, keep it out of the repo (env var / secret store)."
    fi
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
  [ -n "$reason" ] && { COMPASS_AUDIT_TOOL="Bash"; COMPASS_AUDIT_RULE="dangerous-command"; deny "$reason"; }
fi

exit 0
