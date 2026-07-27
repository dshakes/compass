# The gate — why a loop without one is just an agent talking to itself

*Fundamentals, page 4. The thesis ([loop-engineering.md](loop-engineering.md)) states the
claim in one line: **iteration under a gate beats one confident guess.** This page stays
on the second half of that sentence — what a gate has to be, structurally, to earn the
word — and extends [the five moves](20-loops.md)'s generator/evaluator split with the
sources behind it and a checklist for telling a real gate from a fake one. Part of [the
layers](22-the-layers.md) this series maps, one rung above [harness](24-harness.md); for
what a gate certifies, see [the verification ladder](26-verification.md) next.*

## In one minute

A loop is just "try, then try again." That's not automatically good — an agent that
retries without anyone checking its work will happily "fix" things that weren't broken and
declare victory on output that still doesn't run. The **gate** is the part that can say no:
a test that actually executes, a reviewer who wasn't in the room when the code was written,
a spending cap, a human at the button that can't be undone. Take any one of those away and
the loop stops being trustworthy, no matter how many times it iterates. The gate isn't a
nice addition to the loop — it *is* the loop's claim to being more than a confident guess
repeated on a timer.

## Generator, meet evaluator — and why a prompt can't fix this

Ask the agent that wrote the code whether the code is good, and it praises itself. That
isn't a smarts problem you can prompt away — "review your own work critically" doesn't
work any better the fifth time you ask it than the first. The context that wrote the code
is full of the reasons it was written that way; the model that generated the fix is reading
its own chain of self-persuasion, not the result. It cannot see around a corner it built.

So the fix has to be **structural**: a second evaluator, on a fresh context, ideally a
different model, that looks at the change from scratch with no memory of why it was
written that way. Fresh context is the necessary part — it's what breaks the loop of
self-persuasion. A different model is the stronger version of the same fix, because two
models trained differently are less likely to share the same blind spot.

## Three names for the same discipline, dated

This isn't a compass invention. The same structural insight has been named at least three
times by three different people, closing in on the same idea from different angles:

