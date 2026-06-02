#!/usr/bin/env bash
# compass-scan.sh — secret scanning at the commit boundary.
#
# The companion to the protect-paths write-hook: the hook stops an agent from
# *writing* a secret into a file; `compass scan` stops one from *committing* a
# secret that's already on disk (yours or an agent's), in a pre-commit hook or CI.
#
# The deterministic gate is the built-in, pure detector set in claude/hooks/lib/
# policy.sh (no dependencies, same rules as the write-hook — what CI relies on).
# If `gitleaks` is installed it is *also* run for extra depth (entropy + a much
# larger ruleset); its findings are folded in but its absence never fails the run.
#
# Exit status: 0 = clean, 1 = secret(s) found, 2 = usage error. Designed to gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../claude/hooks/lib/common.sh
. "$ROOT/claude/hooks/lib/common.sh"
# shellcheck source=../claude/hooks/lib/policy.sh
. "$ROOT/claude/hooks/lib/policy.sh"

usage() {
  cat <<EOF
compass scan — find secrets before they're committed

usage: compass scan [--staged|--diff|--all] [PATH...]

  --staged   scan staged changes (default — pre-commit / CI use)
  --diff     scan unstaged working-tree changes
  --all      scan every tracked file in the repo
  PATH...    scan specific files or directories
  -h|--help  this message

Exits non-zero if a secret is found, so it gates a commit or pipeline:
  pre-commit:  compass scan --staged || exit 1
The built-in detectors are the gate; if gitleaks is installed it adds depth.
Mark a deliberate placeholder with an 'allowlist secret' comment on its line.
EOF
}

mode=staged; paths=(); strict=0
while [ $# -gt 0 ]; do
  case "$1" in
    --staged)            mode=staged ;;
    --diff|--unstaged)   mode=diff ;;
    --all)               mode=all ;;
    --strict)            strict=1 ;;   # let gitleaks findings gate too (non-deterministic)
    --gate|-q|--quiet)   : ;;   # accepted for symmetry with other compass cmds
    -h|--help)           usage; exit 0 ;;
    --)                  shift; while [ $# -gt 0 ]; do paths+=("$1"); shift; done; break ;;
    -*)                  echo "compass scan: unknown flag '$1'" >&2; usage >&2; exit 2 ;;
    *)                   paths+=("$1") ;;
  esac
  shift
done
[ ${#paths[@]} -gt 0 ] && mode=paths

in_git() { git rev-parse --git-dir >/dev/null 2>&1; }

# Turn a unified diff on stdin into a "<file>\t<added-line>" stream (added lines only).
emit_added() {
  local line file=""
  while IFS= read -r line; do
    case "$line" in
      '+++ '*) file="${line#+++ }"; file="${file#b/}" ;;
      '+'*)    printf '%s\t%s\n' "${file:-?}" "${line#+}" ;;
    esac
  done
}

# Read a "<file>\t<line>" stream and print one indented finding per detected secret.
scan_stream() {
  local file content one f
  while IFS=$'\t' read -r file content; do
    f="$(secret_content_findings "$content")" || true
    [ -n "$f" ] || continue
    while IFS= read -r one; do
      [ -n "$one" ] && printf '  %s\t%s\n' "$file" "$one"
    done <<EOF
$f
EOF
  done
}

# Scan whole files (no diff) — fast, one detector pass per file; attributed by name.
scan_files() {
  local p f one content
  for p in "$@"; do
    [ -f "$p" ] || continue
    content="$(cat "$p" 2>/dev/null)" || continue
    f="$(secret_content_findings "$content")" || true
    [ -n "$f" ] || continue
    while IFS= read -r one; do
      [ -n "$one" ] && printf '  %s\t%s\n' "$p" "$one"
    done <<EOF
$f
EOF
  done
}

# Resolve the file list for --all / PATH modes (tracked files only when in git).
resolve_files() {
  local p
  if [ "$mode" = all ]; then
    if in_git; then git ls-files -z | tr '\0' '\n'; fi
    return
  fi
  for p in "${paths[@]}"; do
    if [ -d "$p" ]; then
      if in_git; then git ls-files -z -- "$p" | tr '\0' '\n'
      else find "$p" -type f; fi
    else
      printf '%s\n' "$p"
    fi
  done
}

# --- Collect built-in findings -------------------------------------------------
case "$mode" in
  staged|diff)
    if ! in_git; then
      echo "compass scan: --${mode} requires a git repository (no .git found)" >&2
      exit 2
    fi ;;
esac
case "$mode" in
  staged) findings="$(git diff --cached --no-color -U0 | emit_added | scan_stream)" ;;
  diff)   findings="$(git diff --no-color -U0 | emit_added | scan_stream)" ;;
  all|paths)
    files="$(resolve_files)"
    if [ -n "$files" ]; then
      # shellcheck disable=SC2046
      findings="$(IFS=$'\n'; scan_files $files)"
    else findings=""; fi ;;
esac

# --- Optional gitleaks depth pass (best-effort; never fails the run) ----------
gl_note=""
if have gitleaks; then
  case "$mode" in
    staged|diff) gl_out="$(gitleaks git --no-banner --redact -v 2>/dev/null || true)" ;;
    *)           gl_out="$(gitleaks dir --no-banner --redact -v "${paths[0]:-.}" 2>/dev/null || true)" ;;
  esac
  if printf '%s' "$gl_out" | grep -qiE 'secret|finding|rule:'; then
    gl_note="$(printf '%s\n' "$gl_out" | grep -iE 'Finding|RuleID|File|Secret' | sed 's/^/  gitleaks: /' | head -40)"
  fi
fi

# --- Report --------------------------------------------------------------------
# The built-in detectors are the GATE: deterministic, dependency-free, allowlist-aware,
# so the exit code never depends on whether gitleaks happens to be installed. gitleaks
# output is advisory by default; --strict promotes it to also gate.
if [ -n "$findings" ]; then
  printf '\033[31m✗ compass scan: secret(s) found\033[0m  (mode: %s)\n' "$mode"
  printf '%s\n' "$findings" | sort -u
  [ -n "$gl_note" ] && { echo "  — gitleaks also flagged:"; printf '%s\n' "$gl_note"; }
  echo
  echo "  If a hit is a placeholder, add an 'allowlist secret' marker on that line."
  echo "  If it is real: remove it, rotate the credential, and store it outside the repo."
  compass_log_metric scan-block "secret(s) found in $mode"
  compass_log_audit block scan "secret-scan" "secret(s) found in $mode: $(printf '%s' "$findings" | tr '\n' ';' | cut -c1-200)"
  exit 1
fi

if [ -n "$gl_note" ]; then
  if [ "$strict" = 1 ]; then
    printf '\033[31m✗ compass scan: gitleaks flagged (--strict)\033[0m  (mode: %s)\n' "$mode"
    printf '%s\n' "$gl_note"
    compass_log_metric scan-block "gitleaks finding in $mode (strict)"
    compass_log_audit block scan "secret-scan-gitleaks" "gitleaks finding in $mode (strict)"
    exit 1
  fi
  printf '\033[33mℹ compass scan: built-in clean; gitleaks flagged (advisory, not gating)\033[0m\n'
  printf '%s\n' "$gl_note"
  echo "  Re-run with --strict to gate on gitleaks, or add a gitleaks allowlist."
  exit 0
fi

printf '\033[32m✓ compass scan: no secrets detected\033[0m  (mode: %s%s)\n' \
  "$mode" "$(have gitleaks && printf ', gitleaks depth on' || true)"
exit 0
