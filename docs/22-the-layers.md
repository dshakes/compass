# The layers — what's evidenced, what's named, and how to tell

*Fundamentals, page 1. A dated, evidence-graded map of agent engineering's vocabulary —
prompt, context, harness, loop, graph — and a rubric for grading the next term before you
adopt it. Standalone: you don't need compass to use the rubric. For the idea compass is
built on, see [the thesis](loop-engineering.md); for how it's built, [the five moves](20-loops.md).*

<p align="center"><img src="../assets/fundamentals-layers.svg" alt="The five layers of agent engineering, dated, attributed and evidence-graded, shown left to right with arrows between them. Prompt, around 2023, governs the wording of one request, marked ABSORBED. Context, June 2025, named by Lütke and Karpathy, governs which tokens the model sees, graded E1 on the strength of the context-rot finding across 18 of 18 frontier models. Harness, February 2026, named by Hashimoto, governs what the system executes and permits, graded E1 on a measured 36 percent to 53 percent improvement from harness changes alone. Loop, June 2026, named by Osmani, governs how many passes and judged by what, graded E2 because the practice was demonstrably in use earlier than the name. Graph, 18 July 2026, originating in a joke tweet, is contested across three or four incompatible senses and graded E4, with a fabricated benchmark already circulating. Below, what survives when you strip the naming: what the model sees, which is context engineering, versus what the system around it enforces, measures and repairs, which is harness, loop and orchestration — where the finer names are still being argued over. At the bottom, the grade legend: E1 measured, a number you can reproduce; E2 reported, a named source with a primary link and date; E3 argued, a mechanism with no measurement; E4 asserted, confident, popular and unsourced. Never let an E3 or E4 claim write a line of config." width="860"></p>

## The treadmill

In 2026 the agent-engineering community named a new discipline roughly every two months.

```text
  prompt ─────► context ─────► harness ─────► loop ─────► graph
   2023        Jun 2025      Feb–Mar 2026   Jun 2026    18 Jul 2026
```

That cadence is not four independent discoveries. It's the shape of content marketing
riding a real trend. And the trend *is* real — but so is the churn, and the two are easy to
confuse, because they arrive in the same blog posts.

The cost of confusing them is concrete. A practice you adopt because it was named
confidently, rather than because it was measured, becomes config you can't delete: nobody
remembers why it's there, so nobody dares remove it. **Config nobody can justify is the
agent-engineering equivalent of a commented-out block that has survived four refactors.**

So before the fundamentals teach you a layer, this page teaches you how to grade one.

## The map

| Layer | Named | By | Governs | Evidence |
|---|---|---|---|---|
| **Prompt** | ~2023 | — | The wording of one request | **Absorbed.** Not falsified — scoped down from "the job" to one tunable component inside a larger system |
| **Context** | Jun 2025 | Lütke coined; Karpathy amplified | Which tokens the model sees | **Strong.** Anthropic's engineering post, Chroma's context-rot finding (all 18 frontier models degrade with input length), Gartner formalized it |
| **Harness** | Feb–Mar 2026 | Hashimoto named; Osmani popularized | What the system executes, permits, and repairs | **Strong.** Harness-only changes moved a coding agent from ~rank 30 to top 5 on Terminal-Bench 2.0 with no model change; Databricks measured 36% → 53% from harness alone |
| **Loop** | Jun 2026 | Osmani named; Willison and Huntley practised it unnamed a year earlier | How many passes, judged by what, stopping when | **Moderate.** One arXiv treatment, wide practitioner agreement — but the term's most-quoted soundbite has no traceable source (below) |
| **Graph** | 18 Jul 2026 | a joke tweet | Contested — 3–4 incompatible meanings | **Weak.** See below |

Two of these have benchmark numbers attached. One has a joke.

## The two receipts

Nothing on this page matters more than these, because they are what a grading habit is *for*.

**The fabricated benchmark.** Within four days of the graph-engineering meme, a statistic
was circulating — a "Microsoft, Stanford and Anthropic" study reporting 18% accuracy gains
and 85% cost cuts. It traces back to an unrelated paper about industrial engineering
diagrams. A second fabricated study ("$3.1M Stanford and Anthropic") was caught the same
week; the writer who checked it reported simply: *"It does not exist."* Neither was
malicious. Both were plausible, and plausible was enough.

