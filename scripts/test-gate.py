#!/usr/bin/env python3
"""Tests for compass-gate.py — stdlib unittest, no external deps.

Run:  python3 scripts/test-gate.py   (exit 0 = all pass)

Spins a fake upstream HTTP server in-process, starts the gate as a subprocess
pointed at it, then exercises the real HTTP stack end-to-end.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
GATE_SCRIPT = os.path.join(SCRIPTS_DIR, "compass-gate.py")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_for_port(port: int, timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return True
        except OSError:
            time.sleep(0.05)
    return False


# ---------------------------------------------------------------------------
# Fake upstream server
# ---------------------------------------------------------------------------


class _UpstreamHits:
    """Thread-safe call log for the fake upstream."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._hits: list[dict] = []

    def record(self, path: str, headers: dict) -> None:
        with self._lock:
            self._hits.append({"path": path, "headers": headers})

    def count(self) -> int:
        with self._lock:
            return len(self._hits)

    def reset(self) -> None:
        with self._lock:
            self._hits.clear()

    def all_headers(self) -> list[dict]:
        with self._lock:
            return [h["headers"] for h in self._hits]


_hits = _UpstreamHits()


def _make_upstream_handler(hits: _UpstreamHits) -> type[BaseHTTPRequestHandler]:
    class FakeUpstream(BaseHTTPRequestHandler):
        def log_message(self, *args: object) -> None:
            pass  # silence

        def do_GET(self) -> None:
            self._respond()

        def do_POST(self) -> None:
            self._respond()

        def _respond(self) -> None:
            length = int(self.headers.get("content-length", 0) or 0)
            body = self.rfile.read(length) if length else b""
            try:
                req = json.loads(body) if body else {}
            except json.JSONDecodeError:
                req = {}

            hits.record(self.path, dict(self.headers))

            # 500 error path
            if "/error" in self.path:
                data = b'{"error":{"message":"internal server error"}}'
                self.send_response(500)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return

            # SSE streaming path
            if req.get("stream"):
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.end_headers()
                events = [
                    {
                        "type": "message_start",
                        "message": {"usage": {"input_tokens": 100, "output_tokens": 0}},
                    },
                    {
                        "type": "content_block_delta",
                        "delta": {"type": "text_delta", "text": "Hi"},
                    },
                    {"type": "message_delta", "usage": {"output_tokens": 50}},
                    {"type": "message_stop"},
                ]
                for ev in events:
                    self.wfile.write(f"data: {json.dumps(ev)}\n\n".encode())
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                return

            # Normal JSON response
            resp = json.dumps(
                {
                    "id": "msg_test",
                    "model": req.get("model", "claude-3-5-sonnet"),
                    "usage": {"input_tokens": 100, "output_tokens": 50},
                    "content": [{"type": "text", "text": "Hi"}],
                }
            ).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)

    return FakeUpstream


# ---------------------------------------------------------------------------
# Gate subprocess lifecycle
# ---------------------------------------------------------------------------


