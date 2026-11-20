"""The proxy's decisions, driven over a loopback listener with an injected dialer.

Every refusal is asserted twice: the client sees a 403 (or a closed tunnel) and the
dialer was never called, so a refused request cannot have touched an upstream. The
log assertions are on captured output: a path, a query or a payload must not appear
in any line the proxy printed.
"""

from __future__ import annotations

import contextlib
import io
import socket
import tempfile
import unittest

import fixtures
from apps.agent_egress import proxy as proxy_module


def a_harness(dial=None) -> fixtures.Harness:
    return fixtures.Harness(fixtures.brave_policy(), "brave", dial=dial)


class ConnectTest(unittest.TestCase):
    def setUp(self) -> None:
        self.upstream = fixtures.Upstream()
        self.harness = a_harness(dial=self.upstream.dial)
        self.addCleanup(self.upstream.close)
        self.addCleanup(self.harness.close)
        self.client = self.harness.client()
        self.addCleanup(self.client.close)

    def connect(self, authority: str) -> bytes:
        self.client.sendall(f"CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n\r\n".encode())
        return fixtures.read_headers(self.client)

    def test_allowed_name_with_matching_sni_is_tunnelled(self) -> None:
        self.assertTrue(self.connect("sync-v2.brave.com:443").startswith(b"HTTP/1.1 200"))

        hello = fixtures.client_hello("sync-v2.brave.com")
        self.client.sendall(hello)
        forwarded = self.upstream.read_at_least(len(hello))
        self.assertEqual(forwarded, hello)
        self.assertEqual(self.upstream.dials, [("sync-v2.brave.com", 443)])

        self.upstream.local.sendall(b"origin-response")
        self.assertEqual(fixtures.recv_exact(self.client, len(b"origin-response")), b"origin-response")

    def test_unlisted_name_is_refused_before_any_dial(self) -> None:
        self.assertTrue(self.connect("evil.example.com:443").startswith(b"HTTP/1.1 403"))
        self.assertEqual(self.upstream.dials, [])
        self.assertIn("deny", self.harness.log.events())
        self.assertIn("not_allowlisted", self.harness.log.text())

    def test_an_allowed_name_on_an_unlisted_port_is_refused(self) -> None:
        self.assertTrue(self.connect("sync-v2.brave.com:8443").startswith(b"HTTP/1.1 403"))
        self.assertEqual(self.upstream.dials, [])

    def test_an_ip_literal_is_refused(self) -> None:
        self.assertTrue(self.connect("93.184.216.34:443").startswith(b"HTTP/1.1 403"))
        self.assertEqual(self.upstream.dials, [])

    def test_sni_that_differs_from_the_requested_host_is_refused_before_any_dial(self) -> None:
        self.assertTrue(self.connect("sync-v2.brave.com:443").startswith(b"HTTP/1.1 200"))
        self.client.sendall(fixtures.client_hello("evil.example.com"))

        # The 200 is already on the wire, so the refusal is the closed tunnel.
        self.assertEqual(self.client.recv(4096), b"")
        self.assertEqual(self.upstream.dials, [])
        self.assertIn("sni_mismatch", self.harness.log.text())

    def test_a_client_hello_without_sni_is_refused_before_any_dial(self) -> None:
        self.assertTrue(self.connect("sync-v2.brave.com:443").startswith(b"HTTP/1.1 200"))
        self.client.sendall(fixtures.client_hello(None))

        self.assertEqual(self.client.recv(4096), b"")
        self.assertEqual(self.upstream.dials, [])
        self.assertIn("has no SNI", self.harness.log.text())

    def test_sni_inside_a_fragmented_client_hello_is_still_checked(self) -> None:
        self.assertTrue(self.connect("sync-v2.brave.com:443").startswith(b"HTTP/1.1 200"))
        hello = fixtures.client_hello("sync-v2.brave.com")
        self.client.sendall(hello[:10])
        self.client.sendall(hello[10:])

        self.assertEqual(self.upstream.read_at_least(len(hello)), hello)
        self.assertEqual(self.upstream.dials, [("sync-v2.brave.com", 443)])

    def test_a_malformed_request_line_is_refused(self) -> None:
        self.client.sendall(b"GET-ONLY-TWO-PARTS\r\n\r\n")
        self.assertTrue(fixtures.read_headers(self.client).startswith(b"HTTP/1.1 403"))
        self.assertEqual(self.upstream.dials, [])


