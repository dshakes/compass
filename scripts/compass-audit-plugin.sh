#!/usr/bin/env bash
# compass-audit-plugin.sh — security scanner for third-party agent plugins
# (Claude Code plugin dirs, agent config repos, marketplace entries).
#
# Checks:
#   a. Injection patterns in .md files and MCP tool descriptions
#   b. Unpinned MCP servers (npx/uvx/pip refs without an exact version)
#   c. Hook scripts that fetch+execute from the network or write outside plugin dir
#   d. settings.json manipulation (hooks/scripts editing ~/.claude/settings* or CLAUDE.md)
#   e. Executable payloads (base64-decode-and-run, eval of downloaded content)
#
# Read-only — never executes target code.
# Exit: 0 = clean (or only INFO + baselined), 1 = HIGH/MED finding(s), 2 = usage error.
# Intentionally no -e: must complete all checks before reporting.
#
# --baseline rationale: the baseline is supplied as a CLI argument by the operator
# running the scan, never read from inside the scanned plugin directory. A plugin
# that could supply its own baseline would be able to suppress any finding against
# itself, defeating the scanner. Operator-controlled suppression only.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../claude/hooks/lib/policy.sh
. "$ROOT/claude/hooks/lib/policy.sh"

JSON=0; TARGET=""; BASELINE_FILE=""

usage() {
  cat <<'EOF'
compass audit-plugin <path> — security scan a third-party agent plugin directory

checks:
  a. Injection patterns in .md files and MCP tool descriptions
  b. Unpinned MCP servers (npx/uvx/pip refs without an exact version)
  c. Hook scripts that fetch+execute from the network or write outside the plugin dir
  d. settings.json manipulation (hooks/scripts editing ~/.claude/settings* or CLAUDE.md)
  e. Executable payloads (base64-decode-and-run, eval of downloaded content)

options:
  --baseline FILE  suppress findings listed in FILE (path<TAB>rule per line);
                   FILE is operator-supplied — never read from inside the plugin
  --json           machine-readable JSON output
  -h|--help        this message

exits: 0 = clean or only INFO/baselined, 1 = HIGH/MED finding(s), 2 = usage error
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json)     JSON=1 ;;
    --baseline) shift; BASELINE_FILE="${1:-}" ;;
    -h|--help)  usage; exit 0 ;;
    -*)         printf 'compass audit-plugin: unknown flag "%s"\n' "$1" >&2; usage >&2; exit 2 ;;
    *)          TARGET="$1" ;;
  esac
  shift
done

[ -n "$TARGET" ] || { printf 'compass audit-plugin: path required\n' >&2; usage >&2; exit 2; }
[ -d "$TARGET" ] || { printf 'compass audit-plugin: not a directory: %s\n' "$TARGET" >&2; exit 2; }

TARGET="$(cd "$TARGET" && pwd)"

# ── Baseline loading ───────────────────────────────────────────────────────
# Baseline is operator-supplied (CLI arg), never from inside the scanned plugin.
BASELINE=""
if [ -n "$BASELINE_FILE" ]; then
  [ -f "$BASELINE_FILE" ] || { printf 'compass audit-plugin: baseline not found: %s\n' "$BASELINE_FILE" >&2; exit 2; }
  # Strip comment lines and blanks; entries are "path<TAB>rule"
  BASELINE="$(grep -v '^[[:space:]]*#' "$BASELINE_FILE" 2>/dev/null | grep -v '^[[:space:]]*$' || true)"
fi

# Returns 0 (true) if this finding is covered by the baseline
_is_baselined() {  # <file> <rule>
  [ -n "$BASELINE" ] || return 1
  # ponytail: grep -F substring match; a path that is a prefix of another could
  # spuriously match — acceptable given typical short baseline files
  printf '%s\n' "$BASELINE" | grep -qF "$(printf '%s\t%s' "$1" "$2")"
}

# ── Finding accumulator ────────────────────────────────────────────────────
# One newline-separated record per finding: FILE\tLINE\tSEVERITY\tRULE\tEVIDENCE
FINDINGS=""

