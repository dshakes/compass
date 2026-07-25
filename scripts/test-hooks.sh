#!/usr/bin/env bash
# test-hooks.sh — behavior tests for the three non-guardrail hooks that run on the hot
# path of every session: format-on-edit.sh (PostToolUse formatter), checkpoint-wip.sh
# (Stop snapshot), inject-context.sh (SessionStart primer).
#
# What these hooks must never do is the point of the corpus: mangle a file they don't
# own (JSONC), touch the working tree, or break a turn when a formatter is missing or
# broken. Every "silent, best-effort" claim in their headers is pinned here.
#
# Hermetic: temp git repos + stub formatters on a shadowing PATH, so no real gofmt /
# biome / ruff is required and the result is the same on every machine. No network.
# Runs in CI. Mirrors the style of scripts/test-protect-paths.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FMT="$ROOT/claude/hooks/format-on-edit.sh"
WIP="$ROOT/claude/hooks/checkpoint-wip.sh"
CTX="$ROOT/claude/hooks/inject-context.sh"

pass=0; fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3')" ;; esac; }
lacks() { case "$2" in *"$3"*) no "$1 (unexpectedly contains '$3')" ;; *) ok "$1" ;; esac; }

command -v git >/dev/null 2>&1 || { echo "git required for hook tests" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/compass-hooks.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- fixtures ----
# Stub formatters: each appends a marker to any file argument, so "did the hook run
# the formatter?" is observable without installing gofmt/biome/ruff/shfmt.
STUB="$TMP/stub"; mkdir -p "$STUB"
mkstub() {
  printf '%s\n' '#!/usr/bin/env bash' \
    'for a in "$@"; do [ -f "$a" ] && printf "FORMATTED\n" >> "$a"; done' \
    'exit 0' > "$STUB/$1"
  chmod +x "$STUB/$1"
}
for t in gofmt goimports biome prettier ruff black shfmt terraform buf; do mkstub "$t"; done
# A formatter that is installed but fails — the hook must still exit 0 and leave the file alone.
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$STUB/rustfmt"; chmod +x "$STUB/rustfmt"

# A PATH with the hook's own dependencies but NO formatter of any kind, so
# `have <formatter>` is deterministically false rather than machine-dependent.
MIN="$TMP/minbin"; mkdir -p "$MIN"
for t in bash sh cat grep sed awk jq python3 date mkdir basename dirname git env; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$MIN/$t"
done

MET="$TMP/metrics"   # COMPASS_HOME for the hooks, so nothing lands in ~/.compass

# run_fmt <path-to-run-hook-with> [PATH-override] — feeds hook-shaped JSON on stdin.
# Always runs from $TMP so a stray metric/git lookup can never touch the real repo.
run_fmt() {
  local path="$1" pathenv="${2:-$STUB:$PATH}" json
  json="$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$path")"
  RC=0
  printf '%s' "$json" | ( cd "$TMP" && PATH="$pathenv" COMPASS_HOME="$MET" bash "$FMT" ) >/dev/null 2>&1 || RC=$?
}
# formatted <label> <file> — the stub marker landed (the hook did format it).
formatted()   { if grep -q FORMATTED "$2" 2>/dev/null; then ok "$1"; else no "$1 (not formatted)"; fi; }
untouched()   { if grep -q FORMATTED "$2" 2>/dev/null; then no "$1 (was formatted, should not be)"; else ok "$1"; fi; }
mkfile()      { printf '%s\n' "${2:-x}" > "$TMP/$1"; printf '%s' "$TMP/$1"; }

echo "format-on-edit — formats the file types it claims to, with the canonical tool:"
for f in a.go a.ts a.tsx a.js a.json a.css a.md a.yaml a.py a.sh a.tf a.proto; do
  p="$(mkfile "$f")"; run_fmt "$p"
  eq "exit 0 for $f" "$RC" 0
  formatted "formatted $f" "$p"
done

echo "format-on-edit — JSONC guard: comment-bearing JSON is NEVER reformatted:"
for f in tsconfig.json tsconfig.build.json settings.jsonc; do
  p="$(mkfile "$f" '{ // a comment biome would strip
  "a": 1 }')"
  run_fmt "$p"
  eq "exit 0 for $f" "$RC" 0
  untouched "left $f alone" "$p"
done
mkdir -p "$TMP/.vscode"; p="$TMP/.vscode/settings.json"; printf '{ // comment\n}\n' > "$p"
run_fmt "$p"; untouched "left .vscode/settings.json alone" "$p"

echo "format-on-edit — unsupported / unknown extensions are left alone:"
for f in a.txt a.rb a.bin Dockerfile; do
  p="$(mkfile "$f")"; run_fmt "$p"
  eq "exit 0 for $f" "$RC" 0
  untouched "left $f alone" "$p"
done

