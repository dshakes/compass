# Context — the window is a budget, not a container

*Fundamentals, page 2. Context engineering is the discipline of deciding which tokens the
model sees, on the empirical premise that more tokens are not free — some of them cost
accuracy. This page grades where that idea came from and shows the compass primitives that
spend the budget deliberately. Part of the [layers](22-the-layers.md) this series maps; for
the layer above it, see [harness](24-harness.md); for the runtime it moves through,
[the five moves](20-loops.md).*

## In one minute

A model doesn't remember your project. Every turn, it sees exactly one thing: whatever
text is in its context window at that moment — your prompt, the system prompt, tool
results, file contents, prior turns. That window has a fixed size, and everything in it
competes for the model's attention.

The old instinct is "give it everything, it's smart enough to find what matters." The
finding underneath context engineering is that this is wrong: past a point, more text in
the window makes the model *worse*, not just slower. So the job isn't filling the window —
it's curating it down to the smallest set of things that let the model do the task. That's
a budget you spend on purpose, not a bucket you top up out of caution.

## Who named it, and what they actually said

| Who | When | Said | Grade |
|---|---|---|---|
| **Tobi Lütke** ([post](https://x.com/tobi/status/1935533422589399127)) | 18 Jun 2025 | context engineering is "the art of providing all the context for the task to be plausibly solvable by the LLM" | E2 |
| **Andrej Karpathy** ([post](https://x.com/karpathy/status/1937902205765607626)) | 25 Jun 2025 | amplified it: "the delicate art and science of filling the context window with just the right information" | E2 |
| **Anthropic** ([post](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)) | 29 Sep 2025 | canonical definition: "the set of strategies for curating and maintaining the optimal set of tokens during LLM inference" | E2 |

Both coinages already carry the tension the rest of this page is about: "all the context"
(Lütke) versus "just the right information" (Karpathy) — completeness versus restraint,
in the same two weeks.

Anthropic's post resolves the tension in favor of restraint and gives it a name: the
governing principle is the **smallest possible set of high-signal tokens**, not the
largest. Every technique below is that principle applied to one part of the window.

## Context rot — the empirical anchor

The reason "just add more context" is actively harmful, not merely wasteful, is a
measured finding from Chroma: across **18 tested frontier models**, accuracy degrades as
input length grows, tracing a U-shaped attention curve — models attend well to the start
and end of a long context and lose the middle. This holds even when the added tokens are
irrelevant filler, not noise designed to mislead.

> **What this rules out.** "Paste the whole file / whole thread / whole codebase, the
> model will find the signal" is not a safe default. It's the one thing the context-rot
> result forbids.

Grade: **E1**. It's a reproducible corpus result, not an argument — which is why it
anchors this page the way the benchmark numbers anchor [harness](24-harness.md).

## The four moves: write, select, compress, isolate

LangChain's taxonomy (Lance Martin, [context engineering for agents](https://www.langchain.com/blog/context-engineering-for-agents))
is the breakdown that stuck, because every context technique in practice is one of these
four:

| Move | What it does | Example |
|---|---|---|
| **Write** | put state somewhere outside the window so it survives | a scratchpad file, a memory store, a tracking issue |
| **Select** | pull only the relevant slice into the window | retrieval, grep a symbol instead of loading the file, a targeted diff |
| **Compress** | shrink what's already in-window without losing the task-relevant part | summarize a long tool result, prune old turns, trim a system prompt |
| **Isolate** | give a sub-task its own window so it can't pollute the parent's | a subagent, a sandboxed run, a separate process |

Grade: **E2** — a named source with a primary link, not independently measured by
compass, but it's the framework this page's "in practice" section is organized against
because it maps directly onto primitives that already exist.

## Budgets shrink as models improve

Anthropic's own post reports removing **more than 80% of Claude Code's system prompt**
for newer models with no measurable loss in quality. That is a strong secondary finding:
most of what accumulates in a context budget is not signal, it's unexamined inheritance —
instructions kept because removing them once felt risky, not because a model still needs
them. As models get better at inferring intent from less, the correct budget shrinks, and
periodically re-auditing what's actually load-bearing catches up to that.

The same logic explains a live trend: Anthropic's Claude Code team said in Jul 2026 they've
"been trying to trend towards fewer tools," dropping the built-in grep/glob tools in favour
of native bash ([Willison's notes on Cat Wu and Thariq at AI Engineer World's Fair, 21 Jul
2026](https://simonwillison.net/2026/Jul/21/cat-and-thariq/)). Grade **E2** — a named
source with a primary link and a date, but a stated intent rather than a measured result.
Treat it as a data point about direction, not a benchmarked claim.

**Where the boundary gets contested.** Birgitta Böckeler (Thoughtworks, in
[harness engineering](https://martinfowler.com/articles/harness-engineering.html), 2 Apr
2026) argues harness engineering is "a specific form of context engineering" — i.e. tools,
permissions, and the loop itself are just more things that end up in or shape the window,
so harness nests *inside* context. [Page 3](24-harness.md) covers sources that nest it the
other way. Nobody has settled this, and this page won't pretend otherwise.

## In practice

compass's own context budget is small on purpose — [philosophy #3](00-philosophy.md) says
it directly: short, true context beats long context, and every line in a memory file
competes with the actual task. The primitives below are that principle applied to the
four moves above.

| Move | compass primitive | What it does |
|---|---|---|
| **Write** | [Serena memory](04-mcp.md) / `session-memory.sh` | durable, cross-repo learnings survive `/clear` and compaction; opt-in, off by default |
| **Select** | `scripts/context-pack.sh` | pulls only the touched symbols and their call sites for a diff — not the whole repo — for the SDLC reviewer |
| **Compress** | `claude/hooks/inject-context.sh` | a compact SessionStart snapshot (branch, dirty state, 5 recent commits) instead of the full log |
| **Isolate** | subagents ([01-architecture](01-architecture.md#subagents-claudeagentsmd)) | each runs in its own window and returns only its conclusion, keeping the driver's context lean |

Try the select move directly:

```bash
scripts/context-pack.sh main...HEAD   # touched symbols + up to 5 call sites each, bounded output
```

`CLAUDE.md` itself is the compress move applied to standing instructions: short and true,
cut when a line stops earning its place, per [00-philosophy](00-philosophy.md#3-short-true-context-beats-long-context)
— the same discipline Anthropic's 80%-removal finding argues for at the system-prompt
layer.

## Honest limits

Context rot (E1) tells you *that* long, low-signal input degrades accuracy — not exactly
*where* the cliff is for a given model or task, and Chroma's own finding is a curve, not a
single threshold you can hard-code. Treat the four-move taxonomy as a checklist for
thinking, not a formula: most real budgets mix all four, and there's no measured ratio of
write/select/compress/isolate that's "correct."

The Böckeler containment question is real and unresolved: if harness is a form of context
engineering, page 3 of this series is a subset of this one, not a peer. This page doesn't
pick a side, and neither should you until someone measures it rather than argues it.

## The takeaway

The context window was never a container to fill — it's a budget every extra token
spends, and context rot is the receipt that overspending has a cost, not just an
opportunity cost. Curate down, write what needs to survive to disk, isolate what would
pollute the rest, and re-audit what's load-bearing as the model gets better at inferring
the rest. **The right context is the smallest one that still solves the task.**

---

*See also: [the layers](22-the-layers.md) · [harness](24-harness.md) · [the five
moves](20-loops.md) · [cost & models](02-cost-and-models.md) · [MCP & memory](04-mcp.md).*