add_finding() {
  local file="$1" line="$2" sev="$3" rule="$4" evidence="$5"
  local row; row="$(printf '%s\t%s\t%s\t%s\t%s' "$file" "$line" "$sev" "$rule" "$evidence")"
  if [ -z "$FINDINGS" ]; then
    FINDINGS="$row"
  else
    FINDINGS="$FINDINGS
$row"
  fi
}

# Relative path for display
rel() { printf '%s' "${1#"$TARGET"/}"; }

# grep -nEi wrapper — never fails on no-match
grep_n() { grep -nEi -- "$1" "$2" 2>/dev/null || true; }

# Parse grep -n output: LINENUM:content (content may contain colons)
_linenum()  { printf '%s' "${1%%:*}"; }
_linebody() { printf '%s' "${1#*:}"; }

# Minimal JSON escaping for string values
_json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/ /g'; }

# ── a. Injection patterns: .md files + MCP tool descriptions ───────────────
_scan_inj_file() {   # <rel_path> <full_path>
  local rel_f="$1" full="$2" text out one
  text="$(cat "$full" 2>/dev/null)" || return 0
  out="$(injection_findings "$text")" || true
  [ -n "$out" ] || return 0
  while IFS= read -r one; do
    [ -n "$one" ] || continue
    add_finding "$rel_f" "-" "HIGH" "${one%%:*}" "${one#*: }"
  done <<EOF
$out
EOF
}

scan_injections() {
  local f
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    _scan_inj_file "$(rel "$f")" "$f"
  done <<EOF
$(find "$TARGET" -type f -name "*.md" 2>/dev/null)
EOF

  # MCP manifest: scan description + command + args blobs for injection
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    local rel_f; rel_f="$(rel "$f")"
    if command -v jq >/dev/null 2>&1; then
      local name blob out one
      while IFS=$'\t' read -r name blob; do
        [ -n "$name" ] || continue
        out="$(injection_findings "$blob")" || true
        [ -n "$out" ] || continue
        while IFS= read -r one; do
          [ -n "$one" ] || continue
          add_finding "${rel_f}:mcp:${name}" "-" "HIGH" "${one%%:*}" "${one#*: }"
        done <<INNER
$out
INNER
      done <<EOF2
$(jq -r '(.servers // .tools // {}) | to_entries[] | [.key, ((.value.description // "")+" "+(.value.command // "")+" "+((.value.args // [])|join(" ")))] | @tsv' "$f" 2>/dev/null)
EOF2
    else
      local name blob out one
      while IFS=$'\t' read -r name blob; do
        [ -n "$name" ] || continue
        out="$(injection_findings "$blob")" || true
        [ -n "$out" ] || continue
        while IFS= read -r one; do
          [ -n "$one" ] || continue
          add_finding "${rel_f}:mcp:${name}" "-" "HIGH" "${one%%:*}" "${one#*: }"
        done <<INNER
$out
INNER
      done <<EOF2
$(python3 - "$f" 2>/dev/null <<'PYEOF'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for name, v in (d.get("servers") or d.get("tools") or {}).items():
    blob = " ".join(filter(None, [v.get("description",""), v.get("command",""), " ".join(v.get("args",[]))]))
    print(name + "\t" + blob)
PYEOF
)
EOF2
    fi
  done <<EOF
$(find "$TARGET" -type f \( -name ".mcp.json" -o -name "mcp.json" -o -name "servers.json" -o -name "manifest.json" \) 2>/dev/null)
EOF
}

# ── b. Unpinned MCP servers ────────────────────────────────────────────────
_pkg_runner() { case "$1" in npx|uvx|npm|pnpm|yarn|pip|pip3|pipx) return 0 ;; *) return 1 ;; esac; }

