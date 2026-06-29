#!/usr/bin/env bash
# compass-digest.sh — the comprehension-rot guard.
#
# A self-running loop's quietest cost: code ships faster than your understanding of it grows,
# until a bug hides in a corner you never read. The defense (from the loop-engineering playbook)
# is not to read everything — that defeats the loop — but to read a REPRESENTATIVE SAMPLE,
# regularly, and force yourself to explain each change. An inability to explain is the precise
# signal your mental map has fallen behind.
#
# `compass digest` samples recently-merged changes you (probably) didn't hand-write, shows each
# as a question — "explain what this did and why" — then reveals the recorded rationale so you
# can self-check. It tracks what it has shown in a ledger, so each run surfaces UNREVIEWED work
# and reports your lag (how far the codebase is ahead of your map).
#
#   Ledger:  ${COMPASS_HOME:-~/.compass}/digest.tsv   (ts<TAB>repo<TAB>ref)
#   Source:  gh merged PRs if available, else git first-parent history (override: COMPASS_DIGEST_SOURCE=git|gh)
#
# Usage: compass digest [-n N] [--since DATE] [--all] [--json] [--mark REF] [--reset] [DIR]
#   -n N         sample size (default 3)
#   --since D    only consider changes since D (git approxidate / ISO date)
#   --all        ignore the ledger (show newest regardless of what you've seen)
#   --json       machine-readable (the sample + lag counts), no rationale reveal
#   --mark REF   record REF as reviewed without showing it (then exit)
#   --reset      clear this repo's digest ledger (then exit)
#   DIR          repo to inspect (default: cwd)
#
# Deterministic and local: no model call, nothing leaves your machine. Read-only on the repo;
# the only thing it writes is its own ledger under COMPASS_HOME. Bash 3.2 compatible (no assoc
# arrays): candidate changes flow through a tab-separated record stream, not parallel maps.
set -euo pipefail

COMPASS_HOME="${COMPASS_HOME:-$HOME/.compass}"
LEDGER="$COMPASS_HOME/digest.tsv"
WINDOW=60   # consider this many recent changes when looking for unreviewed ones

N=3; SINCE=""; ALL=0; JSON=0; MARK=""; RESET=0; DIR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n)        [ "$#" -ge 2 ] || { echo "-n requires a value" >&2; exit 2; }; N="$2"; shift ;;
    -n*)       N="${1#-n}" ;;
    --since)   [ "$#" -ge 2 ] || { echo "--since requires a value" >&2; exit 2; }; SINCE="$2"; shift ;;
    --since=*) SINCE="${1#--since=}" ;;
    --all)     ALL=1 ;;
    --json)    JSON=1 ;;
    --mark)    [ "$#" -ge 2 ] || { echo "--mark requires a value" >&2; exit 2; }; MARK="$2"; shift ;;
    --mark=*)  MARK="${1#--mark=}" ;;
    --reset)   RESET=1 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        echo "unknown option: $1" >&2; exit 2 ;;
    *)         DIR="$1" ;;
  esac
  shift
done
case "$N" in ''|*[!0-9]*) echo "invalid -n: $N" >&2; exit 2 ;; esac

[ -n "$DIR" ] && cd "$DIR"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "compass digest: not a git repo" >&2; exit 2; }
REPO="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")")"
mkdir -p "$COMPASS_HOME" 2>/dev/null || true

# --reset / --mark are bookkeeping side-doors: do the one thing and leave.
if [ "$RESET" = 1 ]; then
  if [ -f "$LEDGER" ]; then
    awk -F'\t' -v r="$REPO" '$2!=r' "$LEDGER" > "$LEDGER.tmp" 2>/dev/null || true
    mv -f "$LEDGER.tmp" "$LEDGER" 2>/dev/null || true
  fi
  echo "compass digest: cleared ledger for $REPO"; exit 0
