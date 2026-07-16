#!/usr/bin/env bash
# format-on-edit.sh — runs gofmt on modified Go files after an edit.
# Clean hook: local-only, no network, no config writes.
set -uo pipefail
input="$(cat)"
file="$(printf '%s' "$input" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("file_path",""))' 2>/dev/null)"
case "$file" in *.go) gofmt -w "$file" 2>/dev/null || true ;; esac
