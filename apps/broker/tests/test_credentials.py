"""Credential resolution and the fail-closed broker path."""

from __future__ import annotations

import io
import unittest

from broker.config import Config, Enrollment, Injection
from broker.credentials import StaticCredentials
from broker.server import Broker


class StaticTests(unittest.TestCase):
    def test_a_static_enrollment_reads_its_file(self):
        enrollment = Enrollment(
            name="neuralwatt",
            scheme="https",
            host="api.example.test",
            port=443,
            allow_private=False,
            secret_name="neuralwatt-api-key",
            injection=Injection(kind="bearer"),
        )
        credentials = StaticCredentials({"neuralwatt-api-key": "sk-test"})
        self.assertEqual(credentials.value(enrollment), "sk-test")
        self.assertEqual(credentials.values(), {"neuralwatt-api-key": "sk-test"})

    def test_an_enrollment_with_no_credential_resolves_to_nothing(self):
        enrollment = Enrollment(
            name="self",
            scheme="http",
            host="agent-control.tenant-apps.svc.cluster.local",
            port=8081,
            allow_private=True,
            secret_name="",
            injection=Injection(kind="none"),
        )
        self.assertEqual(StaticCredentials({}).value(enrollment), "")


class Handler:
    command = "GET"
    path = "/notify/v1/notify"
    headers = {"Host": "broker"}

    def __init__(self):
        self.wfile = io.BytesIO()
        self.rfile = io.BytesIO(b"")
        self.status = None

    def send_response_only(self, status):
        self.status = status

    def send_header(self, name, value):
        return

    def end_headers(self):
        return


class FailClosedTests(unittest.TestCase):
    def test_an_unprovisioned_optional_secret_is_a_503_and_never_a_forward(self):
        # SDLC #640: a host enrolled before its credential exists must not take
        # the broker down at startup, and must never be forwarded without it.
        config = Config(
            listen_host="127.0.0.1",
            listen_port=8080,
            deny_addresses=(),
            hosts={
                "notify": Enrollment(
                    name="notify",
                    scheme="https",
                    host="notify.invalid",
                    port=443,
                    allow_private=False,
                    secret_name="notify-token",
                    injection=Injection(kind="bearer"),
                    optional_secret=True,
                )
            },
        )
        broker = Broker(
            config=config,
            credentials=StaticCredentials({}),
            resolver=lambda *args, **kwargs: [(2, 1, 6, "", ("93.184.216.34", 443))],
        )
        handler = Handler()
        handler.command = "POST"
        handler.headers = {"Host": "broker", "Content-Length": "0"}

        broker.handle(handler)

        self.assertEqual(handler.status, 503)
        self.assertIn(b"credential_unavailable", handler.wfile.getvalue())


if __name__ == "__main__":
    unittest.main()
