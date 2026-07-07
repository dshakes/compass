#!/usr/bin/env bash
# format-on-edit.sh — PostToolUse auto-formatter.
#
# After Claude edits a file, format just that file with the canonical formatter
# for its language, if the tool is installed. Keeps diffs clean and review-ready
# without Claude having to remember. Silent and best-effort: never fails a turn.
#
# Wired in settings.json as a PostToolUse hook matching "Edit|Write|MultiEdit".

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

INPUT="$(cat)"
FILE="$(json_get "$INPUT" '.tool_input.file_path')"
[ -z "$FILE" ] && exit 0
[ -f "$FILE" ] || exit 0

fmt() { "$@" >/dev/null 2>&1 && _fmt_ran=1 || true; }

case "$FILE" in
  # JSONC guard: tsconfig / .vscode / *.jsonc are JSON-with-comments despite the
  # .json name; biome/prettier can strip those comments, so skip formatting them.
  *tsconfig*.json|*/.vscode/*.json|*.jsonc) : ;;
  *.go)
    have gofmt   && fmt gofmt -w "$FILE"
    have goimports && fmt goimports -w "$FILE" ;;
  *.rs)
    have rustfmt && fmt rustfmt --edition 2021 "$FILE" ;;
  *.ts|*.tsx|*.js|*.jsx|*.json|*.css|*.md|*.mdx|*.yaml|*.yml)
    if have biome; then fmt biome format --write "$FILE"
    elif have prettier; then fmt prettier --write "$FILE"
    elif npx --no-install prettier --version >/dev/null 2>&1; then fmt npx --no-install prettier --write "$FILE"
    fi ;;
  *.py)
    if have ruff; then fmt ruff format "$FILE"; fmt ruff check --fix "$FILE"
    elif have black; then fmt black -q "$FILE"
    fi ;;
  *.sh)
    have shfmt && fmt shfmt -w "$FILE" ;;
  *.tf)
    have terraform && fmt terraform fmt "$FILE" ;;
  *.proto)
    have buf && fmt buf format -w "$FILE" ;;
esac

[ -n "${_fmt_ran:-}" ] && compass_log_metric format "${FILE##*.}"
exit 0
