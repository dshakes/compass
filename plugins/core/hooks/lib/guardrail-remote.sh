#!/usr/bin/env bash
# guardrail-remote.sh — OPTIONAL escalation to a managed guardrails service.
#
# compass is local-first: the pattern detectors in policy.sh are the always-on,
# offline floor. If you want a model-grade ceiling, set COMPASS_GUARDRAIL_BACKEND and
# the hooks will send untrusted text to your service for a verdict. HONEST TRADEOFF:
# this SENDS that content off-box (privacy/egress) — it is opt-in and disclosed.
#
# remote_guardrail_action "<source-label>" "<text>"  -> echoes "BLOCK" or "" (allow).
# Fails OPEN (prints nothing) on any error/missing dep so a backend outage or a
# missing CLI never bricks a hook on the hot path.
#
# Backends (COMPASS_GUARDRAIL_BACKEND):
#   none    (default) — no-op
#   bedrock — AWS Bedrock Guardrails ApplyGuardrail. Needs the aws CLI + COMPASS_GUARDRAIL_ID
#             (+ COMPASS_GUARDRAIL_VERSION, default DRAFT; region via AWS_REGION).
#   azure   — Azure AI Content Safety "Prompt Shields" (jailbreak + indirect-injection).
#             Needs COMPASS_GUARDRAIL_URL + COMPASS_GUARDRAIL_KEY.
#   webhook — POST {"source","text"} to COMPASS_GUARDRAIL_URL; expect {"action":"BLOCK"|"NONE"}.
#             The neutral shape for Llama Guard / NeMo / Lasso / a self-hosted proxy.

remote_guardrail_action() {
  local source="$1" text="$2" backend="${COMPASS_GUARDRAIL_BACKEND:-none}"
  [ "$backend" = none ] && return 0
  [ -n "$text" ] || return 0
  case "$backend" in
    bedrock) _gr_bedrock "$text" ;;
    azure)   _gr_azure   "$text" ;;
    webhook) _gr_webhook "$source" "$text" ;;
    *) return 0 ;;
  esac
}

# _gr_verdict <backend> <raw-response>  -> "BLOCK" (echoed) if the service flagged it.
# Pure parse logic, split out so scripts/test-guardrail-remote.sh contract-tests each
# backend's response shape against fixtures (the network call still needs your creds).
_gr_verdict() {
  case "$1" in
    bedrock) case "$2" in *GUARDRAIL_INTERVENED*) printf BLOCK ;; esac ;;
    azure)   case "$2" in *'"attackDetected":true'*|*'"attackDetected": true'*) printf BLOCK ;; esac ;;
    webhook) case "$2" in *'"action":"BLOCK"'*|*'"action": "BLOCK"'*) printf BLOCK ;; esac ;;
  esac
}

_gr_bedrock() {
  have aws || return 0
  [ -n "${COMPASS_GUARDRAIL_ID:-}" ] || return 0
  local out
  out="$(aws bedrock-runtime apply-guardrail \
      --guardrail-identifier "$COMPASS_GUARDRAIL_ID" \
      --guardrail-version "${COMPASS_GUARDRAIL_VERSION:-DRAFT}" \
      --source INPUT \
      --content "[{\"text\":{\"text\":$(json_string "$1")}}]" \
      --output json 2>/dev/null)" || return 0
  _gr_verdict bedrock "$out"
}

_gr_azure() {
  have curl || return 0
  [ -n "${COMPASS_GUARDRAIL_URL:-}" ] && [ -n "${COMPASS_GUARDRAIL_KEY:-}" ] || return 0
  local out
  out="$(curl -fsS --max-time 8 -X POST "$COMPASS_GUARDRAIL_URL" \
      -H "Ocp-Apim-Subscription-Key: $COMPASS_GUARDRAIL_KEY" \
      -H 'Content-Type: application/json' \
      -d "{\"userPrompt\":$(json_string "$1"),\"documents\":[]}" 2>/dev/null)" || return 0
  _gr_verdict azure "$out"
}

_gr_webhook() {
  have curl || return 0
  [ -n "${COMPASS_GUARDRAIL_URL:-}" ] || return 0
  local out
  out="$(curl -fsS --max-time 8 -X POST "$COMPASS_GUARDRAIL_URL" \
      -H 'Content-Type: application/json' \
      -d "{\"source\":$(json_string "$1"),\"text\":$(json_string "$2")}" 2>/dev/null)" || return 0
  _gr_verdict webhook "$out"
}
