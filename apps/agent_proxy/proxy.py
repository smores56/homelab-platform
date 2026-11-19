#!/usr/bin/env python3
"""OpenAI-compatible reverse proxy pinned to exactly one hosted provider.

The safety rule this module exists for: the general agent gateway must be able to
spend a hosted model account **without holding that account's key**, and turning
the host into that proxy must not turn it into a general-purpose egress hop.

Every rule below is structural, not a header check that a future request can talk
its way past:

* The upstream is a module constant -- scheme, host, port and path prefix. No
  request field, no inbound header and no environment variable can move it, so
  another host costs a source change and an image rebuild.
* Only four routes exist: ``GET /v1/models``, ``POST /v1/chat/completions``,
  ``POST /v1/completions`` and ``GET /healthz``. Everything else, including a
  request for a different upstream path, is a 404 with a JSON body.
* A request body over the cap (1 MiB by default) is refused from its
  ``Content-Length``, before a byte of it is read.
* The inbound ``Authorization`` header is dropped and replaced with the pinned
  key. ``Host`` is set by the connection, hop-by-hop headers and every
  ``X-Forwarded-*`` are dropped, and responses are relayed unbuffered so
  ``stream: true`` keeps streaming.
* Redirects are not followed, and a ``Location`` header is dropped from the
  response so a client cannot be talked into leaving the pinned host either --
  that client has egress, and following it would spend requests off the account
  this proxy exists to protect.
* The key is read once from a file, held in memory, and never logged, echoed,
  returned or placed in argv. Logs carry the request line and status only.

Run it with ``AGENT_PROXY_KEY_FILE`` pointing at the mounted secret; the default
listen address is loopback, and a container sets ``AGENT_PROXY_HOST=0.0.0.0`` so
the published port can reach it.
"""

from __future__ import annotations

import http.client
import json
import logging
import os
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

# The pin. A different provider is a code change, a review and a rebuild.
UPSTREAM_SCHEME = "https"
UPSTREAM_HOST = "api.neuralwatt.com"
UPSTREAM_PORT = 443
# The provider serves the OpenAI wire format at the root: /v1/... is forwarded
# unchanged, and nothing else is reachable upstream because nothing else routes.
UPSTREAM_PATH_PREFIX = ""

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 18003
DEFAULT_KEY_FILE = "/run/secrets/agent-hosted-key"
DEFAULT_MAX_BODY_BYTES = 1 << 20
UPSTREAM_TIMEOUT_SECONDS = 600.0

ROUTES = frozenset(
    {
        ("GET", "/v1/models"),
        ("POST", "/v1/chat/completions"),
        ("POST", "/v1/completions"),
    }
)
HEALTH_PATH = "/healthz"

#: Headers from the client that may cross. An allowlist on purpose: a credential
#: the caller sends, a forwarding hint, or a Host override is not "filtered", it
#: was never forwarded.
FORWARD_REQUEST_HEADERS = ("Content-Type", "Accept")

#: Hop-by-hop plus the two that would move the caller somewhere else.
DROP_RESPONSE_HEADERS = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "trailers",
        "transfer-encoding",
        "upgrade",
        "content-length",
        "location",
    }
)

LOG = logging.getLogger("agent-proxy")


def load_key(path):
    """Read the provider key. An empty file is a failure, not an empty token."""
    with open(path, "r", encoding="utf-8") as handle:
        key = handle.read().strip()
    if not key:
        raise ValueError("%s is empty" % path)
    return key


