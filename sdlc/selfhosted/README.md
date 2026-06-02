# Keyless cloud agents via a self-hosted runner

These workflows run the SDLC agents **on your subscription** — they shell out to
`claude -p` and `codex exec` on a self-hosted runner, so **no API key and no token**
are needed. Same `claude -p` approach as the local `orchestrate.sh`, just triggered
by GitHub PR events.

## ⚠️ Security — required reading
A self-hosted runner **executes workflow code on your machine**. Therefore:
- Use **only on private repos** or with **fully trusted collaborators**.
- **Never** attach a self-hosted runner to a public repo that accepts fork PRs — that's
  arbitrary remote code execution on your machine. These workflows already refuse fork
  PRs (`head.repo == repo`), but the runner itself is the real boundary.
- Run the runner as a low-privilege user; the agents inherit that machine's access.

## 1. Register the runner (one time, machine where `claude`/`codex` are logged in)
GitHub generates exact, version-pinned commands + a token here:
**repo → Settings → Actions → Runners → New self-hosted runner** (pick macOS/Linux).
Run those commands, adding the **`compass` label** so these workflows target it:
```bash
# the config step from GitHub's page, plus:  --labels compass
./config.sh --url https://github.com/<owner>/<repo> --token <TOKEN> --labels compass --unattended
./run.sh                 # foreground; or:  ./svc.sh install && ./svc.sh start  (background service)
```
Ephemeral alternative (handles one job then exits — good for trying it out):
```bash
./config.sh --url …/<owner>/<repo> --token <TOKEN> --labels compass --ephemeral --unattended && ./run.sh
```
The runner must be able to run `claude` and `codex` (logged in) on its `PATH`.

## 2. Install the keyless workflows
```bash
cd <your-repo>
~/compass/sdlc/setup.sh --self-hosted     # installs these in place of the hosted (Action) ones
```

## 3. Use it

The closed loop works the same as on hosted runners:

- Open a PR → **Reviewer** (`claude -p`) runs on every push. If it finds Blocking issues it
  labels `agent:needs-fix`, which triggers the **Builder** (`claude -p`) to fix on the PR
  branch and push — re-running the Reviewer. Repeats up to `SDLC_MAX_FIX_ROUNDS` (default 3),
  then labels `sdlc:needs-human`.
- Add the **`agent:audit`** label → **Auditor** (`codex exec`) posts an independent audit.
- Comment **`@claude <task>`** → **Builder** (`claude -p`) implements on a branch + opens a PR.
- Label an issue **`agent:plan`** → **Planner** posts a plan comment.

**The "keyless" part is model authentication** — no API key or token needed for Claude/Codex
to run. The loop still needs **`SDLC_BOT_TOKEN`** (a fine-grained PAT: Contents+PRs write) to
chain: a push made with the default token will not re-trigger the Reviewer. Set it once:
```bash
gh secret set SDLC_BOT_TOKEN
```
Without it, the loop degrades gracefully to one review + one fix, then waits for a human push.

Your subscription does the model calls; humans keep the merge gate as always.

## Hosted-only workflows (not provided self-hosted)

- **sdlc-autoapprove** — auto-approve stays on hosted with the trusted-author allowlist;
  auto-approving on a self-hosted runner is riskier (the runner inherits broader machine
  access) and is intentionally omitted.
- **release** — the release workflow is a hosted GitHub Actions pipeline and is not
  ported to self-hosted.

Everything else mirrors the hosted logic on a keyless self-hosted runner. When in doubt,
check `sdlc/workflows/` for the canonical hosted versions.
