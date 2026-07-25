# ADR 0007 — Agent identity and attestation for SDLC roles

- **Status:** **Proposed**
- **Date:** 2026-07-25
- **Deciders:** Shekhar Mudarapu
- **Refines:** agent-trace provenance (ADR-0006), the autonomous loop trust boundary
  (ADR-0002), and roadmap §15

## Context

compass's SDLC loop assigns four roles — Builder, Reviewer, Security, QA — each
running as a distinct GitHub Actions job. Today the outputs of those jobs are
distinguished only by convention: the job name, the prompt the job loads, and the
commit author field. No cryptographic assertion binds a given output to the role
that produced it.

That gap has two concrete failure modes:

1. **Replay / confusion.** A Reviewer verdict is a PR comment; a Builder commit is a
   git object. Either could be attributed to the wrong role without detection.
   A malicious (or buggy) orchestration step could present a Builder output as if
   a Reviewer had signed off.

2. **Privilege creep.** Per-role least-privilege scoping (Builder may push to the
   feature branch; Reviewer may not) cannot be enforced at the infra level if the
   infrastructure cannot verify which role is running.

This maps to **OWASP Agentic Security Initiative ASI03: Agent Identity and Privilege
Abuse** — the failure mode where agents can impersonate each other or escalate beyond
their intended role.

The Agent Trace record (`compass trace`, ADR-0006) already captures `metadata.role`
and `metadata.run_id`, but the record is best-effort: it records what the environment
*claims*, and a signature on the record proves who *attached* the note, not which
role produced the underlying output. The missing layer is a short-lived,
infrastructure-issued identity tied to the role at the moment of the run.

SPIFFE (Secure Production Identity Framework For Everyone) provides exactly this
pattern: a SPIRE agent on each workload issues short-lived X.509 SVIDs (SPIFFE
Verifiable Identity Documents) whose URI SAN encodes the workload's identity —
e.g. `spiffe://compass/sdlc/reviewer/<run-id>`. A downstream consumer can verify
the SVID against the trust root without trusting the commit author field or the
job name.

Choosing a SVID issuance scheme, an embedding point, and a verification contract
crosses a trust-boundary design decision that outlives the code — hence an ADR.

## Decision

**Not building yet** (see trigger below). The proposed design, to be implemented
when the trigger is met:

1. **One SVID per SDLC role per run.** A SPIRE agent on the Actions runner (or an
   equivalent GitHub OIDC → SPIRE bootstrap) issues a short-lived SVID to each job
   at start:
   - `spiffe://compass/sdlc/builder/<run-id>`
   - `spiffe://compass/sdlc/reviewer/<run-id>`
   - `spiffe://compass/sdlc/security/<run-id>`
   - `spiffe://compass/sdlc/qa/<run-id>`

2. **Identity embedded in the Agent Trace record.** `compass trace emit` reads the
   SVID (or its SHA-256 hash) from a well-known env var (`COMPASS_TRACE_SVID`) and
   writes it into `metadata.identity`. When `COMPASS_TRACE_SIGN=1`, the cosign
   signature over the record then transitively covers the identity claim.

3. **`compass trace verify` checks identity when present.** The verify subcommand
   already checks well-formedness and the cosign signature. It will additionally
   check that `metadata.identity` parses as a valid SPIFFE URI matching the expected
   role pattern — non-blocking if the field is absent (backward-compatible with
   unsigned records from before this ADR).

4. **Downstream gate consumes the identity.** A future merge gate (or a
   `compass trace verify --require-role reviewer` flag) can require that a Reviewer
   SVID is present and verified before merging. The human merge gate is unchanged —
   this adds a machine-readable pre-check, not a new authority.

## Consequences

**Enables:**
- Cryptographic per-role attribution: "this Reviewer verdict was produced by the
  Reviewer job on run `abc123`," verifiable against the SPIRE trust root.
- Infrastructure-enforced role separation: a Reviewer SVID cannot be used to push
  commits; the runner's SVID scope controls what the role is allowed to do.
- Closes OWASP ASI03 at the compass SDLC boundary.
- Composes cleanly with ADR-0006: identity becomes an additional signed field in the
  existing Agent Trace record, no new storage format.

**Costs:**
- Requires external infrastructure: a SPIRE server + agent, or a GitHub OIDC issuer
  configured to emit role-scoped tokens (not a built-in GitHub primitive — custom
  claims require a custom issuer).
- SVIDs are short-lived; `compass trace attach` must run before the SVID expires (or
  the hash must be captured at job start and embedded before the job exits).
- Does not prevent a fully compromised runner from forging its SVID — the trust root
  (SPIRE server) is external infrastructure that must be secured separately.
- Adds an optional external dependency (SPIRE) that is deliberately absent today.

**Deliberately NOT:**
- A replacement for the human merge gate (ADR-0002) — that gate is permanent.
- A guarantee that the AI actually performed the role faithfully — identity proves
  *who ran*, not *what they decided*.

## Alternatives considered

**Git commit signing alone** (`SDLC_SIGN=1` in `orchestrate.sh`) — insufficient.
Commit signing proves that *a specific key* signed the commit; it does not distinguish
compass SDLC roles. Builder and Reviewer would share the same signing key (the
Actions runner's key), so a Reviewer verdict is indistinguishable from a Builder
commit at the crypto layer. Signing is per-actor, not per-role, and does not cover
non-commit outputs (PR comments, Agent Trace records).

**GitHub OIDC job identity** (`id-token: write` on the workflow) — partial. GitHub's
OIDC token is already available on every Actions runner and scopes to the job and
workflow. It proves "this ran in a GitHub Actions job on this repo at this SHA." It
does not distinguish compass SDLC *roles* within a workflow — Builder and Reviewer
jobs would receive tokens with the same `job_workflow_ref` if they live in the same
workflow file. It can serve as the bootstrap credential for a SPIRE trust domain,
but a full per-role SVID still requires a custom issuer or SPIRE. GitHub OIDC is
the right first step; full SPIFFE identity is the complete solution.

## Not building until

All three conditions are met:

1. A real downstream consumer — a merge gate, an audit system, or an external
   compliance requirement — needs cryptographic per-role attestation. The current
   convention-based attribution is sufficient until someone needs to verify it
   programmatically.

2. The SDLC agent-team primitive stabilizes enough that role boundaries within a
   single orchestration run are well-defined and stable (roadmap §12 and §15 are
   co-dependent here).

3. An operator is running SPIRE or a compatible OIDC issuer that can be configured
   with compass's role URI scheme — or GitHub adds native per-job role scoping to
   its OIDC token claims, which would reduce the external infra requirement to zero.
