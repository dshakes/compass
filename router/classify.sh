#!/usr/bin/env bash
# classify.sh — local Naive-Bayes tier classifier: the free/fast fallback layer.
# Reads the task on STDIN, prints a tier — or ABSTAINS (exit 3, no output) when it is
# OFF, has no model, or isn't confident enough (top-class margin < min_margin). Abstaining
# lets fallback-cascade.sh fall through to the LLM judge.
#
# Toggle (OFF by default): ROUTER_CLASSIFIER=on|off  or  spec classifier.enabled.
#   train-classifier.sh <data>      # build the model first
#   echo "<task>" | ROUTER_CLASSIFIER=on classify.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC="${COMPASS_ROUTER_SPEC:-$HERE/router.json}"; MODEL=""
while [ $# -gt 0 ]; do case "$1" in --model) MODEL="${2:?}"; shift ;; --spec) SPEC="${2:?}"; shift ;; esac; shift; done
command -v jq >/dev/null 2>&1 || exit 3

enabled="$(jq -r '.classifier.enabled // false' "$SPEC" 2>/dev/null || echo false)"
case "${ROUTER_CLASSIFIER:-}" in on|1|true) enabled=true ;; off|0|false) enabled=false ;; esac
[ "$enabled" = true ] || exit 3
if [ -z "$MODEL" ]; then
  m="$(jq -r '.classifier.model // "classifier.model"' "$SPEC" 2>/dev/null || echo classifier.model)"
  case "$m" in /*) MODEL="$m" ;; *) MODEL="$HERE/$m" ;; esac   # absolute path used as-is
fi
[ -f "$MODEL" ] || exit 3
MINM="$(jq -r '.classifier.min_margin // 1.0' "$SPEC" 2>/dev/null || echo 1.0)"

cat | awk -F'\t' -v model="$MODEL" -v minm="$MINM" '
  BEGIN{
    while((getline line < model) > 0){
      n=split(line, f, "\t")
      if(f[1]=="P") docs[f[2]]=f[3]
      else if(f[1]=="N") N=f[2]
      else if(f[1]=="V") V=f[2]
      else if(f[1]=="T") tw[f[2]]=f[3]
      else if(f[1]=="W") cnt[f[2] SUBSEP f[3]]=f[4]
    }
  }
  { task = task " " tolower($0) }
  END{
    if(N+0==0) exit 3
    nt=split(task, w, /[^a-z0-9]+/)
    best=""; bests=-1e9; second=-1e9
    for(t in docs){
      s=log((docs[t]+0)/N)
      for(i=1;i<=nt;i++){ tok=w[i]; if(tok==""||length(tok)<2) continue;
        s += log((cnt[t SUBSEP tok]+1)/((tw[t]+0)+V)) }
      if(s>bests){ second=bests; bests=s; best=t } else if(s>second){ second=s }
    }
    if(best=="" || (bests-second) < minm) exit 3
    print best
  }
'
