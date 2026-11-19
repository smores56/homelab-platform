"""In-process tests for the hosted-model proxy.

No network and no TLS: the upstream connection is replaced with a fake that
records the request it was given and replays a canned response, so every
assertion is about what the shipped handler does with a request rather than about
a provider on the internet. The HTTP server itself is real, on a random loopback
port, and the client is a real ``http.client`` connection.
"""

from __future__ import annotations

import http.client
import json
import socket
import threading
import unittest
from unittest import mock

import proxy

PINNED_KEY = "pinned-hosted-key-value"
CALLER_KEY = "caller-supplied-token"
CAP = 4096


class FakeResponse:
    """The part of ``http.client.HTTPResponse`` the handler reads."""

    def __init__(self, status=200, reason="OK", headers=None, body=b"", chunks=None):
        self.status = status
        self.reason = reason
        if headers is None:
            # A body without a length would be relayed as a chunked stream with
            # nothing in it, so the default is the shape a provider returns.
            headers = [("Content-Type", "application/json"), ("Content-Length", str(len(body)))]
        self._headers = list(headers)
        self._body = body
        self._chunks = list(chunks or [])
        self._replay = list(chunks or [])
        self._sent = False

    def reset(self):
        """Rewind, so one fake response can answer a subtest's requests."""
        self._sent = False
        self._chunks = list(self._replay)

    def getheader(self, name):
        for header, value in self._headers:
            if header.lower() == name.lower():
                return value
        return None

    def getheaders(self):
        return list(self._headers)

    def read(self, _amount=None):
        if self._sent:
            return b""
        self._sent = True
        return self._body

    def read1(self, _amount=None):
        return self._chunks.pop(0) if self._chunks else b""


class FakeConnection:
    """The upstream connection: records what was sent, replays one response."""

    def __init__(self, response):
        self.response = response
        self.requests = []
        self.closed = False

    def request(self, method, target, body=None, headers=None):
        self.response.reset()
        self.requests.append(
            {"method": method, "target": target, "body": body, "headers": dict(headers or {})}
        )

    def getresponse(self):
        return self.response

    def close(self):
        self.closed = True


