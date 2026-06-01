---
name: harden
description: Run the toolkit's security commands in order to surface secrets, MCP supply-chain issues, install drift, release provenance gaps, and untrusted-code risks before shipping. Use before opening a PR, after adding a dependency, or whenever the security posture needs a fresh check.
argument-hint: "[optional: -- <cmd> to sandbox-test a specific command]"
allowed-tools: Read, Grep, Glob, Bash
---

# Harden — security sweep in five ordered steps

Run each command in sequence. Stop on a non-zero exit and fix the finding before
proceeding. All five must pass before the branch is considered hardened.

## Steps

### 1 · Secrets — `compass scan --staged`
Scan the staged diff for secrets at the commit boundary.

```
compass scan --staged
```

Exits 0 (clean) or 1 (secrets found). Fix: remove the secret, rotate the
credential, then re-stage. Add an `# allowlist secret` comment ONLY for
confirmed test fixtures — never real credentials.

### 2 · MCP supply-chain pins — `scripts/check-mcp.sh`
Verify every auto-installed MCP server is pinned to an exact version and that
no `@latest` float or shell-injection marker has crept in.

```
bash scripts/check-mcp.sh
```

Exits 0 (pinned + clean) or non-zero (floating version or injection marker).
Fix: pin the version in `mcp/servers.json` and re-run. (`setup-mcp.sh` runs this
same audit as a pre-flight, and `compass doctor` includes it.)

### 3 · Install fidelity — `compass drift`
Check that the installed `~/.claude` config still matches this repo's source.
Catches hand-edited copies, stale hooks, and non-executable guardrail scripts.

```
compass drift
```

Exits 0 (in sync) or non-zero (drift detected). Fix: re-run `quickstart.sh`
or remove the hand-edited file and let the install re-link it.

### 4 · Release provenance — `compass verify`
Verify the latest release tarball's keyless SLSA attestation. Requires `gh`.

```
compass verify
```

Exits 0 (attestation valid), 77 (gh lacks attestation support — skip), or
non-zero (attestation missing or invalid). A 77 is a safe skip on old gh
versions; anything else is a provenance gap to investigate.

### 5 · Untrusted code — `compass sandbox -- <cmd>`
Run any untrusted command inside a real OS sandbox (no network, writes confined
to cwd/tmp via bwrap/firejail/sandbox-exec). Required before executing code
fetched from external sources.

```
compass sandbox -- <cmd>
```

Exits 0 (ran confined), 2 (usage error — supply a command), or non-zero if the
sandboxed command itself fails. If no backend is available the CLI refuses to
run the command unconfined — install bwrap or firejail first.

## Notes
- Run the five steps in order; each one gates the next in severity.
- `compass scan --staged` should also be wired as a pre-commit hook
  (`compass scan --staged` in `.git/hooks/pre-commit`) for continuous coverage.
- Security (`compass scan`, `compass verify`) and drift detection (`compass drift`)
  are also surfaced in `compass dashboard` for a fleet-wide view.
- This skill does not replace a full `/security-review` — it gates the mechanical
  checks. Run `/security-review` on the diff for human-judgment findings.
