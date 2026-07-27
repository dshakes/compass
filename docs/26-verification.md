# Verification — the ladder of what counts as proof

*Fundamentals, page 5. [The gate](25-the-gate.md) argues that a loop is only as trustworthy
as the check it can't talk its way past. This page ranks the checks: a ladder from "the
model said so" to "a human watched it run," so you can name where a given piece of evidence
actually sits before you call something verified. Closes out [the layers](22-the-layers.md)
this series maps; it builds on the same discipline as [the thesis](loop-engineering.md) and
[the five moves](20-loops.md).*

## In one minute

"It works" is not one claim, it's several different claims wearing the same sentence. The
model saying it works, a green checkmark, a test that ran, a second reviewer confirming it,
and a human watching it run in production are five different amounts of evidence — and
they get quoted interchangeably, which is how a green checkmark ends up carrying the weight
of a human watching it run. The fix is naming which rung you're actually standing on before
you call something verified, and refusing to round up.

## The ladder

This ladder is compass's own synthesis, not a cited finding — grade it **E3, argued**, and
apply the same skepticism to it that [the layers](22-the-layers.md) asks you to apply to
any unmeasured claim.

| Level | What it takes to reach | What it still fails to catch |
|---|---|---|
| **L1 — Told** | the model (or a person) says the change works | wishful thinking, hallucinated success, the author's own chain of self-persuasion |
| **L2 — Asserted** | assertions or tests pass | a test that never exercises the changed path; behavior mocked away instead of run |
| **L3 — Executed** | the test actually runs the real behavior, and the output is read, not skimmed | a test that's stale against the *new* requirement; only the happy path is covered |
| **L4 — Reviewed** | an independent, fresh-context reviewer — ideally a different model — confirms it | a reviewer that reads the diff instead of running it; shared blind spots between close-kin models |
| **L5 — Observed** | the artifact runs in a real environment and a human watches the outcome | rare or slow-to-surface failures; anything outside the scenario a human thought to watch |

Each rung subsumes the ones below it in confidence but not in cost — L5 is the strongest
evidence and the most expensive to get, which is exactly why most verification quietly
settles for L2 and calls it done. The discipline is refusing to let L1 or L2 stand in for
L4 or L5 just because they're cheaper to produce.

## A five-level spec on paper — read honestly

