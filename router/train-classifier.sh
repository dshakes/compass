#!/usr/bin/env bash
# train-classifier.sh — distill logged judgments into a tiny local Naive-Bayes tier
# classifier (zero ML deps — just awk). This is the cost step of the progression: the
# LLM judge LABELS data (router --log), and this turns it into a fast, free, local model
# so you stop paying per call once volume justifies it.
#
#   train-classifier.sh DATA.tsv [-o model]
# DATA may be any of: "<tier>\t<task>" · the evalset ("split\ttier\ttask") · the router
# --log ("ts\ttier\tconf\ttask"). Output model (default router/classifier.model) is a flat
# TSV; classify.sh reads it. Retrain whenever the log has grown.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/classifier.model"; DATA=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out) OUT="${2:?}"; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "train-classifier: unknown flag '$1'" >&2; exit 2 ;;
    *) DATA="$1" ;;
  esac
  shift
done
[ -n "$DATA" ] || { echo "train-classifier: need a DATA file (tier<TAB>task, evalset, or --log)" >&2; exit 2; }
[ -f "$DATA" ] || { echo "train-classifier: no such file: $DATA" >&2; exit 2; }

awk -F'\t' '
  function learn(tier, task,   n,w,i,t){
    if (tier !~ /^(haiku|sonnet|opus)$/) return
    docs[tier]++; total++
    n=split(tolower(task), w, /[^a-z0-9]+/)
    for(i=1;i<=n;i++){ t=w[i]; if(t==""||length(t)<2) continue; cnt[tier SUBSEP t]++; tw[tier]++; vocab[t]=1 }
  }
  /^#/ || /^[[:space:]]*$/ { next }
  { if (NF>=4) learn($2,$4); else if (NF==3) learn($2,$3); else if (NF>=2) learn($1,$2) }
  END{
    if (total==0){ print "train-classifier: no usable rows" > "/dev/stderr"; exit 2 }
    for(t in docs) print "P\t"t"\t"docs[t]
    print "N\t"total
    v=0; for(x in vocab) v++; print "V\t"v
    for(t in docs) print "T\t"t"\t"tw[t]
    for(k in cnt){ split(k,a,SUBSEP); print "W\t"a[1]"\t"a[2]"\t"cnt[k] }
  }' "$DATA" > "$OUT"

printf 'trained: %s  (%s classes, %s token weights)\n' \
  "$OUT" "$(grep -c '^P	' "$OUT" || echo 0)" "$(grep -c '^W	' "$OUT" || echo 0)" >&2
