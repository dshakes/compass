#!/usr/bin/env python3
"""compass-gate — localhost reverse proxy that enforces spend caps for any coding agent.

Point ANTHROPIC_BASE_URL / OPENAI_BASE_URL at http://127.0.0.1:4141 (or COMPASS_GATE_PORT).
Requests are forwarded to the real APIs; once session + daily spend reaches the configured cap
(COMPASS_MAX_USD / COMPASS_MAX_USD_DAY) all further requests return 402 without hitting upstream.

Speaks the same ledger (spend.tsv) and env vars as the Claude Code budget-gate.sh hook so caps
are unified across agents.

Usage:
    python3 scripts/compass-gate.py [--port N] [--status]

Env:
    COMPASS_GATE_PORT                 listen port (default 4141)
    COMPASS_MAX_USD                   session spend cap in USD (fail-open if unset)
    COMPASS_MAX_USD_DAY               daily spend cap in USD (fail-open if unset)
    COMPASS_HOME                      ledger dir (default ~/.compass)
    COMPASS_GATE_UPSTREAM_ANTHROPIC   override Anthropic base URL
    COMPASS_GATE_UPSTREAM_OPENAI      override OpenAI base URL
"""

from __future__ import annotations

import argparse
import http.client
import http.server
import json
import logging
import os
import re
import signal
import ssl
import sys
import threading
import time
import urllib.parse
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Pricing table (USD per 1M tokens): (input, output)
# Approximate; last updated 2025-07. Unknown models fall back to conservative tier.
# ---------------------------------------------------------------------------
_PRICING: dict[str, tuple[float, float]] = {
    # Anthropic
    "claude-3-haiku-20240307": (0.25, 1.25),
    "claude-3-5-haiku": (0.80, 4.00),
    "claude-3-5-haiku-20241022": (0.80, 4.00),
    "claude-haiku-4-5": (0.80, 4.00),
    "claude-haiku-4-5-20251001": (0.80, 4.00),
    "claude-3-sonnet-20240229": (3.00, 15.00),
    "claude-3-5-sonnet": (3.00, 15.00),
    "claude-3-5-sonnet-20241022": (3.00, 15.00),
    "claude-3-7-sonnet": (3.00, 15.00),
    "claude-3-7-sonnet-20250219": (3.00, 15.00),
    "claude-sonnet-4": (3.00, 15.00),
    "claude-sonnet-5": (3.00, 15.00),
    "claude-3-opus-20240229": (15.00, 75.00),
    "claude-opus-4": (15.00, 75.00),
    "claude-opus-4-8": (15.00, 75.00),
    "claude-fable-5": (15.00, 75.00),
    # OpenAI
    "gpt-4o": (2.50, 10.00),
    "gpt-4o-mini": (0.15, 0.60),
    "gpt-4-turbo": (10.00, 30.00),
    "gpt-4": (30.00, 60.00),
    "gpt-3.5-turbo": (0.50, 1.50),
    "o1": (15.00, 60.00),
    "o1-mini": (3.00, 12.00),
    "o3": (10.00, 40.00),
    "o3-mini": (1.10, 4.40),
    "o4-mini": (1.10, 4.40),
}
# ponytail: conservative fallback — over-estimates so cap is never silently exceeded
_UNKNOWN_PRICE: tuple[float, float] = (15.00, 75.00)

_HOP_BY_HOP = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    }
)
# Headers that must never appear in log output
_SENSITIVE_HEADERS = frozenset({"authorization", "x-api-key"})


# ---------------------------------------------------------------------------
# Shared session state (thread-safe)
# ---------------------------------------------------------------------------


