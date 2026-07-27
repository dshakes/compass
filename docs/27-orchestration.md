# Orchestration — when fan-out earns its cost

*Fundamentals, page 6. Orchestration means coordinating more than one agent on the same
piece of work — subagents, a dynamic workflow, a fleet of overnight loops. The field spent
2025 and 2026 arguing, loudly, about whether that ever helps. This page grades both sides
of the argument and gives you the one rule that survives it. Part of the layers this
series maps ([the layers](22-the-layers.md)); for the harness underneath, see
[harness](24-harness.md); for the runtime that fans out for real, see
[dynamic workflows](13-workflows.md).*

## In one minute

Fan-out — running several agents instead of one — buys thoroughness, not speed. It's worth
its cost on **independent, read-mostly work**: reviewing a diff from five angles at once,
hunting for six different classes of bug, drafting a plan from three perspectives. It is
not worth its cost on anything you could finish in a few tool calls, on verifying your own
work, or on splitting one small task into pieces so it merely looks parallel.

The field argued about this in public for over a year and converged on one rule:

> **Writes stay single-threaded.** Fan out the reading — investigation, review, retrieval,
> drafting alternatives. Never fan out the writing: one agent, or one synchronized step,
> commits the code or edits the file, so two agents can never silently overwrite each
> other's work. Everything below is commentary on this one line.

## The real disagreement: does fan-out help or hurt?

