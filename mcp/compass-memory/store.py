"""compass-memory store — the security-critical logic, kept free of the MCP SDK so it is
unit-testable (see test_store.py). Redaction + trust tiers live here; server.py is a thin
MCP wrapper. Gated by docs/adr/0001-cross-repo-memory.md (Accepted for local v1 only).

Posture (ADR 0001, v1 = local, opt-in, stdio over SQLite — no network):
- NEVER persist secrets: record() refuses text/tags/repo matching secret shapes. This is
  BEST-EFFORT defense-in-depth, NOT a guarantee — never paste credentials.
- Per-repo trust tiers (read-write / read-only / deny); default deny; most-restrictive-wins.
- DB file is created 0600 (trust tiers are an in-process filter, not OS access control).
"""

from __future__ import annotations

import os
import re
import sqlite3
import time

DB_PATH = os.environ.get(
    "COMPASS_MEMORY_DB", os.path.expanduser("~/.compass-memory.db")
)

_VALID_REPO = re.compile(r"^[A-Za-z0-9._/\-]{1,100}$")

# Shapes that must never be persisted. Conservative; a false positive just rejects a note.
_SECRET_PATTERNS = [
    re.compile(r"sk-[a-zA-Z0-9_\-]{16,}"),  # Anthropic/OpenAI-style keys
    re.compile(r"\b[sr]k_live_[0-9a-zA-Z]{10,}"),  # Stripe live keys
    re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"),  # GitHub tokens
    re.compile(r"glpat-[0-9A-Za-z_\-]{16,}"),  # GitLab PAT
    re.compile(r"AKIA[0-9A-Z]{16}"),  # AWS access key id
    re.compile(r"AIza[0-9A-Za-z_\-]{35}"),  # Google API key
    re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),  # Slack tokens
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),  # private key (PEM header)
    re.compile(
        r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"
    ),  # JWT
    re.compile(
        r"(?i)\b(postgres(ql)?|mysql|mongodb(\+srv)?|redis|amqps?)://[^\s:@/]+:[^\s@/]+@"
    ),  # creds in URI
    re.compile(
        r"(?i)(password|passwd|secret|api[_-]?key|token|bearer)\s*[:=]\s*\S+"
    ),  # k=v secrets
    re.compile(r"\b[0-9a-fA-F]{64,}\b"),  # long hex (sha256+/keys); 64 avoids git SHAs
    re.compile(r"\b[A-Za-z0-9+/]{44,}={0,2}\b"),  # long base64 blob
]

_ORDER = {"deny": 0, "read-only": 1, "read-write": 2}


def looks_secret(text: str) -> bool:
    """True if text appears to contain a credential. Best-effort, not a guarantee."""
    return any(p.search(text or "") for p in _SECRET_PATTERNS)


def valid_repo(repo: str) -> bool:
    """Repo identifiers are constrained (charset + length) — defends the team version's IDOR seed."""
    return bool(_VALID_REPO.match(repo or ""))


def trust_tier(repo: str, env: str | None = None) -> str:
    """Tier from COMPASS_MEMORY_TRUST='repo:read-write,other:read-only'. Default deny.
    Most-restrictive-wins on duplicate entries (a later/earlier 'deny' always overrides)."""
    raw = env if env is not None else os.environ.get("COMPASS_MEMORY_TRUST", "")
    found: str | None = None
    for pair in raw.split(","):
        name, sep, tier = pair.partition(":")
        t = tier.strip()
        if sep and name.strip() == repo and t in _ORDER:
            found = t if found is None or _ORDER[t] < _ORDER[found] else found
    return found or "deny"


def connect(db_path: str | None = None) -> sqlite3.Connection:
    path = db_path or DB_PATH
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE IF NOT EXISTS mem("
        "id INTEGER PRIMARY KEY, text TEXT NOT NULL, repo TEXT NOT NULL, "
        "tags TEXT DEFAULT '', ts REAL NOT NULL)"
    )
    if path != ":memory:":  # keep the corpus owner-only (and its WAL/SHM sidecars)
        for p in (path, f"{path}-wal", f"{path}-shm"):
            try:
                if os.path.exists(p):
                    os.chmod(p, 0o600)
            except OSError:
                pass
    return conn


def _like_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def record(
    conn: sqlite3.Connection, text: str, repo: str, tags: str = "", *, trust_env=None
) -> str:
    """Record a durable, non-secret learning. Requires read-write trust; refuses secret-looking input."""
    text = (text or "").strip()
    if not text:
        return "rejected: empty"
    if not valid_repo(repo):
        return "rejected: invalid repo id"
    if trust_tier(repo, trust_env) != "read-write":
        return f"denied: '{repo}' is not read-write (set COMPASS_MEMORY_TRUST)"
    if looks_secret(f"{text} {tags} {repo}"):  # scan every stored field
        return "rejected: looks like a secret — not stored (scrubbing is best-effort, never paste creds)"
    conn.execute(
        "INSERT INTO mem(text, repo, tags, ts) VALUES(?,?,?,?)",
        (text[:4000], repo, tags[:200], time.time()),
    )
    conn.commit()
    return "recorded"


def search(
    conn: sqlite3.Connection,
    query: str,
    repo: str = "",
    limit: int = 20,
    *,
    trust_env=None,
):
    """Return learnings matching query, scoped to repos the caller may READ (tier != deny).

    The trust/repo filter is applied to each candidate row BEFORE the limit is counted:
    we stream rows newest-first and stop once `limit` *readable* ones are collected.
    Applying SQL LIMIT first (the old behaviour) let deny-tier rows consume the budget
    and silently starve out authorized results.
    """
    pattern = f"%{_like_escape(query or '')}%"
    cap = max(1, min(limit, 100))
    out = []
    cur = conn.execute(
        "SELECT text, repo, tags, ts FROM mem WHERE text LIKE ? ESCAPE '\\' ORDER BY ts DESC",
        (pattern,),
    )
    for t, r, g, ts in cur:
        if trust_tier(r, trust_env) == "deny" or (repo and r != repo):
            continue
        out.append({"text": t, "repo": r, "tags": g, "ts": ts})
        if len(out) >= cap:
            break
    return out


def _main(argv: list[str]) -> int:
    """Tiny CLI so the opt-in hooks (session-memory / record-learning) can use the
    SAME redaction + trust logic as the MCP server, without the MCP SDK. Local only.

        store.py record --repo R [--tags T] <text…>
        store.py search [--repo R] [--limit N] [--json] <query…>
    """
    import json as _json

    if not argv:
        print("usage: store.py record|search …", file=__import__("sys").stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    repo, tags, limit, as_json, words = "", "", 20, False, []
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--repo":
            i += 1; repo = rest[i] if i < len(rest) else ""
        elif a == "--tags":
            i += 1; tags = rest[i] if i < len(rest) else ""
        elif a == "--limit":
            i += 1; limit = int(rest[i]) if i < len(rest) and rest[i].isdigit() else 20
        elif a == "--json":
            as_json = True
        else:
            words.append(a)
        i += 1
    text = " ".join(words)
    conn = connect()
    if cmd == "record":
        print(record(conn, text, repo, tags))
        return 0
    if cmd == "search":
        rows = search(conn, text, repo=repo, limit=limit)
        if as_json:
            print(_json.dumps(rows))
        else:
            for r in rows:
                tg = f"  [{r['tags']}]" if r["tags"] else ""
                print(f"- {r['text']}  ({r['repo']}){tg}")
        return 0
    print(f"unknown command: {cmd}", file=__import__("sys").stderr)
    return 2


if __name__ == "__main__":
    import sys

    raise SystemExit(_main(sys.argv[1:]))
