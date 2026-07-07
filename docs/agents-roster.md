# Agent roster

The named specialists the driver can delegate to. Each is a plain markdown file in
[`claude/agents/`](../claude/agents/) — `name`, a `description` the driver reads to
**auto-pick** the right one, a deliberately-chosen `model` tier, and a scoped tool set.
The description is the routing signal: it says *when* to reach for the agent, so the
driver delegates without being told which one.

**Model tier follows the cost discipline** in [`claude/CLAUDE.md`](../claude/CLAUDE.md):
cheap models for mechanical/parallel work, the strong model only where a wrong answer
is expensive. Reserve Opus for judgment; push fan-out down to Sonnet and Haiku.

- **Haiku** — mechanical, high-volume: test runs, log triage, formatting sweeps.
- **Sonnet** — most implementation: feature coding, refactors, docs, profiling.
- **Opus** — expensive-if-wrong judgment: architecture, security, subtle debugging,
  schema/migration and API-contract design.

Every agent carries the same discipline as the driver: **verify before done** — run the
check, paste the output, label anything it couldn't run as **UNVERIFIED**. A delegated
"passing" is a claim, so the driver re-runs the gate on returned work.

## Implementers — language specialists

Focused feature/bugfix work in one language; write code **and** tests, run the language's
gate before handing back.

| Agent | Tier | Reach for it when |
|---|---|---|
| [`go-engineer`](../claude/agents/go-engineer.md) | Sonnet | Go services, gRPC, concurrency — control-plane / backend work. Runs `vet` + tests. |
| [`rust-engineer`](../claude/agents/rust-engineer.md) | Sonnet | Latency-sensitive Rust — gateway/router/runtime, async, typed errors. Runs `clippy` + tests. |
| [`typescript-engineer`](../claude/agents/typescript-engineer.md) | Sonnet | Strict TS/Node — typed backends, SDKs, server/client boundaries, `zod` at inputs. Runs typecheck + lint. |
| [`python-engineer`](../claude/agents/python-engineer.md) | Sonnet | Python 3.11+ services, data/ML glue — type hints, pydantic. Runs `ruff` + tests. |

## Designers — expensive-if-wrong contracts

Design surfaces that are costly to unship. Reason about compatibility and safety first.

| Agent | Tier | Reach for it when |
|---|---|---|
| [`architect`](../claude/agents/architect.md) | Opus | Planning a non-trivial, multi-file/service change before any code. Read-only plan + risks. |
| [`api-designer`](../claude/agents/api-designer.md) | Opus | Shaping REST/gRPC/proto contracts, versioning a public surface, backward-compat review. |
| [`db-expert`](../claude/agents/db-expert.md) | Opus | Schema/index design, migration safety, slow-query tuning (SQL + common stores). |

## Diagnosers — find the cause

Something is wrong, slow, or failing; isolate the cause before proposing a fix.

| Agent | Tier | Reach for it when |
|---|---|---|
| [`debugger`](../claude/agents/debugger.md) | Opus | Something is **broken** — failing test, panic, wrong behavior, cause unclear. Proves it, then minimal fix. |
| [`perf-profiler`](../claude/agents/perf-profiler.md) | Sonnet | Something is **slow** (not broken) — latency/throughput/CPU/memory. Measures, changes one thing, re-measures. |
| [`k8s-operator`](../claude/agents/k8s-operator.md) | Sonnet | Failing pods / cluster state, drafting manifest changes. Reads freely; never applies or deletes. |

## Reviewers & gates — is it safe to ship

The safety net around autonomous work: review, test, audit.

| Agent | Tier | Reach for it when |
|---|---|---|
| [`code-reviewer`](../claude/agents/code-reviewer.md) | Sonnet | After a non-trivial change, before committing — correctness, security, conventions. |
| [`security-auditor`](../claude/agents/security-auditor.md) | Opus | Touching auth, secrets, tenant isolation, crypto, external input. Read-only deep review. |
| [`test-architect`](../claude/agents/test-architect.md) | Sonnet | The gate before an autonomous fix merges — generates + hardens tests, validates behavior. |
| [`test-runner`](../claude/agents/test-runner.md) | Haiku | Just run the suite and triage failures without spending driver tokens. |

## Scribes

| Agent | Tier | Reach for it when |
|---|---|---|
| [`docs-writer`](../claude/agents/docs-writer.md) | Sonnet | READMEs, ADRs, API docs, runbooks — matching the repo's voice. Cheap, prose-focused. |

---

Add your own: drop a markdown file in [`claude/agents/`](../claude/agents/) with a `name`,
a routing-friendly `description`, a `model`, and the minimum tools. Write the description
so it says *when* to use the agent and doesn't overlap an existing one — that's what keeps
the driver's routing sharp.

*See also: [Every agent, one source](12-every-agent.md) · [Cost & models](02-cost-and-models.md) · [Customize](03-customize.md).*
