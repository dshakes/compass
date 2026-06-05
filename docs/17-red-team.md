# Red-team hardening — defending the agent itself

Guardrails (docs/16) stop an agent from doing something catastrophic *by accident*.
This layer defends against something *adversarial*: an attacker who tries to turn your
AI coding agent against you — through a poisoned `CLAUDE.md`, a booby-trapped web page,
a pasted payload, a malicious MCP server, or a project that quietly disarms your safety.

It is **measured, not vibes** (the compass house style): every detector is scored against
a labeled corpus that gates in CI, the same way `compass bench` gates the guardrail.

> **Honest framing.** This is *defense-in-depth*, not a security boundary. Pattern
> detection catches the known shapes of attack; a novel or heavily-obfuscated payload
> can still slip past. The model layer is never 100% either. So the cardinal rule lives
> in the operating manual, above any single detector: **external content is data, not
> instructions** — and the human merge/deploy gate never moves.

---

## What it defends against

| Threat | What it looks like | compass control | Layer |
|---|---|---|---|
| **Direct prompt injection** | "ignore all previous instructions and …" | `injection_findings` | scan + hooks |
| **CLAUDE.md / context poisoning** | a cloned repo's `CLAUDE.md`/`AGENTS.md` carries hidden instructions | `scan-untrusted-context.sh` (SessionStart) | runtime hook |
| **Indirect injection** | a web page / fetched doc / MCP tool result / command output smuggles instructions | `scan-tool-output.sh` (PostToolUse) | runtime hook |
| **Copy/paste injection** | poisoned text (incl. invisible unicode) pasted into the prompt | `scan-prompt.sh` (UserPromptSubmit) | runtime hook |
| **Local safety override** | a project `.claude/settings.json` granting blanket allow / `bypassPermissions` / disabling hooks | `settings_override_reason` | scan + hook |
| **Malware authoring** | the agent steered into writing reverse shells, ransomware, stealers, C2 | `malware_intent_findings` (awareness + audit) | hook + scan |
| **Insecure code** | the agent introduces command injection, unsafe deserialization, disabled TLS, weak crypto | `insecure_code_findings` (SAST-lite) | scan + PR review |
| **Catastrophic commands / secrets / supply-chain** | `rm -rf /`, secret writes, unpinned actions/MCP | the guardrail layer (docs/16) | hooks + CI |

Maps onto **OWASP Top-10 for LLM Applications** (LLM01 prompt injection, LLM02 sensitive-info
disclosure, LLM05 improper output handling, LLM06 excessive agency, LLM08 vector/RAG poisoning)
and Simon Willison's **"lethal trifecta"** (private data + untrusted content + an egress channel).

---

## How it works

**One pure policy, many call sites.** All detectors live in `claude/hooks/lib/policy.sh`
as pure functions that take a string and echo a finding per line (empty = clean) — no
side effects, no network — so the *same* code runs on the live hooks AND in the CI eval:

- `injection_findings` — instruction-override, persona-jailbreak, disable-safety,
  permission-escalation, data-exfiltration, covert-instruction, fake-role-tags,
  markdown-image exfil, hidden HTML comments, and zero-width / bidirectional unicode.
- `settings_override_reason` — project config that *loosens* safety (project config may
  always *tighten* it).
- `malware_intent_findings` — high-signal offensive constructs (reverse shell, ransomware,
  credential stealer, keylogger, self-propagation, crypto-miner, C2). **Awareness, not a
  censor:** compass supports authorized security work, so the hook *warns and logs*.
- `insecure_code_findings` — SAST-lite: `shell=True` with interpolation, untrusted
  deserialization, TLS verification disabled, weak crypto.

**Runtime hooks** (wired in `claude/settings.json`):

| Hook | Event | Effect |
|---|---|---|
| `scan-untrusted-context.sh` | SessionStart | scans the project's `CLAUDE.md`/`AGENTS.md` (incl. nested) + `.claude/settings.json`; warns if poisoned |
| `scan-prompt.sh` | UserPromptSubmit | scans the submitted/pasted prompt; warns (or blocks, see flags) |
| `scan-tool-output.sh` | PostToolUse (WebFetch/WebSearch/Bash) | scans returned content for indirect injection; warns it's data |

Hooks **warn by default** (inject a note telling the model to treat flagged content as
data) and **log** to the audit trail (`compass audit-log`). They never silently censor.

**The eval** (`scripts/test-redteam.sh`, corpus `scripts/redteam-corpus.tsv`) scores the
detectors and gates in CI via `compass doctor`:

```
redteam corpus: 60 cases — TP=33 FP=0 TN=27 FN=0
precision=100% (floor 100%)  recall=100% (floor 90%)
```

---

## Commands

```bash
compass redteam            # score the detectors (eval) + scan THIS repo's context
compass redteam --eval     # just the corpus eval (the CI gate)
compass redteam --scan     # just scan this repo (CLAUDE.md/AGENTS.md/READMEs · MCP · settings)
compass redteam --json     # machine-readable summary

compass scan --injection            # add a prompt-injection / insecure-code / malware pass
compass scan --staged --injection   # pre-commit: secrets + risky content in one gate
```