def open_upstream():
    """Open the one connection this proxy is allowed to make.

    No argument is request-derived, which is what makes "the upstream is fixed"
    checkable instead of merely intended.
    """
    factory = http.client.HTTPSConnection if UPSTREAM_SCHEME == "https" else http.client.HTTPConnection
    return factory(UPSTREAM_HOST, UPSTREAM_PORT, timeout=UPSTREAM_TIMEOUT_SECONDS)


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "agent-proxy"
    sys_version = ""

    #: Set by make_server.
    api_key = ""
    max_body_bytes = DEFAULT_MAX_BODY_BYTES

    # One method per verb so an unknown verb reaches the same 404 as an unknown
    # path: there is no verb whose default handler answers anything.
    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def do_PUT(self):
        self._dispatch("PUT")

    def do_PATCH(self):
        self._dispatch("PATCH")

    def do_DELETE(self):
        self._dispatch("DELETE")

    def do_HEAD(self):
        self._dispatch("HEAD")

    def do_OPTIONS(self):
        self._dispatch("OPTIONS")

    def do_CONNECT(self):
        # An open proxy is exactly what this must never be, and a tunnel has no
        # path to route: same answer as any other unknown verb.
        self._dispatch("CONNECT")

    def do_TRACE(self):
        self._dispatch("TRACE")

    def _dispatch(self, method):
        parts = urlsplit(self.path)
        if (method, parts.path) not in ROUTES:
            if method == "GET" and parts.path == HEALTH_PATH:
                self._health()
                return
            self._error(404, "no route for %s %s" % (method, parts.path))
            return

        body = self._read_body()
        if body is None:
            return

        target = parts.path + (("?" + parts.query) if parts.query else "")
        self._forward(method, UPSTREAM_PATH_PREFIX + target, body)

    def _read_body(self):
        """Return the request body, or None once an error has been answered."""
        if self.headers.get("Transfer-Encoding"):
            self._error(411, "a chunked request body is not accepted; send Content-Length")
            return None
        declared = self.headers.get("Content-Length", "0")
        try:
            length = int(declared)
        except ValueError:
            self._error(400, "Content-Length is not an integer")
            return None
        if length < 0:
            self._error(400, "Content-Length is negative")
            return None
        # Refused before the body is read: the cap bounds memory, so a caller
        # must not be able to make it allocate first.
        if length > self.max_body_bytes:
            self._error(413, "request body exceeds %d bytes" % self.max_body_bytes)
            return None
        body = self.rfile.read(length) if length else b""
        if len(body) != length:
            self._error(400, "request body is shorter than Content-Length")
            return None
        return body

    def _forward(self, method, target, body):
        headers = {"Authorization": "Bearer " + self.api_key}
        for name in FORWARD_REQUEST_HEADERS:
            value = self.headers.get(name)
            if value:
                headers[name] = value
        headers["Content-Length"] = str(len(body))

        try:
            connection = open_upstream()
        except OSError as exc:
            self._error(502, "upstream unavailable: %s" % exc.__class__.__name__)
            return
        try:
            connection.request(method, target, body=body, headers=headers)
            response = connection.getresponse()
            self._relay(response)
        except (OSError, http.client.HTTPException) as exc:
            self._error(502, "upstream failed: %s" % exc.__class__.__name__)
        finally:
            connection.close()

    def _relay(self, response):
        """Copy the upstream response through without buffering it."""
        declared = response.getheader("Content-Length")
        chunked = declared is None or not declared.isdigit()
        self.send_response(response.status, response.reason)
        for name, value in response.getheaders():
            if name.lower() in DROP_RESPONSE_HEADERS:
                continue
            self.send_header(name, value)
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        else:
            self.send_header("Content-Length", declared)
        self.end_headers()
        self._answered = True

        if chunked:
            while True:
                chunk = response.read1(65536)
                if not chunk:
                    break
                self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        else:
            while True:
                chunk = response.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()

    def _health(self):
        body = json.dumps({"status": "ok", "upstream": UPSTREAM_HOST}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, status, message):
        # Once the response has started, an error cannot replace it: the only
        # safe move is to stop talking.
        self.close_connection = True
        if getattr(self, "_answered", False):
            return
        LOG.warning("%s %s -> %d %s", self.command, self.path, status, message)
        body = json.dumps(
            {"error": {"message": message, "type": "agent_proxy_error", "code": status}}
        ).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_request(self, code="-", size="-"):
        # The request line and the status only: no headers, so no credential,
        # whatever a future change decides to forward.
        LOG.info("%s %s -> %s", self.command, self.path, code)


def make_server(host=DEFAULT_HOST, port=DEFAULT_PORT, api_key="", max_body_bytes=DEFAULT_MAX_BODY_BYTES):
    handler = type(
        "ConfiguredProxyHandler",
        (ProxyHandler,),
        {"api_key": api_key, "max_body_bytes": max_body_bytes},
    )
    server = ThreadingHTTPServer((host, port), handler)
    server.daemon_threads = True
    return server


def main(argv=None):
    logging.basicConfig(stream=sys.stderr, level=logging.INFO, format="agent-proxy: %(message)s")
    host = os.environ.get("AGENT_PROXY_HOST", DEFAULT_HOST)
    port = int(os.environ.get("AGENT_PROXY_PORT", DEFAULT_PORT))
    key_file = os.environ.get("AGENT_PROXY_KEY_FILE", DEFAULT_KEY_FILE)
    max_body_bytes = int(os.environ.get("AGENT_PROXY_MAX_BODY_BYTES", DEFAULT_MAX_BODY_BYTES))

    try:
        api_key = load_key(key_file)
    except (OSError, ValueError) as exc:
        # Fail closed: a proxy with no credential can only produce upstream 401s.
        LOG.error("cannot read the provider key from %s: %s", key_file, exc.__class__.__name__)
        return 1

    server = make_server(host, port, api_key, max_body_bytes)
    LOG.info("listening on %s:%d, forwarding to %s://%s", host, port, UPSTREAM_SCHEME, UPSTREAM_HOST)

    def stop(signum, _frame):
        LOG.info("signal %d: draining", signum)
        # shutdown() waits for serve_forever() to return, so it cannot run on
        # this thread.
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        LOG.info("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