@dataclass
class _State:
    session_usd: float = 0.0
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    def add(self, amount: float) -> None:
        with self._lock:
            self.session_usd += amount

    def check_caps(
        self,
        session_cap: float | None,
        day_cap: float | None,
        day_usd: float,
    ) -> str | None:
        """Return an error message string if any cap is breached, else None."""
        with self._lock:
            if session_cap is not None and self.session_usd >= session_cap:
                return (
                    f"Session budget cap reached: ${self.session_usd:.4f} spent "
                    f"(cap ${session_cap:.2f}, COMPASS_MAX_USD). "
                    "Raise the cap or start a fresh proxy session."
                )
            if day_cap is not None and (self.session_usd + day_usd) >= day_cap:
                total = self.session_usd + day_usd
                return (
                    f"Daily budget cap reached: ~${total:.4f} spent today "
                    f"(cap ${day_cap:.2f}, COMPASS_MAX_USD_DAY). "
                    "Raise the cap or resume tomorrow."
                )
        return None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _resolve_cap(env_var: str, config_key: str, config_path: str) -> float | None:
    """Read a cap from env (wins) or the compass config file. Returns None if unset/invalid."""
    val = os.environ.get(env_var, "").strip()
    if not val:
        try:
            with open(config_path, encoding="utf-8") as fh:
                for line in fh:
                    k, _, v = line.partition("=")
                    if k.strip() == config_key:
                        val = v.strip()
                        break
        except FileNotFoundError:
            pass
    try:
        v = float(val)
        return v if v > 0 else None
    except (ValueError, TypeError):
        return None


