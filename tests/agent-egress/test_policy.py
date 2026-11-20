"""The policy document: what a document may say, and what is refused at startup.

Every refusal is asserted here because a proxy that started on a document it only
half understood is an open proxy. The literal `sync-v2.brave.com:443` appears only
as the worked example; the tests below also show a second label with a different
host and port, so nothing is keyed to it.
"""

from __future__ import annotations

import tempfile
import unittest

from apps.agent_egress import policy as policy_module
from apps.agent_egress.policy import Policy, PolicyError
from apps.agent_egress.proxy import main as proxy_main
from apps.agent_egress.resolver import main as resolver_main

import fixtures


def a_policy(**sources: list[str]) -> dict:
    return {"version": 1, "sources": {name: {"allow": allow} for name, allow in sources.items()}}


class DocumentTest(unittest.TestCase):
    def test_the_worked_example_is_read_as_a_host_and_a_port(self) -> None:
        policy = Policy.from_document(a_policy(brave=["sync-v2.brave.com:443"]))
        self.assertEqual(policy.source_names, ("brave",))
        self.assertEqual(policy.allowlist("brave"), frozenset({("sync-v2.brave.com", 443)}))
        self.assertEqual(policy.hostnames("brave"), frozenset({"sync-v2.brave.com"}))
        self.assertTrue(policy.permits("brave", "sync-v2.brave.com", 443))
        self.assertFalse(policy.permits("brave", "sync-v2.brave.com", 80))

    def test_a_second_label_carries_its_own_hosts_and_ports(self) -> None:
        policy = Policy.from_document(
            a_policy(brave=["sync-v2.brave.com:443"], search=["api.search.example.com:443", "api.search.example.com:80"])
        )
        self.assertEqual(policy.source_names, ("brave", "search"))
        self.assertEqual(
            policy.allowlist("search"),
            frozenset({("api.search.example.com", 443), ("api.search.example.com", 80)}),
        )
        self.assertFalse(policy.permits("search", "sync-v2.brave.com", 443))

    def test_malformed_json_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = f"{tmp}/policy.json"
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("{not json")
            with self.assertRaisesRegex(PolicyError, "not JSON"):
                Policy.load(path)

    def test_a_missing_document_is_refused(self) -> None:
        with self.assertRaisesRegex(PolicyError, "unreadable"):
            Policy.load("/nonexistent/policy.json")

    def test_a_document_that_is_not_an_object_is_refused(self) -> None:
        for document in ([], "sources", 7, None):
            with self.assertRaisesRegex(PolicyError, "not a JSON object"):
                Policy.from_document(document)

    def test_an_unknown_version_is_refused(self) -> None:
        document = a_policy(brave=["sync-v2.brave.com:443"])
        document["version"] = 2
        with self.assertRaisesRegex(PolicyError, "unsupported policy version"):
            Policy.from_document(document)
        document.pop("version")
        with self.assertRaisesRegex(PolicyError, "unsupported policy version"):
            Policy.from_document(document)

    def test_an_unknown_document_key_is_refused(self) -> None:
        document = a_policy(brave=["sync-v2.brave.com:443"])
        document["constants"] = {"proxyPort": 3128}
        with self.assertRaisesRegex(PolicyError, "unknown keys"):
            Policy.from_document(document)

    def test_a_document_with_no_sources_is_refused(self) -> None:
        for document in ({"version": 1}, {"version": 1, "sources": {}}, {"version": 1, "sources": []}):
            with self.assertRaisesRegex(PolicyError, "no sources"):
                Policy.from_document(document)

    def test_a_source_with_an_empty_allowlist_is_refused(self) -> None:
        with self.assertRaisesRegex(PolicyError, "empty allowlist"):
            Policy.from_document(a_policy(brave=[]))

    def test_a_source_without_an_allow_key_is_refused(self) -> None:
        with self.assertRaisesRegex(PolicyError, "empty allowlist"):
            Policy.from_document({"version": 1, "sources": {"brave": {}}})

    def test_an_unknown_source_key_is_refused(self) -> None:
        document = a_policy(brave=["sync-v2.brave.com:443"])
        document["sources"]["brave"]["gateway"] = "10.77.10.1"
        with self.assertRaisesRegex(PolicyError, "unknown keys"):
            Policy.from_document(document)

    def test_a_source_that_is_not_an_object_is_refused(self) -> None:
        with self.assertRaisesRegex(PolicyError, "not an object"):
            Policy.from_document({"version": 1, "sources": {"brave": ["sync-v2.brave.com:443"]}})

    def test_a_source_label_is_a_plain_name(self) -> None:
        for name in ("Brave", "../brave", "brave/../../etc", "", "a b"):
            with self.assertRaisesRegex(PolicyError, "not a source label"):
                Policy.from_document({"version": 1, "sources": {name: {"allow": ["sync-v2.brave.com:443"]}}})

    def test_a_grant_must_carry_its_port(self) -> None:
        for grant in ("sync-v2.brave.com", "sync-v2.brave.com:", ":443", "sync-v2.brave.com:https"):
            with self.assertRaisesRegex(PolicyError, "host:port|non-numeric port"):
                Policy.from_document(a_policy(brave=[grant]))

    def test_a_grant_must_be_a_real_dns_name_on_a_real_port(self) -> None:
        for grant in (
            "127.0.0.1:443",
            "https://sync-v2.brave.com:443",
            "user@sync-v2.brave.com:443",
            "[::1]:443",
            "sync-v2.brave.com:0",
            "sync-v2.brave.com:70000",
            "*.brave.com:443",
        ):
            with self.assertRaises(PolicyError):
                Policy.from_document(a_policy(brave=[grant]))

    def test_a_repeated_grant_is_refused(self) -> None:
        with self.assertRaisesRegex(PolicyError, "repeats a grant"):
            Policy.from_document(a_policy(brave=["sync-v2.brave.com:443", "SYNC-v2.brave.com:443"]))

    def test_an_unknown_source_raises(self) -> None:
        policy = Policy.from_document(a_policy(brave=["sync-v2.brave.com:443"]))
        with self.assertRaisesRegex(PolicyError, "unknown source"):
            policy.allowlist("nope")
        with self.assertRaisesRegex(PolicyError, "unknown source"):
            policy.hostnames("nope")
        with self.assertRaisesRegex(PolicyError, "unknown source"):
            policy.permits("nope", "sync-v2.brave.com", 443)

    def test_the_policy_is_immutable(self) -> None:
        policy = Policy.from_document(a_policy(brave=["sync-v2.brave.com:443"]))
        with self.assertRaises(AttributeError):
            policy.allowlist("brave").add(("evil.example.com", 443))  # type: ignore[union-attr]


