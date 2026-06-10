# ADR 0006 — Agent Trace provenance for AI-assisted commits

- **Status:** **Accepted** (shipped — opt-in, per-commit)
- **Date:** 2026-06-10
- **Deciders:** Shekhar Mudarapu
- **Refines:** release provenance (`compass verify`, release-sign.yml) and the
  human-merge-gate principle (ADR-0002, docs/17)

## Context

compass already proves *release* provenance (keyless SLSA attestations on tarballs),
but says nothing about *code* provenance: which lines of a commit an AI agent wrote,
with which tool and model, in which session. That gap matters more every quarter —
review policy ("AI-assisted diffs get a stricter pass"), incident forensics ("which
agent session introduced this line?"), and machine-readable AI-disclosure expectations
(e.g. the EU AI Act's transparency direction) all want the same record.

The Agent Trace specification (https://github.com/cursor/agent-trace, CC BY 4.0,
multi-vendor) defines exactly that record: JSON linking file line ranges to the
conversation/tool/model that produced them. It is deliberately unopinionated about
storage and says nothing about integrity — an unsigned attribution record can be
fabricated or stripped. Nobody in the ecosystem combines the open record with signing.
Choosing a record format + a storage location + a signing scheme crosses a design
boundary that outlives the code, so it gets an ADR.

## Decision

Ship `compass trace` (`scripts/compass-trace.sh`): **emit open-spec Agent Trace
records, store them as git notes, sign opportunistically, never block a commit.**

1. **The open spec, faithfully.** Records use the Agent Trace field names
   (`version`/`id`/`timestamp`/`vcs`/`tool`/`files[].conversations[].contributor.model_id`
   /`ranges`), not a compass-private schema — records interoperate with any consumer
   of the spec. compass-specific bits (repo, session id) live in `metadata`.
2. **Git notes as storage** (`refs/notes/agent-trace`): travels with the repo, no
   server, no new files in the tree, strippable/shareable explicitly
   (`git push origin refs/notes/agent-trace`). Records are deterministic per commit
   (id derived from the sha, timestamp = committer time), so attach is idempotent.
3. **Opportunistic signing**: with cosign present and signing requested, the record
   blob is signed (`cosign sign-blob`, key via `COSIGN_KEY` or keyless) and the
   signature stored under `refs/notes/agent-trace-sig`. No cosign → attach still
   works; `verify` reports "unsigned" with a warning and **still passes**.
4. **Never a gate.** `compass trace verify` is evidence for humans and CI to *read*;
   it does not hook the commit path, and the human merge gate is unchanged (ADR-0002).

## Consequences

- **Enables:** verifiable per-commit AI attribution (`emit`/`attach`/`show`/`verify`),
  forensics from line range → session, policy that keys off provenance, and a
  machine-readable disclosure artifact in an open, vendor-neutral format.
- **Costs:** notes don't push by default (sharing is an explicit `git push` of the
  ref); attribution is **best-effort** — it records what the environment claims
  (tool/model/session env vars), and a signature proves *who attached* the record,
  not that the AI actually wrote those lines; rebases rewrite shas and orphan notes.
- **Deliberately NOT:** a commit hook, a tamper-proof audit system, or a compliance
  guarantee. Unsigned records are honest hints; signed records are evidence. The
  human merge/deploy gate remains the real control. See docs/19-provenance.md.