def _day_ledger_usd(ledger_path: str) -> float:
    """Sum today's cost_usd column from spend.tsv (UTC date)."""
    today = time.strftime("%Y-%m-%d", time.gmtime())
    total = 0.0
    try:
        with open(ledger_path, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("#") or "\t" not in line:
                    continue
                parts = line.split("\t")
                if len(parts) >= 5 and parts[0][:10] == today:
                    try:
                        total += float(parts[4])
                    except ValueError:
                        pass
    except FileNotFoundError:
        pass
    return total


def _append_ledger(
    ledger_path: str, model: str, cost_usd: float, provider: str
) -> None:
    """Append one row to spend.tsv in the existing compass format."""
    os.makedirs(os.path.dirname(ledger_path), exist_ok=True)
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    row = f"{ts}\tcompass-gate\t{provider}\t{model}\t{cost_usd:.8f}\n"
    with open(ledger_path, "a", encoding="utf-8") as fh:
        fh.write(row)


def _tokens_to_usd(model: str, input_tokens: int, output_tokens: int) -> float:
    key = model.lower()
    # try exact match, then strip -YYYYMMDD date suffix
    price = _PRICING.get(key) or _PRICING.get(re.sub(r"-\d{8}$", "", key))
    if price is None:
        logging.warning(
            "compass-gate: unknown model %r — using conservative pricing; update _PRICING if this recurs",
            model,
        )
        price = _UNKNOWN_PRICE
    inp_rate, out_rate = price
    return (input_tokens * inp_rate + output_tokens * out_rate) / 1_000_000


def _extract_model(body: bytes) -> str:
    try:
        return str(json.loads(body).get("model") or "unknown")
    except (json.JSONDecodeError, AttributeError):
        return "unknown"


def _parse_sse_usage(buf: bytes, provider: str) -> tuple[int, int]:
    """Extract (input_tokens, output_tokens) from accumulated SSE byte buffer.

    Anthropic: message_start carries input_tokens; message_delta carries running output_tokens
    (take the last value seen — it's a cumulative counter).
    OpenAI: last chunk carries usage when stream_options.include_usage is true.
    """
    input_toks = 0
    output_toks = 0
    has_usage = False

    for line in buf.decode("utf-8", errors="replace").splitlines():
        if not line.startswith("data: "):
            continue
        data = line[6:]
        if data.strip() == "[DONE]":
            continue
        try:
            obj = json.loads(data)
        except json.JSONDecodeError:
            continue

        if provider == "anthropic":
            evt = obj.get("type", "")
            if evt == "message_start":
                u = obj.get("message", {}).get("usage", {})
                input_toks = u.get("input_tokens", input_toks)
                output_toks = u.get("output_tokens", output_toks)
                has_usage = True
            elif evt == "message_delta":
                u = obj.get("usage", {})
                # cumulative counter — overwrite with latest value
                output_toks = u.get("output_tokens", output_toks)
                has_usage = True
        elif provider == "openai":
            u = obj.get("usage")
            if u is not None:
                input_toks = u.get("prompt_tokens", input_toks)
                output_toks = u.get("completion_tokens", output_toks)
                has_usage = True

    if not has_usage and provider == "openai":
        logging.warning(
            "compass-gate: OpenAI stream had no usage data — cost recorded as $0.00. "
            'Pass stream_options={"include_usage":true} for accurate tracking.'
        )
    return input_toks, output_toks


# ---------------------------------------------------------------------------
# HTTP handler factory (closure keeps shared state off the class hierarchy)
# ---------------------------------------------------------------------------


def _make_handler(
    state: _State,
    session_cap: float | None,
    day_cap: float | None,
    ledger_path: str,
    upstream_anthropic: str,
    upstream_openai: str,
) -> type[http.server.BaseHTTPRequestHandler]:

    class GateHandler(http.server.BaseHTTPRequestHandler):
        # Never log request bodies, paths, or headers to stdout/stderr
        def log_message(self, fmt: str, *args: object) -> None:
            logging.debug("compass-gate request: %s", fmt % args)

        def log_error(self, fmt: str, *args: object) -> None:
            logging.debug("compass-gate request error: %s", fmt % args)

        def _upstream_for(self, path: str) -> tuple[str, str]:
            """(upstream_base_url, provider_name)"""
            if path.startswith("/v1/messages"):
                return upstream_anthropic, "anthropic"
            return upstream_openai, "openai"

        def _send_json(self, status: int, body: dict) -> None:
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _handle(self) -> None:
            content_length = int(self.headers.get("content-length", 0) or 0)
            body = self.rfile.read(content_length) if content_length > 0 else b""

            upstream_base, provider = self._upstream_for(self.path)

            # Cap check (fail-open: only blocks when cap is set and spend data is available)
            if session_cap is not None or day_cap is not None:
                day_usd = _day_ledger_usd(ledger_path)
                msg = state.check_caps(session_cap, day_cap, day_usd)
                if msg is not None:
                    self._send_json(
                        402,
                        {"error": {"type": "compass_budget_exceeded", "message": msg}},
                    )
                    return

            model = _extract_model(body) if body else "unknown"

            # Build upstream connection
            parsed = urllib.parse.urlparse(upstream_base)
            host = parsed.netloc
            use_ssl = parsed.scheme == "https"

            fwd_headers: dict[str, str] = {}
            for k, v in self.headers.items():
                if k.lower() in _HOP_BY_HOP or k.lower() == "host":
                    continue
                fwd_headers[k] = v

            try:
                if use_ssl:
                    ctx = ssl.create_default_context()
                    conn: http.client.HTTPConnection = http.client.HTTPSConnection(
                        host, timeout=10, context=ctx
                    )
                else:
                    conn = http.client.HTTPConnection(host, timeout=10)
                conn.connect()
                # Switch to long read timeout after the TCP/TLS handshake
                if conn.sock is not None:
                    conn.sock.settimeout(600)
                conn.request(
                    self.command, self.path, body=body or None, headers=fwd_headers
                )
                resp = conn.getresponse()
            except TimeoutError as exc:
                self._send_json(
                    504, {"error": {"type": "upstream_timeout", "message": str(exc)}}
                )
                return
            except OSError as exc:
                self._send_json(
                    502, {"error": {"type": "upstream_error", "message": str(exc)}}
                )
                return

            is_sse = "text/event-stream" in (resp.getheader("content-type") or "")

            self.send_response(resp.status)
            for k, v in resp.getheaders():
                if k.lower() in _HOP_BY_HOP:
                    continue
                self.send_header(k, v)
            self.end_headers()

            buf = bytearray()
            try:
                while True:
                    chunk = resp.read(8192)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    buf.extend(chunk)
                self.wfile.flush()
            except OSError:
                pass  # client disconnected; still parse whatever we buffered

            conn.close()

            # Track cost only for successful responses
            if resp.status < 400:
                if is_sse:
                    input_toks, output_toks = _parse_sse_usage(bytes(buf), provider)
                else:
                    input_toks, output_toks = 0, 0
                    try:
                        data = json.loads(buf)
                        if provider == "anthropic":
                            u = data.get("usage", {})
                            input_toks = int(u.get("input_tokens", 0))
                            output_toks = int(u.get("output_tokens", 0))
                        else:
                            u = data.get("usage", {})
                            input_toks = int(u.get("prompt_tokens", 0))
                            output_toks = int(u.get("completion_tokens", 0))
                    except (json.JSONDecodeError, AttributeError, ValueError):
                        pass

                cost = _tokens_to_usd(model, input_toks, output_toks)
                if cost > 0:
                    state.add(cost)
                    _append_ledger(ledger_path, model, cost, provider)
                    logging.info(
                        "compass-gate: %s %s model=%s in=%d out=%d cost=$%.6f session=$%.4f",
                        provider,
                        self.path,
                        model,
                        input_toks,
                        output_toks,
                        cost,
                        state.session_usd,
                    )

        do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = _handle

    return GateHandler


# ---------------------------------------------------------------------------
# Status display
# ---------------------------------------------------------------------------


def _print_status(
    session_cap: float | None,
    day_cap: float | None,
    ledger_path: str,
    state: _State,
) -> None:
    day_usd = _day_ledger_usd(ledger_path)
    print("\n  compass gate · status")
    print(f"  session spend : ${state.session_usd:.4f}", end="")
    if session_cap is not None:
        pct = state.session_usd / session_cap * 100
        print(f" / ${session_cap:.2f} ({pct:.0f}%)")
    else:
        print("  (no session cap — set COMPASS_MAX_USD)")
    print(f"  today ledger  : ${day_usd:.4f}", end="")
    if day_cap is not None:
        combined = state.session_usd + day_usd
        pct = combined / day_cap * 100
        print(f" / ${day_cap:.2f} combined ({pct:.0f}%)")
    else:
        print("  (no daily cap — set COMPASS_MAX_USD_DAY)")
    print()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        description="compass-gate: localhost budget-enforcing reverse proxy for AI APIs"
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("COMPASS_GATE_PORT", "4141")),
        help="listen port (default 4141, or COMPASS_GATE_PORT)",
    )
    parser.add_argument(
        "--status", action="store_true", help="print current spend and exit"
    )
    args = parser.parse_args(argv)

    compass_home = os.environ.get("COMPASS_HOME", os.path.expanduser("~/.compass"))
    ledger_path = os.path.join(compass_home, "spend.tsv")
    config_path = os.path.join(compass_home, "config")

    session_cap = _resolve_cap("COMPASS_MAX_USD", "max_usd", config_path)
    day_cap = _resolve_cap("COMPASS_MAX_USD_DAY", "max_usd_day", config_path)
    state = _State()

    if args.status:
        _print_status(session_cap, day_cap, ledger_path, state)
        return

    upstream_anthropic = os.environ.get(
        "COMPASS_GATE_UPSTREAM_ANTHROPIC", "https://api.anthropic.com"
    )
    upstream_openai = os.environ.get(
        "COMPASS_GATE_UPSTREAM_OPENAI", "https://api.openai.com"
    )

    handler_cls = _make_handler(
        state, session_cap, day_cap, ledger_path, upstream_anthropic, upstream_openai
    )

    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stderr)

    caps_note = ""
    if session_cap:
        caps_note += f" session_cap=${session_cap:.2f}"
    if day_cap:
        caps_note += f" day_cap=${day_cap:.2f}"
    if not caps_note:
        caps_note = " (no caps set — fail-open; export COMPASS_MAX_USD to enable)"

    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), handler_cls)
    logging.info("compass-gate: listening on 127.0.0.1:%d%s", args.port, caps_note)

    def _shutdown(signum: int, frame: object) -> None:
        logging.info(
            "compass-gate: shutting down — session spend $%.4f", state.session_usd
        )
        # shutdown() blocks; run in a daemon thread so the signal handler returns quickly
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    server.serve_forever()


if __name__ == "__main__":
    main()