fi
mark_seen() { printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REPO" "$1" >> "$LEDGER" 2>/dev/null || true; }
if [ -n "$MARK" ]; then mark_seen "$MARK"; echo "compass digest: marked $MARK reviewed"; exit 0; fi

seen() { [ -f "$LEDGER" ] && awk -F'\t' -v r="$REPO" -v ref="$1" '$2==r && $3==ref{f=1} END{exit !f}' "$LEDGER"; }
is_agent() { # bot/agent author? these are the changes you most likely didn't write — rank first
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    *bot*|*claude*|*compass*|*codex*|*sdlc*) return 0 ;; *) return 1 ;;
  esac
}

# --- Source selection: gh merged PRs if available, else git first-parent history. ---
SOURCE="${COMPASS_DIGEST_SOURCE:-}"
if [ -z "$SOURCE" ]; then
  if command -v gh >/dev/null 2>&1 && gh repo view >/dev/null 2>&1; then SOURCE="gh"; else SOURCE="git"; fi
fi

# --- Gather candidates into a TAB record stream: ref \t author \t date \t title  (newest first). ---
TMP="$(mktemp)"; CAND="$TMP.cand"; SEL="$TMP.sel"
trap 'rm -f "$TMP" "$CAND" "$SEL" "$TMP.a" "$TMP.b"' EXIT
sanitize() { printf '%s' "$1" | tr '\t\n' '  '; }

if [ "$SOURCE" = gh ]; then
  since_arg=""; [ -n "$SINCE" ] && since_arg="merged:>=$SINCE"
  rows="$(gh pr list --state merged --limit "$WINDOW" ${since_arg:+--search "$since_arg"} \
            --json number,title,author,mergedAt 2>/dev/null || echo '[]')"
  printf '%s' "$rows" | jq -r '.[] | "PR#\(.number)\t\(.author.login // "?")\t\(.mergedAt[0:10])\t\(.title)"' \
    2>/dev/null > "$CAND" || : > "$CAND"
else
  gitargs=(--first-parent --format=%H%x09%an%x09%ad --date=short)
  if [ -n "$SINCE" ]; then gitargs+=(--since="$SINCE"); else gitargs+=(-n "$WINDOW"); fi
  # subject fetched per-line (keeps the format string simple and tab-safe)
  git log "${gitargs[@]}" 2>/dev/null | while IFS=$'\t' read -r sha author date; do
    [ -z "$sha" ] && continue
    printf '%s\t%s\t%s\t%s\n' "$sha" "$author" "$date" "$(sanitize "$(git show -s --format=%s "$sha" 2>/dev/null)")"
  done > "$CAND"
fi

TOTAL="$(wc -l < "$CAND" | tr -d ' ')"; TOTAL="${TOTAL:-0}"

# --- Filter unseen (unless --all), then rank agent-authored first, preserving newest-first. ---
: > "$TMP.a"; : > "$TMP.b"
while IFS=$'\t' read -r ref author date title; do
  [ -z "$ref" ] && continue
  if [ "$ALL" = 0 ] && seen "$ref"; then continue; fi
  if is_agent "$author"; then printf '%s\t%s\t%s\t%s\n' "$ref" "$author" "$date" "$title" >> "$TMP.a"
  else printf '%s\t%s\t%s\t%s\n' "$ref" "$author" "$date" "$title" >> "$TMP.b"; fi
done < "$CAND"
cat "$TMP.a" "$TMP.b" > "$TMP.ord"
UNREVIEWED="$(wc -l < "$TMP.ord" | tr -d ' ')"; UNREVIEWED="${UNREVIEWED:-0}"
head -n "$N" "$TMP.ord" > "$SEL"
SAMPLED="$(wc -l < "$SEL" | tr -d ' ')"; SAMPLED="${SAMPLED:-0}"

