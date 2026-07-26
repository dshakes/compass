# Using compass — get the most out of it

A practical guide: **install in one command**, understand the pieces, and adopt the daily
habits that make you fast and cheap. If you read one doc, read this one.

---

## 1. Install — pick a row, run one command

| You want… | One command | What it touches |
|---|---|---|
| It everywhere on my machine (**simplest**) | `git clone https://github.com/dshakes/compass ~/compass && cd ~/compass && ./quickstart.sh` | preview → symlink `~/.claude` + `~/.codex` → validate → on-ramp (one command; re-run to repair) |
| It everywhere, steps by hand | `… && make dry-run && make install && make doctor` | same, three explicit steps |
| Just the machinery, no global config | `/plugin marketplace add dshakes/compass && /plugin install compass@compass` | per-session plugin (no memory/permissions) |
| Committed config in **one** repo | `make new-repo DIR=~/code/my-repo` | starter `CLAUDE.md` + `AGENTS.md` symlink |
| Committed config across **many** repos | `make apply-many DIRS="~/code/*"` *(or `scripts/apply-repos.sh --git-only ~/code/*`)* | the per-repo pieces, in every repo at once |
| The team to get it on a repo | `make new-repo DIR=~/code/my-repo TEAM=1` | pins `compass@compass` in `.claude/settings.json` |

Then **always**: `make doctor` — it validates everything and tells you what (if anything) to fix.
Symlink install means `git -C ~/compass pull` updates every repo at once.

> **Mental model:** `make install` makes compass the *default* in every repo (global manual +
> hooks + agents + MCP). `new-repo` / `apply-many` add the *committed, per-repo* bits a team
> shares (a starter `CLAUDE.md`, the `AGENTS.md` symlink, an optional plugin pin).

---

## 2. The pieces — what each is, and when it fires

| Piece | What it is | When it acts | You invoke it… |
|---|---|---|---|
| **Operating manual** (`CLAUDE.md`/`AGENTS.md`) | the standing instructions | every session, automatically | never — it's just on |
| **Hooks** | shell scripts the harness runs deterministically | on tool calls / session events | never — automatic (e.g. blocks `rm -rf /`, auto-formats) |
| **Subagents** (15) | specialists in their own context, on the right model | when the driver delegates | by asking, or auto-delegated |
| **Commands** (`/ship` `/review` `/tdd` `/spec` …) | saved prompts / procedures | when you type them | `/<name>` |
| **Skills** | procedures with steps, auto-loaded by relevance | when relevant, or by name | `/<skill>` or automatically |
| **MCP servers** | external tools (docs, fetch, git, browser, memory) | when a tool is used | configured once; the agent calls them |
| **Status line** | model · dir · git · context · `$cost` | always visible | glance at it |

**Rule of thumb:** *hooks* are for "must happen every time" (guardrails, formatting). *Skills/
commands* are for "a procedure I run on purpose" (`/ship`, `/spec`). *Subagents* are for "go do
this in a fresh context and bring back the answer" (review, security, deep search). *MCP* is the
extension point for new tools. Add your own — drop a markdown file in `agents/`, `commands/`, or
`skills/` and it's picked up. → [Customize](03-customize.md)

---

## 3. The daily workflow (what "good" looks like)

1. **Just start.** Open any repo, run `claude` (or `codex`). The manual, guardrails, subagents,
   and MCP are already loaded; the status line shows live `$` spend.
2. **Ask for the change.** Claude reads first, states a short plan, implements. It auto-delegates
   grunt work to cheap models and auto-formats every file it edits.
3. **For non-trivial work, spec it first:** `/spec add rate limiting to login` writes a short
   intent + acceptance criteria the build and review then verify *against*. (Skip for one-liners.)
4. **Pre-ship:** `/ship` runs tests + a fresh-context review and prepares a clean commit. Or
   `/review` for just a review, `/tdd` to write the failing test first, `/triage` on a failure.
   For a **deeper** pass, `/compass-review` fans the review out across five dimensions in
   parallel and has a skeptic refute each finding before it's reported (research preview; see
   [dynamic workflows](13-workflows.md)). `/compass-audit` does the same for a whole-repo sweep;
   `/compass-plan` drafts a hard plan from several angles and picks the best.
5. **Raise the PR.** The [autonomous loop](09-sdlc.md) takes over: review · security · tests ·
   Codex audit → if Blocking, the Builder fixes on the branch and re-reviews until green. **You
   merge.**

