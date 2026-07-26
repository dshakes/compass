# Making this the default for new repos

There are two layers: the **global** layer (applies everywhere automatically) and
the **per-repo** layer (committed, shared with a team).

## 1. Global — already automatic everywhere
After `make install`, `~/.claude/CLAUDE.md` loads in **every** Claude Code session
in any directory, and `~/.codex/AGENTS.md` (a symlink to the same file) loads for
Codex. You don't scaffold anything per repo to get the operating manual, hooks,
subagents, commands, skills, status line, and MCP servers — they're global. This
is the main answer to "make it the default."

## 2. Per-repo — committed CLAUDE.md / AGENTS.md (+ optional team pin)
A repo-specific `CLAUDE.md` (build/test commands, invariants) is worth committing.
`git init.templateDir` **can't** do this — it only seeds `.git/` (hooks/excludes),
not working-tree files. Use the scaffolder instead:

```bash
~/compass/scripts/new-repo.sh ./my-service          # starter CLAUDE.md + AGENTS.md symlink
~/compass/scripts/new-repo.sh ./my-service --team   # also pins compass@compass
```

Then fill `CLAUDE.md` from the real code with Claude's `/init` or the
`bootstrap-agent-config` skill.

### Make it a one-word command
Add to `~/.zshrc` (or `~/.bashrc`):
```bash
newrepo() { ~/compass/scripts/new-repo.sh "$@"; }
```
Now `newrepo ./thing` or `newrepo ./thing --team` anywhere.

### Seed git hooks into every new repo (optional)
`init.templateDir` *is* the right tool for `.git/` contents like a pre-commit hook:
```bash
mkdir -p ~/.git-template/hooks
git config --global init.templateDir ~/.git-template
# put an executable hook at ~/.git-template/hooks/pre-commit
```
Every future `git init`/`git clone` copies it into `.git/hooks/`. (This is separate
from CLAUDE.md, which lives in the working tree.)

## 3. One source for Claude + Codex (cross-tool)
`AGENTS.md` is the open standard Codex and 20+ other agents read; `CLAUDE.md` is
Claude Code's. To avoid drift, keep **one file**:
- **Global:** `~/.codex/AGENTS.md` is a symlink to `~/.claude/CLAUDE.md` — byte-identical.
- **Per-repo:** `AGENTS.md` → `CLAUDE.md` symlink (the scaffolder and the bootstrap
  skill do this; an internal repo is set up this way).

Edit the manual once; both tools pick it up. See `docs/07-practices.md` for why
this is convention rather than a spec requirement.
