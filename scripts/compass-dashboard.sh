#!/usr/bin/env bash
# compass-dashboard.sh — a zero-infra control surface for local agentic work.
#
# The honest answer to "I can't *see* the fleet": one panel that renders the local
# ledgers (footguns blocked, files formatted, spend, $ saved) and — when `gh` + a
# fleet/repos.txt are present — the live state of every open SDLC PR across your repos.
# No service, no server, no upload: it reads ~/.compass and asks GitHub read-only.
#
#   compass dashboard            # terminal panel
#   compass dashboard --json     # machine-readable (impact + fleet)
#   compass dashboard --html     # write a static dashboard.html and print its path
#   compass dashboard --fleet    # force the fleet section even if it's slow
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR="${COMPASS_HOME:-$HOME/.compass}"
JSON=0; HTML=0; WANT_FLEET=auto
usage(){ echo "usage: compass dashboard [--json|--html] [--fleet|--no-fleet]"; }
for a in "$@"; do case "$a" in
  --json) JSON=1 ;; --html) HTML=1 ;; --fleet) WANT_FLEET=yes ;; --no-fleet) WANT_FLEET=no ;;
  -h|--help) usage; exit 0 ;; *) usage; exit 2 ;;
esac; done

# Locate a fleet repo list (the same file the fleet workflows use).
fleet_list=""
for c in "$HOME_DIR/repos.txt" "$ROOT/sdlc/fleet/repos.txt" "$ROOT/fleet/repos.txt" "./fleet/repos.txt"; do
  [ -f "$c" ] && { fleet_list="$c"; break; }
done

# --- fleet: open SDLC PRs across the repo list (best-effort, read-only) ----------
# Emits TSV rows: repo<TAB>number<TAB>state<TAB>title  (state derived from sdlc labels).
fleet_rows() {
  [ -n "$fleet_list" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local repo
  while IFS= read -r repo; do
    case "$repo" in ''|\#*) continue ;; esac
    gh pr list --repo "$repo" --state open \
      --json number,title,labels,isDraft 2>/dev/null \
      | jq -r --arg r "$repo" '.[] | [
          $r, (.number|tostring),
          ( [.labels[].name] as $l
            | if   ($l|index("sdlc:needs-human")) then "needs-human"
              elif ($l|index("agent:needs-fix"))  then "needs-fix"
              elif ($l|index("reviewed-clean"))   then "reviewed-clean"
              elif (.isDraft)                       then "draft"
              else "open" end ),
          .title ] | @tsv' 2>/dev/null || true
  done < "$fleet_list"
}

run_fleet() { [ "$WANT_FLEET" = no ] && return 0; [ "$WANT_FLEET" = auto ] && [ -z "$fleet_list" ] && return 0; fleet_rows; }
FLEET_TSV="$(run_fleet)"

# --- impact JSON (reuse the canonical aggregator) --------------------------------
IMPACT_JSON="$("$ROOT/scripts/compass-impact.sh" --json 2>/dev/null || echo '{}')"

# Count fleet rows by state (pure awk, no deps).
fleet_counts() { printf '%s' "$FLEET_TSV" | awk -F'\t' 'NF>=3{c[$3]++; t++} END{printf "%d|%d|%d|%d", t+0, c["needs-human"]+0, c["needs-fix"]+0, c["reviewed-clean"]+0}'; }
IFS='|' read -r f_total f_human f_fix f_clean <<EOF
$(fleet_counts)
EOF

# ── JSON ───────────────────────────────────────────────────────────────────────
if [ "$JSON" = 1 ]; then
  rows_json="[]"
  if [ -n "$FLEET_TSV" ] && command -v jq >/dev/null 2>&1; then
    rows_json="$(printf '%s\n' "$FLEET_TSV" | awk -F'\t' 'NF>=4' | jq -R -s 'split("\n")|map(select(length>0)|split("\t")|{repo:.[0],number:(.[1]|tonumber),state:.[2],title:.[3]})')"
  fi
  printf '{"impact":%s,"fleet":{"open":%s,"needs_human":%s,"needs_fix":%s,"reviewed_clean":%s,"prs":%s}}\n' \
    "$IMPACT_JSON" "${f_total:-0}" "${f_human:-0}" "${f_fix:-0}" "${f_clean:-0}" "$rows_json"
  exit 0