class GateProcess:
    def __init__(
        self,
        gate_port: int,
        upstream_port: int,
        ledger_path: str,
        session_cap: float | None = None,
        day_cap: float | None = None,
    ) -> None:
        env = {
            **os.environ,
            "COMPASS_GATE_PORT": str(gate_port),
            "COMPASS_GATE_UPSTREAM_ANTHROPIC": f"http://127.0.0.1:{upstream_port}",
            "COMPASS_GATE_UPSTREAM_OPENAI": f"http://127.0.0.1:{upstream_port}",
            "COMPASS_HOME": os.path.dirname(ledger_path),
        }
        if session_cap is not None:
            env["COMPASS_MAX_USD"] = str(session_cap)
        else:
            env.pop("COMPASS_MAX_USD", None)
        if day_cap is not None:
            env["COMPASS_MAX_USD_DAY"] = str(day_cap)
        else:
            env.pop("COMPASS_MAX_USD_DAY", None)

        self._proc = subprocess.Popen(
            [sys.executable, GATE_SCRIPT],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self._gate_port = gate_port

    def wait_ready(self, timeout: float = 5.0) -> bool:
        return _wait_for_port(self._gate_port, timeout)

    def stop(self) -> tuple[bytes, bytes]:
        self._proc.terminate()
        try:
            out, err = self._proc.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            self._proc.kill()
            out, err = self._proc.communicate()
        return out, err

    def url(self, path: str = "") -> str:
        return f"http://127.0.0.1:{self._gate_port}{path}"


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestGate(unittest.TestCase):
    upstream_server: HTTPServer
    upstream_port: int

    @classmethod
    def setUpClass(cls) -> None:
        cls.upstream_port = _free_port()
        handler = _make_upstream_handler(_hits)
        cls.upstream_server = HTTPServer(("127.0.0.1", cls.upstream_port), handler)
        t = threading.Thread(target=cls.upstream_server.serve_forever, daemon=True)
        t.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.upstream_server.shutdown()

    def setUp(self) -> None:
        _hits.reset()
        self._tmpdir = tempfile.mkdtemp()
        self._ledger = os.path.join(self._tmpdir, "spend.tsv")
        self._gate_port = _free_port()

    def _gate(
        self, session_cap: float | None = None, day_cap: float | None = None
    ) -> GateProcess:
        g = GateProcess(
            self._gate_port,
            self.upstream_port,
            self._ledger,
            session_cap=session_cap,
            day_cap=day_cap,
        )
        if not g.wait_ready():
            g.stop()
            self.fail("gate did not start in time")
        return g

    def _post(
        self, url: str, body: dict, headers: dict | None = None
    ) -> tuple[int, bytes]:
        data = json.dumps(body).encode()
        req = urllib.request.Request(
            url,
            data=data,
            headers={"content-type": "application/json", **(headers or {})},
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read()

    # -- Test 1: non-stream JSON → usage accounted to ledger ------------------

    def test_json_usage_written_to_ledger(self) -> None:
        g = self._gate()
        try:
            status, body = self._post(
                g.url("/v1/messages"),
                {"model": "claude-3-5-sonnet", "messages": []},
            )
        finally:
            g.stop()

        self.assertEqual(status, 200)
        self.assertEqual(_hits.count(), 1)

        # Ledger must exist and contain a cost row
        self.assertTrue(os.path.exists(self._ledger), "ledger not created")
        with open(self._ledger) as fh:
            rows = [ln for ln in fh if ln.strip() and not ln.startswith("#")]
        self.assertEqual(len(rows), 1, f"expected 1 ledger row, got: {rows}")
        parts = rows[0].split("\t")
        self.assertEqual(len(parts), 5)
        cost = float(parts[4])
        self.assertGreater(cost, 0.0, "cost must be > 0")
        # 100 in + 50 out at claude-3-5-sonnet = (100*3 + 50*15)/1e6 = 0.001050
        self.assertAlmostEqual(cost, 0.001050, places=6)

    # -- Test 2: SSE streaming → bytes pass through intact, usage accounted ---

    def test_sse_stream_passthrough_and_usage(self) -> None:
        g = self._gate()
        try:
            status, body = self._post(
                g.url("/v1/messages"),
                {"model": "claude-3-5-sonnet", "stream": True},
            )
        finally:
            g.stop()

        self.assertEqual(status, 200)
        body_str = body.decode()
        # "Hi" must appear in the streamed content
        self.assertIn("Hi", body_str)
        # message_start event must have passed through
        self.assertIn("message_start", body_str)

        with open(self._ledger) as fh:
            rows = [ln for ln in fh if ln.strip() and not ln.startswith("#")]
        self.assertEqual(len(rows), 1)
        cost = float(rows[0].split("\t")[4])
        # 100 in + 50 out (from SSE message_delta) → same as non-stream
        self.assertAlmostEqual(cost, 0.001050, places=6)

    # -- Test 3: 500 from upstream passes through, nothing written to ledger --

    def test_upstream_500_passthrough(self) -> None:
        g = self._gate()
        try:
            status, body = self._post(
                g.url("/v1/error"),
                {"model": "claude-3-5-sonnet"},
            )
        finally:
            g.stop()

        self.assertEqual(status, 500)
        self.assertIn(b"internal", body.lower())
        # No ledger entry for failed requests
        if os.path.exists(self._ledger):
            with open(self._ledger) as fh:
                rows = [ln for ln in fh if ln.strip() and not ln.startswith("#")]
            self.assertEqual(rows, [], "no cost should be logged for a 500")

    # -- Test 4: session cap breached → 402, upstream never hit ---------------

    def test_session_cap_blocks_without_upstream_hit(self) -> None:
        # Seed the ledger so the gate's session spend starts at zero but we
        # set the cap to 0.000001 so the very first request exceeds it.
        # Cap enforcement uses the in-process session counter, so we set a
        # tiny cap and confirm the gate rejects without forwarding.
        g = self._gate(session_cap=0.000001)
        try:
            # First request: passes (session_usd=0 < cap=0.000001) and writes ~$0.001050
            status1, _ = self._post(
                g.url("/v1/messages"),
                {"model": "claude-3-5-sonnet", "messages": []},
            )
            first_hits = _hits.count()

            # Second request: session now exceeds cap → must return 402
            status2, body2 = self._post(
                g.url("/v1/messages"),
                {"model": "claude-3-5-sonnet", "messages": []},
            )
            second_hits = _hits.count()
        finally:
            g.stop()

        self.assertEqual(status1, 200)
        self.assertEqual(status2, 402)

        err = json.loads(body2)
        self.assertEqual(err["error"]["type"], "compass_budget_exceeded")
        # Upstream must NOT have been hit for the blocked request
        self.assertEqual(second_hits, first_hits, "upstream was hit despite cap breach")

    # -- Test 5: Authorization header never appears in gate stderr ------------

    def test_authorization_not_logged(self) -> None:
        fake_key = "sk-test-SUPERSECRET-KEY-9999"
        g = self._gate()
        try:
            self._post(
                g.url("/v1/messages"),
                {"model": "claude-3-5-sonnet"},
                headers={"Authorization": f"Bearer {fake_key}"},
            )
        finally:
            _, err = g.stop()

        stderr_text = err.decode("utf-8", errors="replace")
        self.assertNotIn(fake_key, stderr_text, "API key leaked into gate stderr")
        self.assertNotIn(
            "SUPERSECRET", stderr_text, "API key fragment leaked into gate stderr"
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