scan_mcp_pinning() {
  local f
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    local rel_f; rel_f="$(rel "$f")"
    if command -v jq >/dev/null 2>&1; then
      local name cmd args pin
      while IFS=$'\t' read -r name cmd args pin; do
        [ -n "$name" ] || continue
        _pkg_runner "$cmd" || continue
        case "$args" in
          *@latest*) add_finding "$rel_f" "-" "HIGH" "unpinned-mcp" "$name: @latest is a floating version (pin to an exact release)" ;;
          *)
            if [ -z "$pin" ] || [ "$pin" = "null" ]; then
              add_finding "$rel_f" "-" "MED" "unpinned-mcp" "$name: $cmd package ref with no pinned version"
            else
              case "$args" in
                *"$pin"*) : ;; # pin present in args — clean
                *) add_finding "$rel_f" "-" "MED" "unpinned-mcp" "$name: declared pin '$pin' absent from args" ;;
              esac
            fi
            ;;
        esac
      done <<EOF
$(jq -r '(.servers // .tools // {}) | to_entries[] | [.key, (.value.command // ""), ((.value.args // [])|join(" ")), (.value.pin // "")] | @tsv' "$f" 2>/dev/null)
EOF
    else
      local kind name extra
      while IFS=$'\t' read -r kind name extra; do
        [ -n "$kind" ] || continue
        case "$kind" in
          LATEST) add_finding "$rel_f" "-" "HIGH" "unpinned-mcp" "$name: @latest is a floating version" ;;
          NOPIN)  add_finding "$rel_f" "-" "MED"  "unpinned-mcp" "$name: $extra package ref with no pinned version" ;;
          BADPIN) add_finding "$rel_f" "-" "MED"  "unpinned-mcp" "$name: declared pin '$extra' absent from args" ;;
        esac
      done <<EOF
$(python3 - "$f" 2>/dev/null <<'PYEOF'
import sys, json
RUNNERS = {"npx","uvx","npm","pnpm","yarn","pip","pip3","pipx"}
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for name, v in (d.get("servers") or d.get("tools") or {}).items():
    cmd = v.get("command","")
    if cmd not in RUNNERS:
        continue
    args = " ".join(v.get("args",[]))
    pin = v.get("pin","")
    if "@latest" in args:
        print("LATEST\t"+name+"\t"+cmd)
    elif not pin:
        print("NOPIN\t"+name+"\t"+cmd)
    elif pin not in args:
        print("BADPIN\t"+name+"\t"+pin)
PYEOF
)
EOF
    fi
  done <<EOF
$(find "$TARGET" -type f \( -name ".mcp.json" -o -name "mcp.json" -o -name "servers.json" \) 2>/dev/null)
EOF
}

# ── c. Hook scripts: network fetch+exec, writes outside plugin dir ──────────
# Reuses danger_reason from policy.sh (already catches curl|sh variants).
scan_hook_scripts() {
  local f rel_f gl gl_num gl_body dr
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    rel_f="$(rel "$f")"

    # c1: curl|sh style remote execute
    while IFS= read -r gl; do
      [ -n "$gl" ] || continue
      gl_num="$(_linenum "$gl")"
      gl_body="$(_linebody "$gl")"
      dr="$(danger_reason "$gl_body")" || true
      add_finding "$rel_f" "$gl_num" "HIGH" "hook-remote-exec" \
        "$(printf '%s' "${dr:-fetch+execute from network: $gl_body}" | cut -c1-80)"
    done <<EOF
$(grep_n '(curl|wget|fetch)[^|#]*\|[[:space:]]*(sudo[[:space:]]+)?[a-z]*sh' "$f")
EOF

    # c2: eval of downloaded content
    while IFS= read -r gl; do
      [ -n "$gl" ] || continue
      gl_num="$(_linenum "$gl")"
      gl_body="$(_linebody "$gl")"
      add_finding "$rel_f" "$gl_num" "HIGH" "hook-eval-download" \
        "$(printf '%s' "$gl_body" | cut -c1-80)"
    done <<EOF
$(grep_n '\b(eval|bash -c|sh -c)\b[^#]*\$\([[:space:]]*(curl|wget|fetch)' "$f")
EOF

    # c3: writes to ~/.claude / ~/.codex / ~/.gemini live config dirs
    while IFS= read -r gl; do
      [ -n "$gl" ] || continue
      gl_num="$(_linenum "$gl")"
      gl_body="$(_linebody "$gl")"
      add_finding "$rel_f" "$gl_num" "HIGH" "hook-config-write" \
        "$(printf '%s' "$gl_body" | cut -c1-80)"
    done <<EOF
$(grep_n '(>>?|tee)[[:space:]]*(~|\$HOME|\$\{HOME\})/\.(claude|codex|gemini)/' "$f")
EOF
  done <<EOF
$(find "$TARGET" -type f \( -name "*.sh" -o -name "*.bash" \) ! -path "*/lib/*" 2>/dev/null)
EOF
}

