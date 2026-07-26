# Distributing as a plugin + marketplace

*Install the subagents, commands, skills, and guardrail hooks with two slash commands — and know what only the full install carries.*

This repo is **also a Claude Code plugin marketplace**, so teammates can install
the machinery with two commands instead of cloning + `make install`.

```
compass/                         # ← the marketplace (repo root)
├── .claude-plugin/marketplace.json     # lists the plugins
└── plugins/
    └── core/             # ← the plugin (self-contained, real files)
        ├── .claude-plugin/plugin.json
        ├── agents/  commands/  skills/  output-styles/
        ├── hooks/   ( *.sh + hooks.json wired with ${CLAUDE_PLUGIN_ROOT} )
        └── .mcp.json   ( context7, fetch, git )
```

## Install (teammates)
```bash
/plugin marketplace add dshakes/compass       # GitHub owner/repo
/plugin install compass@compass
```
Local testing from a clone:
```bash
/plugin marketplace add ./compass
/plugin install compass@compass
```

## Other agents — native installs (one source)

The operating manual and the version-pinned MCP servers are shared across agents, each
in the format that tool expects — kept in sync by symlinks + `scripts/check-vendor.sh`:

```bash
# Codex — native plugin marketplace (.codex-plugin/plugin.json + .agents/plugins/marketplace.json)
codex plugin marketplace add dshakes/compass   # then: /plugin install  (browse with /plugins)

# Gemini CLI — native extension (gemini-extension.json → GEMINI.md + context7/fetch/git MCP)
gemini extensions install https://github.com/dshakes/compass

# Codex (own the files instead) — symlinks ~/.codex/AGENTS.md + config.toml profiles
make install            # or ./install.sh --codex-only

# Gemini global context instead of the extension: ~/.gemini/GEMINI.md
./install.sh --gemini

# Cursor · Copilot · OpenCode · Windsurf — read the repo's AGENTS.md (the agents.md standard)
make install            # clone first; AGENTS.md is a symlink of the same manual
```

`GEMINI.md`, `AGENTS.md`, and `CLAUDE.md` are **one file** (symlinks). `gemini-extension.json`'s
version + MCP servers are CI-checked against `plugins/core` and `mcp/servers.json` so a vendor
manifest can never silently drift from the real config.

## What the plugin delivers
15 subagents · 12 commands · 8 hooks (guardrail · inject-context · red-team ×3 · budget-gate · format-on-edit · notify) ·
`bootstrap-agent-config` skill · "Concise" output style ·
3 MCP servers. Validated via `claude plugin details compass@compass`
(≈1,165 always-on tokens; agents/commands cost only when invoked).

## What the plugin **cannot** carry — and why both methods exist
Claude Code plugins cannot ship user-level **memory, permissions, model defaults,
or a global status line**. So:

| | `make install` | plugin |
|---|---|---|
| Subagents, commands, skills, hooks, output style, MCP | ✓ | ✓ |
| `CLAUDE.md` operating manual (loaded every session) | ✓ | ✗ |
| Permission posture (`acceptEdits`, allow/deny) | ✓ | ✗ |
| Model / effort defaults | ✓ | ✗ |
| Rich status line | ✓ | ✗ |
| Codex parity (`AGENTS.md`, profiles) | ✓ | ✗ |

**Use one method, not both at once** — running the plugin alongside `make install`
double-fires the hooks and double-registers the MCP servers. For the full
experience, `make install`. For zero-friction team rollout of the machinery, the
plugin. A common pattern: individuals `make install`; a shared repo pins the
plugin in its project `.claude/settings.json` so everyone on that repo gets it.

## Maintaining the plugin
The plugin ships **real files** (cross-repo symlinks aren't reliably followed by
the loader), generated from the canonical `claude/` source:
```bash
make sync-plugin     # regenerate plugins/core/ from claude/
make doctor          # warns if the plugin has drifted from claude/
```
Authored, plugin-only files (`hooks/hooks.json`, `.mcp.json`, `plugin.json`) are
preserved by the sync. Bump `version` in `plugin.json` when you cut a release.

## Submitting to the official plugin directory
The in-tool `/plugin > Discover` directory is the highest-leverage distribution
channel — it's where most users browse, with near-zero install friction. Listing
is by review, via the submission form (a web form; not a PR or `gh` action), and
clears a quality + security bar. Before submitting, confirm the readiness gate:

- [ ] `make doctor` is **0 error** and `scripts/sync-plugin.sh --check` says *in sync*.
- [ ] `.claude-plugin/marketplace.json` and `plugins/core/.claude-plugin/plugin.json`
      both validate and carry `name`, `owner`/`author`, `homepage`, `repository`,
      `license`, `description`, `keywords`, `category` (they do — CI-checked).
- [ ] `plugin.json` `version` matches the latest release tag (CI gate: `check-vendor.sh`).
- [ ] The README leads with the one differentiator and a reproducible-in-30s demo;
      the network-egress table (which servers phone where) is honest and visible —
      undisclosed network calls are a common rejection reason.
- [ ] A short demo (GIF/clip) of the governance moment is linked from the README.

Then submit the marketplace at the directory form and link the repo. Re-run the
sync + doctor gate after every release so the listed plugin never ships stale files.