| Voice | Claim | Grade |
|---|---|---|
| **Anthropic** | the evaluator-optimizer pattern — one model drafts, a second critiques in a loop, with explicit stopping conditions and "ground truth from the environment" ("Building Effective Agents," 19 Dec 2024, <https://www.anthropic.com/research/building-effective-agents>) | E2 |
| **Willison** | "an agent runs tools in a loop to achieve a goal... the art of using them well is to carefully design the tools and loop" (30 Sep 2025, <https://simonwillison.net/2025/Sep/30/designing-agentic-loops/>) | E2 |
| **Huntley** | verification is "backpressure" — the hard problem once generation is cheap (14 Jul 2025, <https://ghuntley.com/ralph/>) | E2 |
| **compass** | the guardrail scores itself against a labeled corpus in CI, so the gate is measured, not asserted (`compass bench --guardrail`) | E1 |

Huntley's word is worth keeping: **backpressure**. Once an agent can generate a plausible
fix in seconds, generation stops being the scarce resource — verification is. A system
with no backpressure just produces more plausible-looking output faster; it doesn't
produce more *correct* output. That's the honest name for what a gate is actually for.

## Real gate vs. fake gate

The word "gate" gets used loosely. Here's the checklist that separates the two:

| Check | Fake version | Real version |
|---|---|---|
| **Tests** | "the assertions pass" — without confirming the changed code path ran at all | the test executes the real behavior and the output is read, not skimmed |
| **Review** | the same model, or the same context, grades its own diff | a fresh-context evaluator — ideally a different model — that defaults to doubt |
| **Stop condition** | a round cap with no convergence check; silence is read as success | a condition checked by something other than the worker producing the change |
| **Irreversible step** | the agent merges, deploys, or pushes because "the loop said done" | a human is the one who presses merge, deploy, or publish |

A loop that fails every row on the right is still a loop. It's just not one worth trusting
with anything you can't easily undo.

## The compass twist: a gate that grades itself

The trap that swallows most "we have guardrails" claims: the gate is *asserted* — a README
says "blocks catastrophic commands" — with nothing behind the sentence. compass's answer is
to treat the gate itself as a thing that needs verifying, not just installing. The
catastrophic-command guardrail and the red-team detectors are each scored, in CI, against a
labeled corpus that ships in the repo (`scripts/guardrail-corpus.tsv`,
`scripts/redteam-corpus.tsv`) — precision and recall floors that fail the build if the
policy regresses. See [the red-team layer](17-red-team.md) and [the benchmark
methodology](18-benchmark.md) for the numbers and how to reproduce them yourself.

> **A gate that is asserted is not a gate.** A README sentence claiming a guardrail exists
> is an E4 claim about itself. A gate that publishes the labeled corpus it's scored against,
> and fails CI when the score drops, is one you can check instead of trust.

## In practice

Reproduce the compass-shipped gates yourself — no tokens, deterministic, offline:

```bash
compass bench --guardrail   # scores danger_reason against scripts/guardrail-corpus.tsv
compass redteam --eval      # scores injection_findings against scripts/redteam-corpus.tsv
compass redteam --attack    # re-scores after obfuscating the corpus — a robustness check
```

The fresh-context evaluator in the SDLC pipeline: the [Reviewer role](../sdlc/roles/reviewer.md)
is told to assume the change is broken and to run the tests, not read the diff — a
different agent from the Builder, on a fresh context. Where a stop condition needs to be
more than a round cap, a **second, cheaper model** judges it by executing the check:

```bash
SDLC_CONVERGE=1 SDLC_GOAL="all tests in test/auth pass and the lint step is clean" \
  ~/compass/sdlc/orchestrate.sh "harden the auth flow"
```

The [goal-judge role](../sdlc/roles/goal-judge.md) runs the tests itself and returns
`SDLC-GOAL: MET` or `UNMET` — anything else counts as unmet, so a judge that can't run the
check is not a pass. And [09-sdlc.md](09-sdlc.md) wires the strongest version of the
different-model checklist row: Claude builds, and Codex and Gemini audit the same PR as
independent, cross-tool second opinions. The hard resource ceiling that stops a
non-converging loop from spending forever lives in the budget hook — see
[cost & models](02-cost-and-models.md) for `COMPASS_MAX_USD` / `COMPASS_MAX_USD_DAY`.

## Honest limits

A gate raises the floor; it doesn't guarantee the ceiling. The corpora above measure
*policy* correctness — did the detector fire on this labeled case — not task success, and
[18-benchmark.md](18-benchmark.md) says so plainly: 100% recall on 99 cases is not a
real-world catch rate, only a floor. The default fresh-context evaluator (Reviewer,
goal-judge) is usually a different *context*, not always a different *vendor* — the
stronger, cross-model version (Codex/Gemini auditing a Claude-built PR) exists in the SDLC
pipeline but isn't the default for every loop. A round cap is a backstop, not proof of
convergence: hitting `SDLC_MAX_FIX_ROUNDS` and stopping is not the same as the goal being
met, it's the loop admitting it couldn't prove the goal and handing off. None of this
replaces the human at the merge button; it just makes the case they're handed better.

## The takeaway

A loop tells you it ran again. Only a gate tells you it's right — and the gate only works
if it's something the generator can't talk its way past: fresh context, a different model
where you can afford one, a check that executes instead of a check that's read, and a human
at the step you can't take back. Build the gate before you trust the loop to run without
you watching. The loop is where the work happens; the gate is where the trust comes from.

---

*See also: [the thesis](loop-engineering.md) · [the five moves](20-loops.md) · [the
layers](22-the-layers.md) · [the verification ladder](26-verification.md) · [the SDLC
loop](09-sdlc.md) · [red-team](17-red-team.md) · [benchmark](18-benchmark.md) · [cost &
models](02-cost-and-models.md).*