# ── d. settings.json manipulation + SessionStart persistence ───────────────
scan_settings_manipulation() {
  local f rel_f gl gl_num gl_body
  # d1: scripts writing to live ~/.claude/settings* or CLAUDE.md
  # lib/ excluded — library/policy code, not hook scripts
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    rel_f="$(rel "$f")"
    while IFS= read -r gl; do
      [ -n "$gl" ] || continue
      gl_num="$(_linenum "$gl")"
      gl_body="$(_linebody "$gl")"
      add_finding "$rel_f" "$gl_num" "HIGH" "settings-manipulation" \
        "$(printf '%s' "$gl_body" | cut -c1-80)"
    done <<EOF
$(grep_n '(~|\$HOME|\$\{HOME\})/\.claude/(settings|CLAUDE)' "$f")
EOF
  done <<EOF
$(find "$TARGET" -type f \( -name "*.sh" -o -name "*.bash" -o -name "*.py" -o -name "*.js" \) ! -path "*/lib/*" 2>/dev/null)
EOF

  # d2: hooks.json with SessionStart (runs at every session open — verify intent)
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if grep -q '"SessionStart"' "$f" 2>/dev/null; then
      add_finding "$(rel "$f")" "-" "INFO" "sessionstart-hook" \
        "plugin registers a SessionStart hook (runs at every session open; verify intent)"
    fi
  done <<EOF
$(find "$TARGET" -type f -name "hooks.json" 2>/dev/null)
EOF
}

# ── e. Executable payloads: base64-decode-and-run, eval of remote content ──
scan_exec_payloads() {
  local f rel_f gl gl_num gl_body
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    rel_f="$(rel "$f")"

    # base64 decoded and piped into a shell interpreter
    while IFS= read -r gl; do
      [ -n "$gl" ] || continue
      gl_num="$(_linenum "$gl")"
      gl_body="$(_linebody "$gl")"
      add_finding "$rel_f" "$gl_num" "HIGH" "exec-payload" \
        "$(printf '%s' "$gl_body" | cut -c1-80)"
    done <<EOF
$(grep_n 'base64[^|#]*(--decode|-d|-D)[^|#]*\|[^|#]*(sh|bash|eval|exec|python|ruby|perl)' "$f")
EOF

    # eval of command-substituted download
    while IFS= read -r gl; do
      [ -n "$gl" ] || continue
      gl_num="$(_linenum "$gl")"
      gl_body="$(_linebody "$gl")"
      add_finding "$rel_f" "$gl_num" "HIGH" "exec-payload" \
        "$(printf '%s' "$gl_body" | cut -c1-80)"
    done <<EOF
$(grep_n '\beval\b[^#]*\$\([^)#]*(curl|wget|fetch)\b' "$f")
EOF
  done <<EOF
$(find "$TARGET" -type f \( -name "*.sh" -o -name "*.bash" -o -name "*.py" -o -name "*.js" -o -name "*.md" \) ! -path "*/lib/*" 2>/dev/null)
EOF
}

# ── Run all checks ─────────────────────────────────────────────────────────
scan_injections
scan_mcp_pinning
scan_hook_scripts
scan_settings_manipulation
scan_exec_payloads

# Deduplicate (same finding from overlapping checks)
if [ -n "$FINDINGS" ]; then
  FINDINGS="$(printf '%s\n' "$FINDINGS" | sort -u | grep -v '^[[:space:]]*$')" || FINDINGS=""
fi

