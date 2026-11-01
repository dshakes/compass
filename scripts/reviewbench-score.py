#!/usr/bin/env python3
"""reviewbench-score.py — run a reviewer over labeled diffs and score precision/recall/F1.

Reviewer protocol: `CMD <case-dir>` prints JSON lines {"file","line","severity","message"};
an optional {"meta":{"cost_usd":N}} line reports spend. A finding is a TP if its (file, line)
falls inside a labeled bug range (each bug matched once; repeats on a matched bug are ignored),
else an FP. A labeled bug with no finding is an FN. A reviewer that fails/times out on a case
scores that case's bugs as FN and is listed as an error.
"""

import argparse
import json
import os
import signal
import subprocess
import sys
from math import sqrt


def wilson(k, n):
    z = 1.959964
    if n == 0:
        return 0.0, 1.0
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return max(0.0, c - h), min(1.0, c + h)


def pct(x):
    return "%.1f%%" % (100 * x)


def ci(c):
    return "[%.1f-%.1f]" % (100 * c[0], 100 * c[1])


def run_reviewer(cmd, case_dir, timeout):
    p = subprocess.Popen(
        cmd + [case_dir],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        return None, 0.0, "timeout"
    findings, cost = [], 0.0
    for ln in out.splitlines():
        try:
            o = json.loads(ln)
        except ValueError:
            continue
        if isinstance(o, dict) and isinstance(o.get("meta"), dict):
            cost += float(o["meta"].get("cost_usd") or 0)
        elif isinstance(o, dict) and "file" in o and "line" in o:
            findings.append(o)
    if p.returncode != 0:
        return (
            None,
            cost,
            (err.strip().splitlines() or ["exit %d" % p.returncode])[-1][:80],
        )
    return findings, cost, ""


def norm(f):
    f = str(f).lstrip("./")
    return f[2:] if f.startswith(("a/", "b/")) else f


def score_case(labels, findings):
    bugs, hit, tp, fp = labels["bugs"], set(), 0, 0
    for f in findings:
        try:
            ln = int(f["line"])
        except (TypeError, ValueError):
            fp += 1
            continue
        idx = next(
            (
                i
                for i, b in enumerate(bugs)
                if norm(f["file"]) == b["file"]
                and b["line_start"] <= ln <= b["line_end"]
            ),
            None,
        )
        if idx is None:
            fp += 1
        elif idx not in hit:
            hit.add(idx)
            tp += 1
    return tp, fp, len(bugs) - len(hit)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", required=True)
    ap.add_argument("--reviewer", required=True)
    ap.add_argument("--json", action="store_true")
    ap.add_argument(
        "--timeout", type=int, default=int(os.environ.get("REVIEWBENCH_TIMEOUT", "600"))
    )
    a = ap.parse_args()
    cap = float(os.environ.get("COMPASS_MAX_USD") or 0)
    cmd = a.reviewer.split()
    rows, cost, halted, streak = [], 0.0, "", 0
    for cid in sorted(os.listdir(a.cases)):
        d = os.path.join(a.cases, cid)
        if not os.path.isfile(os.path.join(d, "labels.json")):
            continue
        labels = json.load(open(os.path.join(d, "labels.json")))
        findings, c, err = run_reviewer(cmd, d, a.timeout)
        cost += c
        tp, fp, fn = score_case(labels, findings or [])
        rows.append(
            {
                "case": cid,
                "expect": labels["expect"],
                "tp": tp,
                "fp": fp,
                "fn": fn,
                "cost_usd": round(c, 4),
                "error": err,
            }
        )
        streak = streak + 1 if err else 0
        if streak >= 3:
            halted = "3 consecutive reviewer errors (last: %s)" % err
            break
        if cap and cost >= cap:
            halted = "cost cap $%.2f reached ($%.4f spent)" % (cap, cost)
            break
    TP, FP, FN = (sum(r[k] for r in rows) for k in ("tp", "fp", "fn"))
    P = TP / (TP + FP) if TP + FP else 0.0
    R = TP / (TP + FN) if TP + FN else 0.0
    F1 = 2 * P * R / (P + R) if P + R else 0.0
    pci, rci = wilson(TP, TP + FP), wilson(TP, TP + FN)
    n = len(rows)
    out = {
        "cases": n,
        "tp": TP,
        "fp": FP,
        "fn": FN,
        "precision": round(P, 4),
        "recall": round(R, 4),
        "f1": round(F1, 4),
        "precision_ci95": [round(x, 4) for x in pci],
        "recall_ci95": [round(x, 4) for x in rci],
        "errors": sum(1 for r in rows if r["error"]),
        "cost_usd": round(cost, 4),
        "cost_per_case": round(cost / n, 4) if n and cost else None,
        "halted": halted or None,
        "per_case": rows,
    }
    if a.json:
        print(json.dumps(out, indent=2))
    else:
        print(
            "%-28s %-6s %3s %3s %3s  %s" % ("case", "expect", "TP", "FP", "FN", "note")
        )
        for r in rows:
            print(
                "%-28s %-6s %3d %3d %3d  %s"
                % (
                    r["case"],
                    r["expect"],
                    r["tp"],
                    r["fp"],
                    r["fn"],
                    ("ERROR " + r["error"]) if r["error"] else "",
                )
            )
        print(
            "\ncases=%d  TP=%d FP=%d FN=%d  errors=%d" % (n, TP, FP, FN, out["errors"])
        )
        print(
            "precision %s %s   recall %s %s   F1 %s   (95%% Wilson CI)"
            % (pct(P), ci(pci), pct(R), ci(rci), pct(F1))
        )
        if cost:
            print("cost $%.4f total, $%.4f/case" % (cost, cost / n))
        if halted:
            print("HALTED: " + halted)
    sys.exit(3 if halted else 0)


if __name__ == "__main__":
    main()
