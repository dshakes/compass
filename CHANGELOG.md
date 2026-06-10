# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions follow [SemVer](https://semver.org/).

## [Unreleased]

## [0.18.0] — 2026-06-10

### Added

- **`compass trace` — provenance for AI-assisted commits.** Emits records in the open
  [Agent Trace](https://github.com/cursor/agent-trace) format (tool, model, session, changed
  line ranges), stores them as git notes (`refs/notes/agent-trace`), and optionally signs them
  with cosign (`--sign` / `COMPASS_TRACE_SIGN=1`). `emit` / `attach` / `show` / `verify`
  subcommands; deterministic and idempotent (re-`emit` is byte-identical). CI-gated by
  `scripts/test-trace.sh` (35 cases, no network). **Honest limit:** the cosign signing path is
  contract-tested with a stub; live Sigstore signing is not verified in CI. ADR-0006 +
  `docs/19-provenance.md`.
- **`compass spend --max-usd N` — hard budget gate.** Exits 2 with a greppable
  `OVER_BUDGET total=$X cap=$Y` line when spend exceeds the cap (env: `COMPASS_MAX_USD`,
  flag wins); `--json` gains `max_usd` / `remaining` / `over_budget`. Use as a kill-switch in
  CI or loops. Covered in `scripts/test-cli.sh`.
- **`docs/18-benchmark.md` — the guardrail benchmark, opened up.** Documents the corpus format
  and scoring so any tool can run the same eval, how to reproduce compass's numbers in ~30s,
  and how to contribute cases — a bypass that beats the guardrail is a prized contribution.
- **OWASP Agentic Top-10 (ASI 2026) mapping** in `docs/17-red-team.md` — each ASI ID mapped to
  the compass control that covers it, with honest Partial/Roadmap ratings (ASI03 agent
  identity and ASI07 inter-agent comms are roadmap, not claimed).
- **Roadmap Phase 5** — team/workflow-scale guardrails, eval-driven routing, per-task hard
  budget caps in the autonomous loop, agent identity/attestation.

### Fixed

- **`claude plugin validate` now passes on `plugins/core`.** The `test-architect` agent's
  frontmatter description contained an unquoted `merged: no` — YAML parsing failed and the
  agent silently loaded with empty metadata. Description quoted; plugin re-synced.
- **`docs/18-benchmark.md`** stated 68 guardrail cases; `compass bench` reports **61** —
  corrected to match the eval output.

### Changed

- **`SECURITY.md` side-effects sentence** now also discloses the `~/.local/bin` CLI symlink
  and the marker-tagged shell-rc `PATH` line `install.sh` appends (both always reverted by
  `make uninstall`). Surfaced by self-running the awesome-claude-code repository-evaluation
  rubric (overall 8/10, "recommend with caveats" — both caveats addressed).

## [0.17.2] — 2026-06-05

### Changed

