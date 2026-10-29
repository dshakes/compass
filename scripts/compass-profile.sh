#!/usr/bin/env bash
# compass-profile.sh — choose a guardrail profile and show the ONE effective policy.
#
# A profile is a data file (claude/hooks/profiles/<name>.conf, key=value) — not a code
# branch. The hooks resolve every knob through compass_policy (lib/common.sh):
# profile → ~/.compass/config → env, then a repo's .compass/policy.conf, which may only
# tighten. This command is the human view of that same resolver, plus the two places the
# policy has to leave the hooks:
#   • Claude settings — `fail_closed=1` adds onFailure:"block" to the security hooks, which
#     is install-time config, so selecting a profile re-renders the installed settings.
#   • Other harnesses — `--env` prints the effective caps as exports, which `compass gate`
#     (the spend proxy for Codex, Gemini and SDKs) loads, so one cap governs all three.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../claude/hooks/lib/common.sh
. "$ROOT/claude/hooks/lib/common.sh"
HOME_C="${COMPASS_HOME:-$HOME/.compass}"
# The hooks whose failure must not wave the action through under fail_closed. PreToolUse +
# UserPromptSubmit only: on PostToolUse/SessionStart a block can't un-run anything.
FAIL_CLOSED_RE='/(protect-paths|budget-gate|scan-prompt)\.sh$'

usage() {
  cat <<EOF
compass profile — guardrail presets + the one effective policy

usage: compass profile                   show the active profile and effective policy
       compass profile <strict|standard|solo>
                                         select a profile (re-renders installed Claude settings)
       compass profile --get KEY         print one effective value
       compass profile --env             print the effective policy as shell exports
                                         (eval it before codex/gemini; compass gate does)
       compass profile --settings-file   render + print the Claude settings file to install

A repo may add .compass/policy.conf (key=value) to TIGHTEN the policy, never loosen it.
EOF
}

# Settings JSON on stdin → the same JSON, with onFailure:"block" on the security hooks
# when the active profile is fail-closed. Otherwise a byte-for-byte passthrough.
render() {
  if [ "$(compass_policy fail_closed)" = 1 ]; then
    jq --arg re "$FAIL_CLOSED_RE" '
      (.hooks.PreToolUse, .hooks.UserPromptSubmit) |= (if . then map(.hooks |= map(
        if ((.command // "") | test($re)) then .onFailure = "block" else . end)) else . end)'
  else cat; fi
}

# → path of the Claude settings file to install: the shipped file untouched when there's
# no personal overlay and the profile is fail-open (today's behavior), else a rendered
# settings.merged.json (gitignored). install.sh calls this, so a reinstall keeps the profile.
settings_file() {
  local shipped="$ROOT/claude/settings.json" overlay="$ROOT/claude/settings.local.json"
  local merged="${COMPASS_SETTINGS_MERGED:-$ROOT/claude/settings.merged.json}"   # override: tests
  if [ ! -f "$overlay" ] && [ "$(compass_policy fail_closed)" != 1 ]; then echo "$shipped"; return; fi
  if ! have jq; then
    echo "compass profile: jq missing — using shipped settings (no overlay, hooks fail open)" >&2
    echo "$shipped"; return
  fi
  { if [ -f "$overlay" ]; then jq -s '.[0] * .[1]' "$shipped" "$overlay"; else cat "$shipped"; fi; } \
    | render >"$merged.tmp" && mv "$merged.tmp" "$merged" || { rm -f "$merged.tmp"; echo "$shipped"; return; }
  echo "$merged"
}

show() {
  local k v rej
  printf 'profile: %s   (%s)\n' "$(compass_profile_name)" "$COMPASS_PROFILES_DIR/$(compass_profile_name).conf"
  for k in $COMPASS_POLICY_DEFAULTS; do
    k="${k%%=*}"; v="$(compass_policy "$k")"
    printf '  %-20s %s\n' "$k" "${v:-unset}"
  done
  rej="$(compass_repo_policy_rejections)"
  [ -f "$(compass_repo_root)/.compass/policy.conf" ] && printf 'repo override: %s/.compass/policy.conf (tighten-only)\n' "$(compass_repo_root)"
  [ -n "$rej" ] && { printf 'REJECTED repo override lines:\n'; printf '%s\n' "$rej" | sed 's/^/  ✗ /'; }
  return 0
}

case "${1:-}" in
  ''|show) show ;;
  -h|--help|help) usage ;;
  --get) [ -n "${2:-}" ] || { usage >&2; exit 2; }; compass_policy "$2"; echo ;;
  --env)
    for k in $COMPASS_POLICY_DEFAULTS; do
      k="${k%%=*}"; v="$(compass_policy "$k")"
      [ -n "$v" ] && printf 'export COMPASS_%s=%q\n' "$(printf '%s' "$k" | tr '[:lower:]' '[:upper:]')" "$v"
    done ;;
  --settings-file) settings_file ;;
  -*) echo "compass profile: unknown flag '$1'" >&2; usage >&2; exit 2 ;;
  *)
    name="$1"
    case "$name" in *[!a-z0-9_-]*|'') echo "compass profile: bad name '$name'" >&2; exit 2 ;; esac
    [ -f "$COMPASS_PROFILES_DIR/$name.conf" ] || {
      echo "compass profile: no profile '$name' — have: $(cd "$COMPASS_PROFILES_DIR" && ls ./*.conf | sed 's|^\./||; s/\.conf$//' | tr '\n' ' ')" >&2; exit 2; }
    mkdir -p "$HOME_C" && printf '%s\n' "$name" >"$HOME_C/profile"
    # Re-point the installed Claude settings only when compass owns them (a symlink into
    # this repo). A copy-mode or hand-managed install is told what to run instead.
    live="$HOME/.claude/settings.json"
    if [ -L "$live" ] && case "$(readlink "$live")" in "$ROOT/claude/"*|"${COMPASS_SETTINGS_MERGED:-//}") true ;; *) false ;; esac; then
      src="$(settings_file)"; ln -sfn "$src" "$live"
      echo "settings: ~/.claude/settings.json -> ${src#"$ROOT"/}"
    else
      echo "settings: ~/.claude/settings.json is not a compass symlink — re-run ./install.sh to apply fail_closed"
    fi
    show ;;
esac
