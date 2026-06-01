#!/usr/bin/env bash
# session-memory.sh — OPT-IN SessionStart hook: inject durable, cross-repo learnings.
#
# The read half of compass's persistent memory (ADR 0001, local v1). On session start,
# it queries the local compass-memory store for non-secret learnings relevant to THIS
# repo and hands the top few to the agent as additionalContext — so a hard-won fact
# ("auth tokens expire in 15m", "the flaky test needs CASS_SEED set") survives /clear,
# compaction, and even moving to a sibling repo.
#
# OFF by default (like route-intent / require-tests). Enable by wiring it under
# hooks.SessionStart in settings.json AND setting COMPASS_MEMORY_TRUST — it self-no-ops
# (silent exit 0) when memory isn't configured, so it can never slow or break a session.
#
# Reads the SAME store (redaction + trust tiers) the MCP server uses — read-only here.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

# No trust config → memory disabled → do nothing.
[ -n "${COMPASS_MEMORY_TRUST:-}" ] || exit 0
have python3 || exit 0

# Resolve the store (repo checkout, or an installed copy under $COMPASS_HOME).
STORE=""
for c in "$DIR/../../mcp/compass-memory/store.py" "${COMPASS_HOME:-$HOME/.compass}/mcp/compass-memory/store.py"; do
  [ -f "$c" ] && { STORE="$c"; break; }
done
[ -n "$STORE" ] || exit 0

repo="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")")"
# At session start we want this repo's most-recent learnings (newest-first), not a keyword
# hit — so search with an empty query scoped to the repo. The store returns readable rows
# only (trust tiers), capped to keep the context-window cost tiny.
learnings="$(python3 "$STORE" search --repo "$repo" --limit "${COMPASS_MEMORY_INJECT_MAX:-5}" "" 2>/dev/null)"

[ -n "$learnings" ] || exit 0
emit_context "compass memory — durable learnings for this repo (recorded by past sessions; treat as hints, verify before relying):
$learnings" "SessionStart"
