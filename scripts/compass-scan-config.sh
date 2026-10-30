#!/usr/bin/env bash
# compass-scan-config.sh — `compass scan --config`: audit the harness config you ALREADY
# run with (yours, not a plugin you're about to install — that's `compass audit-plugin`).
#
# Reads, never writes:
#   ~/.claude/settings.json (+ .local)   <project>/.claude/settings.json (+ .local)
#   <project>/.mcp.json                  ~/.codex/config.toml      ~/.gemini/settings.json
# and flags the settings that quietly turn a guardrail off:
#   HIGH  permission bypass (bypassPermissions / danger-full-access / yolo)
#   HIGH  wildcard Bash allow rule (Bash, Bash(*), Bash(:*))
#   HIGH  hook script that is world-writable (anyone on the box can rewrite your guardrail)
#   HIGH  MCP server via fetch-and-exec (curl|sh) or an unpinned npx/bunx package
#   HIGH  plaintext secret in an env block — reported by KEY NAME only, never the value
#   MED   hook script that is missing (the guardrail silently never runs), unpinned uvx,
#         approval_policy = "never"
#   LOW   hook without a timeout
# Exit: 0 = no HIGH, 1 = HIGH finding(s), 2 = usage error. --json for machines.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../claude/hooks/lib/common.sh
. "$ROOT/claude/hooks/lib/common.sh"
# shellcheck source=../claude/hooks/lib/policy.sh
. "$ROOT/claude/hooks/lib/policy.sh"

H="$HOME"; P=""; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --home) H="${2:?--home DIR}"; shift ;;
    --project) P="${2:?--project DIR}"; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; echo "usage: compass scan --config [--json] [--home DIR] [--project DIR]"; exit 0 ;;
    *) echo "compass scan --config: unknown arg '$1'" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$P" ] || P="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
have jq || { echo "compass scan --config: jq required" >&2; exit 2; }

FINDINGS=""   # sev<TAB>file<TAB>rule<TAB>detail
add() { local t="~"; FINDINGS="${FINDINGS}$1	${2/#"$H"/$t}	$3	$4
"; }
SECRET_NAME_RE='(^|_)(TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|ACCESS_KEY|PRIVATE_KEY|CREDENTIALS?)($|_)'

# env_check FILE CONTEXT KEY VALUE — literal secret? (names only; references like $VAR are fine)
env_check() {
  case "$4" in ''|'$'*) return 0 ;; esac
  if printf '%s' "$3" | tr '[:lower:]' '[:upper:]' | grep -Eq "$SECRET_NAME_RE" \
     || [ -n "$(secret_content_findings "$4")" ]; then
    add HIGH "$1" plaintext-secret "$2 env $3 holds a literal secret — move it to a secret store / \$VAR reference"
  fi
}

# mcp_check FILE NAME "command args..."
mcp_check() {
  local f="$1" n="$2" cl="$3" runner pkg
  if printf '%s' "$cl" | grep -Eiq '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?[a-z]*sh([[:space:]]|$)'; then
    add HIGH "$f" mcp-fetch-exec "MCP server '$n' pipes a download into a shell"
  fi
  # shellcheck disable=SC2086  # deliberate word split of the command line
  set -- $cl; runner="${1##*/}"; shift 2>/dev/null
  [ "$runner" = pnpm ] && [ "${1:-}" = dlx ] && shift
  pkg=""; for a in "$@"; do case "$a" in -*) ;; *) pkg="$a"; break ;; esac; done
  case "$runner" in
    npx|bunx|pnpm)
      # pinned = name@<digit…> (scoped: @scope/name@1.2.3); @latest or no version floats
      case "$pkg" in *@latest|*@next) pkg="" ;; esac
      printf '%s' "$pkg" | grep -Eq '^.+@[0-9]' \
        || add HIGH "$f" mcp-unpinned "MCP server '$n' runs an unpinned $runner package — pin an exact version" ;;
    uvx)
      printf '%s' "$cl" | grep -Eq '==[0-9]|@[0-9]' \
        || add MED "$f" mcp-unpinned "MCP server '$n' runs an unpinned uvx package — pin with ==X.Y.Z" ;;
  esac
}

