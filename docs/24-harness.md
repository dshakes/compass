# Harness — everything around the model that isn't the model

*Fundamentals, page 3. "Agent = Model + Harness" is the compact version: the harness is
the tool surface, the permissions, the sandbox, the loop, and the durable state the model
runs inside of — and the evidence says it moves outcomes more than swapping the model
does. Part of the [layers](22-the-layers.md) this series maps; for the layer the harness
sits above, see [context](23-context.md); for what runs the harness on a schedule,
[the five moves](20-loops.md).*

## In one minute

Two agents can run the identical model and get wildly different results, because the
model is never the whole system. Everything around it — which tools it's handed, what
it's allowed to touch, whether a run is checked before it's trusted, whether state
survives past one conversation — is the harness. Change the harness with the model held
fixed, and the numbers move. That's the finding this page is built on.

## Who named it, and what they meant

| Who | When | Said | Grade |
|---|---|---|---|
| **Mitchell Hashimoto** ([post](https://mitchellh.com/writing/my-ai-adoption-journey)) | 5 Feb 2026 | first used the term: "anytime you find an agent makes a mistake, you take the time to engineer a solution" into the environment, permanently | E2 |
| **Addy Osmani** ([post](https://addyosmani.com/blog/agent-harness-engineering/)) | 19 Apr 2026 | popularized it: "A decent model with a great harness beats a great model with a bad harness" | E2 |

Hashimoto's framing is the operational one worth keeping: a harness isn't designed up
front, it accretes — every time an agent fails the same way twice, that failure gets
engineered out of the environment so it can't recur. The harness is the memory of every
mistake you've already fixed once.

## The evidence — harness-only gains

This is why harness grades **E1**, same tier as context rot on the previous page —
these are numbers, not arguments:

| Result | Change | Model held fixed? | Grade |
|---|---|---|---|
| LangChain Deep Agents on Terminal-Bench 2.0 | moved a coding agent from ~rank 30 to top 5 | yes — harness-only | E1 |
| Databricks harness benchmark ([post](https://www.databricks.com/blog/ai-harness)) | 36.10% -> 52.63% task success | yes — harness-only | E1 |

The Databricks number is worth sitting with: that's not a marginal gain, it's **roughly
halving the error rate** with zero change to the model underneath. If your instinct when
an agent underperforms is "try a bigger model," the harness evidence says check the
scaffolding first — it's frequently the cheaper fix and the larger lever.

## What's actually in a harness

Five components recur across every description of the term:

| Component | What it governs | Example |
|---|---|---|
| **Tool surface** | what the agent can even attempt | which functions/commands are exposed, and how many |
| **Permissions & guardrails** | what it's allowed to do without asking | deny rules, approval prompts, blocked actions |
| **Sandboxing** | the blast radius if it does the wrong thing anyway | a real OS boundary around untrusted execution |
| **The loop itself** | how it reasons and acts in turns | ReAct — reason, act, observe, repeat (Yao et al. 2022, [arXiv:2210.03629](https://arxiv.org/abs/2210.03629)) |
| **Durable state** | what survives past one run | filesystem + git as the memory, not the conversation |
| **Observability** | whether anyone can tell what happened | logs, audit trails, a diff a human can review |

Note the loop lives *inside* the harness here — a single run's ReAct cycle — which is a
narrower use of "loop" than [page 2 of the loop-engineering series](20-loops.md), where a
loop is the thing that makes a *harness* repeat itself on a schedule. Same word, one layer
apart; read the surrounding sentence, not just the noun.

## Fewer tools, not more

The intuitive move is to keep adding tools — more surface, more capability. The current
evidence cuts the other way: Anthropic's Claude Code team has said they've been trending
toward *fewer* tools, dropping the built-in grep/glob tools in favor of native bash (see
[context, page 2](23-context.md#budgets-shrink-as-models-improve) — E2, primary link and
date). A large, overlapping tool surface gives the model more ways to pick the wrong
one; a small, well-named surface is easier for the model to reason about correctly, which
is a harness decision, not a context one, even though it shows up as fewer tokens in the
window.

## In practice

compass's harness accretes exactly the way Hashimoto describes: each guardrail below
exists because a specific mistake was engineered out, and each is scored against a
labeled corpus rather than asserted.

| Component | compass primitive |
|---|---|
| **Tool surface** | subagents scope tools per role (`tools:` frontmatter in `claude/agents/*.md`) — a reviewer gets `Read, Grep, Glob, Bash`, not the full set |
| **Permissions & guardrails** | `claude/hooks/protect-paths.sh` blocks secret writes, catastrophic shell commands, and force-push/hard-reset on shared branches; `claude/hooks/budget-gate.sh` halts a session at a spend ceiling |
| **Sandboxing** | `compass sandbox` — a real OS boundary (bwrap/firejail/sandbox-exec, no network) for untrusted code, not just a guardrail |
| **The loop itself** | the SDLC roster's fix/review/goal-judge cycle ([09-sdlc](09-sdlc.md)) |
| **Durable state** | git worktrees per task + a PR as the handoff unit ([the five moves](20-loops.md)) |
| **Observability** | `claude/hooks/scan-untrusted-context.sh` / `scan-prompt.sh` / `scan-tool-output.sh` flag injection attempts into the session log |

The evaluator that keeps this honest is deterministic and CI-gated, not a vibe check:

```bash
compass bench              # guardrail precision/recall + router accuracy, CI-gated floor
compass bench --guardrail  # just precision/recall over scripts/guardrail-corpus.tsv
compass redteam --eval     # injection/override/malware detector precision & recall
```

`compass bench` exists for the same reason the Terminal-Bench and Databricks numbers do:
"the guardrail is good" is worthless without a corpus, a scoring method, and a way for
someone else to rerun it. → [18-benchmark](18-benchmark.md) has the full corpora and floors.

## Honest limits

The containment question this page shares with [context, page 2](23-context.md) is
genuinely unresolved, and this page won't manufacture a resolution: Böckeler argues
harness is a specific form of context engineering (harness inside context); Osmani and the
Databricks framing nest it the other way (context is one input the harness manages,
alongside tools and permissions). Both readings are internally coherent. Pick the one that
matches how your team already thinks about the boundary — the primitives above work either
way.

The Terminal-Bench and Databricks numbers are E1 *for their authors* — reproducible on
their corpora — but compass has not rerun them, so treat them here as E2: a named source
with a primary link, not independently verified by this page. That distinction matters more
than the number itself, per the grading rule on [the layers](22-the-layers.md#grading-a-claim-before-you-adopt-it):
a claim's grade is a property of your verification, not its author's reputation.

## The takeaway

The model is the part everyone benchmarks; the harness is the part that actually moves
your numbers, because it's the part you control turn over turn and mistake over mistake.
Every fixed footgun, every scoped-down tool list, every guardrail with a corpus behind it
is the harness getting better at a fixed model cost. **A great model in a bad harness
loses to a decent model in a great one — build the harness like you mean to keep it.**

---

*See also: [the layers](22-the-layers.md) · [context](23-context.md) · [the five
moves](20-loops.md) · [red-team](17-red-team.md) · [benchmark](18-benchmark.md) ·
[SDLC](09-sdlc.md).*
