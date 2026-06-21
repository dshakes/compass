# Demo

`preview.gif` (shown at the top of the root README) is generated from
[`demo.tape`](demo.tape) with [vhs](https://github.com/charmbracelet/vhs) — a tool
that records a terminal session from a script, so the demo is reproducible and
diff-able instead of a hand-captured screen recording.

There are two tapes:
- [`demo.tape`](demo.tape) → `demo/preview.gif` — the day-to-day feel (guardrails · status line · loop · crew).
- [`budget.tape`](budget.tape) → `assets/budget.gif` — the **governance moment**: the live budget ceiling
  hard-stopping a session at your cap. It drives the real `claude/hooks/budget-gate.sh` hook (via the
  `budget` helper in `_demo.sh`), so the HALT on screen is the actual gate firing, not a mockup.

## Render it
```bash
brew install vhs        # or: go install github.com/charmbracelet/vhs@latest
make demo               # == vhs demo/demo.tape    -> demo/preview.gif
make demo-budget        # == vhs demo/budget.tape  -> assets/budget.gif
git add demo/preview.gif assets/budget.gif && git commit -m "docs: refresh demo gifs"
```

The tape only runs repo-local, read-only commands (`make doctor`, the status line,
the guardrail, the agent/command roster), so it needs no network or plugin install
and produces the same output every time.

## Prefer a web player?
`asciinema rec demo.cast` records a lightweight, copy-pasteable cast you can embed
via asciinema.org or `agg demo.cast demo.gif`.
