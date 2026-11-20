"""The resolver: answers an allowed name, refuses everything else.

No packet leaves the process. `handle` is called with a socket stand-in and an
injected upstream lookup, so the response bytes and the fact that an unlisted name
was never looked up are both assertions.
"""

from __future__ import annotations

import unittest

import fixtures


class ResolveTest(unittest.TestCase):
    def setUp(self) -> None:
        self.resolver, self.log, self.asked, self.sock = fixtures.resolver_of(
            fixtures.brave_policy(), "brave", ["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"]
        )
        self.peer = ("127.0.0.1", 5353)

    def ask(self, qname: str, qtype: int = 1) -> bytes:
        self.resolver.handle(self.sock, fixtures.dns_query(qname, qtype), self.peer)
        return self.sock.sent[-1]

    def test_an_allowed_name_is_answered(self) -> None:
        answer = self.ask("sync-v2.brave.com")
        self.assertEqual(fixtures.dns_rcode(answer), 0)
        self.assertEqual(fixtures.dns_answer_count(answer), 1)
        self.assertIn(bytes([93, 184, 216, 34]), answer)
        self.assertEqual(self.asked, ["sync-v2.brave.com"])

    def test_an_allowed_name_answers_aaaa(self) -> None:
        answer = self.ask("sync-v2.brave.com", qtype=28)
        self.assertEqual(fixtures.dns_rcode(answer), 0)
        self.assertEqual(fixtures.dns_answer_count(answer), 1)

    def test_an_unlisted_name_is_refused_without_resolving_it(self) -> None:
        answer = self.ask("evil.example.com")
        self.assertEqual(fixtures.dns_rcode(answer), 5)
        self.assertEqual(fixtures.dns_answer_count(answer), 0)
        self.assertEqual(self.asked, [])
        self.assertIn("not_allowlisted", self.log.text())

    def test_an_unsupported_qtype_is_refused(self) -> None:
        answer = self.ask("sync-v2.brave.com", qtype=16)  # TXT
        self.assertEqual(fixtures.dns_rcode(answer), 5)
        self.assertEqual(self.asked, [])
        self.assertIn("unsupported_type", self.log.text())

    def test_a_non_public_answer_is_dropped(self) -> None:
        resolver, _log, _asked, sock = fixtures.resolver_of(fixtures.brave_policy(), "brave", ["127.0.0.1"])
        resolver.handle(sock, fixtures.dns_query("sync-v2.brave.com"), self.peer)
        self.assertEqual(fixtures.dns_answer_count(sock.sent[-1]), 0)

    def test_a_malformed_query_is_dropped(self) -> None:
        self.resolver.handle(self.sock, b"\x00\x01", self.peer)
        self.assertEqual(self.sock.sent, [])
        self.assertIn("drop", self.log.events())

    def test_one_label_does_not_answer_another_labels_names(self) -> None:
        resolver, _log, asked, sock = fixtures.resolver_of(
            fixtures.policy_of(
                {
                    "version": 1,
                    "sources": {
                        "brave": {"allow": ["sync-v2.brave.com:443"]},
                        "search": {"allow": ["api.search.example.com:443"]},
                    },
                }
            ),
            "search",
            ["198.51.100.7"],
        )
        resolver.handle(sock, fixtures.dns_query("sync-v2.brave.com"), self.peer)
        self.assertEqual(fixtures.dns_rcode(sock.sent[-1]), 5)
        resolver.handle(sock, fixtures.dns_query("api.search.example.com"), self.peer)
        self.assertEqual(fixtures.dns_rcode(sock.sent[-1]), 0)
        self.assertEqual(asked, ["api.search.example.com"])

    def test_the_log_never_carries_a_path_or_a_query(self) -> None:
        self.ask("sync-v2.brave.com")
        self.ask("evil.example.com")
        text = self.log.text()
        for forbidden in ("/", "?", "&"):
            self.assertNotIn(forbidden, text)


if __name__ == "__main__":
    unittest.main()
