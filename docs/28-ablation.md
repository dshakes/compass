# Ablation — make every config rule defend itself

*Fundamentals, page 7. Agent config only ever grows, because nobody can prove a rule
isn't load-bearing. Ablation is how you find out: remove the rule, re-run the corpus,
read the delta. Standalone as an idea; `compass ablate` is one implementation. Prior
pages: [the gate](25-the-gate.md) · [verification](26-verification.md).*

<p align="center"><img src="../assets/ablation.svg" alt="The ablation experiment in four steps. Step 1, measure the baseline: guardrail precision 100 percent, recall 100 percent, across 61 corpus cases. Step 2, ablate one rule: the line 'aws-access-key-id|(AKIA…' is struck through and replaced by 'aws-access-key-id|zzABLATEDzz', neutralised in place so the file still parses. Step 3, re-run the corpus and record recall and the delta against baseline, then restore the file and take the next rule. Step 4, read the verdict: the score either moved or it didn't, and either way you now know something you could not assert before. Below, the three possible verdicts. Load-bearing, in green: removing it dropped a score, so it has earned its context window — keep it and record the delta as its receipt. Unmeasured, in amber: removing it changed nothing, which is NOT the same as useless — add a corpus case, then decide, and never auto-delete. Broken, in red: removing it improved a score, so the rule is costing you accuracy — investigate now. A closing note reads: absence of evidence is not evidence of absence; a tool that conflated unmeasured with useless would delete your best-written, least-tested guardrail first, so this one never deletes anything." width="860"></p>

## In one minute

Every rule in your agent config was added for a reason. Almost none of them are ever
removed, because removing one means proving it isn't doing anything — and nobody can
prove that. So config grows forever, and it grows in the context window, where you pay
for it on every single call.

Ablation borrows the standard trick from machine learning: to find out what a component
contributes, take it out and re-measure. Point it at config instead of model layers and
you get a number for each rule — kept, or costing you, or never actually tested.

The important part is the third answer. **A rule whose removal changes nothing is not
proven useless — it is untested.** Conflate those two and you will delete your best
guardrail, because the best-written rules are often the ones no corpus case exercises.

## Why config never shrinks

The asymmetry is brutal and entirely rational at the individual level:

| | Adding a rule | Removing a rule |
|---|---|---|
| **Cost if you're wrong** | A few tokens, invisible | An incident, with your name on it |
| **Evidence needed** | An anecdote — it failed once | Proof of a negative |
| **Who notices** | Nobody | Everybody, eventually |

So every incident adds a line, every model release adds a caveat, and nothing ever comes
out. The result isn't a policy; it's sediment. And unlike dead code — which at least sits
inert on disk — dead config is re-read, re-tokenized, and re-paid for on every call, and
it competes for the model's attention with the rules that matter.

> **The precedent worth knowing:** Anthropic removed more than 80% of Claude Code's
> system prompt for newer models with no measurable loss. Most teams could not attempt
> that, because they have no way to tell what the 80% was doing. The blocker is not
> courage — it's instrumentation.

## The experiment

A config rule is a falsifiable claim: *without me, this system gets worse.* That is
testable, and the test is cheap when your corpora are deterministic.

```text
  for each rule:
      neutralise it in place        (keep the file parseable)
      re-run the corpus that covers it
      delta = ablated_recall - baseline_recall
      restore
```

Four properties make this an experiment rather than a script:

- **A control.** The baseline is measured first, from the same corpus, in the same run.
- **One variable.** Exactly one rule changes; everything else is byte-identical.
- **Determinism.** No model calls, no network, no tokens — so the delta is the rule's
  effect and not sampling noise. Run it twice, get the same table.
- **Reversibility.** The live policy is restored on every exit path, including a kill.

## Three verdicts, and only one of them means "delete"

| Verdict | What happened | What it actually means | What to do |
|---|---|---|---|
| **load-bearing** | Removing it dropped a score | The rule earns its context. You now have the receipt | Keep it, and record the delta next to it |
| **unmeasured** | Removing it changed nothing | Either dead weight **or** a real defence your corpus never exercises | Write the corpus case first. *Then* decide |
| **broken** | Removing it **improved** a score | The rule is costing you accuracy right now | Investigate immediately — this is the rare urgent one |
| **inconclusive** | The ablated file didn't parse | A measurement failure, not a finding | Fix the tool, not the config |

