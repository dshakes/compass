#!/usr/bin/env bash
# compass-trace.sh — verifiable provenance for AI-assisted commits (Agent Trace).
#
# Emits records in the open Agent Trace format (https://github.com/cursor/agent-trace,
# field names checked against the spec's schemas on 2026-06-10): a JSON record linking a
# commit's changed line ranges to the tool / model / session that produced them. The
# record is stored as a git note under refs/notes/agent-trace, and — when cosign is
# installed and signing is requested — signed (cosign sign-blob) with the signature
# attached under refs/notes/agent-trace-sig. Everything degrades gracefully: no cosign,
# no jq, no problem. It never blocks a commit; the human merge gate is the control.
#
#   compass trace emit   [<commit>] [--out FILE]   # print the record (default HEAD)
#   compass trace attach [<commit>] [--sign]       # store it as a git note (idempotent)
#   compass trace show   [<commit>]                # print the attached record
#   compass trace verify [<commit>]                # 0 = well-formed (+ signature if any)
#
# Env: COMPASS_TRACE_TOOL / _TOOL_VERSION   tool that produced the code (auto: claude-code)
#      COMPASS_TRACE_MODEL                  contributor model_id, e.g. anthropic/claude-opus-4-5
#      COMPASS_TRACE_SESSION                conversation/session id (auto: $CLAUDE_SESSION_ID)
#      COMPASS_TRACE_CONVERSATION_URL       URL to the conversation, if one exists
#      COMPASS_TRACE_SIGN=1                 sign on attach (same as --sign)
#      COSIGN_KEY / COSIGN_PUB              key-based signing / verification
#      COMPASS_TRACE_CERT_IDENTITY + COMPASS_TRACE_OIDC_ISSUER   keyless verification
#
# Notes are local by default — share them with: git push origin refs/notes/agent-trace
# Exit: 0 = ok · 1 = verification FAILED · 2 = usage error.
set -uo pipefail

SPEC_VERSION="0.1.0"
NOTES_REF="refs/notes/agent-trace"
SIG_REF="refs/notes/agent-trace-sig"

