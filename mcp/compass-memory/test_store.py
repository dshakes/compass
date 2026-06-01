"""Tests for the security-critical memory logic. Pure stdlib (no MCP SDK) → runs in CI.
Run: python3 mcp/compass-memory/test_store.py   (exit 0 = pass)
"""

import sys

import store

P = 0
F = 0


def check(name, got, want):
    global P, F
    if got == want:
        P += 1
        print(f"  ok   {name}")
    else:
        F += 1
        print(f"  FAIL {name} — got {got!r} want {want!r}")


TRUST = "repo-a:read-write,repo-b:read-only,evil:deny"

# trust tiers
check("read-write tier", store.trust_tier("repo-a", TRUST), "read-write")
check("read-only tier", store.trust_tier("repo-b", TRUST), "read-only")
check("unlisted → deny", store.trust_tier("unknown", TRUST), "deny")
check("explicit deny", store.trust_tier("evil", TRUST), "deny")

# secret detection
check(
    "anthropic key is secret",
    store.looks_secret("key sk-ant-oat01-abcdefghijklmnop"),  # allowlist secret
    True,
)
check(
    "github token is secret",
    store.looks_secret("ghp_0123456789abcdefghijABCDEFG"),  # allowlist secret
    True,
)
check("password kv is secret", store.looks_secret("password = hunter2"), True)
check(
    "plain note not secret",
    store.looks_secret("the build fails on arm64; pin go 1.21"),
    False,
)

# record + search (in-memory db)
conn = store.connect(":memory:")
check(
    "record denied for read-only",
    store.record(conn, "x", "repo-b", trust_env=TRUST),
    "denied: 'repo-b' is not read-write (set COMPASS_MEMORY_TRUST)",
)
check(
    "record refuses secret",
    store.record(
        conn, "token = ghp_0123456789abcdefghijABCDEFG", "repo-a", trust_env=TRUST
    ),
    "rejected: looks like a secret — not stored (scrubbing is best-effort, never paste creds)",
)
check(
    "record ok",
    store.record(
        conn,
        "flaky test X fixed by seeding rng",
        "repo-a",
        tags="testing",
        trust_env=TRUST,
    ),
    "recorded",
)

hits = store.search(conn, "flaky", trust_env=TRUST)
check("search finds the note", len(hits), 1)
check("search returns repo", hits[0]["repo"] if hits else None, "repo-a")

# deny-tier rows never leak in search
store.record(conn, "secret-ish ops note", "repo-a", trust_env=TRUST)
conn.execute("INSERT INTO mem(text,repo,tags,ts) VALUES('leak me','evil','',1.0)")
conn.commit()
leak = [h for h in store.search(conn, "leak", trust_env=TRUST) if h["repo"] == "evil"]
check("deny repo excluded from search", leak, [])

# H3 — most-restrictive-wins on duplicate trust entries (no privilege escalation)
check(
    "dup read-write,deny → deny", store.trust_tier("a", "a:read-write,a:deny"), "deny"
)
check(
    "dup deny,read-write → deny", store.trust_tier("a", "a:deny,a:read-write"), "deny"
)
# M4 — repo id validation
check(
    "invalid repo rejected",
    store.record(conn, "note", "bad repo!$", trust_env="bad repo!$:read-write"),
    "rejected: invalid repo id",
)
# L1 — secret in tags is caught, not just text
check(
    "secret in tags refused",
    store.record(
        conn,
        "ok note",
        "repo-a",
        tags="ghp_0123456789abcdefghijABCDEFG",
        trust_env=TRUST,
    ),
    "rejected: looks like a secret — not stored (scrubbing is best-effort, never paste creds)",
)
# H2 — connection string with creds caught
check(
    "db uri creds is secret",
    store.looks_secret("dsn = postgres://admin:S3cr3tP4ss@db:5432/prod"),
    True,
)
# M2 — LIKE wildcard is escaped (literal %, not match-all)
check("wildcard query is literal", store.search(conn, "%", trust_env=TRUST), [])

# Trust filter is applied BEFORE the limit: newer deny-tier rows must not starve out
# older readable ones (regression — old code applied SQL LIMIT first).
c2 = store.connect(":memory:")
for i in range(3):  # readable, older
    c2.execute(
        "INSERT INTO mem(text,repo,tags,ts) VALUES('widget note', 'repo-a', '', ?)",
        (float(i),),
    )
for i in range(5):  # deny-tier, NEWER (would win ORDER BY ts DESC + LIMIT)
    c2.execute(
        "INSERT INTO mem(text,repo,tags,ts) VALUES('widget note', 'evil', '', ?)",
        (float(10 + i),),
    )
c2.commit()
res = store.search(c2, "widget", limit=3, trust_env=TRUST)
check("limit counts readable rows only", len(res), 3)
check("no deny rows leak past the limit", [h for h in res if h["repo"] == "evil"], [])

print(f"\nstore tests: {P} passed, {F} failed")
sys.exit(0 if F == 0 else 1)
