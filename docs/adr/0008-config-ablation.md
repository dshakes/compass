# ADR 0008 — Config ablation: every policy rule must defend itself with a number

- **Status:** **Accepted** (shipped — `compass ablate`, CI-gated on `broken`)
- **Date:** 2026-07-27
- **Deciders:** Shekhar Mudarapu
- **Refines:** the eval-gated-guardrail principle (ADR-0005, docs/17, docs/18) — extends
  it from "the policy as a whole is scored" to "every individual rule is scored"

## Context

compass scores its guardrail against labeled corpora in CI, which is more than most
agent configs can say. But that score is an aggregate. It answers *is the policy good?*
and never *is this rule doing anything?* — so the policy could only ever grow.

The asymmetry driving that is entirely rational for any individual engineer. Adding a
rule costs a few tokens and is invisible if wrong; removing one requires proving a
negative and is career-visible if wrong. So every incident adds a line and nothing is
ever taken out. The result is not a policy, it's sediment — and unlike dead code, dead
config is re-read and re-tokenized on every single call, competing for the model's
attention with the rules that matter.

Anthropic removed more than 80% of Claude Code's system prompt for newer models with no
measurable loss. Most projects cannot attempt that, because they have no way to tell
what the 80% was doing. The blocker is instrumentation, not courage.

## Decision

**Treat every policy rule as a falsifiable hypothesis — *without me, this system gets
worse* — and test it by ablation.** Neutralize one rule, re-run the corpus that covers
it, record the delta, restore. This is the standard ablation study from ML, pointed at
config instead of model components.

Four verdicts, and only one of them means "delete":

| Verdict | Meaning | Action |
|---|---|---|
| **load-bearing** | removing it dropped a score | keep, and record the delta as its receipt |
| **unmeasured** | removing it changed nothing | write a corpus case, *then* decide |
| **broken** | removing it **improved** a score | investigate immediately |
| **inconclusive** | the ablated file didn't parse | fix the tool, not the config |

Three properties are load-bearing in the design:

1. **It never deletes anything.** The output is a table and an argument; the deletion
   stays a human decision, for the same reason the merge does.
2. **`unmeasured` is not `useless`.** Absence of evidence is not evidence of absence. A
   tool that conflated the two would delete the best-written, least-tested guardrail
   first — the one whose corpus case nobody got around to writing.
3. **A broken parse is a refusal to answer.** The first implementation deleted whole
   lines, which silently broke a shell `case` arm, scored 0%, and reported the rule as
   catastrophically load-bearing — the exact inverse of the truth. An instrument that
   can be confidently backwards is worse than no instrument.

## Consequences

**What it found on the first honest run.** Ablating all 38 rules reported 25 as
unmeasured — and the cause was not thin corpora but *three detector families with no
eval harness at all*: `secret_content_findings`, `malware_intent_findings`, and
`insecure_code_findings` were never scored by anything. Only `injection_findings` had a
corpus. This had been true for the life of the project and no aggregate score could
have surfaced it.

Following the methodology's own rule — write the case, then decide — that gap is now
closed by `scripts/content-corpus.tsv` (39 cases) and `compass bench --content`. Writing
it exposed two further real defects, both now fixed and measured:

- Three detectors had genuine recall gaps (`keylogger` matched only the dotted
  `pynput.keyboard` form and not `from pynput import keyboard`; `credential-stealer` and
  `self-propagation` matched intent words but not the mechanic). Widened, with the
  corpus's 16 precision cases as the guard — precision stayed 100%.
- compass's own secret hook **refused to let the corpus be committed**, correctly. An
  `allowlist secret` marker would have silenced the refusal *and* neutralized the
  detector under test, making every case a false negative. The corpus therefore stores
  credential-shaped fragments as `@TOKENS@`, materialized in memory by the scorer only.

**Cost.** A full sweep is ~38 corpus runs, ~90s, no tokens and no network. CI gates on
`broken` only; `unmeasured` has a ratchet floor (`COMPASS_ABLATE_UNMEASURED_FLOOR`) to
be lowered as coverage grows, because a new detector legitimately lands before its
corpus case does.

**Scope, honestly.** Ablation measures a rule against *your corpus and nothing else*. It
cannot see the attack nobody wrote a case for; it tests one rule at a time, so it misses
rules that only matter in combination and reports both halves of a redundant pair as
unmeasured. It reaches only config a deterministic corpus scores — prose instructions in
`CLAUDE.md` are config in every sense that matters and are **not** covered. Extending to
them needs a behavioural eval, which costs tokens and gives up the determinism that
makes this trustworthy.

## Alternatives considered

- **Aggregate scores only (status quo).** Cheap, and what everyone else does. Rejected:
  it cannot answer the per-rule question, which is the one that lets config shrink.
- **Auto-delete unmeasured rules.** Rejected outright — it inverts the security posture
  by removing exactly the rules with the thinnest test coverage.
- **LLM-judged config review.** Rejected for the gate: non-deterministic, costs tokens,
  and grades an argument rather than a corpus. Usable as a suggestion source, never as
  the measurement.

## References

- `scripts/compass-ablate.sh` · `scripts/content-corpus.tsv` · `compass bench --content`
- [docs/28-ablation.md](../28-ablation.md) — the concept, and the worked results
- [docs/22-the-layers.md](../22-the-layers.md) — the E1–E4 evidence rubric this enforces
- [docs/18-benchmark.md](../18-benchmark.md) · [docs/17-red-team.md](../17-red-team.md)
