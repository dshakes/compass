#!/usr/bin/env bash
# compass-sbom.sh — provenance + dependency audit for autonomous PRs.
#
# In a world of agent-generated changes, "what's in this build, and is any of it known-
# vulnerable?" becomes a trust differentiator. This detects the ecosystem, emits a simple
# dependency SBOM and runs the native vuln audit. Best-effort + dependency-light: every
# tool is optional and it degrades to a plain dependency list. With --gate it exits
# non-zero when the audit finds vulnerabilities.
#
#   compass-sbom.sh                 # dependency list + audit for the current repo
#   compass-sbom.sh --no-audit      # SBOM only (offline, fast)
#   compass-sbom.sh --gate          # non-zero exit if the audit finds vulns (CI/QA use)
#   compass-sbom.sh --json          # machine-readable summary
#   compass-sbom.sh --cyclonedx     # minimal valid CycloneDX 1.5 JSON (requires python3)
set -uo pipefail

NO_AUDIT=0; GATE=0; JSON=0; CYCLONEDX=0
for a in "$@"; do case "$a" in
  --no-audit) NO_AUDIT=1 ;; --gate) GATE=1 ;; --json) JSON=1 ;; --cyclonedx) CYCLONEDX=1 ;;
  -h|--help) echo "usage: compass-sbom.sh [--no-audit] [--gate] [--json] [--cyclonedx]"; exit 0 ;;
  *) echo "unknown arg: $a" >&2; exit 2 ;;
esac; done

have() { command -v "$1" >/dev/null 2>&1; }

# Temp dir for audit output — unpredictable path prevents symlink-race on /tmp/_xx.$$
_SBOM_TMP="$(mktemp -d)"
trap 'rm -rf "$_SBOM_TMP"' EXIT

eco="none"; deps=0; vulns=0; audit_ran=0; audit_note="not run"
sbom_lines=""

add_deps() { deps=$(( deps + $(printf '%s' "$1" | grep -c . ) )); sbom_lines="$sbom_lines$1
"; }

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
    govulncheck ./... >"$_SBOM_TMP/gv" 2>&1; audit_ran=1
    vulns="$(grep -c 'Vulnerability #' "$_SBOM_TMP/gv" 2>/dev/null || echo 0)"; audit_note="govulncheck"
  fi
elif [ -f Cargo.toml ]; then
  eco="rust"
  have cargo && add_deps "$(cargo tree --prefix none 2>/dev/null | sort -u | tr ' ' '@')"
  if [ "$NO_AUDIT" = 0 ] && have cargo-audit; then
    cargo audit -q >"$_SBOM_TMP/ca" 2>&1; audit_ran=1
    vulns="$(grep -c 'RUSTSEC' "$_SBOM_TMP/ca" 2>/dev/null || echo 0)"; audit_note="cargo audit"
  fi
elif { [ -f pyproject.toml ] || for _f in requirements*.txt; do [ -f "$_f" ] && break; done; }; then
  eco="python"
  if [ -f requirements.txt ]; then add_deps "$(grep -vE '^\s*(#|$)' requirements.txt 2>/dev/null)"; fi
  if [ "$NO_AUDIT" = 0 ] && have pip-audit; then
    pip-audit -q >"$_SBOM_TMP/pa" 2>&1; audit_ran=1
    vulns="$(grep -cE 'PYSEC|GHSA' "$_SBOM_TMP/pa" 2>/dev/null || echo 0)"; audit_note="pip-audit"
  fi
fi
: "${vulns:=0}"

if [ "$CYCLONEDX" = 1 ]; then
  if ! have python3; then
    echo "compass-sbom: --cyclonedx requires python3" >&2; exit 2
  fi
  printf '%s' "$sbom_lines" > "$_SBOM_TMP/deps"
  ECO="$eco" python3 - "$_SBOM_TMP/deps" <<'PYEOF'
import sys, json, re, os

eco = os.environ.get("ECO", "none")
with open(sys.argv[1]) as f:
    lines = [l.rstrip() for l in f if l.strip()]

components = []
for line in lines:
    name, ver, purl = line, "", ""

    if eco == "go":
        # module@version e.g. golang.org/x/crypto@v0.1.0
        at = line.rfind("@")
        if at > 0:
            name, ver = line[:at], line[at+1:]
        purl = ("pkg:golang/" + name + "@" + ver) if ver else ("pkg:golang/" + name)

    elif eco == "node":
        # @scope/pkg@version  or  pkg@version  or  just pkg (package-lock names)
        if line.startswith("@"):
            slash = line.find("/")
            if slash > 0:
                scope = line[1:slash]
                rest = line[slash+1:]
                at = rest.rfind("@")
                if at > 0:
                    pkg, ver = rest[:at], rest[at+1:]
                    ver = re.sub(r'^[~^>=< ]+', '', ver)
                else:
                    pkg = rest
                name = "@" + scope + "/" + pkg
                encoded = "%40" + scope + "%2F" + pkg
            else:
                name = line
                encoded = line.replace("@", "%40")
        else:
            at = line.rfind("@")
            if at > 0:
                name, ver = line[:at], line[at+1:]
                ver = re.sub(r'^[~^>=< ]+', '', ver)
            encoded = name
        purl = ("pkg:npm/" + encoded + "@" + ver) if ver else ("pkg:npm/" + encoded)

    elif eco == "rust":
        # cargo tree --prefix none | tr ' ' '@'  →  name@version[@(path)]
        parts = line.split("@")
        name = parts[0]
        ver = parts[1] if len(parts) > 1 else ""
        ver = re.sub(r'\s*\(.*', '', ver).strip()  # drop path suffix
        purl = ("pkg:cargo/" + name + "@" + ver) if ver else ("pkg:cargo/" + name)

    elif eco == "python":
        # requirements.txt: requests==2.28.0  flask>=2.0  etc.
        m = re.match(r'^([A-Za-z0-9][A-Za-z0-9._-]*)', line)
        if m:
            name = m.group(1)
            m2 = re.search(r'==\s*([^\s,;]+)', line)
            ver = m2.group(1) if m2 else ""
        purl = ("pkg:pypi/" + name.lower() + "@" + ver) if ver else ("pkg:pypi/" + name.lower())

    comp = {"type": "library", "name": name}
    if ver:
        comp["version"] = ver
    if purl:
        comp["purl"] = purl
    components.append(comp)

bom = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "version": 1,
    "components": components,
}

# structural sanity — fails loudly before printing if invariants break
assert bom["bomFormat"] == "CycloneDX", "bomFormat wrong"
assert bom["specVersion"] == "1.5", "specVersion wrong"
assert isinstance(bom["components"], list), "components must be a list"
for c in bom["components"]:
    assert "type" in c and "name" in c, "component missing type/name: " + repr(c)

print(json.dumps(bom, indent=2))
PYEOF
  if [ "$GATE" = 1 ] && [ "${vulns:-0}" -gt 0 ]; then
    echo "SBOM gate: $vulns known vulnerabilit(y/ies) found — failing." >&2
    exit 1
  fi
  exit 0
fi

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
