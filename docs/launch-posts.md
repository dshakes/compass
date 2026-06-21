# Launch posts (paste-ready)

All the copy for launching compass, in one place. Post as a **human** (these
communities flag automated/agent posting). Timing: **Tue–Thu, 8–10am ET**.
Sequence: Show HN first → X thread (gif on tweet 1) → r/ClaudeAI → then reply to
every comment for the next 2 hours (early engagement is the whole game).

Hero asset for every channel: `assets/budget-real.gif` (real session hitting the cap).

---

## 1. Show HN

**Where:** news.ycombinator.com → log in → submit. Put the **URL** in the URL field
and leave the text field empty; then add the body below as your **first comment**
(HN convention for URL submissions).

**Title**
```
Show HN: Compass – guardrails and a hard budget cap for AI coding agents
```

**URL**
```
https://github.com/dshakes/compass
```

**First comment (body) — use this one.** Understated/technical register; HN flags
new-account posts that read like marketing. Limitations stated before claims; the
corpus is framed as "help me find what I missed," not a 100% boast.
```
I kept hitting two annoyances running Claude Code and Codex: there's no hard stop
on spend (an agent stuck in a loop can run up a real bill before you look), and no
easy way to tell whether a "safe command" policy actually holds. So I wrote compass
— a set of hooks plus a small config layer that runs locally.

The budget piece is a PreToolUse hook. It reads the session's running cost from the
data Claude Code hands the status line, and denies the next tool call once you're
over COMPASS_MAX_USD. It's deliberately dumb: accurate only to the last status-line
render, and it fails open if it can't read the cost — I'd rather it occasionally
let a call through than wedge a session on missing data.

The guardrail piece blocks the usual footguns before they run (rm -rf of $HOME,
force-push to a protected branch, writing a file that looks like a live secret).
The part I cared about is that the policy is a pure function with a labeled corpus,
so `compass bench` reports precision/recall instead of me asserting it's safe —
which also means any bypass I haven't thought of is just a missing test case. That's
mostly why I'm posting.

It's shell scripts you can read, makes no network calls of its own, MIT, alpha. To
be clear, pattern-matching guardrails aren't a security boundary — they catch
accidents, not a determined process.

Two things I'd genuinely like input on: command bypasses my corpus misses, and
whether a per-session cap is the right unit or it should be per-task.

https://github.com/dshakes/compass
```

<details>
<summary>Old promo version (v1) — flagged on the first attempt; kept for reference, don't reuse</summary>

```
I use Claude Code and Codex daily and got tired of two things: hoping the agent
wouldn't run something destructive, and watching an autonomous loop quietly burn
money with no hard stop. So I built compass — a local-first config layer (hooks +
subagents + a cost router) for AI coding agents, with two things I couldn't find
elsewhere:

1. A live budget hard-gate. Set COMPASS_MAX_USD=5 and the session is *blocked*
before the next tool call once spend hits the cap — not a usage report after the
fact. An agent can't run up a bill overnight while you're away.

2. Guardrails with a score. Catastrophic commands and secret writes are blocked
before they run, and the blocking policy is graded against a published corpus in
CI (`compass bench` -> 100% precision/recall on 61 cases), so you can reproduce
the claim instead of trusting it. A red-team layer scans prompts/fetched content/
config for injection, also corpus-scored.

It's all local — no service, no telemetry, no curl | sh. Hooks are short shell
scripts you can read. Releases are SLSA-signed (`compass verify v0.19.2`). One
config works across Claude Code, Codex, and Gemini. MIT.

Honest limits: it's alpha; pattern-based guardrails are best-effort defense-in-
depth, not a hard security boundary; the budget gate is accurate to the last
status-line render and fails open if it can't read spend.

Repo: https://github.com/dshakes/compass

Feedback very welcome — especially: what command bypasses is my guardrail corpus
missing, and does the budget gate fit how you actually run agents?
```
</details>