**The soundbite with no source.** Loop engineering's most-quoted line is attributed to the
creator of Claude Code: *I don't prompt Claude anymore — my job is to write loops.* It is
quoted everywhere. It could not be traced to a primary source. The transcript most often
cited as its origin has him saying something closer to the opposite — that he is
*"purely bottlenecked on how fast I can prompt"* — and describing loops as producing about
a third of his code, with the caveat that *"it doesn't totally click yet."*

The underlying practice is still sound. But a field that cannot distinguish a real
benchmark from an invented one in under four days, or a real quote from a manufactured one
at all, is a field where **grading your sources is an engineering control, not an academic
courtesy.**

## Grading a claim before you adopt it

Four grades. Apply them to any practice — including every one compass ships.

| Grade | Means | Test |
|---|---|---|
| **E1 — Measured** | A number, from a named corpus, reproducible by you | Can you run it and get the number? |
| **E2 — Reported** | A named source with a primary link and a date; not independently reproduced | Did you follow the link, or trust a summary of it? |
| **E3 — Argued** | A coherent mechanism with no measurement | Would you notice if it were wrong? |
| **E4 — Asserted** | Confident, popular, unsourced | Who first said it, and when? |

The test column is the load-bearing part. Most E4 claims survive because nobody asks the
question in the right-hand column — and every one of them reads exactly like an E2 until
you do.

Two rules follow, and they're what separate this from a reading exercise:

- **Never let an E3 or E4 claim write config.** Argument and assertion are fine for
  deciding what to *try*. They are not sufficient for a rule that will sit in every future
  context window, unexamined, for a year.
- **A claim's grade is a property of your verification, not of its author.** Anthropic
  publishing something doesn't make it E1 for you. Following the link and running the
  corpus does.

## What this says about graph engineering

Applying the rubric to the newest rung, honestly:

It began as satire — *"Are we still talking loops or did we shift to graphs yet?"* — mocking
this exact treadmill. Earnest essays followed within hours, a fabricated benchmark within
days. The term now carries at least four incompatible meanings: multi-agent orchestration
topology, graph-structured knowledge and memory (which genuinely predates the meme by
years and has real research behind it), execution traces, and "graphs of loops." And the
technical objection is the one nobody has answered: **a loop is already a directed cyclic
graph.** Even LangChain, whose product is literally named for the idea, published the
deflation rather than the victory lap — a loop is *"a simple version"* of a graph, not its
rival.

Grade: **E4** for the discipline, **E1–E2** for the older knowledge-graph work now being
conflated with it. Those are not the same claim and should not inherit each other's
credibility.

One thing underneath it is real and modest: a node in an orchestration graph can now be an
entire autonomous agent run to completion, not a single model call. That genuinely changes
failure isolation and per-node cost accounting. It did not need a new discipline name, and
compass will document it under orchestration when it earns an E1.

## What is actually load-bearing

Strip the naming and one distinction survives every source, uncontested:

> **What the model sees** (context) is a different engineering problem from **what the
> system around it enforces, measures, and repairs** (everything after context).

That's the split worth teaching. The finer subdivisions — harness vs. loop vs. graph — are
still being argued over by the people who coined them, and they disagree about the ordering:
one puts loop *above* harness, another nests context *inside* harness, and Anthropic's own
flagship context-engineering post never uses the word "harness" at all.

The rest of the fundamentals series teaches the durable parts and dates the rest.

## Honest limits

This rubric grades evidence, not importance. An E4 idea can be correct — the practice
usually arrives before the measurement, and Willison and Huntley were running loops a year
before anyone named them. Grading tells you what you're entitled to *assert*, and what you
should attach a date and a source to. It does not tell you what to try.

The grades here are also a snapshot, and a self-interested one: compass's own thesis sits
on this map. `loop-engineering.md` was written independently of the June 2026 essays and
arrives at the same structure, which makes compass a participant in this argument, not a
neutral referee. Read the sources, not the summary — every claim above links to one.

## The takeaway

The treadmill will produce another name before this page is a quarter old. That's fine.
Grade it, date it, and make it earn an E1 before it earns a line of your config. **A
discipline you can't cite is a discipline you can't delete.**

---

*See also: [the thesis](loop-engineering.md) · [the five moves](20-loops.md) ·
[practices we follow, and where they come from](07-practices.md)*
