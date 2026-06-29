# RTK — optional token-optimized command proxy

RTK rewrites common dev commands to token-cheaper equivalents (often **60–90% less output**)
**transparently**, via a `PreToolUse` hook — same command effect, far fewer tokens spent reading
the result. It's **opt-in and external**: you install the `rtk` binary yourself, and without it the
hook is a silent no-op, so enabling the integration costs nothing until you do.

> **Status: draft / experimental.** Wired and unit-tested, but the live rewrite path depends on a
> third-party binary and Claude Code's `updatedInput` application — validate it in your own session
> (below) before relying on it.

## What it is

`rtk` (the "Rust Token Killer") is a standalone CLI that proxies dev commands and trims their
output to what matters. compass ships a thin hook (`claude/hooks/rtk-rewrite.sh`) that delegates
*all* rewrite logic to `rtk rewrite` — the binary is the single source of truth; the hook just
wires it into the agent loop.

## Enable it

1. Install `rtk` (≥ 0.23.0 — the version that added `rtk rewrite`) and `jq`. Verify:
   ```bash
   rtk --version      # rtk X.Y.Z
   which rtk           # the right binary (see the name-collision note in claude/RTK.md)
   ```
2. The hook is already registered in `claude/settings.json` (and the plugin's `hooks.json`) as a
   `PreToolUse` hook on `Bash`. With `rtk` on PATH it activates automatically; with it absent it
   no-ops. To turn it off, remove the `rtk-rewrite.sh` entry from `settings.json`.
3. Check savings any time:
   ```bash
   rtk gain            # token-savings analytics  (rtk gain --history for per-command)
   rtk discover        # opportunities rtk could have caught in your history
   ```

## How it stays safe

The rewriter runs **alongside** compass's guardrails, and **cannot weaken them**:

- PreToolUse hooks run in parallel with **deny-precedence** — if `protect-paths.sh` returns
  `deny` for a dangerous command, the rewriter's `allow` can never override it. The guardrail and
  budget gate still apply to whatever runs.
- The rewriter **never emits `deny`** — it only rewrites safe commands or no-ops; `deny` is owned
  by the guardrail. (Enforced by `scripts/test-rtk-hook.sh`.)
- Only the rewriter emits `updatedInput`, so there's no ambiguous multi-hook rewrite.
- It's a no-op without the binary, and `claude/hooks/.rtk-hook.sha256` pins the hook against
  tampering.

## Validation

`scripts/test-rtk-hook.sh` (in CI) validates the hook's logic deterministically by **stubbing
`rtk`**: the no-op-when-absent path, the rewrite JSON shape (`updatedInput.command`), the
unchanged/empty no-ops, that it never denies, and the sha256 tamper check.

What the unit test **cannot** cover — and you should confirm once in a live session with `rtk`
installed before trusting it:

1. A safe command is actually rewritten and **runs correctly** (`updatedInput` applied).
2. `rm -rf /` (or another dangerous command) is **still blocked** with the rewriter active —
   proving the guardrail holds end-to-end.
3. `rtk gain` shows real savings on your workload.

Until you've done that, treat it as experimental.
