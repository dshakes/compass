#!/usr/bin/env bash
# test-trace.sh — unit tests for compass trace (Agent Trace provenance for AI-assisted
# commits). Pure + fixture-based: a temp git repo, deterministic commit dates, no
# network, no real cosign required (signing paths use a stub). Mirrors test-cli.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRACE="$ROOT/scripts/compass-trace.sh"
pass=0; fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3')" ;; esac; }

command -v git >/dev/null 2>&1 || { echo "git required for trace tests" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
G="$TMP/repo"
export GIT_AUTHOR_DATE="2026-01-02T03:04:05Z" GIT_COMMITTER_DATE="2026-01-02T03:04:05Z"
git init -q "$G"; git -C "$G" config user.email t@t; git -C "$G" config user.name t
printf 'one\ntwo\nthree\n' > "$G/a.txt"
git -C "$G" add a.txt; git -C "$G" commit -qm c1
printf 'one\nTWO\nthree\nfour\n' > "$G/a.txt"
git -C "$G" add a.txt; git -C "$G" commit -qm c2
C1="$(git -C "$G" rev-parse HEAD^)"; C2="$(git -C "$G" rev-parse HEAD)"

# All invocations run inside the fixture repo with a pinned tool/model/session env.
trace() { ( cd "$G" && COMPASS_TRACE_TOOL=test-tool COMPASS_TRACE_TOOL_VERSION=1.0.0 \
            COMPASS_TRACE_MODEL='test/model-1' COMPASS_TRACE_SESSION=sess-1 bash "$TRACE" "$@" ); }

echo "emit — open-spec Agent Trace record (required fields + attribution):"
R1="$(trace emit "$C1" 2>/dev/null)"
has "spec version"            "$R1" '"version":"0.1.0"'
has "uuid-shaped id"          "$R1" "\"id\":\"${C1:0:8}-"
has "deterministic timestamp" "$R1" '"timestamp":"2026-01-02T03:04:05Z"'
has "vcs revision = commit"   "$R1" "\"vcs\":{\"type\":\"git\",\"revision\":\"$C1\"}"
has "tool from env"           "$R1" '"tool":{"name":"test-tool","version":"1.0.0"}'
has "contributor is ai"       "$R1" '"contributor":{"type":"ai","model_id":"test/model-1"}'
has "session id in metadata"  "$R1" '"session_id":"sess-1"'
has "changed file path"       "$R1" '"path":"a.txt"'
has "root commit range 1..3"  "$R1" '"ranges":[{"start_line":1,"end_line":3}]'
R2="$(trace emit "$C2" 2>/dev/null)"
has "modified line range"     "$R2" '{"start_line":2,"end_line":2}'
has "appended line range"     "$R2" '{"start_line":4,"end_line":4}'
eq  "emit is deterministic"   "$(trace emit "$C2" 2>/dev/null)" "$R2"
eq  "default commit is HEAD"  "$(trace emit 2>/dev/null)" "$R2"
if command -v jq >/dev/null 2>&1; then
  if printf '%s' "$R2" | jq -e . >/dev/null 2>&1; then ok "record is valid JSON (jq)"; else no "record is not valid JSON"; fi
else ok "jq absent — skipping JSON validity check"; fi
trace emit "$C2" --out "$TMP/rec.json" >/dev/null 2>&1
eq  "--out writes the record"  "$(cat "$TMP/rec.json")" "$R2"
if trace emit deadbeef >/dev/null 2>&1; then no "bad commit should be a usage error"; else ok "bad commit → usage error"; fi
if trace bogus >/dev/null 2>&1; then no "unknown subcommand should exit 2"; else ok "unknown subcommand rejected"; fi

echo "attach / show / verify — git-notes round trip:"
if trace attach "$C2" >/dev/null 2>&1; then ok "attach exits 0"; else no "attach should exit 0"; fi
eq  "show prints the attached record" "$(trace show "$C2" 2>/dev/null)" "$R2"
if trace attach "$C2" >/dev/null 2>&1; then ok "attach is idempotent (re-run ok)"; else no "re-attach should exit 0"; fi
V="$(trace verify "$C2" 2>&1)"; VRC=$?
eq  "verify exits 0 on a well-formed record" "$VRC" 0
has "verify reports unsigned (warning, still passes)" "$V" "unsigned"
if trace verify "$C1" >/dev/null 2>&1; then no "verify should fail with no record"; else ok "missing record → verify fails"; fi

echo "verify — malformed records are rejected:"
git -C "$G" notes --ref=refs/notes/agent-trace add -f -m 'not json at all' "$C2" 2>/dev/null
if trace verify "$C2" >/dev/null 2>&1; then no "invalid JSON should fail verify"; else ok "invalid JSON rejected"; fi
git -C "$G" notes --ref=refs/notes/agent-trace add -f -m '{"version":"0.1.0","id":"x"}' "$C2" 2>/dev/null
if trace verify "$C2" >/dev/null 2>&1; then no "missing required fields should fail"; else ok "missing required fields rejected"; fi
if command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
  printf '%s' "$R2" | sed "s/$C2/${C1}/" | git -C "$G" notes --ref=refs/notes/agent-trace add -f -F - "$C2" 2>/dev/null
  if trace verify "$C2" >/dev/null 2>&1; then no "vcs.revision mismatch should fail"; else ok "vcs.revision mismatch rejected"; fi
else ok "no jq/python3 — skipping revision-mismatch check"; fi
trace attach "$C2" >/dev/null 2>&1   # restore the good record

echo "signing — optional, degrades gracefully (stubbed cosign, no real keys):"
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/cosign" <<'EOF'
#!/usr/bin/env bash
cmd="${1:-}"; shift
if [ "$cmd" = sign-blob ]; then
  sig=""; cert=""
  while [ $# -gt 0 ]; do case "$1" in
    --output-signature) sig="$2"; shift ;; --output-certificate) cert="$2"; shift ;;
  esac; shift; done
  [ "${STUB_SIGN_RC:-0}" = 0 ] || exit 1
  [ -n "$sig" ] && printf 'RkFLRVNJRw==' > "$sig"
  [ -n "$cert" ] && : > "$cert"
  exit 0