> **Note (lesson from attempt #1):** a brand-new HN account posting a Show HN +
> promo-styled comment gets flagged fast. Before relaunching: build some account
> history (thoughtful comments on other posts over a couple weeks), then repost
> with the understated v2 comment above. Reposting a genuine project that got no
> traction is allowed on HN.

---

## 2. X / Twitter thread

Attach `assets/budget-real.gif` to tweet **1/**. After posting, edit the last
tweet to include your Show HN link.

**1/**
```
Your AI coding agent will happily loop overnight and run up a bill.
Cost dashboards tell you *after*.

compass stops it *live* — set a dollar cap and the agent halts before the
next action.

  export COMPASS_MAX_USD=5

🧭 github.com/dshakes/compass
[attach assets/budget-real.gif]
```

**2/**
```
It's not just budget. compass is a local-first guardrail layer for
Claude Code / Codex / Gemini:

• catastrophic commands + secret writes blocked *before* they run
• the blocking policy is graded in CI — 100% precision/recall on a
  published 61-case corpus you can run yourself
```

**3/**
```
Everything is local. No service, no telemetry, no `curl | sh`.
The hooks are short shell scripts you can read.
Releases are SLSA-signed, so you can verify what you installed:

  compass verify v0.19.2
```

**4/**
```
One config, every agent. MIT licensed. Install + the eval numbers:
github.com/dshakes/compass

Question for you: what should a coding agent *never* be allowed to do? 👇

(Show HN if you'd rather discuss there: <paste HN link>)
```

---

## 3. r/ClaudeAI

**Where:** r/ClaudeAI → Create Post → paste title + body → attach
`assets/budget-real.gif` → post. Reply to every comment; concede + fix on
critique. Don't cross-post the identical text to many subreddits same-day.

**Title**
```
I built a local guardrail layer for Claude Code that hard-stops the agent at a dollar budget (and blocks destructive commands) — feedback welcome
```

**Body**
```
I've been using Claude Code heavily and two things kept bugging me:

1. An autonomous loop can quietly burn money — the cost trackers I found only
   *report* spend after the fact, none of them *stop* the agent.
2. I was relying on hope that it wouldn't run something destructive.

So I built **compass** — a local-first config layer (hooks + subagents + a cost
router) you install once. Two parts I think are genuinely new:

**A live budget hard-gate.** `export COMPASS_MAX_USD=5` and the session is blocked
before the next tool call the moment spend hits the cap. Not a warning — a stop.
[attach the clip]

**Guardrails you can actually verify.** Destructive commands and secret writes are
blocked before they run, and the blocking policy is graded against a published
corpus in CI (`compass bench` → 100% precision/recall on 61 cases). So you don't
have to take "it's safe" on faith — you can reproduce the number. There's also a
red-team layer (prompt-injection / config-poisoning), same corpus-scored approach.

It's fully local: no service, no telemetry, no `curl | sh`. The hooks are short
shell scripts you can read before trusting. Works across Claude Code, Codex, and
Gemini from one config. MIT, free.

Repo: https://github.com/dshakes/compass

It's alpha and I'd really value feedback from people who run agents hard:
- What destructive command would you want blocked that I might be missing?
- Does the budget gate match how you actually work, or would you want it per-task
  instead of per-session?

Honest about limits in the README — pattern-based guardrails are defense-in-depth,
not a hard security boundary, and the budget gate is accurate to the last status-
line render. Not overselling it.
```

---

## Launch-day checklist

- [ ] Repo page renders cleanly; hero gif loads; install line + badges resolve.
- [ ] Tue–Thu, 8–10am ET.
- [ ] Show HN posted (URL + first-comment body).
- [ ] X thread posted (gif on 1/, HN link in last tweet).
- [ ] r/ClaudeAI posted (gif attached).
- [ ] Reply to every comment for the first 2 hours.
- [ ] Do NOT ask for HN upvotes. Do NOT mass-cross-post. Concede + fix on critique.