have() { command -v "$1" >/dev/null 2>&1; }
note() { printf '  %s\n' "$*" >&2; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*" >&2; }
die()  { printf 'compass trace: %s\n' "$*" >&2; exit 2; }

usage() {
  cat <<EOF
usage: compass trace <emit|attach|show|verify> [<commit>] [flags]

  emit   [<commit>] [--out FILE]   print an Agent Trace record for a commit (default HEAD)
  attach [<commit>] [--sign]       store the record as a git note ($NOTES_REF)
  show   [<commit>]                print the attached record
  verify [<commit>]                exit 0 if a well-formed record is attached;
                                   verifies the cosign signature when one exists
EOF
}

# JSON string escaping for the values we embed (paths, env-derived strings).
json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

# Changed-file line ranges (new side) as "path<TAB>start<TAB>end", one per hunk.
diff_ranges() {
  local sha="$1"
  if git rev-parse -q --verify "$sha^" >/dev/null 2>&1; then
    git diff --unified=0 --no-color --diff-filter=d "$sha^" "$sha"
  else
    git diff-tree --root -r -p --unified=0 --no-color --no-commit-id "$sha"
  fi | awk '
    /^\+\+\+ b\// { f = $0; sub(/^\+\+\+ b\//, "", f); next }
    /^\+\+\+ /    { f = ""; next }
    /^@@ /        { if (f == "") next
                    if (match($0, /\+[0-9]+(,[0-9]+)?/)) {
                      h = substr($0, RSTART + 1, RLENGTH - 1)
                      n = split(h, a, ","); s = a[1] + 0; c = (n > 1 ? a[2] + 0 : 1)
                      if (c > 0) printf "%s\t%d\t%d\n", f, s, s + c - 1
                    } }'
}

# Deterministic record id derived from the commit sha (UUID-shaped, stable across runs).
uuid_for() { local s="$1"; printf '%s-%s-5%s-8%s-%s' "${s:0:8}" "${s:8:4}" "${s:12:3}" "${s:15:3}" "${s:18:12}"; }

# Build the Agent Trace record for a commit, on stdout (one line, deterministic).
emit_record() {
  local sha="$1" tool toolver model ctype session conv_url repo ts contrib urlpart role run_id
  tool="${COMPASS_TRACE_TOOL:-${CLAUDE_SESSION_ID:+claude-code}}"; tool="${tool:-unknown}"
  toolver="${COMPASS_TRACE_TOOL_VERSION:-unknown}"
  model="${COMPASS_TRACE_MODEL:-}"
  ctype="${COMPASS_TRACE_CONTRIBUTOR:-ai}"
  session="${COMPASS_TRACE_SESSION:-${CLAUDE_SESSION_ID:-}}"
  conv_url="${COMPASS_TRACE_CONVERSATION_URL:-}"
  role="${COMPASS_TRACE_ROLE:-}"
  run_id="${COMPASS_TRACE_RUN:-}"
  repo="$(git config --get remote.origin.url 2>/dev/null || true)"
  [ -n "$repo" ] || repo="$(basename "$(git rev-parse --show-toplevel)")"
  ts="$(TZ=UTC0 git show -s --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ "$sha")"

  contrib="{\"type\":\"$(json_escape "$ctype")\""
  [ -n "$model" ] && contrib="$contrib,\"model_id\":\"$(json_escape "$model")\""
  contrib="$contrib}"
  urlpart=""
  [ -n "$conv_url" ] && urlpart="\"url\":\"$(json_escape "$conv_url")\","

  local files_json="" cur="" ranges="" f s e
  flush() {
    [ -n "$cur" ] || return 0
    files_json="$files_json${files_json:+,}{\"path\":\"$(json_escape "$cur")\",\"conversations\":[{${urlpart}\"contributor\":$contrib,\"ranges\":[$ranges]}]}"
  }
  while IFS=$'\t' read -r f s e; do
    [ -n "$f" ] || continue
    if [ "$f" != "$cur" ]; then flush; cur="$f"; ranges=""; fi
    ranges="$ranges${ranges:+,}{\"start_line\":$s,\"end_line\":$e}"
  done < <(diff_ranges "$sha")
  flush

  local meta
  meta="{\"generator\":\"compass-trace\",\"repo\":\"$(json_escape "$repo")\""
  [ -n "$session" ] && meta="$meta,\"session_id\":\"$(json_escape "$session")\""
  [ -n "$role" ]    && meta="$meta,\"role\":\"$(json_escape "$role")\""
  [ -n "$run_id" ]  && meta="$meta,\"run_id\":\"$(json_escape "$run_id")\""
  meta="$meta}"

  printf '{"version":"%s","id":"%s","timestamp":"%s","vcs":{"type":"git","revision":"%s"},"tool":{"name":"%s","version":"%s"},"files":[%s],"metadata":%s}\n' \
    "$SPEC_VERSION" "$(uuid_for "$sha")" "$ts" "$sha" \
    "$(json_escape "$tool")" "$(json_escape "$toolver")" "$files_json" "$meta"
}

# Well-formedness: valid JSON + the spec's required fields, and — when we can parse —
# the record's vcs.revision must match the commit it's attached to.
record_ok() {
  local file="$1" sha="$2"
  if have jq; then
    jq -e --arg sha "$sha" '
      (.version|type) == "string" and (.id|type) == "string"
      and (.timestamp|type) == "string" and (.files|type) == "array"
      and ([.files[] | (.path|type) == "string" and (.conversations|type) == "array"] | all)
      and ((has("vcs")|not) or .vcs.revision == $sha)' <"$file" >/dev/null 2>&1
  elif have python3; then
    python3 - "$file" "$sha" <<'PY' 2>/dev/null
import json, sys
try:
    r = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
ok = (isinstance(r, dict)
      and isinstance(r.get("version"), str) and isinstance(r.get("id"), str)
      and isinstance(r.get("timestamp"), str) and isinstance(r.get("files"), list)
      and all(isinstance(f, dict) and isinstance(f.get("path"), str)
              and isinstance(f.get("conversations"), list) for f in r["files"])
      and ("vcs" not in r or r["vcs"].get("revision") == sys.argv[2]))
sys.exit(0 if ok else 1)
PY
  else  # last-resort shape check (no JSON parser available)
    grep -q '"version"' "$file" && grep -q '"id"' "$file" \
      && grep -q '"timestamp"' "$file" && grep -q '"files"' "$file"
  fi
}

# Sign the attached record with cosign and store the signature as a second note:
# line 1 = base64 signature, rest = certificate (keyless). Best-effort by design.
sign_record() {
  local sha="$1" blob sigf certf
  if ! have cosign; then warn "cosign not installed — attached unsigned"; return 0; fi
  blob="$(mktemp)"; sigf="$(mktemp)"; certf="$(mktemp)"
  git notes --ref="$NOTES_REF" show "$sha" >"$blob" 2>/dev/null
  local args=(sign-blob --yes --output-signature "$sigf" --output-certificate "$certf")
  [ -n "${COSIGN_KEY:-}" ] && args+=(--key "$COSIGN_KEY")
  if cosign "${args[@]}" "$blob" >/dev/null 2>&1; then
    { cat "$sigf"; echo; cat "$certf"; } | git notes --ref="$SIG_REF" add -f -F - "$sha" 2>/dev/null
    note "signed: $SIG_REF @ ${sha:0:12}"
  else
    warn "cosign signing failed — attached unsigned"
  fi
  rm -f "$blob" "$sigf" "$certf"
}

# Verify the signature note against the record, when verification material exists.
verify_signature() {
  local sha="$1" signote blob sigf certf
  signote="$(git notes --ref="$SIG_REF" show "$sha" 2>/dev/null)" || { warn "unsigned — no signature note ($SIG_REF)"; return 0; }
  if ! have cosign; then warn "signature attached but cosign not installed — cannot verify"; return 0; fi
  blob="$(mktemp)"; sigf="$(mktemp)"; certf="$(mktemp)"
  git notes --ref="$NOTES_REF" show "$sha" >"$blob" 2>/dev/null
  printf '%s\n' "$signote" | head -n1 >"$sigf"
  printf '%s\n' "$signote" | tail -n +2 | grep -v '^$' >"$certf" || true
  local args=(verify-blob --signature "$sigf")
  if [ -n "${COSIGN_PUB:-}" ]; then
    args+=(--key "$COSIGN_PUB")
  elif [ -s "$certf" ] && [ -n "${COMPASS_TRACE_CERT_IDENTITY:-}" ] && [ -n "${COMPASS_TRACE_OIDC_ISSUER:-}" ]; then
    args+=(--certificate "$certf" --certificate-identity "$COMPASS_TRACE_CERT_IDENTITY" --certificate-oidc-issuer "$COMPASS_TRACE_OIDC_ISSUER")
  else
    warn "signature attached but no verification material (set COSIGN_PUB, or COMPASS_TRACE_CERT_IDENTITY + COMPASS_TRACE_OIDC_ISSUER for keyless)"
    rm -f "$blob" "$sigf" "$certf"; return 0
  fi
  if cosign "${args[@]}" "$blob" >/dev/null 2>&1; then
    printf '\033[32m  ✓ signature verified (cosign)\033[0m\n' >&2
    rm -f "$blob" "$sigf" "$certf"; return 0
  fi
  printf '\033[31m  ✗ signature verification FAILED\033[0m\n' >&2
  rm -f "$blob" "$sigf" "$certf"; return 1
}

cmd="${1:-help}"; [ "$#" -gt 0 ] && shift
COMMIT=""; OUT=""; SIGN="${COMPASS_TRACE_SIGN:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --out)  OUT="${2:-}"; [ -n "$OUT" ] || die "--out needs a file"; shift ;;
    --sign) SIGN=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag '$1'" ;;
    *)  [ -z "$COMMIT" ] || die "unexpected arg '$1'"; COMMIT="$1" ;;
  esac
  shift