That fourth row is not padding. The first version of this tool deleted whole lines, which
silently broke a shell `case` arm, scored 0%, and reported the rule as *catastrophically
load-bearing* — the exact inverse of the truth. **An instrument that can be confidently
backwards is worse than no instrument**, so a broken parse is now a refusal to answer
rather than an answer.

## In practice

```bash
compass ablate                              # sweep every detector, print the table
compass ablate --detector instruction-override   # interrogate one rule
compass ablate --json                       # machine-readable, for dashboards
compass ablate --gate                       # CI mode: fail on any 'broken' rule
```

Each detector is scored against the corpus that actually covers it — injection detectors
against [the red-team corpus](17-red-team.md), and secret, malware and insecure detectors
against `content-corpus.tsv` via `compass bench --content` (see
[the benchmark](18-benchmark.md)). Scoring a rule against a corpus that never exercises it
produces "unmeasured" for everything, which is true and useless.

Worked results from this repo, reproducible with the command above:

```text
  DETECTOR                   CORPUS       RECALL    DELTA   VERDICT
  data-exfiltration          redteam         82%    -18.0   load-bearing
  instruction-override       redteam         85%    -15.0   load-bearing
  keylogger                  content       95.7%     -4.3   load-bearing
```

Those rules now have receipts. Eighteen and fifteen points of injection recall depend on
the first two, measured, on a corpus you can read. Nobody has to take their presence on
faith again — and if a future refactor weakens one, the number moves and CI says so.

## What the first study actually found

The first honest sweep reported **25 of 38 rules unmeasured** — and the cause was not thin
corpora. Three whole detector families had *no eval harness at all*: `secret_content_findings`,
`malware_intent_findings`, and `insecure_code_findings` were never scored by anything, for
the life of the project. Only injection detection had a corpus. **No aggregate score could
have surfaced that**, because the aggregate only reports on what it already measures.

Following this page's own rule — write the case, *then* decide — closing that gap took
three steps, each of which found something:

| Step | What it exposed |
|---|---|
| Wrote [`content-corpus.tsv`](../scripts/content-corpus.tsv), 39 cases | compass's own secret hook **refused to commit it** — correctly. An `allowlist secret` marker would have silenced the refusal *and* neutralised the detector under test, making every case a false negative. Credential-shaped fragments are now stored as `@TOKENS@` and materialised in memory by the scorer only |
| Ran it | 3 genuine recall gaps: `keylogger` matched only the dotted `pynput.keyboard` form, not `from pynput import keyboard`; `credential-stealer` and `self-propagation` matched intent *words* but not the *mechanic* |
| Widened those 3 detectors | precision held at 100% — the corpus's 16 precision cases are what made that safe to do |

The scoreboard moved from **13 load-bearing / 25 unmeasured** to **34 / 4**. The four that
remain are redundancy rather than gaps: another detector already matches the same case, so
removing either alone leaves recall flat.

## Honest limits

Ablation measures a rule against *your corpus*, and nothing else. It cannot see the
attack you never wrote a case for, and a corpus is a floor rather than a proof — which is
why "unmeasured" recommends writing a case instead of reaching for the delete key. It
tests one rule at a time, so it will miss rules that only matter in combination, and it
will report both members of a redundant pair as unmeasured when either alone would hold
the line. Cross-family interactions are invisible to it for the same reason.

It also only reaches config that a deterministic corpus scores. Prose instructions in
`CLAUDE.md` are config in every sense that matters and are not covered here; extending
ablation to them needs an eval that grades behaviour, which costs tokens and gives up
the determinism that makes this trustworthy. That's honest scope, not a roadmap promise.

And the loop is not automatic on purpose. Nothing here deletes anything — it produces a
table and an argument. The deletion stays a human decision, for the same reason
[the merge does](loop-engineering.md).

## The takeaway

Config is the one part of an agent system that never gets refactored, because it's the
one part nobody can measure. Ablation makes each rule state its case in a number, and
turns "we've always had that rule" into either a receipt or a corpus gap. **Every line of
agent config pays rent in the context window — ablation is how you collect.**

---

*See also: [the layers](22-the-layers.md) · [the gate](25-the-gate.md) ·
[verification](26-verification.md) · [the benchmark](18-benchmark.md)*
