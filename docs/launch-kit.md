# Launch kit (internal) — submit & announce compass

Everything to list compass on the awesome-Claude ecosystem and announce it, written to be
**true** (a reviewer can run every claim) and **differentiated** (lead where the giants
don't compete). **You** submit/post as a human — automated/self-promo posting is exactly
what these communities flag, and awesome-claude-code *bans* non-human submissions.

---

## 0. Pre-flight — hard eligibility gates (check ALL before submitting)

awesome-claude-code rejects (and cooldown-bans) on these. Verify each at submission time:

| Gate | Requirement | Status |
|---|---|---|
| **Repo public age** | ≥ 7 days since first commit | ✅ first commit 2026-05-24 → met on/after 2026-05-31 |
| **Stars** | **≥ 5 stars** | ✅ met (8★ as of 2026-06-09) — re-confirm at submit time |
| **Account age** | GitHub account ≥ 14 days | ✅ (existing account) |
| **No other open issues** by you in their repo | 0 | ✅ confirm at submit time |
| **Human, web UI** | issue **form** in a browser — **not** `gh`, **not** an agent, **not** a PR | ⚠️ you do this by hand |
| **Not crypto-related** | n/a | ✅ |

> The ≥ 5 stars gate is the one thing that will silently fail the submission. Do it first.

---

## 1. Primary listing — awesome-claude-code (the canonical list)

**Submission model (2026):** you do **not** open a PR and do **not** edit files. You open a
GitHub **issue form** in the browser; a bot validates it; the maintainer's bot turns an
approved issue into the PR. Read `docs/CONTRIBUTING.md` + `docs/CODE_OF_CONDUCT.md` first
(the form makes you attest you did).

**Framing (decided 2026-06-10): submit ONE focused capability, not the toolkit.** The
maintainer's guidance is explicit — "select one, or a small subset" even from a marketplace
of plugins, and the form warns against "complex systems that require long onboarding" and
general-purpose marketplaces. So the submission is **the eval-gated guardrail + red-team
hooks**; the router, SDLC loop, and cross-vendor layer get one "also in the box" line, no
more. *(Submit after the open-benchmark doc `docs/18-benchmark.md` is on main — it's cited
in the claims.)*

**Pre-flight rubric:** run their own reviewer prompt on compass before submitting —
`.claude/commands/evaluate-repository.md` in their repo (scores Code Quality, Security,
Docs/Transparency, Functionality, Hygiene). compass should score well; fix anything it flags.

### Open the form (in a browser, logged in, on/after the star gate is met)
`https://github.com/hesreallyhim/awesome-claude-code/issues/new?template=recommend-resource.yml`

### Field values (verbatim)

| Field | Value |
|---|---|
| Display Name | `compass` |
| Category | **`Hooks`** — the focused capability is the guardrail/red-team hook layer *(if the form routes plugins to `Agent Skills` / `Tooling`, accept it; the maintainer recategorizes — don't fight the dropdown)* |
| Primary Link | `https://github.com/dshakes/compass` |
| Author Name | `Shekhar Mudarapu` |
| Author Link | `https://github.com/dshakes` |
| License | `MIT` |

### Description (1–3 sentences, no emojis, descriptive not promotional, third-person)
> compass provides eval-gated guardrail hooks for Claude Code: catastrophic commands and
> secret writes are blocked before they run, and the blocking policy is scored in CI —
> `compass bench` reports 100% precision and recall on a published 61-case corpus that any
> other tool can run. A companion red-team layer scans prompts, fetched content, and project
> config for injection and context poisoning (100% precision/recall on a labeled corpus,
> robust to base64/zero-width/homoglyph obfuscation). The hooks are short commented shell
> scripts installed locally — no service, no telemetry — and ship inside a broader auditable
> config layer (measured cost router, SLSA-signed releases, Codex/Gemini parity).

### Validate Claims / Specific Task(s) / Specific Prompt(s) — *mandatory for plugins*
A reviewer can confirm these in ~2 minutes (guardrail claim first — it IS the submission):

> 1. `git clone https://github.com/dshakes/compass ~/compass && cd ~/compass && make install && make doctor` → expect `0 error`.
> 2. In Claude Code, ask it to run `rm -rf $HOME` or write a `.env` → **blocked before it runs**; ask for `rm -rf ./build` → allowed (`compass audit-log` shows the block and why).
> 3. `compass bench` → guardrail **100% precision / 100% recall on the 61-case corpus** — reproducible, CI-gated; the corpus format is documented in `docs/18-benchmark.md` so the same eval can be run against any other guardrail.
> 4. `compass redteam` → injection corpus **100% precision/recall**; `compass redteam --attack` → **100% robustness** after base64/zero-width/homoglyph/leetspeak obfuscation.
> 5. *(Optional)* `compass verify <latest tag>` → keyless SLSA provenance for the release you installed.

### Additional Comments (uniqueness + security — the maintainer's two filters)
> **What this submission is (and isn't).** This recommends the **guardrail + red-team hook
> layer** specifically: ~13 short, commented shell hooks in `claude/hooks/` whose blocking
> policy and injection detectors are scored against published, labeled corpora in CI
> (`compass bench`, `compass redteam` — precision/recall with hard floors, not assertions).
> The corpus and scoring are documented in `docs/18-benchmark.md` so any other guardrail
> tool can run the same eval — to my knowledge no entry in the Hooks category publishes
> precision/recall for its blocking policy. The same repo also contains a measured cost-tier
> router, SLSA-signed releases, and an optional human-gated PR loop; those are in the box
> but are *not* this submission.
> *Stated honestly in the docs:* pattern detection is best-effort defense-in-depth (corpus
> recall ≠ real-world recall); the optional managed-guardrail adapters (webhook · Bedrock ·
> Azure) are response-parsing-tested but not verified against live endpoints in CI
> ([docs/17](docs/17-red-team.md), [ADR-0005](docs/adr/0005-red-team-hardening.md)).
> **Security (your #1 filter):** no telemetry; **no `--dangerously-skip-permissions`** anywhere;
> no auto-update (you `git pull`); install is reversible (`make uninstall`). **Network beyond
> Anthropic only via opt-in MCP:** `context7` → Upstash (library docs), `fetch` → URLs you
> request; everything else is local. The hooks themselves make no network calls except the
> optional, off-by-default managed-guardrail escalation. Hooks are short, commented shell
> scripts in `claude/hooks/`, disabled by editing `claude/settings.json`. Egress table in
> `SECURITY.md`. MIT.

### After acceptance — add the badge to README
```markdown
[![Mentioned in Awesome Claude Code](https://awesome.re/mentioned-badge.svg)](https://github.com/hesreallyhim/awesome-claude-code)
```

---

## 2. Secondary listings (lower bar, parallel reach)

| Channel | How | Notes |
|---|---|---|
| **Gemini CLI extension** | `gemini extensions install https://github.com/dshakes/compass` (`gemini-extension.json` → `GEMINI.md` + context7/fetch/git MCP). | Cross-vendor reach; same one-source manual. |
| **Codex plugin marketplace** | `codex plugin marketplace add dshakes/compass` → `/plugin install` (`.codex-plugin/plugin.json` + `.agents/plugins/marketplace.json`). | Native Codex plugin, mirrors the Claude marketplace. |
| **claudemarketplaces.com** | Auto-crawls GitHub for a valid `.claude-plugin/marketplace.json` — **already valid** (name, owner, plugins[], pinned versions). Nothing to submit; optionally email `hi@claudemarketplaces.com`. | Discovery-based. |
| **Chat2AnyLLM/awesome-claude-plugins** | PR-based awesome-list for plugins/marketplaces — add an entry. | Standard PR. |
| **jeremylongshore/claude-code-plugins-plus-skills** (`ccpi`) | Submit repo link per its CONTRIBUTING / email `jeremy@intentsolutions.io`. | Accepted ones get featured. |
| **aitmpl.com** | Aggregator; gets picked up once you're in a crawled marketplace. | Passive. |
| **anthropics/claude-plugins-official** | Highest bar — directory submission form; automated validation + safety screening. | Apply after traction. |

Install path for all of them is already shipped: `/plugin marketplace add dshakes/compass` → `/plugin install core@compass`.

---

## 3. Positioning — the one line everything leads with

> **compass — eval-gated guardrails + red-team hardening, a measured cost router, and signed
> supply-chain for Claude Code, Codex & Gemini. Auditable config you own, not a service.**

Do **not** lead with "turns your agent into a senior engineer" — that's the crowded,
well-owned skill-framework lane. Lead with the three things the giants *don't* have: **measured safety**,
**red-team resistance you can reproduce**, and **provenance**. The self-fixing PR loop is the
demo; the eval numbers (`compass bench`, `compass redteam`) and `compass verify` are the proof.

---

## 4. Go-to-market — channels (executive tone, honest, you post as a human)

> Post from your own accounts, engage genuinely, stay to answer. Check each community's
> self-promo rules. Sequence: GitHub stars → awesome-claude-code → Show HN (Tue–Thu AM PT) →
> X/LinkedIn same day → Reddit → dev.to write-up.

### Show HN
**Title:** `Show HN: Compass – eval-gated guardrails + red-team layer + cost router for Claude Code`
**Body:**
> I kept rebuilding the same Claude Code / Codex / Gemini setup in every repo, and I didn't
> trust the "vibes-based" safety in most agent configs — so I built one that's measured.
> Compass installs one operating manual across ~/.claude and ~/.codex, plus guardrail hooks
> that block the catastrophic before it runs (rm -rf /, secret writes, force-push to main) and
> a cost-tier router that sends cheap work to cheap models. Two things I haven't seen elsewhere:
> (1) the guardrail and router are **eval-gated** — `compass bench` reports 100% precision/recall
> on a 61-case bypass corpus and 96.9% routing accuracy, in CI, so the safety claim is a number
> you can reproduce, not a promise; (2) releases carry **SLSA provenance** (`compass verify`),
> because 2026 had real marketplace-plugin-hijack incidents. There's also an optional, human-gated
> autonomous PR loop (review → security → tests → Codex cross-audit → auto-fix its own Blocking
> findings → re-review until green; you merge) — and you can run it on one PR or **schedule it
> across every repo you own** (the "fleet": governed, test-gated, approve from your phone). New
> in this release: a **red-team layer** that defends the agent itself — it flags prompt-injection
> (direct, indirect via web/MCP output, and copy-paste, including base64/zero-width/homoglyph
> obfuscation), CLAUDE.md poisoning, and a project trying to disable the guardrails. It's
> measured too: `compass redteam` is 100% precision/recall on a corpus and `--attack` is 100%
> robust against the obfuscation transforms. (Honest: pattern detection is best-effort, and the
> optional Bedrock/Azure backends are parsing-tested, not live-verified in CI.) The router is
> **cache-aware** and ships as a reusable module. No service, no curl|sh, MIT, every hook a
> commented shell script. Alpha — feedback welcome, especially on the corpora.
> https://github.com/dshakes/compass

### LinkedIn (executive)
> Most "AI coding agent" setups ask you to trust their safety on faith. I open-sourced **compass**
> to make it measurable instead.
>
> compass is a single-source configuration and safety layer for Claude Code, Codex, and Gemini.
> What makes it different from the dozens of agent-config repos:
> • **Safety with a number.** The guardrail that blocks destructive commands and secret writes is
>   eval-gated — 100% precision/recall on a published 61-case corpus, enforced in CI. You can
>   reproduce it.
> • **Cost discipline that's measured.** A cost-tier router (eval-scored, ~61% cheaper than
>   all-Opus at ~98% quality on a fair task mix) instead of "up to 80%" marketing.
> • **Red-team resistance you can reproduce.** A new layer flags prompt-injection (direct,
>   indirect, copy-paste — even base64/zero-width/homoglyph-obfuscated), CLAUDE.md poisoning, and
>   local safety-override. `compass redteam` scores 100% P/R on a corpus and `--attack` stays
>   100% robust under obfuscation — both CI-gated (and honestly bounded in the docs).
> • **Supply-chain provenance.** Releases are signed (SLSA); `compass verify` rejects a tampered
>   download — a direct answer to 2026's marketplace-plugin-hijack incidents.
> • **Scales to your whole org.** The same governed loop runs as a *fleet* — scheduled across
>   every repo, test-gated, approve from your phone — not just one PR at a time.
> • **No service.** Auditable config files, `git pull` to update, MIT.
>
> Plus an optional human-gated loop that reviews and fixes its own PRs — you always merge.
> Alpha, and I'd value your feedback. → github.com/dshakes/compass

### LinkedIn (authentic / personal — written by hand, first person)
> I almost didn't post this.
>
> A few weeks ago I noticed I was doing the same thing in every repo: re-explaining to Claude
> Code (and Codex, and Gemini) how I actually work — what to read first, what never to touch,
> which model to use for which job. Copy-paste config, every time. So I started keeping it in one
> place. Then it grew teeth.
>
> The part that changed my mind about sharing it: I stopped trusting "safe by default" claims —
> including my own. It's easy to say "it blocks dangerous commands." So I made it prove it. There's
> a little corpus of 61 commands that must-block or must-allow, and the guardrail is scored against
> it in CI — 100% precision and recall, and you can run the exact command and see the number. Same
> for cost: instead of "saves you money," it's an eval you can reproduce.
>
> It's called compass. It's alpha. It's MIT. It is honestly not perfect — the autonomous PR loop
> is the newest part and I've been deliberately careful not to oversell it (its logic is tested in
> CI; the live behavior you reproduce with a checklist). I'd rather undersell and have you find it
> better than the README, than the other way around.
>
> If you use Claude Code or Codex daily, I'd genuinely love your eyes on the guardrail corpus — tell
> me what it should catch that it doesn't. That feedback is worth more to me than stars.
>
> github.com/dshakes/compass — and thanks to everyone who let me think out loud about this.

### X / Twitter (thread)
1. Most Claude Code / agent configs ask you to *trust* their safety. I shipped **compass** 🧭 to make it **measurable**. One config for Claude Code, Codex & Gemini. MIT. 🧵
2. Guardrails with a number: `compass bench` → **100% precision/recall on a 61-case bypass corpus**, in CI. It blocks `rm -rf /`, secret writes, force-push to `main` — and you can reproduce the score, not just read a promise.
3. Cost routing that's *measured*: an eval-scored, **cache-aware** cost-tier router, **~61% cheaper than all-Opus at ~98% quality** on a fair task mix. Cheap work → Haiku/Sonnet; hard calls → Opus. Ships as a reusable module.
4. Supply-chain provenance for a config: releases are **SLSA-signed**; `compass verify` rejects a tampered tarball. (2026 had real marketplace-plugin-hijack incidents — this is the answer.)
5. New: a **red-team layer** that defends the agent itself — prompt-injection (direct/indirect/paste, even base64·zero-width·homoglyph-obfuscated), CLAUDE.md poisoning, a project disabling your guardrails. `compass redteam` → 100% P/R; `--attack` → 100% robust under obfuscation. Measured, and honestly bounded.
6. The demo: an optional human-gated PR loop — review → security → tests → **Codex cross-audit** → **auto-fix its own findings** → green. You keep the merge.
7. And it scales: run that loop on one PR, or **schedule it across every repo you own** (the *fleet* — governed, test-gated, approve from your phone). No service, no curl|sh. Alpha; feedback welcome 👉 github.com/dshakes/compass

### r/ClaudeAI / r/ChatGPTCoding
**Title:** `I open-sourced an eval-gated safety + cost layer for Claude Code, Codex & Gemini (MIT)`
**Body:** Same substance as Show HN, slightly more casual. Lead with the problem (per-repo
config + unmeasured safety), the three proof points (bench number, measured router, provenance),
then the optional loop, then MIT/alpha + ask for feedback on the corpus. Include the hero image.

### dev.to / blog (highest-credibility, optional)
600–900 words: *"Stop trusting your AI agent's safety on faith — measure it."* Outline: the
unmeasured-safety problem → the 61-case corpus + how precision/recall is computed → the measured
router (cost-at-iso-quality) → provenance (`compass verify`) → the optional loop → install/uninstall.
Link from README once live.

---

## 5. Differentiator cheat-sheet (when someone compares you in a thread)

| If they mention… | Lead with |
|---|---|
| **"senior engineer" skill frameworks** | "Different aim — compass is the *measured safety + cost + provenance* layer; it composes with skill frameworks, doesn't replace them." |
| **spec-kit** | "compass has `/spec` and reads spec-kit's `spec.md`; it's a layer on top, not a competitor." |
| **claude-router / cost tools** | "Ours is eval-scored + CI-gated with a reproducible cost-at-iso-quality number, **cache-aware** (ADR-0004), and a reusable module (`router/`)." |
| **rulebricks / cloud guardrails** | "No service or cloud dependency — auditable files, `git pull` to update; the policy is a corpus-tested pure function." |
| **amtiYo/agents, agent-kit (config sync)** | "Those sync config; compass *is* opinionated config plus guardrails, routing, provenance, and a governed loop." |
| **CI bots / Dependabot-style automation** | "compass's *fleet* runs the full review→fix→test loop across all your repos on a schedule, governed and human-gated — not single-purpose, and it fixes its own findings." |
| **prompt-injection / red-team tools** (Lasso, promptfoo, garak, Rebuff, Llama Guard) | "compass ships an eval-gated red-team layer in the config itself (`compass redteam` 100% P/R, `--attack` 100% robust) covering injection, CLAUDE.md poisoning, and local safety-override — local-first, and it *escalates* to a managed backend (Bedrock/Azure/webhook) or pairs with garak/promptfoo for live-fire; it doesn't compete with them." |

---

## 6. Assets

Render on GitHub straight from the repo: the animated **explainer** (`assets/explainer.svg`),
the **router cascade** hero (`assets/router-cascade.svg`), the **self-fixing loop diagram**
(`assets/sdlc-loop.svg`), the **red-team layer** diagram (`assets/red-team.svg`), the **fleet**
diagram (`assets/fleet.svg`), the **hardening/frontier** map (`assets/hardening-frontier.svg`),
and a terminal demo (`demo/preview.gif`). `assets/loop.gif` is a **real screen recording**
(2026-06-10) of the loop closing itself on a live, public PR —
<https://github.com/dshakes/compass-loop-demo/pull/1> — captured headless (Playwright
screencast of the PR timeline → ffmpeg GIF). The README image links to that PR so a skeptic
can click through and inspect every event: Blocking review + `agent:needs-fix` → the
Builder's fix commit on the PR's own branch → re-review clean + `agent:reviewed-clean`.
Keep the demo repo public; re-record with the same harness (`/tmp` scripts archived in the
session, or re-run `scripts/smoketest-scaffold.sh` + a fresh PR) if the loop's UX changes.

---

*Internal checklist. Re-verify the star count and eligibility gates immediately before submitting.*