# Rationale (recorded "why") for a ref, on demand — only for the few picked.
rationale() {
  local ref="$1"
  if [ "${ref#PR#}" != "$ref" ]; then gh pr view "${ref#PR#}" --json body --jq '.body' 2>/dev/null | head -8
  else git show -s --format=%b "$ref" 2>/dev/null | head -8; fi
}
diffstat() {
  local ref="$1"
  if [ "${ref#PR#}" != "$ref" ]; then gh pr diff "${ref#PR#}" --stat 2>/dev/null | tail -12
  else git show --stat --format='' "$ref" 2>/dev/null | sed '/^$/d' | head -12; fi
}

# --- JSON: the sample + the lag counts (for tooling; no rationale reveal). ---
if [ "$JSON" = 1 ]; then
  printf '{"repo":"%s","source":"%s","considered":%d,"unreviewed":%d,"sampled":%d,"sample":[' \
    "$REPO" "$SOURCE" "$TOTAL" "$UNREVIEWED" "$SAMPLED"
  first=1
  while IFS=$'\t' read -r ref author date title; do
    [ -z "$ref" ] && continue
    [ "$first" = 1 ] || printf ','; first=0
    printf '{"ref":"%s","title":"%s","author":"%s","date":"%s"}' \
      "$ref" "$(printf '%s' "$title" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
      "$(printf '%s' "$author" | sed 's/\\/\\\\/g; s/"/\\"/g')" "$date"
    mark_seen "$ref"
  done < "$SEL"
  printf ']}\n'
  exit 0
fi

# --- Human digest: each change as a question, then its recorded rationale to self-check. ---
bold=""; dim=""; grn=""; ylw=""; rst=""
if [ -t 1 ]; then bold=$'\033[1m'; dim=$'\033[2m'; grn=$'\033[32m'; ylw=$'\033[33m'; rst=$'\033[0m'; fi

if [ "$TOTAL" -eq 0 ]; then
  printf '\n%scompass digest%s · %s\n  No merged changes found to review yet.\n\n' "$bold" "$rst" "$REPO"; exit 0
fi
if [ "$SAMPLED" -eq 0 ]; then
  printf '\n%scompass digest%s · %s\n  %s✓ caught up%s — every recent change has been through a digest. (%d considered)\n  Run with %s--all%s to revisit, or come back after the next merge.\n\n' \
    "$bold" "$rst" "$REPO" "$grn" "$rst" "$TOTAL" "$dim" "$rst"; exit 0
fi

printf '\n%scompass digest%s · %s — read a sample, stay ahead of the loop\n' "$bold" "$rst" "$REPO"
printf '%sYour map is %s%d%s change(s) behind; here are %d to catch up on. Explain each before you read the rationale.%s\n' \
  "$dim" "$rst$ylw" "$UNREVIEWED" "$dim" "$SAMPLED" "$rst"

i=0
while IFS=$'\t' read -r ref author date title; do
  [ -z "$ref" ] && continue
  i=$((i+1))
  printf '\n%s── %d/%d · %s%s  %s%s%s  %s%s · %s%s\n' \
    "$bold" "$i" "$SAMPLED" "$ref" "$rst" "$bold" "$title" "$rst" "$dim" "$author" "$date" "$rst"
  printf '%s   touched:%s\n' "$dim" "$rst"
  diffstat "$ref" | sed 's/^/     /'
  printf '\n   %sQ: what did this change do, and why was it done this way?%s\n' "$ylw" "$rst"
  body="$(rationale "$ref")"
  if [ -n "$body" ]; then
    printf '   %s— rationale (the recorded answer; check yours against it) —%s\n' "$dim" "$rst"
    printf '%s\n' "$body" | sed 's/^/     /'
  else
    printf '   %s— no recorded rationale; reconstruct it from the diff. (a missing "why" is itself a finding)%s\n' "$dim" "$rst"
  fi
  mark_seen "$ref"
done < "$SEL"

printf '\n%sCould you explain all %d? If not, that gap is where comprehension rot starts.%s\n' "$dim" "$SAMPLED" "$rst"
printf '%sMarked reviewed. Next run shows the next unreviewed changes; %scompass digest --all%s revisits.%s\n\n' "$dim" "$rst$dim" "$rst$dim" "$rst"
