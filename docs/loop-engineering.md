# Loop engineering: iteration under a gate beats one confident guess

*The thesis behind compass. Also a standalone read — you don't need to use compass to take the idea.*

## The one-shot problem

Most AI coding tools are one-shot. You write a prompt, the model writes a guess, and the quality of the output is the quality of that single guess. When it's wrong — a subtle off-by-one, a missed edge case, a test that doesn't actually run — you notice later, fix it by hand, and quietly absorb the cost. The model never finds out it was wrong, because nothing checked.

We've gotten very good at making that single guess better: bigger models, better prompts, more context. But there's a ceiling to how good a *first try* can be on a non-trivial change, and we're bumping into it. The interesting gains aren't in the guess anymore. They're in what happens *after* the guess.

## The unit of work is the loop, not the prompt

Here's the reframe: **the unit of work is not "generate," it's "generate → check → critique → fix → repeat — until a gate says done."**

That's how good engineers actually work. You don't write a function and ship it. You write it, run the tests, read the failure, fix it, run again. The loop *is* the work; the first draft is just the loop's first iteration. Quality is an emergent property of iterating against something that can tell you you're wrong — not a property of the draft.

An agent that loops will beat a smarter agent that doesn't, on anything where correctness is checkable. The looping agent gets to be wrong on iteration 1 and right on iteration 3. The one-shot agent has to be right on iteration 1 or it's just wrong.

## The hard part is the gate, not the loop

A loop without a gate is just a confident agent talking to itself — it'll "fix" things that weren't broken and declare victory on output that doesn't work. The loop only produces quality if each pass is judged by something the model can't sweet-talk:

- **Tests that actually execute** (not "the assertions pass" — does the thing *do* what it's supposed to?).
- **A review pass from fresh context** — ideally a different model, so it isn't grading its own homework.
- **A hard resource ceiling** — so a loop that isn't converging stops *spending* before it stops being useful.
- **A human at the irreversible step** — merge, deploy, publish.

The gate is the whole game. It's what separates "iteration under a gate" from "an agent in a loop running up a bill." Most autonomous-agent demos fail here: they have the loop and no real gate, so they're impressive for ninety seconds and untrustworthy forever.

## Loops all the way up

Once the loop is your unit, the same shape composes at every scale. It's not four features — it's one idea applied four times:

| Scale | The loop | The gate |
|---|---|---|
| **A task** | generate → test → critique → fix → repeat | tests + review pass |
| **A pull request** | review · security · tests · cross-audit → auto-fix the Blocking findings → re-review | round-capped; hands off to a human if still red |
| **A fleet of repos** | the PR loop, scheduled across every repo overnight | a PR per repo, approved by a human |
| **A hard question** | parallel agents fan out, fact-check each other, converge | a synthesized answer a skeptic verified |

Every one of them ends the same way: it runs until a gate says "done," then **stops at a human.** That gate never moves. Autonomy isn't "the agent does everything" — it's "the agent does everything *up to* the irreversible step, and proves it with a check you can read."

## What this looks like in practice

compass is one implementation of this idea, built for Claude Code / Codex / Gemini and kept deliberately boring — shell hooks and config you can read, no service, local-first.

- **The task/PR loop**: open a PR and it reviews, security-checks, runs the tests, cross-audits with a second model, pushes its own fixes to the branch, and re-reviews — round-capped at three passes, then it stops and waits for you to merge.
- **The resource gate**: a live budget hook halts the session before the next tool call once spend crosses a cap you set — the loop can't run away while you're not looking.
- **The safety gate**: catastrophic commands and secret writes are blocked before they run, and that policy is scored against a labeled corpus in CI, so the gate is measured, not asserted.
- **The human gate**: agents prepare; you push, merge, and deploy. There is no "merge to prod" button.

None of these are exotic. The point isn't any single piece — it's that they're *gates around a loop*, which is what makes the loop safe enough to let run.

## Honest limits

Looping is not free and not magic. More iterations cost more tokens and more wall-clock, which is exactly why a hard budget gate is load-bearing rather than a nice-to-have. The checks are only as good as you make them — pattern-based guardrails catch accidents, not a determined adversary, and a test suite that doesn't cover the behavior gives the loop nothing real to converge against. And the human gate is permanent on purpose: the loop's job is to arrive at the merge button with evidence, not to press it.

## The takeaway

If you're building with coding agents, stop optimizing the guess and start building the loop — and then spend your real effort on the gate, because that's where trust comes from. Iteration under a gate beats one confident guess. The gate is what makes the iteration worth trusting.

---

*compass is the version of this I actually use: <https://github.com/dshakes/compass>. The loop running on a live PR, every event inspectable: <https://github.com/dshakes/compass-loop-demo/pull/1>.*
