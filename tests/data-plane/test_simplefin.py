"""SimpleFIN transport tests: parsing, redaction and the one read.

The provider is a fake opener: the request that would go out is inspected
instead, so the header, the query and the refusal messages are all asserted
without a socket.
"""

from __future__ import annotations

import base64
import json
import unittest
import urllib.error
import urllib.parse
from typing import Any

from data_plane.collectors.raw.simplefin import (
    AccessUrl,
    claim_setup_token,
    fetch_accountset,
    redact,
)
from data_plane.errors import AuthenticationError, ValidationError

ACCESS = "https://alice:s3cr%40t@bridge.example.org/simplefin/"


class FakeResponse:
    def __init__(self, body: bytes, status: int = 200) -> None:
        self._body = body
        self.status = status

    def read(self) -> bytes:
        return self._body

    def __enter__(self) -> FakeResponse:
        return self

    def __exit__(self, *_: Any) -> None:
        return None


class AccessUrlTests(unittest.TestCase):
    def test_splits_and_unquotes(self) -> None:
        access = AccessUrl.parse(ACCESS)
        self.assertEqual(access.url, "https://bridge.example.org/simplefin/")
        self.assertEqual(access.username, "alice")
        self.assertEqual(access.password, "s3cr@t")
        self.assertNotIn("alice", access.url)

    def test_refuses_plain_http(self) -> None:
        with self.assertRaises(ValidationError):
            AccessUrl.parse("http://alice:pass@bridge.example.org/simplefin")

    def test_refuses_an_unclaimed_url(self) -> None:
        with self.assertRaises(ValidationError) as caught:
            AccessUrl.parse("https://bridge.example.org/simplefin")
        self.assertIn("claim the setup token", str(caught.exception))

    def test_accounts_url_asks_for_pending(self) -> None:
        access = AccessUrl.parse(ACCESS)
        url = access.accounts_url(start_date="2026-01-01", end_date="2026-04-01")
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
        self.assertEqual(query["pending"], ["1"])
        self.assertEqual(query["start-date"], ["2026-01-01"])
        self.assertTrue(url.startswith("https://bridge.example.org/simplefin/accounts?"))

    def test_redaction_removes_userinfo(self) -> None:
        self.assertEqual(
            redact(ACCESS), "https://<redacted>@bridge.example.org/simplefin/"
        )
        self.assertEqual(redact("https://bridge.example.org/x"), "https://bridge.example.org/x")


class ClaimTests(unittest.TestCase):
    def test_claims_and_returns_the_access_url(self) -> None:
        claim = "https://bridge.example.org/claim/abc"
        token = base64.b64encode(claim.encode("utf-8")).decode("ascii")
        seen: list[str] = []

        def opener(request, timeout=30):
            seen.append(request.get_method())
            return FakeResponse(ACCESS.encode("utf-8"))

        access = claim_setup_token(token, opener=opener)
        self.assertEqual(access.username, "alice")
        self.assertEqual(seen, ["POST"])

    def test_refuses_a_token_that_is_not_base64(self) -> None:
        with self.assertRaises(ValidationError):
            claim_setup_token("not base64 at all!!")

    def test_a_failed_claim_names_the_host_and_not_the_token(self) -> None:
        token = base64.b64encode(b"https://bridge.example.org/claim/abc").decode("ascii")

        def opener(request, timeout=30):
            raise urllib.error.URLError("name resolution failed")

        with self.assertRaises(AuthenticationError) as caught:
            claim_setup_token(token, opener=opener)
        message = str(caught.exception)
        self.assertIn("bridge.example.org", message)
        self.assertNotIn(token, message)


class FetchTests(unittest.TestCase):
    def test_sends_basic_auth_and_parses_the_document(self) -> None:
        captured: dict[str, Any] = {}

        def opener(request, timeout=30):
            captured["url"] = request.full_url
            captured["authorization"] = request.get_header("Authorization")
            captured["accept"] = request.get_header("Accept")
            return FakeResponse(json.dumps({"accounts": []}).encode("utf-8"))

        payload = fetch_accountset(
            AccessUrl.parse(ACCESS),
            start_date="2026-01-01",
            end_date="2026-04-01",
            opener=opener,
        )
        self.assertEqual(payload, {"accounts": []})
        expected = base64.b64encode(b"alice:s3cr@t").decode("ascii")
        self.assertEqual(captured["authorization"], f"Basic {expected}")
        self.assertEqual(captured["accept"], "application/json")
        self.assertNotIn("alice", captured["url"])
        self.assertNotIn("s3cr", captured["url"])

    def test_an_http_error_is_an_authentication_error(self) -> None:
        def opener(request, timeout=30):
            raise urllib.error.HTTPError(request.full_url, 403, "Forbidden", {}, None)

        with self.assertRaises(AuthenticationError) as caught:
            fetch_accountset(AccessUrl.parse(ACCESS), opener=opener)
        self.assertIn("403", str(caught.exception))
        self.assertNotIn("s3cr", str(caught.exception))

    def test_a_non_json_body_is_refused(self) -> None:
        def opener(request, timeout=30):
            return FakeResponse(b"<html>nope</html>")

        with self.assertRaises(ValidationError):
            fetch_accountset(AccessUrl.parse(ACCESS), opener=opener)

    def test_a_non_object_body_is_refused(self) -> None:
        def opener(request, timeout=30):
            return FakeResponse(b"[1, 2, 3]")

        with self.assertRaises(ValidationError):
            fetch_accountset(AccessUrl.parse(ACCESS), opener=opener)

    def test_a_transport_failure_names_the_host(self) -> None:
        def opener(request, timeout=30):
            raise urllib.error.URLError("connection refused")

        with self.assertRaises(ValidationError) as caught:
            fetch_accountset(AccessUrl.parse(ACCESS), opener=opener)
        self.assertIn("bridge.example.org", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