done

case "$cmd" in
  emit|attach|show|verify) ;;
  -h|--help|help) usage; exit 0 ;;
  *) printf 'compass trace: unknown subcommand %s\n\n' "$cmd" >&2; usage >&2; exit 2 ;;
esac

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
SHA="$(git rev-parse --verify "${COMMIT:-HEAD}^{commit}" 2>/dev/null)" || die "cannot resolve commit '${COMMIT:-HEAD}'"

case "$cmd" in
  emit)
    if [ -n "$OUT" ]; then emit_record "$SHA" >"$OUT"; note "wrote $OUT"
    else emit_record "$SHA"; fi
    ;;
  attach)
    TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
    emit_record "$SHA" >"$TMP"
    git notes --ref="$NOTES_REF" add -f -F "$TMP" "$SHA" 2>/dev/null || die "could not attach note ($NOTES_REF)"
    note "attached: $NOTES_REF @ ${SHA:0:12}"
    [ "$SIGN" = 1 ] && sign_record "$SHA"
    note "share it: git push origin $NOTES_REF"
    ;;
  show)
    git notes --ref="$NOTES_REF" show "$SHA" 2>/dev/null || { printf 'compass trace: no record attached to %s\n' "${SHA:0:12}" >&2; exit 1; }
    ;;
  verify)
    TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
    if ! git notes --ref="$NOTES_REF" show "$SHA" >"$TMP" 2>/dev/null; then
      printf '\033[31m✗ no Agent Trace record attached to %s\033[0m\n' "${SHA:0:12}" >&2; exit 1
    fi
    if ! record_ok "$TMP" "$SHA"; then
      printf '\033[31m✗ attached record is malformed (invalid JSON, missing required fields, or revision mismatch)\033[0m\n' >&2; exit 1
    fi
    verify_signature "$SHA" || exit 1
    printf '\033[32m✓ Agent Trace record verified for %s\033[0m\n' "${SHA:0:12}"
    ;;
esac