echo "format-on-edit — degrades quietly (a turn must never fail on a missing tool):"
p="$(mkfile "nofmt.sh")"; before="$(cat "$p")"
run_fmt "$p" "$MIN"
eq  "exit 0 with no formatter installed" "$RC" 0
eq  "file unchanged with no formatter installed" "$(cat "$p")" "$before"
p="$(mkfile "broken.rs")"; before="$(cat "$p")"
run_fmt "$p"
eq  "exit 0 when the formatter itself fails" "$RC" 0
eq  "file unchanged when the formatter fails" "$(cat "$p")" "$before"
run_fmt "$TMP/does-not-exist.go";  eq "exit 0 for a nonexistent file"  "$RC" 0
RC=0; printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | \
  ( cd "$TMP" && PATH="$STUB:$PATH" COMPASS_HOME="$MET" bash "$FMT" ) >/dev/null 2>&1 || RC=$?
eq "exit 0 when there is no file_path at all" "$RC" 0
RC=0; printf 'not json at all' | \
  ( cd "$TMP" && PATH="$STUB:$PATH" COMPASS_HOME="$MET" bash "$FMT" ) >/dev/null 2>&1 || RC=$?
eq "exit 0 on malformed stdin" "$RC" 0

echo "format-on-edit — logs the impact metric only when it actually formatted:"
has "metric recorded for a formatted file" "$(cat "$MET/metrics.tsv" 2>/dev/null)" "format"
M2="$TMP/metrics2"; RC=0
printf '{"tool_input":{"file_path":"%s"}}' "$(mkfile skip.txt)" | \
  ( cd "$TMP" && PATH="$STUB:$PATH" COMPASS_HOME="$M2" bash "$FMT" ) >/dev/null 2>&1 || RC=$?
lacks "no metric when nothing was formatted" "$(cat "$M2/metrics.tsv" 2>/dev/null)" "format"

# ------------------------------------------------------------ checkpoint-wip ----
newrepo() { # <dir> — a repo with one commit; echoes the dir
  local g="$1"
  git init -q "$g"
  git -C "$g" config user.email t@t; git -C "$g" config user.name t
  printf 'one\n' > "$g/a.txt"
  git -C "$g" add a.txt
  git -C "$g" commit -qm c1
  printf '%s' "$g"
}
run_wip() { # <cwd-json-value> — runs the Stop hook; always from a safe cwd
  RC=0
  printf '{"cwd":"%s"}' "$1" | ( cd "$TMP" && bash "$WIP" ) >/dev/null 2>&1 || RC=$?
}

echo "checkpoint-wip — snapshots dirty work to refs/compass/wip/<branch>:"
G="$(newrepo "$TMP/wip1")"
BR="$(git -C "$G" rev-parse --abbrev-ref HEAD)"
printf 'one\nTWO-uncommitted\n' > "$G/a.txt"
STATUS_BEFORE="$(git -C "$G" status --porcelain)"; HEAD_BEFORE="$(git -C "$G" rev-parse HEAD)"
run_wip "$G"
eq  "exit 0"                     "$RC" 0
if git -C "$G" show-ref --verify --quiet "refs/compass/wip/$BR"; then ok "created refs/compass/wip/$BR"
else no "did not create refs/compass/wip/$BR"; fi
# The promise is a RESTORABLE snapshot, not just a ref that exists.
eq  "snapshot holds the uncommitted content" \
    "$(git -C "$G" show "refs/compass/wip/$BR:a.txt" 2>/dev/null)" "$(printf 'one\nTWO-uncommitted')"
echo "checkpoint-wip — never destroys working-tree state:"
eq  "working tree content preserved" "$(cat "$G/a.txt")" "$(printf 'one\nTWO-uncommitted\n')"
eq  "git status unchanged"           "$(git -C "$G" status --porcelain)" "$STATUS_BEFORE"
eq  "HEAD unchanged"                 "$(git -C "$G" rev-parse HEAD)" "$HEAD_BEFORE"
eq  "branch history untouched"       "$(git -C "$G" rev-list --count HEAD)" 1
eq  "stash list untouched"           "$(git -C "$G" stash list | wc -l | tr -d ' ')" 0

echo "checkpoint-wip — staged changes are snapshotted too:"
G2="$(newrepo "$TMP/wip2")"; BR2="$(git -C "$G2" rev-parse --abbrev-ref HEAD)"
printf 'staged\n' > "$G2/a.txt"; git -C "$G2" add a.txt
run_wip "$G2"
eq "exit 0" "$RC" 0
if git -C "$G2" show-ref --verify --quiet "refs/compass/wip/$BR2"; then ok "snapshotted a staged-only change"
else no "staged-only change was not snapshotted"; fi
eq "index still staged" "$(git -C "$G2" diff --cached --name-only)" "a.txt"