class ProxyTest(unittest.TestCase):
    def setUp(self):
        self.server = proxy.make_server("127.0.0.1", 0, PINNED_KEY, CAP)
        self.address = self.server.server_address
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self._stop)
        self.upstream = FakeConnection(FakeResponse(body=b'{"object":"list","data":[]}'))
        patcher = mock.patch.object(proxy, "open_upstream", return_value=self.upstream)
        self.open_upstream = patcher.start()
        self.addCleanup(patcher.stop)

    def _stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    # -- helpers -----------------------------------------------------------

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection(*self.address, timeout=5)
        self.addCleanup(connection.close)
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        return response

    def json_request(self, method, path, payload=None, headers=None):
        body = None if payload is None else json.dumps(payload).encode("utf-8")
        base = {"Content-Type": "application/json"}
        base.update(headers or {})
        response = self.request(method, path, body, base)
        return response, response.read()

    # -- (a) the allowed routes are forwarded --------------------------------

    def test_allowed_routes_reach_the_pinned_upstream(self):
        cases = (
            ("GET", "/v1/models", None),
            ("POST", "/v1/chat/completions", {"model": "hosted", "messages": []}),
            ("POST", "/v1/completions", {"model": "hosted", "prompt": "hi"}),
        )
        for method, path, payload in cases:
            with self.subTest(method=method, path=path):
                self.upstream.requests.clear()
                response, body = self.json_request(method, path, payload)
                self.assertEqual(response.status, 200)
                self.assertEqual(json.loads(body), {"object": "list", "data": []})
                self.assertEqual(len(self.upstream.requests), 1)
                sent = self.upstream.requests[0]
                self.assertEqual(sent["method"], method)
                self.assertEqual(sent["target"], path)
                self.assertEqual(sent["headers"]["Authorization"], "Bearer " + PINNED_KEY)
                if payload is None:
                    self.assertEqual(sent["body"], b"")
                else:
                    self.assertEqual(json.loads(sent["body"]), payload)

    def test_query_string_is_forwarded_and_nothing_else_moves(self):
        response, _body = self.json_request("GET", "/v1/models?limit=3")
        self.assertEqual(response.status, 200)
        self.assertEqual(self.upstream.requests[0]["target"], "/v1/models?limit=3")

    def test_healthz_answers_locally_without_dialling_upstream(self):
        response, body = self.json_request("GET", "/healthz")
        self.assertEqual(response.status, 200)
        self.assertEqual(json.loads(body)["status"], "ok")
        self.assertEqual(self.upstream.requests, [])

    def test_streaming_response_is_relayed_chunk_by_chunk(self):
        self.upstream.response = FakeResponse(
            headers=[("Content-Type", "text/event-stream")],
            chunks=[b'data: {"delta":1}\n\n', b'data: {"delta":2}\n\n', b"data: [DONE]\n\n"],
        )
        response, body = self.json_request(
            "POST", "/v1/chat/completions", {"model": "hosted", "stream": True}
        )
        self.assertEqual(response.status, 200)
        self.assertEqual(response.getheader("Transfer-Encoding"), "chunked")
        self.assertEqual(body, b'data: {"delta":1}\n\ndata: {"delta":2}\n\ndata: [DONE]\n\n')

    # -- (b) unknown routes -------------------------------------------------

    def test_unknown_path_is_404_json_and_never_forwarded(self):
        for method, path in (
            ("GET", "/v1/embeddings"),
            ("POST", "/v1/models"),
            ("GET", "/"),
            ("POST", "/v1/chat/completions/../../admin"),
            ("DELETE", "/v1/models"),
            ("OPTIONS", "/v1/completions"),
        ):
            with self.subTest(method=method, path=path):
                self.upstream.requests.clear()
                response, body = self.json_request(method, path, {})
                self.assertEqual(response.status, 404)
                self.assertEqual(json.loads(body)["error"]["code"], 404)
                self.assertEqual(response.getheader("Cache-Control"), "no-store")
                self.assertEqual(self.upstream.requests, [])

    # -- (c) and (e) the body cap ------------------------------------------

    def test_oversized_body_is_refused_before_it_is_read(self):
        connection = socket.create_connection(self.address, timeout=5)
        self.addCleanup(connection.close)
        connection.sendall(
            b"POST /v1/chat/completions HTTP/1.1\r\n"
            b"Host: localhost\r\n"
            b"Content-Type: application/json\r\n"
            b"Content-Length: %d\r\n\r\n" % (CAP + 1)
        )
        answer = connection.recv(4096)
        self.assertIn(b"413", answer.split(b"\r\n", 1)[0])
        self.assertIn(b"Cache-Control: no-store", answer)
        self.assertEqual(self.upstream.requests, [])

    def test_body_at_the_cap_is_accepted(self):
        payload = {"model": "hosted", "messages": [{"role": "user", "content": "x" * 1000}]}
        encoded = json.dumps(payload).encode("utf-8")
        response, _body = self.json_request("POST", "/v1/chat/completions", payload)
        self.assertEqual(response.status, 200)
        self.assertEqual(len(self.upstream.requests[0]["body"]), len(encoded))

    # -- (d) the credential -------------------------------------------------

    def test_inbound_authorization_is_replaced_not_forwarded(self):
        response, _body = self.json_request(
            "POST",
            "/v1/chat/completions",
            {"model": "hosted", "messages": []},
            headers={"Authorization": "Bearer " + CALLER_KEY},
        )
        self.assertEqual(response.status, 200)
        sent = self.upstream.requests[0]
        self.assertEqual(sent["headers"]["Authorization"], "Bearer " + PINNED_KEY)
        self.assertNotIn(CALLER_KEY, json.dumps(sent["headers"]))
        self.assertNotIn(CALLER_KEY, json.dumps({k.lower(): v for k, v in sent["headers"].items()}))

    def test_credential_bearing_headers_are_dropped(self):
        response, _body = self.json_request(
            "GET",
            "/v1/models",
            None,
            headers={
                "Cookie": "session=" + CALLER_KEY,
                "X-Api-Key": CALLER_KEY,
                "Proxy-Authorization": "Basic " + CALLER_KEY,
            },
        )
        self.assertEqual(response.status, 200)
        forwarded = json.dumps(self.upstream.requests[0]["headers"])
        self.assertNotIn(CALLER_KEY, forwarded)
        self.assertEqual(
            set(name.lower() for name in self.upstream.requests[0]["headers"]),
            {"authorization", "content-length", "content-type"},
        )

    # -- (f) the upstream cannot be moved ----------------------------------

    def test_upstream_is_fixed_regardless_of_request_arguments(self):
        self.assertEqual(proxy.UPSTREAM_SCHEME, "https")
        self.assertEqual(proxy.UPSTREAM_HOST, "api.neuralwatt.com")
        self.assertEqual(proxy.UPSTREAM_PORT, 443)
        response, _body = self.json_request(
            "GET",
            "/v1/models?upstream=https://attacker.invalid/v1&host=attacker.invalid",
            None,
            headers={
                "Host": "attacker.invalid",
                "X-Forwarded-Host": "attacker.invalid",
                "X-Forwarded-For": "203.0.113.7",
                "X-Original-URL": "https://attacker.invalid/v1/models",
            },
        )
        self.assertEqual(response.status, 200)
        # No argument, so no request-derived value can reach the dial.
        self.open_upstream.assert_called_once_with()
        sent = self.upstream.requests[0]
        self.assertEqual(sent["target"], "/v1/models?upstream=https://attacker.invalid/v1&host=attacker.invalid")
        self.assertNotIn("attacker.invalid", json.dumps({k: v for k, v in sent["headers"].items() if k.lower() != "authorization"}))

    def test_upstream_redirect_is_not_followed_and_location_is_dropped(self):
        self.upstream.response = FakeResponse(
            status=302,
            reason="Found",
            headers=[("Location", "https://attacker.invalid/steal"), ("Content-Type", "text/plain")],
            body=b"",
        )
        response, _body = self.json_request("POST", "/v1/chat/completions", {"model": "hosted"})
        self.assertEqual(response.status, 302)
        self.assertIsNone(response.getheader("Location"))
        self.assertEqual(len(self.upstream.requests), 1)

    # -- failure paths ------------------------------------------------------

    def test_upstream_error_is_a_502_json_without_cache(self):
        with mock.patch.object(proxy, "open_upstream", side_effect=OSError("refused")):
            response, body = self.json_request("POST", "/v1/chat/completions", {"model": "hosted"})
        self.assertEqual(response.status, 502)
        self.assertEqual(json.loads(body)["error"]["code"], 502)
        self.assertEqual(response.getheader("Cache-Control"), "no-store")

    def test_key_loading_strips_whitespace_and_refuses_empty(self):
        import tempfile
        from pathlib import Path

        with tempfile.TemporaryDirectory() as directory:
            key_file = Path(directory) / "key"
            key_file.write_text(PINNED_KEY + "\n", encoding="utf-8")
            self.assertEqual(proxy.load_key(str(key_file)), PINNED_KEY)
            key_file.write_text("\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                proxy.load_key(str(key_file))
            with self.assertRaises(OSError):
                proxy.load_key(str(Path(directory) / "absent"))


if __name__ == "__main__":
    unittest.main()