# hook_check FILE "command" "timeout"
hook_check() {
  local f="$1" cmd="$2" t="$3" p="" w
  [ -n "$t" ] || add LOW "$f" hook-no-timeout "hook '$cmd' has no timeout (a hung hook stalls every call)"
  for w in $cmd; do case "$w" in */*) p="$w"; break ;; esac; done
  [ -n "$p" ] || return 0
  case "$p" in *CLAUDE_PLUGIN_ROOT*) return 0 ;; esac   # resolved by the plugin loader
  p="${p//\"/}"; p="${p//\$\{HOME\}/$H}"; p="${p//\$HOME/$H}"; p="${p/#\~/$H}"
  p="${p//\$\{CLAUDE_PROJECT_DIR\}/$P}"; p="${p//\$CLAUDE_PROJECT_DIR/$P}"
  case "$p" in /*) ;; *) return 0 ;; esac
  if [ ! -e "$p" ]; then add MED "$f" hook-missing "hook script $p does not exist — that guardrail never runs"
  elif [ -n "$(find -L "$p" -maxdepth 0 -perm -0002 2>/dev/null)" ] \
    || [ -n "$(find -L "$(dirname "$p")" -maxdepth 0 -perm -0002 ! -perm -1000 2>/dev/null)" ]; then
    add HIGH "$f" hook-world-writable "hook script $p (or its directory) is world-writable"
  fi
}

# Claude/Gemini-shaped JSON settings (+ any mcpServers block in them, + .mcp.json).
scan_json() {
  local f="$1" k v n c t
  [ -f "$f" ] || return 0
  jq -e . "$f" >/dev/null 2>&1 || { add MED "$f" unparseable "not valid JSON — the harness may ignore it silently"; return 0; }
  [ "$(jq -r '.permissions.defaultMode // empty' "$f")" = bypassPermissions ] \
    && add HIGH "$f" bypass-permissions "permissions.defaultMode = bypassPermissions (every tool runs unprompted)"
  [ -n "$(jq -r '[.. | strings | select(. == "yolo")] | first // empty' "$f")" ] \
    && add HIGH "$f" bypass-permissions "approval mode 'yolo' (every tool runs unprompted)"
  while IFS= read -r v; do
    [ -n "$v" ] && add HIGH "$f" wildcard-bash "allow rule '$v' pre-approves every shell command"
  done <<EOF
$(jq -r '.permissions.allow[]? | select(test("^Bash(\\((\\*|:\\*|\\*:\\*)?\\))?$"))' "$f")
EOF
  while IFS='	' read -r c t; do
    [ -n "$c" ] && hook_check "$f" "$c" "$t"
  done <<EOF
$(jq -r '.hooks // {} | .[]? | .[]? | .hooks[]? | select(.type == "command" or .command) | [.command, (.timeout // "" | tostring)] | @tsv' "$f" 2>/dev/null)
EOF
  while IFS='	' read -r k v; do
    [ -n "$k" ] && env_check "$f" "settings" "$k" "$v"
  done <<EOF
$(jq -r '.env // {} | to_entries[] | [.key, (.value | tostring)] | @tsv' "$f" 2>/dev/null)
EOF
  while IFS='	' read -r n c; do
    [ -n "$n" ] && mcp_check "$f" "$n" "$c"
  done <<EOF
$(jq -r '([.mcpServers, (.projects // {} | .[]?.mcpServers)] | map(. // {}) | add) | to_entries[] | select(.value.command) | [.key, ([.value.command] + (.value.args // []) | join(" "))] | @tsv' "$f" 2>/dev/null)
EOF
  while IFS='	' read -r n k v; do
    [ -n "$k" ] && env_check "$f" "MCP server '$n'" "$k" "$v"
  done <<EOF
$(jq -r '([.mcpServers, (.projects // {} | .[]?.mcpServers)] | map(. // {}) | add) | to_entries[] | .key as $n | (.value.env // {}) | to_entries[] | [$n, .key, (.value | tostring)] | @tsv' "$f" 2>/dev/null)
EOF
}

# Codex TOML — line-based: no TOML parser in bash, and the checks are line-local.
scan_toml() {
  local f="$1" line sec="top-level" name="" cmd="" args="" pair k v
  [ -f "$f" ] || return 0
  flush() { [ -n "$name" ] && [ -n "$cmd" ] && mcp_check "$f" "$name" "$cmd $args"; name=""; cmd=""; args=""; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    if printf '%s' "$line" | grep -Eq '^[[:space:]]*\[[^]]+\][[:space:]]*$'; then
      flush; sec="$(printf '%s' "$line" | tr -d '[:space:][]')"
      case "$sec" in mcp_servers.*.*) ;; mcp_servers.*) name="${sec#mcp_servers.}" ;; esac
      continue
    fi
    printf '%s' "$line" | grep -Eq '^[[:space:]]*sandbox_mode[[:space:]]*=[[:space:]]*"danger-full-access"' \
      && add HIGH "$f" bypass-permissions "[$sec] sandbox_mode = danger-full-access (no sandbox)"
    printf '%s' "$line" | grep -Eq '^[[:space:]]*approval_policy[[:space:]]*=[[:space:]]*"never"' \
      && add MED "$f" no-approvals "[$sec] approval_policy = never (nothing asks first)"
    if [ -n "$name" ]; then
      case "$line" in
        *command*=*) cmd="$(printf '%s' "$line" | sed -n 's/^[[:space:]]*command[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p')" ;;
        *args*=*) args="$(printf '%s' "$line" | grep -o '"[^"]*"' | tr -d '"' | tr '\n' ' ')" ;;
      esac
    fi
    while IFS= read -r pair; do
      [ -n "$pair" ] || continue
      k="$(printf '%s' "$pair" | sed 's/[[:space:]]*=.*//')"; v="$(printf '%s' "$pair" | sed 's/^[^"]*"//; s/"$//')"
      case "$k" in command|model|model_provider|approval_policy|sandbox_mode|base_url|name) continue ;; esac
      env_check "$f" "[$sec]" "$k" "$v"
    done <<EOF
$(printf '%s' "$line" | grep -oE '[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*"[^"]*"')
EOF
  done <"$f"
  flush
}

