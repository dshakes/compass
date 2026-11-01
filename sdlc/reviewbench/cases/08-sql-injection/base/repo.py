import sqlite3


def find_user(conn: sqlite3.Connection, name: str):
    cur = conn.execute("SELECT id, name FROM users WHERE name = ?", (name,))
    return cur.fetchone()
