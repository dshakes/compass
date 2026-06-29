# RTK — token-optimized command proxy (optional)

RTK rewrites common dev commands to token-cheaper equivalents (often 60–90% less output)
**transparently**, via a PreToolUse hook — same effect, far fewer tokens. It is **opt-in and
external**: install the `rtk` binary yourself; without it the hook is a silent no-op, so this
section costs nothing until you opt in. See [docs/21-rtk.md](../docs/21-rtk.md) for setup.

## Meta commands (run `rtk` directly)

```bash
rtk gain              # token-savings analytics  (rtk gain --history for per-command)
rtk discover          # analyze history for missed opportunities
rtk proxy <cmd>       # run a raw command unfiltered (debugging)
rtk --version         # verify install (need >= 0.23.0 for the rewrite hook)
```

## Hook-based usage

Once `rtk` is installed and the hook is enabled, ordinary Bash commands are rewritten
automatically (e.g. `git status` → `rtk git status`) — no tokens, nothing for you to do. The
rewrite **cannot bypass safety**: the guardrail and budget hooks run alongside it and a `deny`
always wins, so a rewritten command is still subject to every gate.

⚠️ Name collision: if `rtk gain` fails, you may have a different `rtk` on PATH (verify `which rtk`).
