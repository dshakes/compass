# Distribution — install, repair, uninstall, listings

## One-line verified install

```bash
curl -fsSL https://raw.githubusercontent.com/dshakes/compass/main/install-remote.sh | bash
# pin a version / pass install.sh flags:
curl -fsSL https://raw.githubusercontent.com/dshakes/compass/main/install-remote.sh | COMPASS_VERSION=v2.2.0 bash -s -- --copy
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
