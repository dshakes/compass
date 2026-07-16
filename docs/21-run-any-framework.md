# Running any methodology under compass

compass is a governance layer. A spec-driven framework, a swarm/orchestration framework,
a persona/methodology pack — any of these can run on top of compass without giving up the
safety and cost controls compass provides. This page is the generic guide.

> **tl;dr:** set `COMPASS_MAX_USD` before any long run, audit third-party plugins before
> installing, and the guardrails + benchmark still hold regardless of what runs on top.

---

## The relationship

compass governs the **environment** (hooks, guardrails, budget caps, audit log) while the
framework governs the **task** (methodology, persona, orchestration). They don't conflict:
compass's PreToolUse hooks see every tool call no matter which framework generated it.

```
framework (specs / swarm / persona)
    ↓  task orchestration
compass (hooks / guardrails / budget / audit)
    ↓  enforced on every tool call
Claude Code / Codex / SDK agent
```

Nothing about installing a framework bypasses the hooks or the human merge gate.

---

## Before you install a third-party framework or plugin pack

Run the security scanner on any directory you're about to install:

```bash
compass audit-plugin /path/to/downloaded-framework-dir
```

It checks for prompt injection in `.md` files and MCP tool descriptions, unpinned MCP
server versions, hook scripts that fetch-and-execute from the network, scripts that write
to your live agent config, and base64-encoded executable payloads. Exit 0 = clean; exit 1 =
HIGH or MED findings to review before installing.

If the vendor supplies a known-good baseline for their own findings:

```bash
compass audit-plugin /path/to/framework --baseline /path/to/vendor-baseline.tsv
```

The baseline is **your** file — never the framework's own. A plugin that supplies its own
baseline could suppress any finding against itself.

---

## Cap token spend before long runs

Frameworks that run multiple agents, loop over tasks, or operate unattended can accumulate
significant spend. Set a ceiling before starting:

```bash
export COMPASS_MAX_USD=10              # hard-stop this session at $10
export COMPASS_MAX_USD_DAY=30          # hard-stop today's combined spend at $30
```

The budget gate (`claude/hooks/budget-gate.sh`, always active when `COMPASS_MAX_USD` is set)
blocks the next tool call once the cap is reached — the framework cannot quietly run past it.
For frameworks that call non-Claude APIs (Codex, SDK scripts), use `compass gate` to extend
enforcement:

```bash
compass gate &                                     # start proxy on 127.0.0.1:4141
export ANTHROPIC_BASE_URL=http://127.0.0.1:4141
export OPENAI_BASE_URL=http://127.0.0.1:4141
# start the framework here — caps apply to all API calls
```

→ [cost & models](02-cost-and-models.md) for full budget documentation.

---

## Guardrails and benchmarks still apply

The injection detectors, guardrail corpus, and benchmarks measure compass's policy layer —
they are independent of what framework is running. `compass bench` and `compass redteam --eval`
give the same numbers whether you run a bare Claude Code session or a framework on top.

If the framework adds its own `.md` files or MCP servers, scan them:

```bash
compass redteam --scan /path/to/framework-install-dir
```

This checks for poisoned context (hidden instructions in `CLAUDE.md`/`AGENTS.md`, MCP
descriptions with injection directives, settings files that try to loosen safety) before
the framework runs.

---

## Human gate — unchanged

No framework configuration changes who has merge authority. The branch protection and required
review checks that `setup.sh --protect` installs are GitHub-enforced — they cannot be bypassed
by a framework that runs on the agent side. The human always merges.

---

## Spec-driven frameworks

compass already auto-discovers specs in common locations (`specs/*/spec.md`, `.specify/specs/*/spec.md`,
`spec.md`) and feeds them to the SDLC Reviewer as acceptance criteria. If a framework drops
its specs in a standard location, compass picks them up with no extra configuration.

For a framework that places specs elsewhere, set `SDLC_SPEC=<path>` in `orchestrate.sh` or
add a `Spec: <path>` line to the PR description for the GitHub-native loop.
