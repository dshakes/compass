#!/usr/bin/env bash
# statusline.sh — a dense, glanceable status line.
#
# Reads the statusline JSON on stdin and prints one line:
#   <model> · <dir> · <git branch +dirty> · <ctx%> · <session cost> · 🧭 <compass today>
# The 🧭 segment shows today's compass activity — 🛡N footguns blocked · 🧹N files auto-formatted ·
# 💡N policy nudges · 📉~$X estimated saved vs all-Opus (from ~/.compass metrics + spend ledgers).
# Omitted when there's nothing to show. Full benefit view: `compass impact`.
#
# Degrades gracefully: any missing field is simply omitted. No hard deps
# beyond a JSON reader (jq preferred, python3 fallback).

. "$HOME/.claude/hooks/lib/common.sh" 2>/dev/null || {
  # Minimal inline reader if common.sh isn't installed yet.
  json_get() {
    local j="$1" p="$2"
    if command -v jq >/dev/null 2>&1; then printf '%s' "$j" | jq -r "$p // empty" 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then printf '%s' "$j" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except: sys.exit(0)
for k in sys.argv[1].lstrip(".").split("."):
    d=d.get(k) if isinstance(d,dict) else None
    if d is None: sys.exit(0)
print(d if isinstance(d,str) else json.dumps(d))' "$p" 2>/dev/null; fi
  }
}

INPUT="$(cat)"

# ANSI (256-color). Dim separators, colored segments.
C_RST=$'\033[0m'; C_DIM=$'\033[2m'
C_MODEL=$'\033[38;5;141m'   # violet
C_DIR=$'\033[38;5;39m'      # blue
C_GIT=$'\033[38;5;42m'      # green
C_DIRTY=$'\033[38;5;214m'   # amber
C_CTX=$'\033[38;5;245m'     # grey
C_COST=$'\033[38;5;108m'    # sage
SEP=" ${C_DIM}·${C_RST} "

model="$(json_get "$INPUT" '.model.display_name')"
dir="$(json_get "$INPUT" '.workspace.current_dir')"
[ -z "$dir" ] && dir="$(json_get "$INPUT" '.cwd')"
dir_short="$(basename "${dir:-$PWD}")"
mode="$(json_get "$INPUT" '.permission_mode')"

# Git segment.
git_seg=""
if git -C "${dir:-$PWD}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git -C "${dir:-$PWD}" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ -n "$(git -C "${dir:-$PWD}" status --porcelain 2>/dev/null)" ]; then
    git_seg="${C_GIT}${branch}${C_DIRTY}*${C_RST}"
  else
    git_seg="${C_GIT}${branch}${C_RST}"
  fi
fi

# Cost segment (cents -> dollars).
cents="$(json_get "$INPUT" '.cost.estimated_cost_cents')"
cost_seg=""
if [ -n "$cents" ] && [ "$cents" != "0" ]; then
  dollars="$(awk "BEGIN{printf \"%.2f\", $cents/100}" 2>/dev/null)"
  cost_seg="${C_COST}\$${dollars}${C_RST}"
fi

# Live budget breadcrumb: drop this session's spend (cents) where budget-gate.sh
# reads it. The statusline is the only place the runtime hands us live session
# cost, so it is the oracle the PreToolUse budget ceiling consults. Best-effort,
# never fails the render; with no ceiling set the gate ignores it (zero cost).
sid="$(json_get "$INPUT" '.session_id')"
if [ -n "$sid" ] && [ -n "$cents" ]; then
  sdir="${COMPASS_HOME:-$HOME/.compass}/sessions"
  { mkdir -p "$sdir" 2>/dev/null && printf '%s' "$cents" >"$sdir/${sid}.cost"; } 2>/dev/null || true
fi

# Context-used segment, if the runtime provides token counts.
ctx_seg=""
in_tok="$(json_get "$INPUT" '.cost.total_input_tokens')"
if [ -n "$in_tok" ] && [ "$in_tok" -gt 0 ] 2>/dev/null; then
  k="$(awk "BEGIN{printf \"%.0f\", $in_tok/1000}" 2>/dev/null)"
  ctx_seg="${C_CTX}${k}k ctx${C_RST}"
fi

# Mode badge only when notable.
mode_seg=""
case "$mode" in
  acceptEdits) mode_seg="${C_DIM}[edits]${C_RST}" ;;
  plan)        mode_seg="${C_DIM}[plan]${C_RST}" ;;
  bypassPermissions) mode_seg="${C_DIRTY}[bypass]${C_RST}" ;;
esac

# compass activity today, at a glance — proof it's working for you. Best-effort; each
# piece is omitted if there's nothing to show. Full benefit view: `compass impact`.
#   🛡N footguns blocked · 🧹N files auto-formatted · 💡N policy nudges  (~/.compass/metrics.tsv)
#   📉~$X estimated saved today vs running it all on Opus  (~/.compass/spend.tsv)
compass_seg=""
chome="${COMPASS_HOME:-$HOME/.compass}"
today="$(date -u +%Y-%m-%d)"
seg=""
mfile="$chome/metrics.tsv"
if [ -f "$mfile" ]; then
  counts="$(awk -F'\t' -v d="$today" 'index($1,d)==1{if($2=="block")b++;else if($2=="format")f++;else if($2=="policy")p++} END{printf "%d\t%d\t%d",b+0,f+0,p+0}' "$mfile" 2>/dev/null)"
  blk="${counts%%	*}"; rest="${counts#*	}"; fmtn="${rest%%	*}"; pol="${rest##*	}"
  [ "${blk:-0}" -gt 0 ] 2>/dev/null && seg="🛡${blk}"
  [ "${fmtn:-0}" -gt 0 ] 2>/dev/null && seg="${seg:+$seg }🧹${fmtn}"
  [ "${pol:-0}" -gt 0 ] 2>/dev/null && seg="${seg:+$seg }💡${pol}"
fi
# Estimated $ saved today — same method as `compass impact`: vs all-Opus, Sonnet spend ×4
# + Haiku spend ×17 (rough price-ratio deltas). Shown only once it rounds to a cent.
sfile="$chome/spend.tsv"
if [ -f "$sfile" ]; then
  # Single awk does the sum AND the threshold (emit only when it rounds to ≥ $0.01,
  # i.e. raw ≥ 0.005) — no extra fork on the render hot path.
  saved="$(awk -F'\t' -v d="$today" 'index($1,d)==1{if($4=="sonnet")s+=$5;else if($4=="haiku")h+=$5} END{v=s*4+h*17; if(v>=0.005) printf "%.2f", v}' "$sfile" 2>/dev/null)"
  [ -n "$saved" ] && seg="${seg:+$seg }${C_COST}📉~\$${saved}${C_RST}"
fi
[ -n "$seg" ] && compass_seg="${C_MODEL}🧭${C_RST} ${seg}"

# Assemble, skipping empty segments.
out="${C_MODEL}${model:-Claude}${C_RST}${SEP}${C_DIR}${dir_short}${C_RST}"
[ -n "$git_seg" ]  && out="${out}${SEP}${git_seg}"
[ -n "$ctx_seg" ]  && out="${out}${SEP}${ctx_seg}"
[ -n "$cost_seg" ] && out="${out}${SEP}${cost_seg}"
[ -n "$compass_seg" ] && out="${out}${SEP}${compass_seg}"
[ -n "$mode_seg" ] && out="${out} ${mode_seg}"

printf '%s' "$out"
