#!/usr/bin/env python3
"""cost-sentinel: flag runaway Anthropic API spend from the Admin API usage report.

Stdlib only. Needs ANTHROPIC_ADMIN_KEY (unset -> exit 0 "skipped"). Exit 1 only when a flag fires.
Env: COST_SENTINEL_MAX_USD_DAY (24h per-key spend limit; unset = check off),
     COST_SENTINEL_MIN_CACHE_RATIO (default 0.5), COST_SENTINEL_ALLOWLIST (default state/cost-sentinel-allowlist.txt).
Cost is estimated from tokens x claude/hooks/lib/pricing.json (the same table budget-gate uses).
"""
import json, os, re, sys, urllib.parse, urllib.request
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

URL = "https://api.anthropic.com/v1/organizations/usage_report/messages"
HERE = Path(__file__).resolve().parent
PRICING = HERE / "../../hooks/lib/pricing.json"  # same relative path in claude/ and the plugin mirror


def rate(model, rows):
    for r in rows:  # first regex match wins; last row is the catch-all
        if re.search(r[0], model or ""):
            return r
    return rows[-1]


def analyze(buckets, rows, max_usd=None, min_cache=0.5, allow=frozenset()):
    """buckets: hourly usage buckets, oldest first (168 = 7d). Returns (report_lines, flags)."""
    cut = len(buckets) - 24
    days = defaultdict(set)  # key -> UTC days with any tokens
    spend = defaultdict(float)
    tok = defaultdict(lambda: [0, 0])  # key -> [cache_read, total_input]
    by_model = defaultdict(float)
    for i, b in enumerate(buckets):
        for r in b["results"]:
            cc = r.get("cache_creation") or {}
            u, w, cr, o = (r.get("uncached_input_tokens", 0),
                           cc.get("ephemeral_5m_input_tokens", 0) + cc.get("ephemeral_1h_input_tokens", 0),
                           r.get("cache_read_input_tokens", 0), r.get("output_tokens", 0))
            k = r.get("api_key_id") or "none"
            if u + w + cr + o:
                days[k].add(b["starting_at"][:10])
            if i < cut:
                continue
            _, pi, po, pw, pr = rate(r.get("model"), rows)
            c = (u * pi + o * po + w * pw + cr * pr) / 1e6  # ponytail: 1h cache writes billed at the 5m rate
            spend[k] += c
            by_model[(k, r.get("model"))] += c
            tok[k][0] += cr
            tok[k][1] += u + w + cr
    flags, lines = [], ["| key | 24h USD | cache-read | days active (7d) | top model |", "|---|---|---|---|---|"]
    for k in sorted(set(spend) | set(days), key=lambda k: -spend[k]):
        ratio = tok[k][0] / tok[k][1] if tok[k][1] else None
        top = max(((m, c) for (kk, m), c in by_model.items() if kk == k), key=lambda t: t[1], default=("-", 0))[0]
        lines.append(f"| {k} | {spend[k]:.2f} | {'n/a' if ratio is None else f'{ratio:.0%}'} | {len(days[k])}/7 | {top} |")
        if max_usd is not None and spend[k] > max_usd:
            flags.append(f"{k}: 24h spend {spend[k]:.2f} exceeds limit {max_usd:g}")
        if len(days[k]) >= 7:
            flags.append(f"{k}: active 7 of 7 days (always-on)")
        if ratio is not None and spend[k] > 0 and ratio < min_cache:
            flags.append(f"{k}: cache-read ratio {ratio:.0%} below {min_cache:.0%}")
        if k not in allow:
            flags.append(f"{k}: key not in allowlist")
    return lines, flags


def fetch(key, now):
    q = [("starting_at", (now - timedelta(days=7)).strftime("%Y-%m-%dT%H:00:00Z")), ("bucket_width", "1h"),
         ("limit", "168"), ("group_by[]", "api_key_id"), ("group_by[]", "model")]
    out, page = [], None
    while True:
        qs = urllib.parse.urlencode(q + ([("page", page)] if page else []))
        req = urllib.request.Request(f"{URL}?{qs}", headers={"x-api-key": key, "anthropic-version": "2023-06-01"})
        with urllib.request.urlopen(req, timeout=30) as r:
            d = json.load(r)
        out += d["data"]
        page = d.get("next_page") if d.get("has_more") else None
        if not page:
            return sorted(out, key=lambda b: b["starting_at"])[-168:]


def selftest():
    rows = json.loads(PRICING.read_text())
    z = {"uncached_input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 0}
    day = lambda i: (datetime(2026, 1, 1, tzinfo=timezone.utc) + timedelta(hours=i)).strftime("%Y-%m-%dT%H:00:00Z")
    bs = [{"starting_at": day(i), "results": []} for i in range(168)]
    for i in range(0, 168, 24):  # k_busy active all 7 days, no cache
        bs[i + 5]["results"].append({**z, "api_key_id": "k_busy", "model": "x", "uncached_input_tokens": 10**6})
    bs[-1]["results"].append({**z, "api_key_id": "k_new", "model": "x", "cache_read_input_tokens": 10**6})
    _, f = analyze(bs, rows, max_usd=0, allow={"k_busy"})
    f = "\n".join(f)
    assert "k_busy: 24h spend" in f and "always-on" in f and "cache-read ratio 0%" in f and "k_new: key not in allowlist" in f, f
    assert "k_new: cache-read" not in f and "k_busy: key not" not in f, f
    _, f = analyze(bs[:100], rows, allow={"k_busy", "k_new"})
    assert not f or all("always-on" not in x for x in f), f
    print("self-test ok")


def main():
    if "--self-test" in sys.argv:
        return selftest()
    key = os.environ.get("ANTHROPIC_ADMIN_KEY")
    if not key:
        print("cost-sentinel: skipped (ANTHROPIC_ADMIN_KEY not set)")
        return 0
    env = os.environ.get
    max_usd = float(env("COST_SENTINEL_MAX_USD_DAY")) if env("COST_SENTINEL_MAX_USD_DAY") else None
    af = Path(env("COST_SENTINEL_ALLOWLIST", "state/cost-sentinel-allowlist.txt"))
    allow = frozenset(l.split("#")[0].strip() for l in af.read_text().splitlines()) - {""} if af.exists() else frozenset()
    try:
        buckets = fetch(key, datetime.now(timezone.utc))
    except Exception as e:  # never echo headers/key
        print(f"cost-sentinel: API error: {type(e).__name__}: {e}", file=sys.stderr)
        return 2
    lines, flags = analyze(buckets, json.loads(PRICING.read_text()), max_usd, float(env("COST_SENTINEL_MIN_CACHE_RATIO", "0.5")), allow)
    print("# cost-sentinel (last 24h, estimated from tokens)\n\n" + "\n".join(lines))
    if max_usd is None:
        print("\n_spend limit check off: set COST_SENTINEL_MAX_USD_DAY_")
    if not af.exists():
        print(f"\n_allowlist {af} missing: every key is flagged unknown_")
    print("\n## Flags\n" + ("\n".join(f"- {f}" for f in flags) if flags else "none"))
    return 1 if flags else 0


if __name__ == "__main__":
    sys.exit(main())
