---
name: cost-sentinel
description: Spend/cache watchdog — reads the Anthropic Admin API usage report for the last 24h and flags per-key spend over a limit, always-on keys (active 7 of 7 days), low cache-read ratio, and keys not in an allowlist of known consumers. Use weekly on a schedule or on demand when spend looks off. Read-only; the deterministic script decides, you only summarize.
allowed-tools: Read, Bash
---

# Cost sentinel — the spend watchdog

Provider caps that live only in a web console rot. This skill is the **early-warning layer**
(see [infra/cost-caps/README.md](../../infra/cost-caps/README.md) for the three layers).
The flags are computed by a script, not by you ([deterministic-gate principle](../../docs/20-loops.md)).

## Run

```bash
python3 "$(dirname "$0")/cost-sentinel.py"   # or: python3 claude/skills/cost-sentinel/cost-sentinel.py
```

- `ANTHROPIC_ADMIN_KEY` unset → prints `skipped`, exit 0. Never read or print the key.
- Exit 0 = clean, 1 = flags fired, 2 = API error.
- Config via env: `COST_SENTINEL_MAX_USD_DAY` (per-key 24h limit; unset = check off),
  `COST_SENTINEL_MIN_CACHE_RATIO` (default 0.5),
  `COST_SENTINEL_ALLOWLIST` (default `state/cost-sentinel-allowlist.txt`, one key id per line, `#` comments).
- Spend is an estimate: tokens × `claude/hooks/lib/pricing.json`. Check: `cost-sentinel.py --self-test`.

## Summarize

Paste the script's report, then 2-3 lines: which key is the likely culprit and the first thing to
check (a loop left running, a missing `cache_control`, a leaked or forgotten key). Do not invent
numbers the report doesn't contain, and do not rotate or revoke keys — that is a human action.

## Scheduling

`/loop 7d /cost-sentinel` or a `compass schedule` routine; pipe the summary through the notify hook.
