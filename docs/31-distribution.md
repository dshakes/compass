# Distribution — install, repair, uninstall, listings

## One-line verified install

The `compass` CLI (doctor, bench, redteam, gate…) comes only from these installs (clone/quickstart, this script, or Homebrew); the Claude Code plugin ships hooks, agents and commands but no CLI.

```bash
curl -fsSL https://raw.githubusercontent.com/dshakes/compass/main/install-remote.sh | bash
# pin a version / pass install.sh flags:
curl -fsSL https://raw.githubusercontent.com/dshakes/compass/main/install-remote.sh | COMPASS_VERSION=v2.3.0 bash -s -- --copy
```

`install-remote.sh` downloads the release tarball and runs the same check as `compass verify`
(`gh attestation verify … --signer-workflow …/release-sign.yml`) **before** extracting or running
it. It fails closed: with no `gh` (>= 2.49) it refuses, and prints the manual verify command.
`--no-verify` skips the check explicitly. It unpacks to `~/.compass/src` and runs `install.sh`.

What this does *not* cover: the installer script itself. `curl | bash` runs `install-remote.sh`
straight from GitHub over HTTPS, before any attestation check. Read it first
(`curl -fsSL …/install-remote.sh | less`), or clone the repo and run `compass verify` yourself.

## Install record, repair, uninstall

`install.sh` writes `~/.compass/install.json`: version, git sha, mode (symlink/copy), timestamp and
every path it created (symlinks, copies, the PATH line, config blocks). Re-installing updates it.

- `compass repair [--dry-run]` re-creates recorded links/files that are missing or dangling, never
  touches a path that now holds something else, then re-runs `compass drift`.
- `scripts/uninstall.sh [--dry-run]` removes exactly the recorded entries. A copy you edited is
  backed up to `~/.claude/backups/compass-uninstall-*` first. With no record it falls back to the
  legacy name list.

## Budget cap only

Claude Code's `--max-budget-usd` applies to print mode (`-p`) only. For an interactive session
hard cap, install just the budget gate:

```bash
./install.sh --only budget          # links budget-gate.sh into ~/.compass/budget/; edits nothing in ~/.claude
export COMPASS_MAX_USD=5            # per session   (COMPASS_MAX_USD_DAY=20 for a daily cap)
```

Then add this to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "$HOME/.compass/budget/budget-gate.sh" }] }
    ]
  }
}
```

Once the estimated spend reaches the cap, tool calls are denied until you raise it or start a new
session. It fails open when no cap is set or spend is unknown; it is a cost guardrail, not a security
boundary.

## Marketplace listing checklist (manual, human-published)

Run first: `claude plugin validate plugins/core`, `scripts/sync-plugin.sh --check`, `scripts/check-vendor.sh`,
`make doctor`, and `compass verify` on the tag you are listing.

- **Claude Code**: users add the repo as a marketplace (`/plugin marketplace add dshakes/compass`,
  then `/plugin install compass@compass`). For a curated directory, submit through that directory's
  own form; the manifests are `.claude-plugin/marketplace.json` and `plugins/core/.claude-plugin/plugin.json`.
- **Codex**: users add the repo with `codex plugin marketplace add dshakes/compass`, then `/plugin install`.
  Confirm that path works against the tag you are listing before pointing anyone at it.
- **Gemini CLI**: the extension is `gemini-extension.json` at the repo root; users install with
  `gemini extensions install https://github.com/dshakes/compass`. Confirm the version matches
  (`scripts/check-vendor.sh`) before tagging.

Listing is a publish step: do it by hand after the release is signed and verified.

### Checklist status (2026-11-01, main)

`claude plugin validate plugins/core` → passes with **0 warnings** (the 9 unquoted
`${CLAUDE_PLUGIN_ROOT}` hook commands are now quoted) · `sync-plugin.sh --check` → in sync ·
`check-vendor.sh` → versions match · `make doctor` → 0 warn / 0 error · `compass verify` →
provenance verified on the latest release. The only remaining step is the submission itself.

### Listing copy (paste-ready; numbers are reproducible with the commands shown)

**One line.** Guardrails, a hard budget cap, and a self-fixing PR loop for your coding agent —
every safety claim scored in CI, every release provenance-verified before it runs. You always merge.

**Short.** compass is a local-first config layer for Claude Code, Codex and Gemini. It blocks
catastrophic commands and secret writes *before they run* (`compass bench` → 100% P/R on a
labeled corpus that gates CI), hard-stops the session at your dollar cap (`COMPASS_MAX_USD=5`),
scans prompts, fetched pages and MCP tool results for prompt-injection (held-out: 21% recall /
100% precision for rules alone, 41% with the optional local classifier — intervals printed), and
runs a review → security → test → fix loop on every PR until it's green. Install is verified against
keyless SLSA provenance before anything is extracted; the scanners emit SARIF for code scanning.
Readable shell, no service, fully reversible.

**Why install from here and not a look-alike.** `compass verify` checks the release attestation;
`install-remote.sh` refuses to run anything that fails it.