echo "checkpoint-wip — no-ops it must not turn into work:"
G3="$(newrepo "$TMP/wip3")"; BR3="$(git -C "$G3" rev-parse --abbrev-ref HEAD)"
run_wip "$G3"
eq "exit 0 on a clean tree" "$RC" 0
if git -C "$G3" show-ref --verify --quiet "refs/compass/wip/$BR3"; then no "created a ref for a clean tree"
else ok "no ref created for a clean tree"; fi
# Untracked-only: `git stash create` cannot capture it, so the documented behaviour is
# "no snapshot" — pinned here so the limitation is visible instead of assumed.
printf 'new\n' > "$G3/untracked.txt"
run_wip "$G3"
eq "exit 0 with only untracked files" "$RC" 0
if [ -f "$G3/untracked.txt" ]; then ok "untracked file left in place"; else no "untracked file disappeared"; fi
run_wip "$TMP/not-a-repo-$$"
eq "exit 0 when cwd does not exist" "$RC" 0
NOGIT="$TMP/plain"; mkdir -p "$NOGIT"; printf 'x\n' > "$NOGIT/f.txt"
run_wip "$NOGIT"
eq "exit 0 outside a git repo" "$RC" 0
RC=0; printf '{}' | ( cd "$NOGIT" && bash "$WIP" ) >/dev/null 2>&1 || RC=$?
eq "exit 0 with no cwd field (falls back to \$PWD)" "$RC" 0

echo "checkpoint-wip — detached HEAD and slashed branch names do not break it:"
G4="$(newrepo "$TMP/wip4")"
git -C "$G4" checkout -q -b feature/deep/name
printf 'dirty\n' > "$G4/a.txt"
run_wip "$G4"
eq "exit 0 on a slashed branch" "$RC" 0
if git -C "$G4" show-ref --verify --quiet 'refs/compass/wip/feature/deep/name'; then ok "ref path handles slashed branch"
else no "slashed branch produced no ref"; fi
git -C "$G4" checkout -q --detach
printf 'dirtier\n' > "$G4/a.txt"
run_wip "$G4"
eq "exit 0 on detached HEAD" "$RC" 0
eq "working tree survives detached HEAD run" "$(cat "$G4/a.txt")" "$(printf 'dirtier\n')"

# ------------------------------------------------------------ inject-context ----
run_ctx() { RC=0; OUT="$(cd "$1" && printf '{"hook_event_name":"SessionStart"}' | bash "$CTX" 2>/dev/null)" || RC=$?; }
valid_json() {
  local rc=0
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$2" | jq -e . >/dev/null 2>&1 || rc=$?
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$2" | python3 -c 'import sys,json;json.load(sys.stdin)' 2>/dev/null || rc=$?
  else
    ok "$1 (skipped — no jq/python3)"; return 0
  fi
  if [ "$rc" -eq 0 ]; then ok "$1"; else no "$1 (invalid JSON)"; fi
}

echo "inject-context — emits a SessionStart additionalContext payload:"
G5="$(newrepo "$TMP/ctx1")"
git -C "$G5" checkout -q -b orient/branch
printf 'two\n' >> "$G5/a.txt"; printf 'new\n' > "$G5/b.txt"
run_ctx "$G5"
eq    "exit 0"                     "$RC" 0
valid_json "output is valid JSON"  "$OUT"
has   "correct hook event"         "$OUT" '"hookEventName":"SessionStart"'
has   "carries additionalContext"  "$OUT" '"additionalContext"'
has   "names the branch"           "$OUT" 'Branch: orient/branch'
has   "counts uncommitted files"   "$OUT" 'Uncommitted files: 2'
has   "lists recent commits"       "$OUT" 'c1'
has   "commits fenced as data (injection guard)" "$OUT" 'data, not instructions'
has   "reminds about CLAUDE.md"    "$OUT" 'CLAUDE.md'
lacks "no upstream => no ahead/behind noise" "$OUT" 'behind'

echo "inject-context — reports ahead/behind once an upstream exists:"
git init -q --bare "$TMP/remote.git"
git -C "$G5" add -A >/dev/null 2>&1; git -C "$G5" commit -qm c2
git -C "$G5" remote add origin "$TMP/remote.git"
git -C "$G5" push -q -u origin orient/branch >/dev/null 2>&1
git -C "$G5" commit -q --allow-empty -m c3
run_ctx "$G5"
has "shows ahead count" "$OUT" 'ahead 1'
has "shows behind count" "$OUT" 'behind 0'
eq  "clean tree reports zero uncommitted" "$(printf '%s' "$OUT" | grep -c 'Uncommitted files: 0')" 1

echo "inject-context — stays silent when there is nothing to inject:"
run_ctx "$NOGIT"
eq "exit 0 outside a git repo"       "$RC" 0
eq "emits nothing outside a git repo" "$OUT" ""

echo
printf 'hook behavior corpus: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