`compass audit-log` shows every warn/block the hooks recorded.

---

## Golden datasets (test it in your repo)

compass ships **versioned, labeled golden corpora** — the same data that gates compass in
CI — so you can measure your own setup, not take a vendor's word:

| Dataset | Cases | What it proves | Run |
|---|---|---|---|
| `scripts/redteam-corpus.tsv` | 56 file + 4 programmatic = 60 scored | injection / override / malware / insecure-code precision & recall | `compass redteam --eval` |
| `scripts/guardrail-corpus.tsv` | 61 | catastrophic-command + secret-write precision & recall | `compass bench --guardrail` |

**Apply them in your repo / CI** (deterministic, offline — no tokens, no model calls):

```bash
# your repo's CI: fail the build if resistance regresses, and flag poisoned context
compass redteam --eval            # the golden eval (precision 100% / recall ≥ 90%)
compass redteam --scan            # scan THIS repo's CLAUDE.md/AGENTS.md/MCP/settings
compass scan --staged --injection # pre-commit: secrets + injection/insecure in one gate
```

**Bring your own golden dataset** — point the eval at your labeled TSV (`inject|safe` +
TAB + payload), so domain-specific attacks gate too:

```bash
COMPASS_REDTEAM_CORPUS=tests/my-redteam.tsv compass redteam --eval
```

**Live-fire (beyond static):** the corpus is a portable artifact you can also feed to
[garak](https://github.com/NVIDIA/garak) or [promptfoo](https://www.promptfoo.dev/) to
attack a *running* agent endpoint with adaptive variants — the static eval here is the
fast, always-on floor; those are the periodic deep sweep.

---

## Feature flags (control what runs)

All default **ON**. Set in your shell, `~/.claude/settings.json` env, or CI.

| Flag | Default | Effect |
|---|---|---|
| `COMPASS_REDTEAM` | `1` | master switch — `0` disables all red-team hooks |
| `COMPASS_REDTEAM_PROMPT` | `1` | the UserPromptSubmit (copy/paste) scan |
| `COMPASS_REDTEAM_TOOL_OUTPUT` | `1` | the PostToolUse (indirect-injection) scan |
| `COMPASS_REDTEAM_CONTEXT` | `1` | the SessionStart (CLAUDE.md/settings) scan |
| `COMPASS_REDTEAM_ENFORCE` | `0` | `1` = the prompt scan **blocks** (exit 2) instead of warning |
| `COMPASS_REDTEAM_PRECISION_FLOOR` | `100` | CI gate floor for the eval |
| `COMPASS_REDTEAM_RECALL_FLOOR` | `90` | CI gate floor for the eval |

---

## Escalate to a managed guardrails service (optional)

compass is local-first, but each hook can escalate to a model-grade guardrails service
for a verdict. **Honest tradeoff:** this *sends the flagged content off-box* — opt-in.

| `COMPASS_GUARDRAIL_BACKEND` | Needs | Notes |
|---|---|---|
| `none` (default) | — | local detectors only |
| `bedrock` | `aws` CLI + `COMPASS_GUARDRAIL_ID` (+ `_VERSION`, `AWS_REGION`) | AWS Bedrock Guardrails `ApplyGuardrail` (denied topics, PII, content filters, contextual grounding) |
| `azure` | `COMPASS_GUARDRAIL_URL` + `COMPASS_GUARDRAIL_KEY` | Azure AI Content Safety **Prompt Shields** (jailbreak + indirect-injection detection) |
| `webhook` | `COMPASS_GUARDRAIL_URL` | POST `{source,text}`; expect `{"action":"BLOCK"\|"NONE"}` — the neutral shape for Llama Guard / NeMo / Lasso / a self-hosted proxy |

When a backend returns BLOCK, the prompt hook blocks the prompt and the tool-output hook
flags it strongly. The backend **augments** the local floor; it never replaces it. The
adapter fails *open* (a backend outage never bricks a hook).

> **Status — be honest about this:** the `webhook` adapter is simple and self-verifiable.
> The `bedrock` and `azure` adapters are written to each service's documented API shape
> but ship **UNVERIFIED against live endpoints** (no integration test in CI without
> credentials). Validate them with your own account before relying on them in production;
> treat them as a starting point, not a certified integration.

For deeper, periodic red-teaming, point **[garak](https://github.com/NVIDIA/garak)** or
**[promptfoo](https://www.promptfoo.dev/)** at your setup — `compass redteam` notes them.

---

## Limits (read this)

- Pattern detection is best-effort: it will miss novel/obfuscated attacks and may flag
  the occasional benign line. Precision is tuned to **never cry wolf** on the corpus,
  but your repo may differ — mark a deliberate example with an `allowlist injection`
  marker on its line.
- Hooks that fire **after** a tool (PostToolUse) cannot un-read content; they warn before
  the model acts on it.
- `malware_intent_findings` is **awareness + audit**, by design — compass supports
  authorized offensive/defensive security work and will not censor it.
- None of this replaces least-privilege credentials, reviewing diffs, or the human gate.