A July 2026 preprint (Sandeco Macedo, arXiv:2607.00038,
<https://arxiv.org/abs/2607.00038>) proposes formalizing a "loop" as a five-field spec —
trigger, goal, verification, stopping rule, memory — and independently proposes its own
five-level verification ladder, tested against a corpus of 50 loops, reporting that 70%
verify autonomously and 74% name a terminal state.

> **Honesty check, read before you quote this.** Only the abstract was verified for this
> page — the full paper was not read. Treat the 70%/74% figures, the exact ladder levels,
> and the 50-loop corpus's composition as **E2, unverified-in-full** — a named, dated,
> linked source, not something reproduced here.

The structural parallel to [the five moves](20-loops.md) is a genuinely interesting echo —
trigger ~ discovery, goal ~ the stop condition, verification ~ the evaluator, stopping rule
~ the round cap, memory ~ persistence — two independent efforts converging on a similar
shape. But that comparison is this page's own observation, not the paper's claim, so grade
the comparison **E3** too. Read the source before you build config on the numbers.

## Verification debt: the cost with no alarm

[The five moves](20-loops.md#compass-digest) names four silent costs a self-running loop
runs up, and the first is the one this page is about: **verification debt** — unverified
output piling up in the gap between "it ran" and "it's right." No alarm sounds while it
accumulates, because nothing failed loudly; a loop that stops at L1 or L2 looks exactly
like one that reached L4 until something breaks downstream.

It compounds because it feeds the other three costs: unverified output erodes your mental
model of the codebase (comprehension rot), which makes you more likely to wave the next
change through without reading it (cognitive surrender), which removes the one check that
would have caught a loop spinning on a task it can't actually finish (token blowout). The
practical gauge compass ships for the human side of this is `compass digest` — it tracks a
ledger of merged, agent-authored changes you haven't yet explained back to yourself, and
the size of that unreviewed pile is a direct read on how much verification debt is sitting
unpaid.

## The delegation rule: a claim is not proof

Never report a check as clean or passing unless you ran it and watched it pass — no
"should work" standing in for "I saw it work." That rule doesn't relax for delegated work;
it tightens. A subagent, or a Builder in the SDLC pipeline, reporting success is a **claim**
about its own output, made by the same generator whose self-persuasion [the gate](25-the-gate.md)
exists to route around. It is not proof, for the same structural reason a model can't
credibly review its own diff.

compass enforces this as a role, not a courtesy: the [Reviewer role](../sdlc/roles/reviewer.md)
is told explicitly to assume the change is broken until proven otherwise, and to *run* the
tests and paste the real output rather than read the Builder's summary of them. When a
loop needs a stop condition stronger than a round cap, the [goal-judge
role](../sdlc/roles/goal-judge.md) decides `MET`/`UNMET` by executing the check itself, not
by reading the diff — a fresh, usually cheaper model, deciding on evidence the worker
didn't hand it pre-chewed. The delegator re-runs the gate; it does not inherit the
delegate's verdict.

## In practice

Move a claim up the ladder with the primitives compass actually ships:

```bash
# L2 -> L3: these don't just assert, they execute the policy function against a
# labeled, versioned corpus and score precision/recall for real.
compass bench --guardrail
compass redteam --eval
```

```bash
# L4: a fresh, cheaper model decides the stop condition by running the check,
# not by reading the diff.
SDLC_CONVERGE=1 SDLC_GOAL="all tests in test/auth pass and the lint step is clean" \
  ~/compass/sdlc/orchestrate.sh "harden the auth flow"
```

[09-sdlc.md](09-sdlc.md) reaches the strongest form of L4 by construction: Claude builds,
and Codex and Gemini audit the same PR as independent, cross-tool second opinions — a
different vendor, not just a different context.

The closest thing compass ships to L5 is `sdlc/taskbench/`: five seeded-bug tasks, each
with its own `check.sh` oracle that is independent of the model that fixes the bug.
`sdlc/taskbench/validate.sh` runs in CI and proves the oracle actually fails before the fix
(so the benchmark isn't measuring a bug that was never real) — that part is deterministic
and token-free. Running the fix itself (`bash sdlc/taskbench/run.sh`) spends real tokens and
produces a live pass/fail a human can read in `results.tsv`; see [the task-success
section of 18-benchmark.md](18-benchmark.md) for what that number does and doesn't claim.
The permanent human-merge gate is what turns any of the above into an actual L5 — a human
watching the real outcome before it ships.

## Honest limits

This ladder is a naming tool, not a measured instrument — E3, built for this page, not
validated against a corpus of its own. The Macedo preprint's numbers are cited, not
reproduced; treat them as a pointer to go read, not a fact to repeat. Reaching L4 in
compass today usually means a fresh context and often a cheaper model, not reliably a
different vendor, except where the SDLC pipeline's cross-tool audit specifically applies —
see the same caveat in [25-the-gate.md](25-the-gate.md#honest-limits). And L3-level corpus
scores (100% precision/recall on a labeled set) prove the *policy* is correct on cases
someone thought to write down; [18-benchmark.md](18-benchmark.md) is explicit that this is
not a real-world catch rate. No rung on this ladder replaces a human reading the diff for
the thing no test was written to catch.

## The takeaway

Every level of this ladder is real evidence — L1 included, a model saying it works is not
nothing — but each is only worth what its rung is worth, and the whole discipline of
verification is refusing to spend an L1 claim as if it were an L4. Know which rung you're
standing on before you call something done.

---

*See also: [the gate](25-the-gate.md) · [the thesis](loop-engineering.md) · [the five
moves](20-loops.md) · [the layers](22-the-layers.md) · [the SDLC loop](09-sdlc.md) ·
[benchmark](18-benchmark.md).*