for f in "$H/.claude.json" "$H/.claude/settings.json" "$H/.claude/settings.local.json" \
         "$P/.claude/settings.json" "$P/.claude/settings.local.json" \
         "$P/.mcp.json" "$H/.gemini/settings.json"; do
  scan_json "$f"
done
scan_toml "$H/.codex/config.toml"

FINDINGS="$(printf '%s' "$FINDINGS" | sort -u | awk '{print ($1=="HIGH"?1:$1=="MED"?2:3) "\t" $0}' | sort -s -n -k1,1 | cut -f2-)"
high="$(printf '%s\n' "$FINDINGS" | grep -c '^HIGH' || true)"
if [ "$JSON" = 1 ]; then
  printf '%s\n' "$FINDINGS" | jq -R -s --argjson high "${high:-0}" \
    '{high: $high, findings: [split("\n")[] | select(length > 0) | split("\t") | {severity: .[0], file: .[1], rule: .[2], detail: .[3]}]}'
else
  printf '\033[1mcompass scan --config\033[0m  (home %s · project %s)\n' "$H" "$P"
  if [ -z "$FINDINGS" ]; then printf '  \033[32mclean\033[0m — no risky harness settings found\n'
  else printf '%s\n' "$FINDINGS" | while IFS='	' read -r s f r d; do printf '  %-4s %-28s %-20s %s\n' "$s" "$f" "$r" "$d"; done
    printf '%s HIGH finding(s)\n' "${high:-0}"
  fi
fi
[ "${high:-0}" -eq 0 ]
