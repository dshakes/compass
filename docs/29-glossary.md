# Fundamentals glossary — every term, dated and graded

*The reference companion to the fundamentals series
([the layers](22-the-layers.md) · [context](23-context.md) · [harness](24-harness.md) ·
[the gate](25-the-gate.md) · [orchestration](27-orchestration.md)): every term those pages
use, alphabetized, dated where a date exists, and graded by the same rubric — so you can
look one up mid-sentence instead of re-reading five pages. Write "—" where a date or
attribution is genuinely unknown; nothing here is a guess dressed up as a fact.*

| Term | Named | By | What it means | Grade |
|---|---|---|---|---|
| **Ablation** | — | — | Remove one component of a system and re-measure to isolate its causal effect; borrowed from ML/statistics, not an agent-engineering coinage | E3 |
| **Agentic loop** | 30 Sep 2025 | Simon Willison ("Designing agentic loops") | The repeated call-model-then-act-then-feed-result-back cycle inside one agent run; "an agent runs tools in a loop to achieve a goal" | E2 |
| **Backpressure** | 14 Jul 2025 | Geoffrey Huntley ("The Ralph technique") | Verification, not generation, is the scarce resource once an agent can produce a plausible fix in seconds — the honest name for what a gate is for | E2 |
| **Compaction** | — | — | Summarizing or discarding older conversation/tool-output history so a session stays inside its context budget; ships as a runtime feature | E3 |
| **Context engineering** | 18 Jun 2025 | Lütke coined; Karpathy amplified (25 Jun 2025); Anthropic gave the canonical definition (29 Sep 2025) | Curating the smallest set of high-signal tokens the model sees, not maximizing what fills the window | E2 |
| **Context rot** | — | Chroma (research finding) | Measured accuracy degradation as input length grows, across 18 tested frontier models, even with irrelevant filler tokens | E1 |
| **Evaluator-optimizer** | 19 Dec 2024 | Anthropic ("Building Effective Agents") | One model drafts, a second critiques in a loop, with explicit stopping conditions and ground truth from the environment | E2 |
| **Fan-out** | — | — | Splitting one piece of work across several concurrent agents that each handle an independent slice, then reconciling their results | E3 |
| **Gate** | — | — | The part of a loop that can say no — an executing test, a fresh-context reviewer, a spend cap, a human at the merge button | E3 |
| **Generator/evaluator split** | — | — | Structural separation of the agent that produces a change from the agent that judges it, on a fresh context, because the author can't see its own chain of self-persuasion | E3 |
| **Graph engineering** | 18 Jul 2026 | A satirical tweet (Peter Steinberger) | Treating agent orchestration as graph-shaped rather than loop-shaped; carries at least 3-4 incompatible meanings | E4 (discipline); E1-E2 (older, unrelated knowledge-graph/GraphRAG research now conflated with it) |
| **Harness engineering** | 5 Feb 2026 | Mitchell Hashimoto named; Addy Osmani popularized (19 Apr 2026) | Everything around the model that isn't the model — tool surface, permissions, sandboxing, the loop, durable state — and the evidence says it moves outcomes more than the model does | E2 |
| **Loop engineering** | Jun 2026 | Addy Osmani named; Simon Willison and Geoffrey Huntley practiced it unnamed a year earlier | The unit of work is "generate, check, critique, fix, repeat, until a gate says done" — a loop is what makes a harness repeat itself | E3 |
| **Maker≠checker** | — | — | The agent that wrote a change must not be the one that judges it; a different context (ideally a different model) evaluates instead | E3 |
| **Prompt engineering** | ~2023 | — | The wording of one request to the model; scoped down from "the whole job" once context, harness, and loop absorbed the rest | E3 |
| **ReAct** | Oct 2022 | Yao et al. (arXiv:2210.03629) | Reason, act, observe, repeat — the think-act-observe cycle a single agent run executes; now described as the loop living inside the harness | E2 |
| **Subagent** | — | — | An isolated agent instance a driver delegates to, with its own context and a scoped tool set, returning only its conclusion | E3 |
| **Tool surface** | — | — | The set of tools/commands an agent can attempt to call; a smaller, well-named surface is easier for a model to reason about correctly | E3 |
| **Verification debt** | — | — | Unverified agent output piling up between "it ran" and "it's right"; one of a self-running loop's four silent costs | E3 |
| **Verification ladder** | — | — | The escalating rigor of a check — assertion, executed test, fresh-context review, cross-model audit, human gate; referenced as a planned companion page not yet published | E4 |

## How to read the grades

Same four grades as
[the layers](22-the-layers.md#grading-a-claim-before-you-adopt-it), applied per term
instead of per layer:

| Grade | Means |
|---|---|
| **E1** | Measured — a number, from a named corpus, reproducible by you |
| **E2** | Reported — a named source, a primary link, a date; not independently reproduced |
| **E3** | Argued — a coherent mechanism, no measurement attached |
| **E4** | Asserted — confident, popular, unsourced |

A high grade doesn't mean "true," and a low one doesn't mean "wrong" — prompt engineering
is E3 in this table and it's still a real, working practice. The grade tells you what
you're entitled to assert without checking further, and where you'd have to follow the
link yourself before repeating it as fact. Never let an E3 or E4 term write a permanent
rule into your config; they're fine for deciding what to try, not for a line that will sit
unexamined in every future context window.

---

*See also: [the layers](22-the-layers.md) · [context](23-context.md) ·
[harness](24-harness.md) · [the gate](25-the-gate.md) ·
[orchestration](27-orchestration.md) · [the five moves](20-loops.md).*