fi

# ── HTML (static, self-contained) ───────────────────────────────────────────────
if [ "$HTML" = 1 ]; then
  out="$HOME_DIR/dashboard.html"; mkdir -p "$HOME_DIR"
  {
    echo '<!doctype html><meta charset="utf-8"><title>compass dashboard</title>'
    echo '<style>body{font:14px/1.5 ui-monospace,monospace;background:#0d1117;color:#e6edf3;max-width:760px;margin:40px auto;padding:0 16px}h1{color:#8A63D2}.k{color:#8b949e}.s td{padding:2px 10px}.b{color:#f85149}.c{color:#3fb950}.p{color:#a371f7}table{border-collapse:collapse;width:100%;margin-top:8px}td,th{text-align:left;padding:4px 8px;border-bottom:1px solid #21262d}</style>'
    echo "<h1>🧭 compass dashboard</h1><p class=k>generated $(date -u +%Y-%m-%dT%H:%MZ) · local ledgers, read-only</p>"
    echo "<pre>$("$ROOT/scripts/compass-impact.sh" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')</pre>"
    if [ -n "$FLEET_TSV" ]; then
      echo "<h2>fleet — open SDLC PRs</h2><table><tr><th>repo</th><th>#</th><th>state</th><th>title</th></tr>"
      printf '%s\n' "$FLEET_TSV" | awk -F'\t' '
        function he(s,  r) {
          r=s; gsub(/&/,"\\&amp;",r); gsub(/</,"\\&lt;",r); gsub(/>/,"\\&gt;",r); gsub(/"/,"\\&quot;",r); return r
        }
        NF>=4{printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n",he($1),he($2),he($3),he($4)}'
      echo "</table>"
    fi
  } > "$out"
  echo "wrote $out"
  exit 0
fi

# ── terminal panel ───────────────────────────────────────────────────────────────
if [ -t 1 ]; then B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; R=$'\033[31m'; P=$'\033[35m'; C=$'\033[36m'; X=$'\033[0m'
else B=""; D=""; G=""; R=""; P=""; C=""; X=""; fi

echo
echo "  ${B}🧭 compass · mission control${X}  ${D}(local, read-only)${X}"
echo "  ${D}════════════════════════════════════════════════${X}"
# impact (strip its own header/footer blank lines, keep the meat)
"$ROOT/scripts/compass-impact.sh" 2>/dev/null | sed -n '3,$p' | sed '/Cost detail/d;/^$/d' | sed 's/^/  /'
echo
if [ "$WANT_FLEET" = no ]; then
  echo "  ${D}fleet section skipped (--no-fleet)${X}"
elif [ -z "$fleet_list" ]; then
  echo "  ${D}fleet: no repos.txt found — add sdlc/fleet/repos.txt to track PRs across repos${X}"
elif ! command -v gh >/dev/null 2>&1; then
  echo "  ${D}fleet: gh CLI not found — install + 'gh auth login' to see live PR state${X}"
elif [ -z "$FLEET_TSV" ]; then
  echo "  ${G}fleet: no open SDLC PRs across $(grep -cvE '^\s*(#|$)' "$fleet_list") repo(s) — all clear${X}"
else
  printf "  ${B}fleet${X}  ${D}%s open · ${X}${R}%s need you${X}${D} · %s in-fix · ${X}${G}%s clean${X}\n" \
    "${f_total:-0}" "${f_human:-0}" "${f_fix:-0}" "${f_clean:-0}"
  printf '%s\n' "$FLEET_TSV" | awk -F'\t' 'NF>=4{printf "    %s#%s  [%s]  %s\n",$1,$2,$3,substr($4,1,48)}'
  [ "${f_human:-0}" -gt 0 ] && echo "  ${P}↳ ${f_human} PR(s) need a human — approve/merge from GitHub Mobile or 'compass listen'${X}"
fi
echo
echo "  ${D}detail: compass impact · compass spend · --html writes a shareable page${X}"
echo