# ── Tally severities (baseline-accepted findings excluded from counts) ─────
count_high=0; count_med=0; count_info=0; count_accepted=0
if [ -n "$FINDINGS" ]; then
  while IFS=$'\t' read -r file _l sev rule _e; do
    [ -n "${sev:-}" ] || continue
    if _is_baselined "$file" "$rule"; then
      count_accepted=$((count_accepted + 1))
    else
      case "$sev" in
        HIGH) count_high=$((count_high + 1)) ;;
        MED)  count_med=$((count_med + 1)) ;;
        INFO) count_info=$((count_info + 1)) ;;
      esac
    fi
  done <<EOF
$FINDINGS
EOF
fi
# INFO alone does not drive a non-zero exit; only HIGH/MED do.
actionable=$((count_high + count_med))

# ── Output ─────────────────────────────────────────────────────────────────
if [ "$JSON" = 1 ]; then
  printf '{"findings":['
  first=1
  if [ -n "$FINDINGS" ]; then
    while IFS=$'\t' read -r file line sev rule evidence; do
      [ -n "${file:-}" ] || continue
      [ "$first" = 1 ] || printf ','
      first=0
      accepted=false; _is_baselined "$file" "$rule" && accepted=true || true
      printf '{"file":"%s","line":"%s","severity":"%s","rule":"%s","evidence":"%s","accepted":%s}' \
        "$(_json_esc "$file")" "$(_json_esc "$line")" "$sev" \
        "$(_json_esc "$rule")" "$(_json_esc "$evidence")" "$accepted"
    done <<EOF
$FINDINGS
EOF
  fi
  printf '],"counts":{"high":%d,"med":%d,"info":%d,"accepted":%d}}\n' \
    "$count_high" "$count_med" "$count_info" "$count_accepted"
  if [ "$actionable" -eq 0 ]; then exit 0; else exit 1; fi
fi

if [ "$actionable" -eq 0 ] && [ "$((count_info + count_accepted))" -eq 0 ]; then
  printf '\033[32m✓ audit-plugin: clean\033[0m  (%s)\n' "$TARGET"
  exit 0
fi

if [ "$actionable" -gt 0 ]; then
  printf '\033[31m✗ audit-plugin: %d HIGH/MED finding(s)\033[0m  (%s)\n\n' "$actionable" "$TARGET"
else
  printf '\033[32m✓ audit-plugin: clean\033[0m  (%s)\n\n' "$TARGET"
fi

if [ -n "$FINDINGS" ]; then
  while IFS=$'\t' read -r file line sev rule evidence; do
    [ -n "${file:-}" ] || continue
    if _is_baselined "$file" "$rule"; then
      # shellcheck disable=SC2059
      if [ "$line" = "-" ]; then
        printf "  \033[2m%-4s\033[0m  %-42s  %s: %s \033[2m(accepted: baseline)\033[0m\n" \
          "$sev" "$file" "$rule" "$evidence"
      else
        printf "  \033[2m%-4s\033[0m  %-42s  %s: %s \033[2m(accepted: baseline)\033[0m\n" \
          "$sev" "${file}:${line}" "$rule" "$evidence"
      fi
      continue
    fi
    case "$sev" in
      HIGH) col='\033[31m' ;;
      MED)  col='\033[33m' ;;
      INFO) col='\033[36m' ;;
      *)    col='' ;;
    esac
    if [ "$line" = "-" ]; then
      # shellcheck disable=SC2059
      printf "  ${col}%-4s\033[0m  %-42s  %s: %s\n" "$sev" "$file" "$rule" "$evidence"
    else
      # shellcheck disable=SC2059
      printf "  ${col}%-4s\033[0m  %-42s  %s: %s\n" "$sev" "${file}:${line}" "$rule" "$evidence"
    fi
  done <<EOF
$FINDINGS
EOF
fi
printf '\nsummary: %d HIGH  %d MED  %d INFO' "$count_high" "$count_med" "$count_info"
[ "$count_accepted" -gt 0 ] && printf '  %d accepted (baseline)' "$count_accepted"
printf '\n'
if [ "$actionable" -eq 0 ]; then exit 0; else exit 1; fi