fi
[ "$cmd" = verify-blob ] && exit "${STUB_VERIFY_RC:-0}"
exit 0
EOF
chmod +x "$STUB/cosign"
if ( cd "$G" && PATH="$STUB:$PATH" bash "$TRACE" attach "$C2" --sign >/dev/null 2>&1 ); then
  ok "attach --sign exits 0 (stub cosign)"; else no "attach --sign should exit 0"; fi
if git -C "$G" notes --ref=refs/notes/agent-trace-sig show "$C2" >/dev/null 2>&1; then
  ok "signature note attached"; else no "signature note missing"; fi
NOMAT="$( cd "$G" && PATH="$STUB:$PATH" bash "$TRACE" verify "$C2" 2>&1 )"; NORC=$?
eq  "sig present, no verification material → still passes" "$NORC" 0
has "…with an honest warning" "$NOMAT" "no verification material"
if ( cd "$G" && PATH="$STUB:$PATH" COSIGN_PUB="$STUB/cosign" STUB_VERIFY_RC=0 bash "$TRACE" verify "$C2" >/dev/null 2>&1 ); then
  ok "good signature verifies (stub rc=0)"; else no "good signature should verify"; fi
if ( cd "$G" && PATH="$STUB:$PATH" COSIGN_PUB="$STUB/cosign" STUB_VERIFY_RC=1 bash "$TRACE" verify "$C2" >/dev/null 2>&1 ); then
  no "bad signature should FAIL verify"; else ok "bad signature fails verify (exit 1)"; fi
if ( cd "$G" && PATH="$STUB:$PATH" STUB_SIGN_RC=1 bash "$TRACE" attach "$C2" --sign >/dev/null 2>&1 ); then
  ok "signing failure degrades gracefully (attach still 0)"; else no "sign failure should not fail attach"; fi

echo "CLI wiring:"
if grep -q 'trace) *run trace' "$ROOT/bin/compass"; then ok "compass trace wired into the dispatcher"; else no "trace not wired into bin/compass"; fi
HASH_HELP="$(bash "$ROOT/bin/compass" help 2>/dev/null || true)"
has "help mentions trace" "$HASH_HELP" "trace"

echo
printf 'trace tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