- **Docs honesty:** the README vendor-install note now states the live install is **manually
  verified** — `gemini extensions install` (gemini 0.26.0) and `codex plugin marketplace add`
  (codex 0.130.0) both succeed against this repo — rather than implying it's only schema-checked.
  Still not run in CI (those CLIs aren't in the runner).

## [0.17.1] — 2026-06-05

### Fixed

- **Codex marketplace install** — `.agents/plugins/marketplace.json` used
  `policy.authentication: "NONE"`, which Codex rejects (`unknown variant NONE, expected
  ON_INSTALL or ON_USE`), breaking `codex plugin marketplace add`. Set to `ON_USE` (compass
  needs no install-time auth). **Verified live** with `codex 0.130.0` (add now succeeds) and
  `gemini 0.26.0` (extension installs as `compass 0.17.x`). `scripts/check-vendor.sh` now
  gates the authentication enum so this can't regress.

## [0.17.0] — 2026-06-05

Cross-vendor native installs + the skills system. One config, every agent — a one-line
marketplace/extension install (no terminal) for every user type, or `make install`. Plugin
manifests `0.17.0`.

### Added

- **Native Codex plugin marketplace** — `plugins/core/.codex-plugin/plugin.json` +
  `.agents/plugins/marketplace.json`: `codex plugin marketplace add dshakes/compass` → `/plugin install`.
- **Native Gemini CLI extension** — `gemini-extension.json` + `GEMINI.md`:
  `gemini extensions install https://github.com/dshakes/compass` (wires context7/fetch/git MCP).
- **`scripts/check-vendor.sh`** (doctor-gated) — keeps every vendor manifest wired to ONE source:
  version == `plugins/core`, MCP == `mcp/servers.json`, component pointers + marketplace source path resolve.
- **Skills system** — `using-compass` dispatcher (auto-reach), plus `verification-before-completion`
  and `systematic-debugging` (trigger-first, enforceable). Plugin bundles 6 skills.
- **README** per-agent native-install table (Claude · Codex · Gemini natively; Cursor/Copilot/OpenCode
  via the AGENTS.md standard).

### Notes

- `CLAUDE.md` · `AGENTS.md` · `GEMINI.md` are one file (symlinks); `git pull` updates every agent.
- Vendor manifests match each tool's **documented schema** and are structure-validated in CI; the
  live `plugin marketplace add` / `extensions install` step needs that vendor's CLI (not run in our CI).

## [0.16.0] — 2026-06-05

Red-team depth — closes the gaps from v0.15.0's first layer. Plugin manifests `0.16.0`.

### Added

- **Decode/normalize layer** (`normalize_untrusted`) — detection now runs on raw text AND a
  de-obfuscated rendering: base64 decode, zero-width/bidi strip, homoglyph + leetspeak fold.
  `compass redteam --attack` adversarially fuzzes the corpus (5 transforms) and reports
  detector robustness — **100% on the corpus's obfuscation transforms**.
- **System-prompt-leakage** detector (OWASP LLM07) + negation-aware allowlist (precision).
- **`compass redteam --attack`** (adversarial fuzz) and **`compass redteam --scan [DIR]`**
  (scan any repo's context; git-or-find file discovery).
- **Adapter contract tests** (`scripts/test-guardrail-remote.sh`, doctor-gated) — the
  webhook/Bedrock/Azure response-parsing is now verified against fixtures. (Live cloud calls
  remain unverified-in-CI — they need your creds; see docs/17.)
- **SAST depth** — `compass scan --injection` runs `semgrep` if installed (advisory; gitleaks
  for secrets). **MCP scan** now covers tool command/args/url, not just descriptions.
- **Continuous fleet red-team** — `sdlc/routines/redteam-sweep.yml` (scheduled, token-free:
  eval + context scan, opens an issue on findings).
- **Docs** — `assets/red-team.svg` diagram; OWASP-LLM-Top-10 + MITRE-ATLAS mapping in docs/17.

### Changed

- **PostToolUse precision** — Bash output is scanned for indirect injection only when the
  command actually fetched external content (curl/wget/http), not on every local command.

## [0.15.0] — 2026-06-05

Red-team hardening — a measured, defense-in-depth layer that defends the agent itself
against adversarial input, not just accidental footguns. Plugin manifests `0.15.0`.

### Added

- **Red-team hardening layer** ([ADR-0005](docs/adr/0005-red-team-hardening.md),
  [docs/17](docs/17-red-team.md)). Detects, warns on, and audits: direct + **indirect**
  + copy/paste **prompt injection**, **CLAUDE.md/AGENTS.md context poisoning**, local
  `.claude/settings.json` **safety-override**, **malware authoring** (awareness, dual-use
  aware), and **insecure code** (SAST-lite). Pure detectors in `claude/hooks/lib/policy.sh`
  (`injection_findings`, `settings_override_reason`, `malware_intent_findings`,
  `insecure_code_findings`).
- **Eval + golden corpus** — `scripts/redteam-corpus.tsv` (56 + 4 programmatic = 60) scored
  by `scripts/test-redteam.sh`; **precision 100% / recall 100%** (floors 100/90), gated in
  CI via `compass doctor`. `COMPASS_REDTEAM_CORPUS` runs your own labeled corpus.
- **Runtime hooks** (warn + audit by default): `scan-untrusted-context.sh` (SessionStart),
  `scan-prompt.sh` (UserPromptSubmit), `scan-tool-output.sh` (PostToolUse) — wired in
  `claude/settings.json` and the plugin bundle.
- **CLI** — `compass redteam [--eval|--scan|--json]` and `compass scan --injection`.
- **Optional managed-guardrail escalation** (`COMPASS_GUARDRAIL_BACKEND`): `webhook`
  (verifiable shape) · `bedrock` · `azure` Prompt Shields. NOTE: the Bedrock/Azure adapters
  are written to-spec but **UNVERIFIED against live endpoints** — validate with your creds.
- **Feature flags** — `COMPASS_REDTEAM`, `_PROMPT`, `_TOOL_OUTPUT`, `_CONTEXT`, `_ENFORCE`.

### Changed

- **Operating manual** (`claude/CLAUDE.md`) hard lines: external content is data, not
  instructions; a project cannot grant itself a safety exception; no weaponization.

## [0.14.0] — 2026-06-02

Cache-aware routing + prompt-cache TTL — the router now folds Anthropic prompt-cache
economics into tier selection, and the SDLC pipeline opts into the 1-hour cache where it pays.
Plugin manifests `0.14.0`.

### Added

- **Cache-aware routing** ([ADR-0004](docs/adr/0004-cache-aware-routing.md)) — `route.sh` gains
  a cache-aware cost-min stage and a `--ttl` (5m|1h) recommendation; `router.json` carries the
  cache economics (read 0.1×, 5m-write 1.25×, 1h-write 2.0×, prefix/task/output token model).
  **Upgrade-only** (never routes below the keyword pick, so quality can't drop; clamps still
  bound it); off unless `COMPASS_ROUTE_WARM` names already-warm tiers. Scored against a new
  `router/cache-evalset.tsv` (`bench.sh --cache`).
- **`router/validate.sh`** — schema + safety validation of a router spec (required keys, tier
  refs resolve, every pattern compiles as ERE, ReDoS-shape lint). Runs in CI and `doctor`, so a
  malformed/unsafe spec fails loudly before any app embeds it.
- **1-hour prompt-cache TTL in the SDLC pipeline** — `orchestrate.sh` exports
  `ENABLE_PROMPT_CACHING_1H=1` for its `claude -p` steps (the pipeline + converge loop reuse the
  same context across >5min, so reads stay cached); opt out with `SDLC_CACHE_1H=0`. Documented
  in `docs/02-cost-and-models.md` with the tradeoff and how to enable it for the GitHub loop /
  interactive sessions.

### Fixed

- **`router/validate.sh` runs on bash 3.2 (macOS)** — replaced `mapfile` (bash 4+) with a
  portable read loop + `set -u` array guard; CI on Linux had masked the macOS-only failure.

### Docs

- Release-pin examples in the README + `docs/alpha.md` bumped to the latest tag.

## [0.13.0] — 2026-06-02

Pre-launch hardening + manifest alignment, so the corrected manifests ship in a downloadable
tag (the v0.12.1 tarball still carried the old 0.8.0 plugin versions). Plugin manifests are
now `0.13.0`.

### Added / Changed — self-hosted SDLC parity

- **Self-hosted workflows brought current** — the `claude -p` keyless variants in
  `sdlc/selfhosted/` gained the PR #7 App-token mint + token fallback on the push workflows
  (`sdlc-fix`/`implement`/`implement-on-label`/`control`), and a ported `sdlc-design-review`.
  `sdlc-autoapprove` and `release` stay hosted-only (documented in `sdlc/selfhosted/README.md`).
  Already covered by `check-actions` + actionlint.

### Fixed — docs truth

- **Status-line `$` claim made honest** — the `📉~$ saved` segment is today-scoped and fed by
  the spend ledger (`~/.compass/spend.tsv`, written by SDLC / onboard / scheduled runs), not by
  everyday interactive use; the README no longer implies it is always present. `compass impact`
  remains the full benefit view.

### Pre-launch hardening (truth + manifests + fixes)

- **Manifests aligned to the release** — `plugins/core` + `core-lsp` `plugin.json` version
  `0.8.0` → `0.12.1`; marketplace description corrected to 10 subagents / 12 commands / 3
  skills and now discloses the context7/fetch network reach. `new-repo.sh` team pin no longer
  hardcodes a stale tag (uses the current release).
- **Docs made falsifiable-proof** — corrected the guardrail corpus size (85 → **61**, the
  real `compass bench` number) everywhere incl. the SVG; reframed the SDLC loop from
  "validated live end-to-end" to "logic statically validated in CI; reproduce live via the
  smoke-test checklist"; relabeled `loop.gif` as a scripted replay; fixed stale workflow
  counts and a stale version-pin example; added an iMessage/WhatsApp "self-hosted bridge"
  caveat and a network-egress note in the README safety section.
- **README UX** — differentiated the headline (eval-gated safety + cost + provenance, not
  "senior engineer"); added a "verify → first run" quickstart so install → test → use is one
  path; added the `test-architect` safety-gate to the crew table (10th agent).
- **Code SHOULD-FIX** — `compass-sbom` dropped dead syft branch + portable requirements glob;
  `compass scan --staged/--diff` now errors (exit 2) outside a git repo instead of silently
  passing; `compass doctor` no longer requires `make`; `release.sh` validates the version
  string; `setup-mcp` writes MCP config via temp file (no eval-quoting hazard);
  `compass-dashboard` HTML-escapes PR titles; `sdlc-autoapprove` denies on an empty
  status-check rollup; `orchestrate.sh` safety-net commit uses `git add -u`.
- **Launch kit** — rewritten with the correct awesome-claude-code eligibility gates (incl. the
  ≥5-star requirement), an honest submission packet, and multi-channel GTM.

## [0.12.1] — 2026-06-01

### Docs

- **Router hero diagram** (`assets/router-cascade.svg`) — an animated SVG in the repo's
  existing style showing the three-layer cascade (free heuristic → optional free local
  classifier → Haiku LLM judge) with the early-exit lane, plus the data-flywheel loop.
  Embedded at the top of `router/README.md` and in the main README (Mermaid kept alongside).
- Dropped the "world-class" phrasing across the docs in favor of plainer equivalents.

## [0.12.0] — 2026-06-01

A standalone, reusable **cost-tier router** module (`router/`) — extracted so it can be
dropped into any app (Go/Rust/TS/Python), instrumented with the metric the field actually
uses, and grown from a deterministic heuristic into a hybrid cascade (#9–#13).

### Added

- **`router/` module** (#9) — a language-agnostic spec (`router.json`: tiers, costs, ordered
  rules) + a bash reference impl (`route.sh`) + a labeled eval set. Any host loads the same
  spec and reimplements a ~10-line matcher (README has Go/Rust/TS/Python snippets).
- **Cost-at-iso-quality harness** (#9) — `bench.sh` reports the metric routers are actually
  judged on (cost vs all-opus at fixed quality), with base/holdout/**adversarial** splits.
  Headline: **~61% cheaper than all-opus at ~98% quality-retention** on a fair mix; the
  adversarial split honestly quantifies where keyword routing under-serves.
- **v1.1 knobs** (#11) — matching `strategy` (first-match/max-hits/weighted), rule `unless`
  veto + `weight`, `length_rules`, cost↔quality `--bias`, `--floor`/`--ceiling`/`--allow`
  clamps, pricing/model `profiles`, a `--domain` second axis, `router.local.json` overlays,
  `--log` telemetry, and `--json`/`--score` output.
- **Three-layer cascade** (#12) — escalation (`--escalate-below` + pluggable `--fallback`)
  with a **Haiku LLM judge** (`fallback-llm.sh`) and an **opt-in local Naive-Bayes classifier**
  (`train-classifier.sh` / `classify.sh`, off by default) chained by `fallback-cascade.sh`:
  free heuristic → free classifier → LLM judge, paying for intelligence only where needed.
  The LLM judge labels real traffic (`--log`) to train the classifier — the data flywheel.

### Changed

- **`compass route` is now backed by the module** (#10) — `compass-route.sh` reads its tier
  rules from `router/router.json` (single source of truth; no more duplicated patterns).
- **`route.sh` reads the spec in one `jq` pass** (#13) — ~15 calls/route → 1; the module
  test suite went from ~112s to ~14s. Behavior identical (`compass route --eval` 96.9%).

### Docs

- Polished Mermaid diagrams (#13): the cascade hero, the routing pipeline, and the
  data-flywheel — in `router/README.md` and the main README.

## [0.11.0] — 2026-06-01

Closes the gap analysis G1–G7 — a security, supply-chain, and DX hardening pass (#8).
Every item is CI-gated; the full local gate is green.

### Added

- **Secret scanning at the agent boundary** (G1) — `compass scan [--staged|--diff|--all]`
  finds secrets before they're committed (pre-commit / CI). High-precision built-in detectors
  (Anthropic/OpenAI/AWS/GitHub/GCP/Slack/Stripe/GitLab/npm/private-key) are the deterministic
  gate; `gitleaks` adds depth when installed. Mark a deliberate placeholder with an
  `allowlist secret` comment.
- **MCP supply-chain pinning** (G3) — every executable MCP server in `mcp/servers.json` is
  pinned to an explicit version (no `@latest`). `scripts/check-mcp.sh` enforces pins +
  manifest integrity (shell-injection markers) as a `setup-mcp` pre-flight and in `doctor` + CI.
- **Release provenance** (G4) — `.github/workflows/release-sign.yml` emits a keyless SLSA
  build-provenance attestation for every `v*` tag; `compass verify [vX.Y.Z|FILE]` rejects a
  tampered or look-alike tarball (needs `gh`).
- **`compass drift`** (G5) — diffs the installed `~/.claude` (and `~/.codex`) against the repo
  source: clobbered/repointed symlinks, hand-edited or stale copies, dangling links, and a
  guardrail hook that lost its `+x` bit.
- **`compass audit-log`** (G6) — a structured JSONL trail of every blocked/gated action
  (ts · decision · tool · rule · redacted detail); `--since` / `--json` for SIEM export.
- **`compass sandbox -- CMD`** (G2) — a real containment boundary (no network, writes confined
  to cwd + temp) via bubblewrap / firejail / macOS `sandbox-exec`, for untrusted code. Refuses
  rather than run unconfined when no backend is available.
- **`harden` skill** (G7) — a repeatable pre-ship security sweep (scan → check-mcp → drift →
  verify → sandbox).
- **One-click release workflow** (`sdlc/workflows/release.yml`, dogfooded at
  `.github/workflows/release.yml`) — a `workflow_dispatch` job that cuts a release from the
  Actions tab / GitHub Mobile (no terminal): resolves the version (input or newest
  `[X.Y.Z]` in CHANGELOG), pushes the tag, publishes the GitHub Release with notes pulled
  from the CHANGELOG, and — if the repo ships a Homebrew tap formula — opens a formula-bump
  PR. Generic (the formula step self-skips when there's no `Formula/*.rb`), idempotent, and
  installed into any repo by `sdlc/setup.sh --workflows`. The local twin is `compass release`.

### Security

- **Inline-secret write-hook** (G1) — `protect-paths` now blocks a Write/Edit that introduces
  a recognizable live credential into a file's content, not just secret file paths.
- **Pinned, integrity-checked MCP manifest** (G3) — a compromised upstream MCP release is no
  longer auto-pulled (tool-poisoning / CVE-2025-54136), and a tampered manifest is rejected.
- **Signed releases** (G4) — provenance you can verify, alongside the existing Homebrew `sha256` pin.
- **Real sandbox for untrusted code** (G2) — an actual boundary beside the (honestly
  best-effort) footgun-reducing hooks.
- **Repo secret self-scan in CI** — `compass scan --all` runs in CI so no credential lands in
  the repo.

### Fixed

- **`policy-synth` parses on bash 3.2** (macOS `/bin/bash`) — a heredoc-in-command-substitution
  with apostrophes broke it on every macOS run; switched to `read -r -d ''`.
- **SDLC orchestrator tests are source-anchored** — `selftest.sh` asserts its mirrored logic
  still matches `orchestrate.sh`, so drift in budget / round-cap / diff-threshold / spec-order
  fails the suite instead of passing silently.

## [0.10.1] — 2026-06-01

### Security

- **Reviewer App-token scoped to least privilege** (#7) — `sdlc-review.yml` minted its
  GitHub App installation token without constraining permissions, so a `read-only` reviewer
  could receive a `contents:write` token when the org App grants it (needed by the
  fix/implement builders). The reviewer now requests `permission-contents: read` +
  `permission-issues: write` + `permission-pull-requests: write`, so untrusted PR content can
  never drive a write-capable token through the read-only reviewer. The builders keep their
  broad write token (they legitimately push).
- **Reviewer no longer falls back to `SDLC_BOT_TOKEN`** (#7) — the reviewer degrades to the
  default `github.token` (loop runs in manual mode) instead of a broad contents-write PAT, so a
  misconfigured App can't silently re-grant write access.

### Fixed

- **App-token fallback is now real** (#7) — all five `Mint GitHub App token` steps
  (`review`/`fix`/`implement`/`implement-on-label`/`control`) are `continue-on-error: true`, so a
  missing/invalid `SDLC_APP_PRIVATE_KEY` falls through to `SDLC_BOT_TOKEN`/`github.token` instead
  of failing the job before the documented fallback is reached. Templates + `.github/` mirrors
  updated identically (drift gate clean).

## [0.10.0] — 2026-06-01

### Added — hardening + frontier layer (competitive-audit recommendations R1–R14)

- **Eval-gated guardrail** (`claude/hooks/lib/policy.sh`, R1/R2/R10) — the guardrail is now a
  pure, sourceable policy (`danger_reason` / `secret_file_reason`); `protect-paths.sh` just
  adapts the PreToolUse contract to it. Closes every bypass the audit found: split/long `rm`
  flags, quoted `$HOME`, `find … -delete`, system dirs, `curl|sh` no-space/`zsh`/`sudo`/
  process-sub/eval, `git push origin +main`, `git -c … push --force`, wider secret-file +
  protected-branch sets. Still footgun-prevention, not a security boundary.
- **Guardrail bypass corpus** (`scripts/test-protect-paths.sh`, R1) — 61-case must-block /
  must-allow labeled corpus, gated in CI; found and fixed 3 real bugs while being written.
- **GitHub Actions audit** (`scripts/check-actions.sh`, R3/R4) — gates mirror-drift
  (`.github/workflows/sdlc-*` vs `sdlc/workflows/` templates), least-privilege `permissions:`,
  SHA-pinning, and run-block `${{ github.event.* }}` script injection. Wired into CI + doctor.
- **`compass bench`** (`scripts/compass-bench.sh` + `scripts/guardrail-corpus.tsv`, R8) —
  reproducible scorecard: guardrail precision/recall (100/100 over 61 cases) + router accuracy
  (96.9%), deterministic and CI-gated on floors. `--sdlc <fixtures>` for a model-driven fix-rate
  harness (not CI-gated).
- **Persistent cross-repo memory** (`claude/hooks/session-memory.sh` +
  `claude/hooks/record-learning.sh`, R5) — opt-in SessionStart inject + Stop/SubagentStop
  record over the redacted, trust-tiered `compass-memory` store (ADR-0001). Off by default
  (no `COMPASS_MEMORY_TRUST` → silent no-op). `store.py` gains a local record/search CLI.
- **`compass dashboard`** (`scripts/compass-dashboard.sh`, R6) — zero-infra control surface:
  impact + spend + live fleet PR state (via `gh`) in one panel; `--json` / `--html`; graceful
  no-op without `gh`.
- **Parallel SDLC + test-impact QA + diff-size review routing + spec-kit interop**
  (`sdlc/orchestrate.sh`, R7/R9/R13) — `SDLC_PARALLEL=1`, `SDLC_TEST_IMPACT=1`, ≤25-line diffs
  review on haiku, and auto-discovery of `.specify/specs/*/spec.md` / `spec.md`. Default path
  byte-for-byte preserved.
- **Cost-aware router** (`compass route --score`, R11) — confidence 0–99 +
  `COMPASS_ROUTE_BUDGET_BIAS=low` to downgrade only weakly-held sonnet defaults to haiku; the
  deterministic keyword tier stays the hard floor so the CI accuracy eval is unchanged.
- **Fleet brain** (`compass policy-synth` + `sdlc/routines/policy-synth.yml`, R12) — clusters
  recurring review findings into PROPOSED CLAUDE.md rules; edits nothing (human accepts). The
  routine files an issue weekly, never a PR or merge.
- **Provenance** (`compass sbom`, R14) — dependency SBOM + native vuln audit
  (npm/govulncheck/cargo-audit/pip-audit, `syft` if present); `orchestrate.sh` `SDLC_SIGN=1`
  signs Builder commits, `SDLC_SBOM=1` attaches a Provenance section to the PR, `SDLC_SBOM_GATE=1`
  drafts the PR on a known vuln.
- **Docs** — `docs/15-competitive-audit.md` (audit vs the 2026 field + prioritized path) and
  `docs/16-hardening-and-frontier.md` (the built layer) with `assets/hardening-frontier.svg`.

### Added — autonomous fleet + mobile mission-control

- **`test-architect` subagent** (`claude/agents/test-architect.md`) — safety gate for the
  autonomous loops: writes unit + e2e tests, runs them, validates each test actually fails
  without the change. `TEST-GATE: FAIL` blocks a fix from advancing to a PR or
  `agent:approve-eligible`. No adequate tests → no approve/merge.
- **`vuln-remediate` routine** (`sdlc/routines/vuln-remediate.yml`) — nightly + dispatch;
  scans deps (govulncheck / npm audit / pip-audit / cargo audit) and GitHub
  Dependabot/code-scanning alerts; auto-fixes SAFE findings into a test-gated PR on
  `routine/security-*`; files one de-duped issue for the rest; never merges.
- **`mission-digest` routine** (`sdlc/routines/mission-digest.yml`) — `*/30` best-effort
  cron + dispatch; gh-only (no model); maintains ONE pinned "fleet panel" issue of every open
  PR's state; @mentions `FLEET_MAINTAINER` only on a NEW `sdlc:needs-human` transition.
- **`auto-approve` workflow** (`sdlc/workflows/sdlc-autoapprove.yml`, ADR-0003) — off by
  default (`SDLC_AUTOAPPROVE=on` to enable); on a `agent:reviewed-clean` PR, evaluates a
  fail-closed allowlist (trusted author, green checks, allowlisted paths default docs/+*.md,
  150-line cap, tests present) and marks it `agent:approve-eligible` with a comment. Comment +
  label only — never calls `gh pr review --approve`, never merges.
- **`compass notify`** (`scripts/compass-notify.sh`) — POSTs to a local iMessage/WhatsApp bridge `/session/<tenant>/send-self` to DM you via iMessage or WhatsApp. Config:
  `COMPASS_NOTIFY_URL`, `COMPASS_NOTIFY_TOKEN`, `COMPASS_NOTIFY_TENANT`. Unconfigured =
  graceful no-op.
- **`sdlc/fleet/` scaffolding** — `repos.txt.example` for cross-repo orchestration (Phase 1;
  needs `FLEET_TOKEN` fine-grained PAT scoped to those repos).
- **`fleet-digest` workflow** (`sdlc/fleet/fleet-digest.yml`, Phase 1 — shipped) — `*/30` +
  dispatch; `gh`-only; loops `fleet/repos.txt`, aggregates open-PR state across ALL fleet repos
  into ONE pinned panel issue in the control repo; @mentions `FLEET_MAINTAINER` on new
  `needs-human`. Needs `FLEET_TOKEN` (multi-repo read + issues:write on control repo). Idempotent.
- **`issue-poller` workflow** (`sdlc/fleet/issue-poller.yml`, Phase 1 — shipped) — `*/30` +
  dispatch; `gh`-only; scans each repo for issues labeled `agent:autofix` by a maintainer; swaps
  to `agent:build` to trigger that repo's own zero-touch intake loop. Never edits code or merges;
  `max_per_run` cost guard (default 5); idempotent. Needs `FLEET_TOKEN` (issues:write on targets).
- **`agent:autofix` label** — maintainer applies this to an issue to opt it into cross-repo
  autonomous dispatch via `issue-poller`; the poller swaps it to `agent:build` so each issue
  dispatches exactly once.
- **`compass listen` daemon** (`scripts/compass-listen.mjs`, Phase 2 — shipped) — long-running
  local Node 22 process (zero npm deps) with **two transports, one command grammar**:
  **Telegram** (universal, free — `COMPASS_NOTIFY_TELEGRAM_TOKEN`+`_CHAT`, long-polls
  getUpdates on your authorized chat) **or an iMessage/WhatsApp bridge** (local WebSocket). Relays
  your DM slash-commands (`/status`, `/approve|/hold|/resume #N`, `/build #N`)
  to GitHub. Posts PR comments (enforced by the existing governed `sdlc-control.yml`) — never
  approves or merges directly. Config: transport env + `COMPASS_FLEET_REPO`,
  `COMPASS_CMD_PREFIX`. Requires `gh` authenticated locally + reachable
  bridge. **UNVERIFIED end-to-end** (needs a live bridge); a chat bot on that thread may auto-reply on
  self-chat — pause the bot if needed.
- **ADR-0003** (`docs/adr/0003-auto-approve-trust-boundary.md`) — records the governance
  decision for the auto-approve trust boundary.
- **GitHub App org identity** (optional) — `sdlc-review/fix/implement/implement-on-label/control` +
  `fleet-digest/issue-poller` mint a short-lived token via `actions/create-github-app-token` when
  `SDLC_APP_ID`/`FLEET_APP_ID` (+ private-key secret) are set; falls back to the PAT/default token.
  Set one App per org instead of a PAT per repo. Docs: `docs/14-fleet.md`.

## [0.9.0] — 2026-05-30

### Added — install, packaging & versioning (consumer-grade)
- **Homebrew install** — `brew tap dshakes/compass https://github.com/dshakes/compass`
  then `brew install dshakes/compass/compass`. Versioned (installs the latest release tag;
  `--HEAD` tracks main), `brew upgrade`-safe. Formula in [`Formula/compass.rb`](Formula/compass.rb).
- **Four documented install paths**, all reversible and `curl|sh`-free: Homebrew (managed),
  `git clone` + `quickstart.sh` (own/edit your config), the Claude Code plugin (no terminal),
  and by-hand `make`. Each is version-pinnable (tag / `--HEAD` / plugin pin).
- **`COMPASS_REPO_ROOT`** override in `bin/compass`, `install.sh`, `quickstart.sh` — lets a
  packaged install pin the repo root to a stable path so the `~/.claude` symlinks survive a
  `brew upgrade`. Backward-compatible (unset → resolve from the script's own location).
- **README rewritten** as a benefit-first, product-grade front door (problem→fix framing,
  every feature visible, prerequisites + token requirements spelled out); team plugin pin
  bumped to `v0.9.0`.

### Fixed — self-audit (`/compass-audit` run on the repo, findings triaged + verified)
- **Security · `notify.sh` AppleScript injection** — untrusted `.message`/repo-path text was
  interpolated into the `osascript -e` source (a trailing `\` or `"` could break out into
  arbitrary AppleScript/shell). Now passed as **argv** to `on run {m,t}`. Injection test added.
- **Cost-safety · unattended cron `claude -p`** (`compass-schedule.sh`) — the scheduled routine
  ran with **no turn/budget cap or timeout**. Now bounded by `--max-turns`/`--max-budget-usd`
  (env-overridable) + `timeout`, and a failure/cap no longer aborts before spend is logged.
- **GitHub Actions authz** — `sdlc-control.yml`, `sdlc-implement.yml` (hosted + self-hosted)
  gated privileged actions on `author_association`, which can't distinguish a maintainer from a
  read/triage collaborator. Replaced with a real **`gh api …/collaborators/{user}/permission`**
  check (admin|maintain|write), mirroring `sdlc-implement-on-label.yml`. Added the **fork guard**
  the self-hosted implement workflow's own header promised (refuses cross-repo PR code on the runner).
- **`store.py` (compass-memory)** — `search()` applied the SQL `LIMIT` before the trust-tier
  filter, so newer deny-tier rows could starve out readable ones. Now filters per-row, stopping
  at `limit` **readable** results. Regression test added.
- **`orchestrate.sh`** — a red QA suite still opened a normal PR; now opens a **draft** with a
  CAUTION banner. Swallowed step/commit failures (`|| true`, empty output) are now surfaced.
- **`compass-audit.js`** — title-based dedup let rephrasings through, so the loop never converged
  (burned every round). Now dedups on file + normalized-title and feeds finders the seen-list.
  **`compass-plan.js`** — guards the all-agents-failed case instead of an opaque `TypeError`.
- **Robustness** — `sync-plugin.sh` (`--check` now catches hooks deleted from source; temp-dir
  leak removed), `new-repo.sh` (dangling `AGENTS.md` symlink no longer aborts), `setup-mcp.sh`
  (`mkdir -p ~/.codex`), `protect-paths.sh` (raw-payload fail-safe when no JSON parser is present).
- CLI tests 24→36; memory tests 20→22. All gates green.

### Added — dynamic workflows (parallel, adversarially-verified subagent orchestration)
- **Three workflow commands** in `claude/workflows/` (Claude Code's new dynamic-workflows
  primitive, research preview, `v2.1.154+`) — each routes stages to compass's **own
  cost-tiered subagents** via `agentType`, so cost follows risk:
  - `/compass-review` — reviews the branch diff on 5 dimensions **in parallel**, a skeptic
    **adversarially refutes** each finding, synthesizes one Blocking/Should-fix/Nit verdict.
  - `/compass-audit` — whole-codebase bug & security sweep: 6 multi-modal finders, **loop
    until two dry rounds**, each finding confirmed by a **2-of-3 perspective-diverse vote**.
  - `/compass-plan` — drafts a plan from MVP-/risk-/simplicity angles, a judge panel scores
    them, synthesizes one plan from the winner grafting the runners-up's best ideas.
- `scripts/check-workflows.sh` — structural + JS-syntax lint for workflow scripts; wired into
  `doctor` and CI. Symlinked into `~/.claude/workflows/` by `install.sh`. Docs:
  [`docs/13-workflows.md`](docs/13-workflows.md).

### Added — router eval harness (autoroute is now measured, not a guess)
- `scripts/route-evalset.tsv` — labeled ground truth; `compass route --eval` scores the
  deterministic tier-picker (per-tier recall + accuracy) and **CI gates** on an accuracy floor
  (`COMPASS_ROUTE_MIN_ACCURACY`, default 90%). Closes the long-standing "no evals yet" caveat
  on `SDLC_AUTOROUTE`. Router internals refactored into a single reusable `route_one()`.

### Added — policy hook + prompt-caching guidance (roadmap §8 / §10)
- `claude/hooks/require-tests.sh` — **opt-in** `PostToolUse` policy hook: nudges when a source
  file changes with **no test diff**; silent once any test file is touched. Advisory, never
  blocks. Tested in `scripts/test-cli.sh`.
- **Prompt caching** documented in [`docs/02`](docs/02-cost-and-models.md): it's automatic; compass
  maximizes the hit rate with stable system prefixes and byte-identical converge-loop prompts.

### Added — one-command quickstart
- `quickstart.sh` (+ `make quickstart` + `compass quickstart`) — preview → install → validate →
  60-second on-ramp, in one idempotent command. Re-run to repair. No `curl | sh`.

### Added — live ROI in the status line
- The 🧭 compass-today segment gains `💡` policy nudges and **`📉~$` estimated saved today** vs
  all-Opus (same method as `compass impact`). Fixture-tested in CI.

### Changed — day-one adoption of the 2026-05-28 release
- Deep tier bumped to **Opus 4.8** (`claude-opus-4-8`): `architect`, `debugger`,
  `security-auditor`, and the driver. `/effort ultracode` documented.
- Architecture diagram (Mermaid) + `assets/explainer.svg` updated to show dynamic workflows and
  the one-command quickstart; README statusline section corrected to the real glyphs + new segments.

## [0.8.0] — 2026-05-27

### Added — the `compass` CLI (local engineering tools)
- **`compass` CLI**, baked into `make install` (symlinked to `~/.local/bin`, on PATH; `--no-cli` to skip):
  - `compass status [dir]` — *is compass enabled here?* (global config + this repo's per-repo extras).
  - `compass onboard [dir]` / `--all <glob>` — onboard into a repo: detect stack → install deps →
    build+test green → grounded `CLAUDE.md` → codebase map. `--all` does many (lists, estimates cost,
    confirms, per-repo budget cap, skips already-onboarded). Also a `/onboard` slash command.
  - `compass impact` — *how is compass benefiting me*: footguns blocked · files auto-formatted ·
    spend by model · estimated `$` saved vs running everything on Opus.
  - `compass spend` — aggregate agent cost by model/repo + budget (`COMPASS_BUDGET_USD`).
  - `compass schedule add|list|remove|run <routine>` — local scheduled routines via cron + `claude -p`.
  - `compass route "<task>"` — cheapest-correct model tier; wired into `orchestrate.sh` behind the
    opt-in, **experimental** `SDLC_AUTOROUTE=1` (off by default — no evals yet).
- **Efficacy observability** — guardrail blocks + auto-formats log best-effort to
  `~/.compass/metrics.tsv`; `orchestrate.sh` logs per-step cost to `~/.compass/spend.tsv`; the status line
  gains a `🧭 🛡N 🧹N` activity segment (footguns blocked / files formatted today). All local, opt-in.

### Added — autonomous SDLC: zero-touch intake + human-in-the-loop
- **Zero-touch intake** (`sdlc-implement-on-label.yml`) — a maintainer labels an issue `agent:build` →
  the Implementer writes the change and opens a PR (which Closes the issue) → the review loop runs.
  Hard-gated: maintainer-applied label + a labeler write-permission re-check; the issue body is passed
  as data (a file), never inlined into the prompt.
- **Human-in-the-loop control** (`sdlc-control.yml`) — steer the loop from a PR comment: `/revise <note>`
  (re-enter the fix loop with your guidance), `/hold` · `/resume`, `/approve`; a sticky status panel shows
  loop state + the available moves. The auto-fix loop now respects `sdlc:hold`.

### Added — from the prior cycle
- **LLM/IDE-agnostic single source** — `./install.sh --gemini` feeds the same manual to Gemini CLI;
  per-repo `AGENTS.md` (Linux Foundation standard) is read by Cursor/Windsurf/Copilot/Codex/Amp/Devin.
  Guide `docs/12-every-agent.md`.
- **`SDLC_LITE=1`** for `orchestrate.sh` — fast/cheap governed run (skips Codex audit + opus security).
- **Bring-your-own-model (Codex side)** — opt-in `--profile local` (Ollama) / `--profile router` (OpenRouter).
- **Spend pre-estimate + post-run analysis** in `orchestrate.sh`. **Roadmap Phase 4** (`docs/10-roadmap.md`).

### Changed
- `make install` installs the `compass` CLI on PATH; `make uninstall` + `make doctor` cover it.
- Diagrams updated: `assets/sdlc-loop.svg` (intake + HITL + per-box 🤖/👤 glyphs + legend),
  `assets/hero.svg` (adds Gemini + the CLI; corrected to 9 subagents · 12 commands), and the README
  "How it fits together" Mermaid (compass CLI + observability path).

### Fixed (each caught by live testing, not static checks)
- `sdlc-control` failed without `GH_REPO` — the job has no checkout, so `gh` couldn't resolve the repo.
- `schedule remove` left a stray blank line in the crontab — now `crontab -r` when nothing remains.
- `orchestrate.sh` QA didn't detect root-level `pytest` — broadened detection + `python3 -m pytest` fallback.
- `compass spend` crashed on shell values interpolated into an awk program — rewritten as a single awk pass.
- `compass onboard` missed Python repos (`requirements*.txt`/`*.py`) and used a stale model id.
- `sdlc-implement-on-label` had a misleading `branch_prefix` (claude-code-action names the branch itself) — removed.

### Validation
- **Cloud SDLC live-validated end-to-end** on a real private repo (Claude GitHub App + real secrets):
  buggy PR → review BLOCKING + `agent:needs-fix` → Builder auto-fix (PAT chaining) → re-review CLEAN;
  zero-touch intake (issue `agent:build` → Implementer PR → review clean); HITL `/revise` → Builder
  addressed → re-review clean; the human merge gate (`enforce_admins` strict) held throughout.
- **`scripts/test-cli.sh`** — 17 fixture tests for `route`/`spend`/`impact` + the metric logger, in CI;
  `bin/compass` added to the shellcheck gate.

## [0.7.0] — 2026-05-25

### Agentic capabilities (roadmap built — opt-in; human merge/deploy gate unchanged)
- **Work-type review routing** — `sdlc-classify.yml` labels each PR `domain:*` (haiku);
  `sdlc-design-review.yml` fires only on `domain:ui`; `route` skill mirrors it locally.
  Reviewer/Security/QA/Auditor stay always-on (routing only *adds* targeted review).
- **Scheduled maintenance agents** (`sdlc/routines/`, `setup.sh --routines`) — cron agents
  (babysit-prs, dep-refresh, flaky-triage, doc-freshness) that open PRs/issues into the loop
  and never merge.
- **Goal-oriented convergence** — `orchestrate.sh SDLC_CONVERGE=1` loops fix→re-review until
  CLEAN or `SDLC_MAX_FIX_ROUNDS` (local mirror of the cloud loop).
- **Spec/intent-driven mode** — `/spec` writes a committed spec; `orchestrate.sh SDLC_SPEC=`
  makes the build implement it and the review verify against its acceptance criteria.
- **Agent-team review** (`/team-review`, experimental) and **forked-subagent triage**
  (`debugger` + `CLAUDE_CODE_FORK_SUBAGENT=1`).
- **Opt-in hooks** — `route-intent.sh` (UserPromptSubmit: nudge ADR/security/spec on
  load-bearing prompts) and `checkpoint-wip.sh` (Stop: non-intrusive WIP snapshot). Not wired
  by default.
- **Browser agent** — opt-in Playwright `browser` MCP in `mcp/servers.json`.
- **Human-gated auto-merge** — `setup.sh --protect` enables GitHub auto-merge as an option
  (a human approves; the PR then merges when checks are green). Unattended merge-to-prod
  deliberately NOT built.
- **Cross-repo memory** — `docs/adr/0001` + reference scaffold `mcp/compass-memory/`
  (experimental, not enabled; production blocked on ADR approval + security review).
- `docs/10-roadmap.md` tracks all of the above with maturity tags; `docs/07-practices.md`
  records the adopted gstack techniques.
- **Cross-repo memory v1** — `mcp/compass-memory/` (tested `store.py` + thin `server.py`),
  opt-in, local SQLite, security-reviewed; ADR 0001 Accepted for local v1 (network gated),
  ADR 0002 records the autonomous-loop trust boundary.
- **One-command UX** — `make apply-many DIRS="~/code/*"` (`scripts/apply-repos.sh`) applies
  per-repo config across many repos at once; new hero graphic (`assets/hero.svg`);
  `docs/11-using-compass.md` ("start here" guide).

### Changed
- `claude/settings.json`: `includeCoAuthoredBy` → `false` (no Claude co-author trailer on commits).

### Added
- **Closed auto-fix loop** (`sdlc-fix.yml`) — when the Reviewer emits a `BLOCKING` verdict
  it labels the PR `agent:needs-fix`, which triggers the Builder to read all PR review
  comments, fix on the PR's own branch, and push. The push (via `SDLC_BOT_TOKEN`) re-runs
  the Reviewer. Repeats until the Reviewer is clean or the round cap is hit.
- **Verdict-driven labels + round cap** — Reviewer sets `agent:needs-fix` or
  `agent:reviewed-clean` based on a structured JSON verdict (`BLOCKING`/`CLEAN`). Builder
  tracks rounds with `sdlc:round-N` and `sdlc:fixing` labels; hitting `SDLC_MAX_FIX_ROUNDS`
  (default 3, configurable as a repo variable) labels `sdlc:needs-human` and posts a comment.
- **Five new workflows** — `sdlc-fix.yml` (Builder fix loop), `sdlc-security.yml` (Claude
  opus deep security pass, advisory), `sdlc-qa.yml` (test suite, required check),
  `sdlc-plan.yml` (Planner on `agent:plan` issue label), `sdlc-release.yml` (CHANGELOG +
  version bump on branch; never tags/publishes/merges).
- **Auditor auto-on-open** — `sdlc-audit.yml` now fires on `opened`/`reopened` in addition
  to the `agent:audit` label, so every new PR gets a Codex cross-audit automatically.
- **`SDLC_BOT_TOKEN` chaining** — all write-capable workflows use a fine-grained PAT
  (Contents+PRs write) so that pushes and labels re-trigger the Reviewer. `setup.sh
  --secrets` sets it and prints creation guidance if unset.
- **Required-status-check merge gate** — `setup.sh --protect` now sets `review` and `qa` as
  required status checks (plus 1 code-owner approval). The Reviewer check goes red on
  `BLOCKING`; QA goes red on test failure. A PR cannot merge while either is red.
- **Self-hosted closed loop** — `sdlc/selfhosted/` variants of all new workflows run the
  same label-driven loop via `claude -p` / `codex exec` on a self-hosted runner. `SDLC_BOT_TOKEN`
  is still required for the loop to chain on self-hosted (model auth is keyless; workflow
  chaining is not).

### Changed
- `sdlc/agents.registry.md` — updated agent table (7 real agents, all now backed by
  workflows), loop diagram, label state machine, and governance invariants (`SDLC_BOT_TOKEN`
  + `SDLC_MAX_FIX_ROUNDS`).
- `docs/09-sdlc.md` — added "The closed loop" section with ASCII diagram, new 8-workflow
  table, `SDLC_BOT_TOKEN` setup guide, required-status-check details, round-cap behavior,
  fork-PR gating, and expanded troubleshooting.
- `README.md` Autonomous SDLC section — describes the closed loop and `SDLC_BOT_TOKEN`
  requirement; Status known-limits updated to match reality.
- **Verification honesty** — operating manual + engineer subagents now forbid claiming a
  check passed without running it (label **UNVERIFIED** instead), and make the delegator
  re-run the gate on returned work. `claude/settings.json` pre-approves the safe validators
  (`actionlint`, `shellcheck`, `yamllint`, `bash -n`) so background subagents can self-verify.

### Fixed (found by live smoke test on a real repo)
- **Reviewer exhausted its turn budget** (`error_max_turns`) by posting per-line inline
  comments via the action — switched to a single summary comment + structured verdict
  (matches the reliable self-hosted reviewer); raised `--max-turns` and added the missing
  `--max-budget-usd`.
- **Builder fix never landed** — `claude-code-action` does not auto-push on a
  `pull_request: labeled` event; added an explicit PAT-authed commit+push step to
  `sdlc-fix.yml` so the fix reaches the PR branch and re-triggers the Reviewer.
- Verified the full loop on a live private repo: buggy PR → review BLOCKING + qa red →
  `agent:needs-fix` → Builder auto-fixed + pushed → qa green → re-review CLEAN → gated on
  human merge. (Note: workflow updates must reach the PR head branch, not only `main`.)

### Validation / testing
- **`sdlc/selftest.sh`** — runnable unit tests for the loop's control logic (round-cap from
  labels, verdict parsing for both the hosted `structured_output`/jq path and the self-hosted
  `SDLC-VERDICT` grep path). 16 assertions; it caught and fixed an empty-`structured_output`
  edge in `sdlc-review.yml` (now normalizes to `CLEAN`).
- **CI gate** — `ci.yml` now runs `actionlint` (with embedded `shellcheck`) across all
  workflows + SDLC templates and executes `sdlc/selftest.sh`, so the pipeline validates
  itself on every push. Added `.github/actionlint.yaml` (declares the `compass` runner label).
- **`sdlc/SMOKETEST.md`** — repeatable live smoke-test checklist for the GitHub-native
  behavior that can't be unit-tested (App, `structured_output`, PAT chaining, the merge gate).

## [0.6.1] — 2026-05-25

### Security / hardening
- SHA-pin all GitHub Actions (`actions/checkout`, `claude-code-action`, `codex-action`) and add Dependabot to keep them current.
- Add `docs/alpha.md` (alpha onboarding); bump an internal repo + default marketplace pins to v0.6.0.

## [0.6.0] — 2026-05-25

### Added
- **Keyless cloud agents** (`sdlc/selfhosted/`) — review / audit / implement workflows that
  shell out to `claude -p` / `codex exec` on a self-hosted runner (your **subscription** — no
  API key or token). `setup.sh --self-hosted`. Statically validated in CI (actionlint + selftest); a live smoke-test checklist is provided.
- **One-command onboarding** — `setup.sh --all`: labels + workflows + CODEOWNERS + commit/push
  + secrets + branch protection (via the GitHub API).
- **Subscription auth for hosted runners** — workflows accept `CLAUDE_CODE_OAUTH_TOKEN`
  (`claude setup-token`) as an alternative to an API key.
- **README Status section** (alpha + known limits) and an alpha badge.

### Fixed
- `claude-code-action` workflows need `id-token: write` (OIDC) — added to review + implement.
- Orchestrator printed the Codex audit twice; deduped a `[profiles.deep]` that an earlier
  rename had duplicated in the local Codex `config.toml`.

## [0.5.0] — 2026-05-25

### Added
- **Autonomous SDLC pipeline** (`sdlc/`, `docs/09-sdlc.md`) — a governed roster
  (Planner · Builder · Reviewer · **Codex Auditor** · Security · QA · Releaser) with
  names/tags/gates. A **headless, task-ordered orchestrator** (`sdlc/orchestrate.sh`:
  plan → build → review → Codex audit → security → QA → open PR) and **GitHub-native
  workflows** (Claude review, Codex cross-audit, `@claude` implement). Humans keep the
  merge/deploy gate (branch protection + CODEOWNERS + required reviewers). Least-privilege
  tokens, no `pull_request_target` footgun, prompt-injection hardening, budget/loop guards,
  and a `/sdlc` command.

## [0.4.0] — 2026-05-25

### Changed
- **Renamed the project to `compass`** (repo, marketplace id, install paths, internal-repo pin);
  plugins now install as `core@compass` / `core-lsp@compass`. Added an SVG hero + animated
  demo GIF, a navigable README (clickable TOC, collapsibles, back-to-top), and open-source
  polish (Code of Conduct, Security policy, issue/PR templates). Fixed a `protect-paths`
  false positive that blocked legitimate `rm -rf` subpaths.

## [0.3.0] — 2026-05-25

### Added
- **Cited best practices** (`docs/07-practices.md`) — adopted verifiable guidance
  from Anthropic's best-practices page, agents.md, Karpathy, and `gstack`, mapped
  to where each lives here. Tightened `CLAUDE.md` with context hygiene,
  verify-as-highest-leverage, explore→plan→code→commit, and self-improving memory.
- **New-repo defaults** (`scripts/new-repo.sh`, `docs/08-defaults.md`) — global
  auto-apply, a per-repo scaffolder, a `newrepo` shell function, and the git
  `init.templateDir` note for hooks.

### Changed
- **CLAUDE.md ↔ AGENTS.md unified to one source** — `AGENTS.md` is now a symlink to
  `CLAUDE.md` (global + per-repo), so Claude and Codex read identical instructions.

## [0.2.0] — 2026-05-25

### Added
- **`core-lsp` plugin** — opt-in language-server intelligence
  (diagnostics + navigation) for Go (gopls), Rust (rust-analyzer), TypeScript
  (typescript-language-server), and Python (pyright). Separate plugin because it
  needs the language-server binaries on `PATH`. See `docs/06-lsp.md`.
- **Team-rollout pattern** — pin the marketplace to a tag and auto-enable the
  plugin from a shared repo's `.claude/settings.json`; per-user opt-out via
  `.claude/settings.local.json`. Documented and applied to an internal repo.

### Notes
- LSP is Claude-only — Codex has no native LSP config, so no LSP parity is claimed.

## [0.1.0] — 2026-05-25

First public release.

### Added
- **Global operating manual** (`claude/CLAUDE.md`) — core operating
  principles, safety hard-lines, and cost discipline; loads every session.
- **Guardrail + quality hooks** — `protect-paths` (PreToolUse: blocks secret
  writes, `rm -rf /`, `curl|sh`, force-push/hard-reset to protected branches),
  `format-on-edit` (PostToolUse), `inject-context` (SessionStart), `notify`.
- **9 cost-tiered subagents** — Haiku `test-runner`; Sonnet `code-reviewer`,
  `go-engineer`, `rust-engineer`, `docs-writer`, `k8s-operator`; Opus `architect`,
  `security-auditor`, `debugger`.
- **8 workflow commands** — `/ship` `/review` `/tdd` `/pr` `/adr` `/triage`
  `/scaffold` `/cost`.
- **`bootstrap-agent-config` skill** — drafts a grounded project `CLAUDE.md`.
- **Rich status line** — model · dir · git · context · session cost.
- **"Concise" output style** — terse, answer-first tone.
- **Codex parity** — `AGENTS.md` constitution + cost profiles (deep/standard/cheap),
  appended without clobbering existing Codex plugins/config.
- **MCP parity** — single-source `mcp/servers.json` → both tools; auto-registers
  context7, fetch, git; documents opt-in github (OAuth) and read-only postgres.
- **Installable plugin + marketplace** — `core@compass`,
  self-contained, regenerated from `claude/` via `make sync-plugin`.
- **Idempotent installer** with backups, `make doctor` validation, and `uninstall`.
- **CI** — validates JSON, frontmatter, plugin sync, and shellcheck on every push.

[0.8.0]: https://github.com/dshakes/compass/releases/tag/v0.8.0
[0.7.0]: https://github.com/dshakes/compass/releases/tag/v0.7.0
[0.6.1]: https://github.com/dshakes/compass/releases/tag/v0.6.1
[0.6.0]: https://github.com/dshakes/compass/releases/tag/v0.6.0
[0.5.0]: https://github.com/dshakes/compass/releases/tag/v0.5.0
[0.4.0]: https://github.com/dshakes/compass/releases/tag/v0.4.0
[0.3.0]: https://github.com/dshakes/compass/releases/tag/v0.3.0
[0.2.0]: https://github.com/dshakes/compass/releases/tag/v0.2.0
[0.1.0]: https://github.com/dshakes/compass/releases/tag/v0.1.0
