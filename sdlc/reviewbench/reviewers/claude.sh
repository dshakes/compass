#!/usr/bin/env bash
# claude.sh <case-dir> — real reviewer: the orchestrate.sh review step (same reviewer role,
# SDLC_REVIEW_MODEL default sonnet, read-only plan mode) with the output format swapped for
# JSON lines. Hard cap $0.25/case; a timeout/budget/auth failure exits non-zero for THIS case.
set -uo pipefail
dir="$(cd "$1" && pwd)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MODEL="${SDLC_REVIEW_MODEL:-sonnet}"
command -v claude >/dev/null || { echo "claude CLI required" >&2; exit 2; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cp -R "$dir/base/." "$work/"
git -C "$work" init -q && git -C "$work" add -A \
  && git -C "$work" -c user.name=rb -c user.email=rb@example.invalid commit -qm base \
  && git -C "$work" apply "$dir/diff.patch" || { echo "could not stage case" >&2; exit 2; }

PROMPT="Review the uncommitted diff in this repo: run 'git diff'. Report only real defects the diff introduces (correctness, security, resource handling); if the diff is correct, report nothing. Output ONLY JSON lines, one per finding, no prose and no code fences: {\"file\":\"<path relative to repo root>\",\"line\":<line number in the NEW version of the file>,\"severity\":\"blocking|should-fix|nit\",\"message\":\"<one sentence>\"}. Print nothing at all if there are no findings."

json="$work/.rb-out.json"
(cd "$work" && claude -p "$PROMPT" --model "$MODEL" \
  --append-system-prompt-file "$ROOT/sdlc/roles/reviewer.md" \
  --permission-mode plan --allowedTools "Read,Grep,Glob,Bash(git diff:*),Bash(git log:*)" \
  --max-turns 25 --max-budget-usd 0.25 --output-format json >"$json" 2>"$work/.rb-err") \
  || { tail -1 "$work/.rb-err" >&2; echo "claude failed" >&2; exit 1; }

python3 - "$json" <<'PY'
import json, sys
o = json.load(open(sys.argv[1]))
if o.get("is_error") or str(o.get("subtype", "success")) != "success":
    sys.stderr.write("claude: %s\n" % (o.get("subtype") or o.get("result") or "error"))
    print(json.dumps({"meta": {"cost_usd": o.get("total_cost_usd", 0)}}))
    sys.exit(1)
print(json.dumps({"meta": {"cost_usd": o.get("total_cost_usd", 0)}}))
for ln in str(o.get("result", "")).splitlines():
    ln = ln.strip()
    if ln.startswith("{"):
        try:
            f = json.loads(ln)
        except ValueError:
            continue
        if "file" in f and "line" in f:
            print(json.dumps(f))
PY