The commands you'll actually reach for: **`/spec` `/ship` `/review` `/tdd` `/triage` `/pr`
`/adr` `/cost`** — and **`/route`** to send a diff to the right specialist. Going deep?
**`/compass-review` `/compass-audit` `/compass-plan`** fan out many verified subagents at once.

---

## 4. Be cost-effective (real money, real latency)

compass is built so the **expensive model does the thinking and cheap models do the labor.**

- **Let it delegate.** The driver (Opus) hands test runs, log triage, and mechanical sweeps to
  **Haiku**; most coding/review to **Sonnet**; keeps **Opus** for architecture, security, subtle
  bugs. You don't manage this — the subagents are pre-tiered. → [Cost & models](02-cost-and-models.md)
- **Watch the status line `$`.** It's right there. If a session is getting pricey, that's your cue.
- **`/cost`** re-plans the current task to the cheapest-correct mix before you spend on it.
- **Use the subscription path** for cloud agents (`CLAUDE_CODE_OAUTH_TOKEN` from `claude
  setup-token`) — no per-call API credits. → [SDLC](09-sdlc.md)
- **Cap autonomy.** Scheduled routines and the fix loop have `--max-budget-usd` / round caps;
  the spend is bounded by design.
- **`/clear` between unrelated tasks.** Context is the scarce resource — a lean window is faster
  *and* cheaper.

---

## 5. Be extremely productive (turn the autonomy on)

Adopt these as you get comfortable — each is opt-in:

- **Close the PR loop** (`sdlc/setup.sh --all`): agents review, security-check, test, cross-audit,
  and **auto-fix their own findings** on every PR. You review intent + click merge. → [SDLC](09-sdlc.md)
- **Schedule the chores** (`sdlc/setup.sh --routines`): nightly flaky-triage, weekly dep-refresh
  and doc-freshness, a PR babysitter — all open PRs you merge, never auto-merge. → [routines](../sdlc/routines/README.md)
- **Spec-drive the big features** (`/spec` + `SDLC_SPEC=`): the loop verifies against your
  acceptance criteria, not just "tests pass."
- **Parallelize review** (`/team-review`, experimental): correctness + security + tests as
  teammates that talk to each other.
- **Route by work type** (`/route`): UI changes get a design pass, API changes a contract pass —
  without over-reviewing typed PRs.
- **Run it locally with no cloud:** `~/compass/sdlc/orchestrate.sh "task"` (add `SDLC_CONVERGE=1`
  to loop fix→review until clean).

→ The full forward map is the [roadmap](10-roadmap.md).

---

## 6. Verify it's working

```bash
make doctor                 # JSON/TOML/frontmatter/symlinks/plugin-sync — should be 0 errors
claude mcp list             # MCP servers healthy
# open a repo, run claude → the status line shows model · branch · context · $cost · 🧭 activity
# try a guardrail:  ask it to `rm -rf $HOME` → it's blocked before running
compass status              # is compass enabled in THIS repo? (global config + per-repo extras)
compass impact              # what compass has done for you: footguns blocked, $ saved, …
```

Uninstall is clean and reversible: `make uninstall` removes only what compass created
(backups in `~/.claude/backups/`).

### New to a repo? Onboard in one command
`make install` already put the `compass` CLI on your PATH (via `~/.local/bin`; open a new shell
if you just installed). Then, in any repo:
```bash
compass onboard             # detect stack → install deps → build+test green → grounded CLAUDE.md → codebase map
```
Or `/onboard` inside a Claude session. The full `compass` CLI: `status` (is it enabled here?),
`onboard` (+ `--all <glob>` for many repos), `impact` (benefit dashboard), `spend` (cost +
budget, `--today` for the per-day loop cap), `digest` (comprehension guard — sample merged
changes you didn't hand-write and explain them), `schedule` (local cron routines), `route`
(model tier). Run `compass help` for the list.

> **Running loops while you sleep?** See [the five moves of a loop](20-loops.md): wire
> `morning-triage` for discovery, keep the acting evaluator gating each change, set
> `COMPASS_MAX_USD_DAY` before the first unattended run, and make `compass digest` a daily habit
> so the code the loop merges never outruns your understanding of it.

---

## 7. Make it yours
It's a starting point, not scripture. Delete the stack section of the global `CLAUDE.md` if
you're not polyglot AI-infra; add your own agents/commands/skills as plain markdown; tune the
cost tiers and the SDLC role prompts. → [Customize](03-customize.md) · [Philosophy](00-philosophy.md)
