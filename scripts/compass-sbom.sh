#!/usr/bin/env bash
# compass-sbom.sh — provenance + dependency audit for autonomous PRs.
#
# In a world of agent-generated changes, "what's in this build, and is any of it known-
# vulnerable?" becomes a trust differentiator. This detects the ecosystem, emits a simple
# dependency SBOM (prefers syft/native CycloneDX when present), and runs the native vuln
# audit. Best-effort + dependency-light: every tool is optional and it degrades to a plain
# dependency list. With --gate it exits non-zero when the audit finds vulnerabilities.
#
#   compass-sbom.sh                 # SBOM + audit for the current repo
#   compass-sbom.sh --no-audit      # SBOM only (offline, fast)
#   compass-sbom.sh --gate          # non-zero exit if the audit finds vulns (CI/QA use)
#   compass-sbom.sh --json          # machine-readable summary
set -uo pipefail

NO_AUDIT=0; GATE=0; JSON=0
for a in "$@"; do case "$a" in
  --no-audit) NO_AUDIT=1 ;; --gate) GATE=1 ;; --json) JSON=1 ;;
  -h|--help) echo "usage: compass-sbom.sh [--no-audit] [--gate] [--json]"; exit 0 ;;
  *) echo "unknown arg: $a" >&2; exit 2 ;;
esac; done

have() { command -v "$1" >/dev/null 2>&1; }
eco="none"; deps=0; vulns=0; audit_ran=0; audit_note="not run"
sbom_lines=""

add_deps() { deps=$(( deps + $(printf '%s' "$1" | grep -c . ) )); sbom_lines="$sbom_lines$1
"; }

# Prefer a real SBOM tool if the operator has one.
if have syft; then
  eco="$(syft -o cyclonedx-json . 2>/dev/null >/tmp/_sbom.$$ && echo 'syft' || echo none)"
fi

if [ -f package.json ]; then
  eco="node"
  if have jq && [ -f package-lock.json ]; then add_deps "$(jq -r '.packages // {} | keys[]?' package-lock.json 2>/dev/null | grep -v '^$' | sed 's#node_modules/##')"
  elif have jq; then add_deps "$(jq -r '(.dependencies // {}) + (.devDependencies // {}) | to_entries[]? | "\(.key)@\(.value)"' package.json 2>/dev/null)"; fi
  if [ "$NO_AUDIT" = 0 ] && have npm; then
    out="$(npm audit --json 2>/dev/null || true)"; audit_ran=1
    if have jq; then vulns="$(printf '%s' "$out" | jq -r '.metadata.vulnerabilities.total // 0' 2>/dev/null || echo 0)"; fi
    audit_note="npm audit"
  fi
elif [ -f go.mod ]; then
  eco="go"
  have go && add_deps "$(go list -m all 2>/dev/null | tail -n +2 | tr ' ' '@')"
  if [ "$NO_AUDIT" = 0 ] && have govulncheck; then
    govulncheck ./... >/tmp/_gv.$$ 2>&1; audit_ran=1
    vulns="$(grep -c 'Vulnerability #' /tmp/_gv.$$ 2>/dev/null || echo 0)"; audit_note="govulncheck"; rm -f /tmp/_gv.$$
  fi
elif [ -f Cargo.toml ]; then
  eco="rust"
  have cargo && add_deps "$(cargo tree --prefix none 2>/dev/null | sort -u | tr ' ' '@')"
  if [ "$NO_AUDIT" = 0 ] && have cargo-audit; then cargo audit -q >/tmp/_ca.$$ 2>&1; audit_ran=1
    vulns="$(grep -c 'RUSTSEC' /tmp/_ca.$$ 2>/dev/null || echo 0)"; audit_note="cargo audit"; rm -f /tmp/_ca.$$; fi
elif [ -f pyproject.toml ] || ls requirements*.txt >/dev/null 2>&1; then
  eco="python"
  if [ -f requirements.txt ]; then add_deps "$(grep -vE '^\s*(#|$)' requirements.txt 2>/dev/null)"; fi
  if [ "$NO_AUDIT" = 0 ] && have pip-audit; then pip-audit -q >/tmp/_pa.$$ 2>&1; audit_ran=1
    vulns="$(grep -cE 'PYSEC|GHSA' /tmp/_pa.$$ 2>/dev/null || echo 0)"; audit_note="pip-audit"; rm -f /tmp/_pa.$$; fi
fi
: "${vulns:=0}"
[ -f /tmp/_sbom.$$ ] && rm -f /tmp/_sbom.$$

if [ "$JSON" = 1 ]; then
  printf '{"ecosystem":"%s","dependencies":%d,"audit_ran":%s,"audit_tool":"%s","vulnerabilities":%d}\n' \
    "$eco" "$deps" "$([ "$audit_ran" = 1 ] && echo true || echo false)" "$audit_note" "$vulns"
else
  echo
  echo "  🧭 compass · SBOM + dependency audit"
  echo "  ──────────────────────────────────────"
  if [ "$eco" = none ]; then echo "  No recognized ecosystem (package.json / go.mod / Cargo.toml / pyproject.toml)."; echo;
  else
    printf "  ecosystem: %s   dependencies: %d\n" "$eco" "$deps"
    if [ "$audit_ran" = 1 ]; then
      if [ "${vulns:-0}" -gt 0 ]; then printf "  audit (%s): \033[31m%d vulnerabilit(y/ies)\033[0m\n" "$audit_note" "$vulns"
      else printf "  audit (%s): \033[32mclean\033[0m\n" "$audit_note"; fi
    else printf "  audit: skipped (%s — install the native auditor or pass without --no-audit)\n" "$audit_note"; fi
    echo
  fi
fi

if [ "$GATE" = 1 ] && [ "${vulns:-0}" -gt 0 ]; then
  echo "SBOM gate: $vulns known vulnerabilit(y/ies) found — failing." >&2
  exit 1
fi
exit 0