class StartupTest(unittest.TestCase):
    def test_the_proxy_refuses_a_malformed_policy(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = f"{tmp}/policy.json"
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("[]")
            self.assertEqual(proxy_main(["--policy", path, "--source", "brave", "--listen", "127.0.0.1:0"]), 1)
            self.assertEqual(resolver_main(["--policy", path, "--source", "brave", "--listen", "127.0.0.1:0"]), 1)

    def test_the_proxy_refuses_a_source_the_document_does_not_name(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = fixtures.write_policy(tmp, a_policy(brave=["sync-v2.brave.com:443"]))
            self.assertEqual(proxy_main(["--policy", path, "--source", "nope", "--listen", "127.0.0.1:0"]), 1)
            self.assertEqual(resolver_main(["--policy", path, "--source", "nope", "--listen", "127.0.0.1:0"]), 1)

    def test_a_listen_address_must_be_host_and_port(self) -> None:
        self.assertEqual(policy_module.parse_bind("127.0.0.1:3128"), ("127.0.0.1", 3128))
        for text in ("127.0.0.1", "127.0.0.1:", "127.0.0.1:http", "127.0.0.1:0", "127.0.0.1:70000"):
            with self.assertRaises(PolicyError):
                policy_module.parse_bind(text)


if __name__ == "__main__":
    unittest.main()