class AbsoluteFormTest(unittest.TestCase):
    def setUp(self) -> None:
        self.upstream = fixtures.Upstream()
        self.harness = fixtures.Harness(fixtures.plain_http_policy(), "brave", dial=self.upstream.dial)
        self.addCleanup(self.upstream.close)
        self.addCleanup(self.harness.close)
        self.client = self.harness.client()
        self.addCleanup(self.client.close)

    def test_an_allowed_absolute_form_request_is_forwarded(self) -> None:
        request = (
            b"GET http://sync-v2.brave.com/secret/path?token=abc HTTP/1.1\r\n"
            b"Host: sync-v2.brave.com\r\nAccept: */*\r\n\r\n"
        )
        self.client.sendall(request)
        forwarded = self.upstream.read_at_least(len(b"GET http://sync-v2.brave.com/secret/path?token=abc"))
        self.assertTrue(forwarded.startswith(b"GET /secret/path?token=abc HTTP/1.1\r\n"), forwarded)
        self.assertIn(b"Host: sync-v2.brave.com\r\n", forwarded)
        self.assertNotIn(b"proxy-connection", forwarded.lower())
        self.assertEqual(self.upstream.dials, [("sync-v2.brave.com", 80)])

    def test_a_host_header_that_disagrees_with_the_target_is_refused_before_any_dial(self) -> None:
        self.client.sendall(
            b"GET http://sync-v2.brave.com/secret/path?token=abc HTTP/1.1\r\n"
            b"Host: other.example.com\r\n\r\n"
        )
        self.assertTrue(fixtures.read_headers(self.client).startswith(b"HTTP/1.1 403"))
        self.assertEqual(self.upstream.dials, [])
        self.assertIn("host_mismatch", self.harness.log.text())

    def test_an_allowed_host_on_an_unlisted_port_is_refused_before_any_dial(self) -> None:
        self.client.sendall(b"GET http://sync-v2.brave.com:8080/ HTTP/1.1\r\nHost: sync-v2.brave.com\r\n\r\n")
        self.assertTrue(fixtures.read_headers(self.client).startswith(b"HTTP/1.1 403"))
        self.assertEqual(self.upstream.dials, [])

    def test_an_unlisted_absolute_form_target_is_refused_before_any_dial(self) -> None:
        self.client.sendall(b"GET http://evil.example.com/ HTTP/1.1\r\nHost: evil.example.com\r\n\r\n")
        self.assertTrue(fixtures.read_headers(self.client).startswith(b"HTTP/1.1 403"))
        self.assertEqual(self.upstream.dials, [])

    def test_an_https_absolute_form_target_is_refused(self) -> None:
        self.client.sendall(b"GET https://sync-v2.brave.com/ HTTP/1.1\r\nHost: sync-v2.brave.com\r\n\r\n")
        self.assertTrue(fixtures.read_headers(self.client).startswith(b"HTTP/1.1 403"))
        self.assertEqual(self.upstream.dials, [])


class LogTest(unittest.TestCase):
    def test_no_log_line_carries_a_path_a_query_or_a_payload(self) -> None:
        # The real sink, not the recorder: this asserts what the process prints.
        captured = io.StringIO()
        marker = "SEKRIT-PAYLOAD-MARKER"
        with contextlib.redirect_stdout(captured):
            harness = fixtures.Harness(fixtures.plain_http_policy(), "brave", emit=proxy_module.log)
            self.addCleanup(harness.close)
            absolute = harness.client()
            self.addCleanup(absolute.close)
            absolute.sendall(
                (
                    f"GET http://sync-v2.brave.com/private/report?token={marker} HTTP/1.1\r\n"
                    f"Host: other.example.com\r\nX-Body-Marker: {marker}\r\n\r\n"
                ).encode()
            )
            fixtures.read_headers(absolute)
            connect = harness.client()
            self.addCleanup(connect.close)
            connect.sendall(b"CONNECT sync-v2.brave.com:443 HTTP/1.1\r\n\r\n")
            fixtures.read_headers(connect)
            connect.sendall(fixtures.client_hello("evil.example.com"))
            connect.recv(4096)

        lines = captured.getvalue().splitlines()
        self.assertTrue(lines, "the proxy printed nothing")
        for line in lines:
            for forbidden in ("/private/report", "/private", "token=", marker):
                self.assertNotIn(forbidden, line)
        self.assertIn("deny", captured.getvalue())


class BindTest(unittest.TestCase):
    def test_the_proxy_refuses_to_start_when_the_listener_cannot_bind(self) -> None:
        occupied = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        occupied.bind(("127.0.0.1", 0))
        occupied.listen(1)
        self.addCleanup(occupied.close)
        port = occupied.getsockname()[1]

        with tempfile.TemporaryDirectory() as tmp:
            path = fixtures.write_policy(tmp, fixtures.BRAVE)
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                code = proxy_module.main(
                    ["--policy", path, "--source", "brave", "--listen", f"127.0.0.1:{port}"]
                )
        self.assertEqual(code, 1)
        self.assertIn("bind-failed", captured.getvalue())


if __name__ == "__main__":
    unittest.main()
