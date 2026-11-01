#!/usr/bin/env bash
# mock.sh <case-dir> — deterministic reviewer for validating the scorer (no tokens).
# Emits one finding per labeled bug (at line_start). Knobs:
#   MOCK_NOISE=n  add n false positives per case (file noise.txt, outside any range)
#   MOCK_MISS=n   skip every bug of the first n flag cases (in sorted order) => FNs
set -uo pipefail
dir="$1"
python3 - "$dir" "${MOCK_NOISE:-0}" "${MOCK_MISS:-0}" <<'PY'
import json, os, sys
d, noise, miss = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
parent = os.path.dirname(os.path.abspath(d))
flags = [c for c in sorted(os.listdir(parent))
         if os.path.isfile(os.path.join(parent, c, "labels.json"))
         and json.load(open(os.path.join(parent, c, "labels.json")))["expect"] == "flag"]
lab = json.load(open(os.path.join(d, "labels.json")))
skip = os.path.basename(os.path.abspath(d)) in flags[:miss]
if not skip:
    for b in lab["bugs"]:
        print(json.dumps({"file": b["file"], "line": b["line_start"], "severity": "blocking",
                          "message": "mock: " + b["class"]}))
for i in range(noise):
    print(json.dumps({"file": "noise.txt", "line": 1000 + i, "severity": "nit", "message": "mock noise"}))
PY
