#!/usr/bin/env bash
# check-docs.sh — reachability + link integrity for the docs tree.
#
# docs/ is served straight to GitHub Pages with no build step, so nothing catches a
# doc that exists but is unreachable, or a link/image that 404s once published. Four
# invariants that were manual (and two of which were already broken when this landed):
#   1. SITE NAV — every docs/*.md appears in the NAV array in docs/docs.html, or the
#      page exists in the repo but is unreachable from the published site.
#   2. README INDEX — every docs/*.md is linked from README.md, the other entry path.
#   3. ASSET MIRROR — every ../assets/*.svg a doc embeds also exists in docs/assets/.
#      The site root IS docs/, and docs.html rewrites ../assets/x → assets/x, so an
#      unmirrored asset renders locally and on GitHub but 404s on Pages.
#   4. RELATIVE LINKS — every relative markdown link from README.md and docs/*.md
#      resolves to a file that exists.
#
# Usage: check-docs.sh          # full audit (CI)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
pass=0; fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

echo "site nav — every docs/*.md reachable from docs/docs.html:"
n=$fail
for f in docs/*.md; do
  b="$(basename "$f" .md)"
  grep -q "'$b'" docs/docs.html || no "$b: not in the NAV array in docs/docs.html (unreachable on the published site)"
done
[ "$fail" -eq "$n" ] && ok "all docs/*.md present in the site NAV"

echo "readme index — every docs/*.md linked from README.md:"
n=$fail
for f in docs/*.md; do
  grep -q "$(basename "$f")" README.md || no "$(basename "$f"): not linked from README.md"
done
[ "$fail" -eq "$n" ] && ok "all docs/*.md linked from README.md"

echo "asset mirror — ../assets/* embedded in docs/*.md must exist in docs/assets/:"
n=$fail
# Docs embed assets as raw HTML: <img src="../assets/x.svg" …>
grep -ho '\.\./assets/[A-Za-z0-9._-]*' docs/*.md | sed 's|\.\./assets/||' | sort -u | while read -r a; do
  [ -f "assets/$a" ]      || echo "MISS|assets/$a (referenced by a doc, does not exist)"
  [ -f "docs/assets/$a" ] || echo "MISS|docs/assets/$a (unmirrored — 404s on GitHub Pages)"
done > /tmp/_assets.$$
while IFS='|' read -r _ msg; do no "$msg"; done < /tmp/_assets.$$
rm -f /tmp/_assets.$$
[ "$fail" -eq "$n" ] && ok "every embedded asset exists in both assets/ and docs/assets/"

echo "relative links — markdown links resolve to a real file:"
n=$fail
for f in README.md docs/*.md; do
  d="$(dirname "$f")"
  # [text](target) — skip absolute URLs, anchors, and mailto.
  grep -o '](\([^)"[:space:]]*\))' "$f" | sed 's/^](//; s/)$//' | while read -r link; do
    case "$link" in http*|\#*|mailto:*|"") continue ;; esac
    target="${link%%#*}"                 # strip #anchor
    [ -z "$target" ] && continue
    [ -e "$d/$target" ] || echo "$f -> $link"
  done
done > /tmp/_links.$$
while IFS= read -r bad; do no "broken relative link: $bad"; done < /tmp/_links.$$
rm -f /tmp/_links.$$
[ "$fail" -eq "$n" ] && ok "all relative links in README.md + docs/*.md resolve"

echo "quoted counts — red-team / router case counts must match the corpora:"
n=$fail
rt="$(bash scripts/test-redteam.sh 2>&1 | sed -n 's/^redteam corpus: \([0-9][0-9]*\) cases.*/\1/p')"
rv="$(grep -vc '^#\|^[[:space:]]*$' scripts/route-evalset.tsv)"
rf="$(grep -vc '^#\|^[[:space:]]*$' scripts/redteam-corpus.tsv)"
[ -n "$rt" ] || no "could not compute red-team corpus size (scripts/test-redteam.sh)"
for f in README.md docs/*.md docs/*.html docs/content.js; do
{ grep -ohiE '(red-?team|P/R|corpus:|recall on)[^<]{0,20} \(?[0-9]+ cases' "$f" | grep -oE '[0-9]+ cases' | sed "s|^|$rt |"
grep -ohiE 'routing accuracy · [0-9]+ cases' "$f" | grep -oE '[0-9]+ cases' | sed "s|^|$rv |"
grep -ohiE '[0-9]+-case eval set' "$f" | grep -oE '[0-9]+' | sed "s|^|$rv |; s|\$| cases|"
grep -ohE '\| Router \| [0-9]+ \|' "$f" | grep -oE '[0-9]+' | sed "s|^|$rv |; s|\$| cases|"
grep -ohE '\| Red-team \(internal\) \| [0-9]+ \||= [0-9]+ scored|\([0-9]+ total: ' "$f" | grep -oE '[0-9]+' | sed "s|^|$rt |; s|\$| cases|"
grep -ohE '[0-9]+ file(-based rows)? \+' "$f" | grep -oE '^[0-9]+' | sed "s|^|$rf |; s|\$| corpus-rows|"; } |
while read -r want got _; do [ "$want" = "$got" ] || echo "$f quotes $got cases, corpus has $want"; done
done > /tmp/_counts.$$
# Catch-all for phrasings the per-corpus patterns above don't know: every "N cases" /
# "N labeled cases" / "N-case" must be the size of SOME live corpus. 28-ablation.md is a
# dated experiment log, so its counts are history, not claims.
# ponytail: can't tell WHICH corpus a bare count means — a red-team page quoting the
# router size passes. Per-corpus patterns above cover the precise cases.
rg="$(grep -vc '^#\|^[[:space:]]*$' scripts/guardrail-corpus.tsv)"
rr="$(grep -vc '^#\|^[[:space:]]*$' router/evalset.tsv)"
rb="$(bash scripts/test-protect-paths.sh 2>&1 | sed -n 's/^guardrail corpus: \([0-9][0-9]*\) passed.*/\1/p')"
for f in README.md docs/*.md docs/*.html docs/content.js; do
  [ "$f" = docs/28-ablation.md ] && continue
  grep -ohE '[0-9]+(-case|( labeled)? cases|</b><span>labeled cases)' "$f" | grep -oE '^[0-9]+' |
  while read -r got; do
    case " $rt $rf $rv $rr $rg $rb " in *" $got "*) ;; *) echo "$f quotes $got cases, no live corpus has that size ($rt/$rv/$rr/$rg/$rb)" ;; esac
  done
done >> /tmp/_counts.$$
while IFS= read -r bad; do no "stale count: $bad"; done < /tmp/_counts.$$
rm -f /tmp/_counts.$$
[ "$fail" -eq "$n" ] && [ -n "$rt" ] && ok "quoted red-team ($rt) and router ($rv) case counts match the corpora"
echo
printf 'docs audit: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