| Voice | Date | Claim | Grade |
|---|---|---|---|
| **Walden Yan** (Cognition) | 12 Jun 2025 | "Running multiple agents in collaboration only results in fragile systems... Share context, and share full agent traces, not just individual messages." ([post](https://cognition.com/blog/dont-build-multi-agents)) | E2 |
| **Anthropic** | ~13 Jun 2025 | Published "How we built our multi-agent research system," defending an orchestrator/subagent architecture for open-ended, read-mostly research tasks — roughly 24 hours after Yan's post | E2 |
| **Walden Yan** (Cognition, revised) | 22 Apr 2026 | Narrowed the position: multiple agents can contribute, as long as writes stay single-threaded; an unstructured swarm remains "mostly a distraction" ([post](https://cognition.com/blog/multi-agents-working)) | E2 |

On the surface, Anthropic's post looked like a same-week rebuttal — multi-agent bad,
multi-agent good, a day apart. It wasn't really a rebuttal, because the two posts describe
different task shapes. Yan's original warning is about agents sharing *mutable state*:
several agents editing the same files, each with a partial, un-synced view of what the
others just did — that's where fragility comes from, and isolating each agent's context
just hides the conflict instead of resolving it. Anthropic's research system fans out on
**independent subtasks with no shared mutable state**: each subagent searches a different
angle of the web, returns a report, and a single lead agent synthesizes — one write, at the
end, done by one agent.

Yan's 2026 follow-up makes the reconciliation explicit rather than leaving readers to infer
it: the failure mode was never "more than one agent," it was contention over the same
write. Once writes are pinned to a single thread, parallel *reading* is fine — which is
exactly Anthropic's shape and exactly the failure mode from the original post, described
from the other side.

## When fan-out earns its cost — and when it doesn't

| Pays off | Doesn't pay off |
|---|---|
| **Wide multi-file investigation** — several independent leads at once | Anything finishable in a few tool calls |
| **Diverse-lens review** — five dimensions, six bug classes, three plan angles | Verifying your own work (needs a fresh evaluator, not more of you) |
| **Read-mostly, independent subtasks** that converge to one synthesis | Splitting one small task into pieces to look parallel |

The pattern in the left column is always the same shape: independent inputs, no shared
write, one synthesis step at the end. The pattern in the right column either has no real
independence to parallelize, or it's the *verification* step itself — and fanning out the
same worker doesn't fix the problem a fresh evaluator fixes, it just runs the same blind
spot twice.

## The cost model nobody puts in the diagram

A fan-out diagram makes parallelism look free because the boxes run at the same time. The
token bill doesn't work that way. Every subagent re-establishes context from scratch — it
reads files the coordinator may have already half-read, re-derives facts the coordinator
already has a hunch about, does its own exploration — and only then reports back. The
coordinator then has to read and reconcile **N reports instead of one**.

[Cost & models](02-cost-and-models.md) describes the same mechanism as a win for the
*driver's* context: "a subagent reads 20 files and returns a 5-line conclusion; the
expensive driver context never holds those 20 files." That's true, and it's exactly why
delegation is cheap for one subagent. Fan-out is that same trade multiplied by however many
agents you spawn — the aggregate token spend is the sum of every subagent's "read 20 files"
step, not just the 5-line conclusions you get to read. [Dynamic workflows](13-workflows.md)
says this plainly about its own three shipped workflows: they buy **thoroughness**, and "a
workflow spawns many agents, so one run uses meaningfully more tokens than the same task in
conversation... spend accordingly."

## Graph engineering, graded honestly

While the fan-out argument was still live, a second, noisier argument arrived and got
tangled up with it: whether "orchestration" is really "graph engineering," a new discipline
distinct from a loop. [The layers](22-the-layers.md) already carries the receipts for how
that term was born; the short version, graded:

| Voice | Date | Claim | Grade |
|---|---|---|---|
| **Peter Steinberger** | 18 Jul 2026 | Satirical tweet — "Are we still talking loops or did we shift to graphs yet?" | E4 |
| **A fabricated "Microsoft, Stanford and Anthropic" study** | within 4 days | Claimed 18% accuracy gains from graph-structured orchestration; traced back to an unrelated paper about industrial engineering diagrams | E4 (fabricated) |
| **Harrison Chase** (LangChain) | 22 Jul 2026 | "Loop engineering isn't an alternative to graphs, so much as a simple version of them," citing David Khourshid's line that "a loop is just a directed cyclic graph" ([post](https://www.langchain.com/blog/3-years-of-graph-engineering-with-langgraph)) | E2 |

Chase's post is the notable one: he runs the company whose product is *named* for this
term (LangGraph) and has the most direct commercial stake in "graph" winning the naming
argument — and what he published was the deflation, not a victory lap. That's a stronger
signal than an enthusiast's essay would have been, precisely because it argues against his
own incentive.

Grade the newly-named discipline **E4** — a joke, earnest essays within hours, a fabricated
benchmark within days, and a technical objection its own namesake conceded. Grade the
older, separate line of knowledge-graph and GraphRAG research **E1–E2** — real work,
predating this meme by years, with actual measured results behind it. Those are different
claims sharing one word, and per
[the layers](22-the-layers.md#what-this-says-about-graph-engineering), neither should
inherit the other's credibility just because July 2026 glued them together.

## The one real change underneath the name

Strip the naming argument away and one thing underneath it is real and modest: a node in an
orchestration graph can now be **an entire autonomous agent run to completion**, not a
single model call. A workflow stage in [dynamic workflows](13-workflows.md) is exactly this
— `agent()` spawns a full subagent run, not one inference — and that genuinely changes two
things: **failure isolation** (a node either completes its whole run or fails as a unit,
so one bad node doesn't corrupt a shared partial state) and **per-node cost accounting**
(a cheap node can run on Haiku, an expensive one on Opus, and you can see the split — see
[cost & models](02-cost-and-models.md)). [The layers](22-the-layers.md) said compass would
document this under orchestration once it earned its keep rather than a new discipline
name; this page is that documentation.

## In practice

compass's fan-out primitive is [dynamic workflows](13-workflows.md), and it already follows
the single-threaded-writes rule without ever naming it that: every shipped workflow fans
out on a **read-mostly stage** and converges to **one synthesis step**.

- `/compass-review` fans out five review dimensions in parallel, then a skeptic
  adversarially verifies each finding before anything is reported, then one synthesis
  returns a single verdict — no stage writes code.
- `/compass-audit` runs six blind finders across different failure classes, repeats until
  two dry rounds, and ships a finding only if two of three perspective-diverse lenses
  confirm it — again, read-only until the human acts on the report.
- `/compass-plan` drafts from three angles, scores each on one rubric, then grafts the best
  ideas into a single synthesized plan — one write (the plan document), many reads.

Each stage routes to compass's cost-tiered [subagent roster](agents-roster.md) via
`agentType`, so the expensive dimension (security) runs on Opus while the rest run on
Sonnet — cost follows risk, the same principle the roster applies everywhere else. Watch
any run with `/workflows`; stop it without losing completed work if it isn't earning its
tokens.

## Honest limits

- **No public benchmark compares fan-out-with-verification against a single careful pass
  on identical tasks.** The cost-model argument above is a mechanism argument (E3), not a
  measured trade-off — it explains why fan-out is expensive, not exactly when the
  thoroughness it buys is worth that price for your task.
- **The single-threaded-writes rule is itself Yan's argued position, not a benchmarked
  one (E3).** It's the most useful heuristic on this page, and it is still an assertion
  from one practitioner's experience, not a corpus anyone has scored.
- **Graph engineering remains E4 and contested** — [the layers](22-the-layers.md) counts
  at least three or four incompatible meanings still in circulation for the word "graph"
  itself, separate from the fan-out question this page is actually about.
- **Dynamic workflows are a research preview** — the exact runtime, concurrency limits,
  and save path are still moving; treat specifics as current, not permanent.

## The takeaway

The two-year argument over multi-agent systems collapses to one operational rule, and it
holds regardless of which side of the "graph vs. loop" naming fight you're on: **let agents
read in parallel, never let them write in parallel.** Fan out when the work is independent
and read-mostly and you want thoroughness; don't fan out to look busy, to verify your own
output, or to split a task that was never going to take more than a few tool calls. The
node inside a graph got bigger — a whole agent run instead of one call — and that's a real,
useful change. The discipline name built around it is not evidence of anything yet.

---

*See also: [the layers](22-the-layers.md) · [the five moves](20-loops.md) ·
[harness](24-harness.md) · [dynamic workflows](13-workflows.md) ·
[cost & models](02-cost-and-models.md) · [agent roster](agents-roster.md).*
