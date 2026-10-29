# Advanced config — profiles, tighten-only overrides, one policy

Every compass guardrail knob resolves through one function, `compass_policy` in
`claude/hooks/lib/common.sh`. The hooks call it, `compass profile` prints it, and
`compass gate` loads it. You get one answer to "what is the policy here?", whichever
harness is asking.

## Profiles

```bash
compass profile                 # show the active profile + every effective value
compass profile strict          # select one (re-renders installed Claude settings)
compass profile --get max_usd   # one value
```

A profile is a data file, `claude/hooks/profiles/<name>.conf`, made of `key=value` lines.
The hooks contain no profile-specific code, so adding a profile means adding a file.

| knob | standard | solo | strict |
|---|---|---|---|
| `redteam_enforce` (prompt-injection hit blocks instead of warns) | 0 | 0 | **1** |
| `max_usd` (session spend ceiling) | unset | unset | **10** |
| `max_usd_day` (daily circuit breaker) | unset | **25** | **50** |
| `fail_closed` (a crashed/missing/timed-out security hook blocks) | 0 | 0 | **1** |
| `redteam`, `redteam_prompt`, `redteam_tool_output`, `redteam_context` | 1 | 1 | 1 |

**`standard` is today's compass.** Its file sets nothing. `scripts/test-profile.sh`
checks that every knob, the budget and prompt hooks' verdicts, and the installed
settings file come out the same as with no profile at all.

Precedence, lowest to highest: profile → `~/.compass/config` → `COMPASS_<KEY>` env. You
are trusted, so your config and shell override your own profile. The active profile name
lives in `~/.compass/profile`, and an unknown name falls back to `standard`.

## Repo overrides: tighten only

A repo can commit `.compass/policy.conf` in the same `key=value` format. It is untrusted
input, like the repo's `CLAUDE.md`, so it is applied last and may only make rules
**stricter**:

```ini
# .compass/policy.conf — this repo touches prod credentials
max_usd=3
redteam_enforce=1
```

- Caps: a lower positive value wins. A repo can add a cap where you set none, but can't
  raise one or clear it (`0`).
- Scan switches: a repo can turn one on, never off.
- Unknown keys are refused. There is no allowlist key, so `protect_paths_allow=.env`
  does nothing. `fail_closed` is install-time and is also refused (see below).

Every refused line is dropped, and your stricter value stays in force. The
session-start hook tells the model what was refused, and `compass profile` lists it
under `REJECTED`. *A project cannot grant itself a safety exception.*

## Fail-closed hooks (`fail_closed=1`)

compass hooks fail open by design. An internal error exits 0, so a broken check never
blocks your work. That design has a gap: if a guardrail **doesn't run at all** (missing
script, timeout, crash), the action goes through and nobody is told. Claude Code's
hook reference documents a per-hook `"onFailure": "block"` (v2.1.295+) that closes it.
With `onFailure` set, a hook that can't start, times out, prints invalid JSON or exits
with a code other than 0 or 2 blocks the action.

Under `fail_closed=1`, `compass profile strict` (and `install.sh`) render your settings
with `onFailure: "block"` on `protect-paths`, `budget-gate` and `scan-prompt`, the
PreToolUse and UserPromptSubmit hooks where blocking stops something. The scripts'
own fail-open behavior stays the same: a soft internal error still exits 0. The
setting only changes what happens when the guardrail never got to decide. PostToolUse
and SessionStart hooks are left alone, because blocking at those points can't undo
anything. `compass doctor` checks that the rendered settings carry the field and that
your `claude` is new enough to honor it.

## One policy, three harnesses

| | Claude Code | Codex CLI | Gemini CLI |
|---|---|---|---|
| spend caps (`max_usd`, `max_usd_day`) | budget-gate hook | via `compass gate` | via `compass gate` |
| prompt / tool-output / context injection scans | hooks | — | — |
| `protect-paths` (secrets, catastrophic commands) | hook | — | — |
| `fail_closed` | rendered settings | — | — |
| repo tighten-only override | yes | caps only, via gate | caps only, via gate |

`compass gate` runs `eval "$(compass profile --env)"` before it starts. A Codex or
Gemini session pointed at the gate therefore gets the same effective ceiling as the
Claude hook, including any cap a repo lowered. The gaps are real: compass ships hook
adapters only for Claude Code. Codex and Gemini get the operating manual
(`AGENTS.md` / `GEMINI.md`) and the spend gate, but no runtime injection scan or path
protection. Two more limits apply. The plugin's `hooks.json` is a single shipped file,
so plugin installs can't switch to fail-closed per profile; use the `install.sh` (git
clone) path for `strict`. And a copy-mode install has to re-run `./install.sh` after
`compass profile` to pick up `fail_closed`.

## Audit the config you already run: `compass scan --config`

```bash
compass scan --config            # human report
compass scan --config --json     # {high, findings:[{severity,file,rule,detail}]}
```

The scan reads `~/.claude/settings.json` (+`.local`), the project's
`.claude/settings*.json` and `.mcp.json`, `~/.codex/config.toml` and
`~/.gemini/settings.json`. It never writes to any of them. It exits 1 on any HIGH
finding.

| severity | finding |
|---|---|
| HIGH | permission bypass: `bypassPermissions`, `sandbox_mode = "danger-full-access"`, `yolo` |
| HIGH | wildcard Bash allow (`Bash`, `Bash(*)`, `Bash(:*)`) |
| HIGH | hook script (or its directory) world-writable |
| HIGH | MCP server via `curl … \| sh`, or an unpinned / `@latest` `npx` package |
| HIGH | literal secret in an `env` block, reported **by key name only**; the value is never printed |
| MED | hook script missing (that guardrail silently never runs), unpinned `uvx`, `approval_policy = "never"` |
| LOW | hook without a `timeout` |

The scan won't install anything for you. To vet a third-party plugin before you
install it, use `compass audit-plugin`. Tests: `scripts/test-scan-config.sh` runs the
scan against `scripts/fixtures/scan-config/`.
