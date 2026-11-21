"""The IMAP stream collector, against a scripted mailbox rather than a server.

Every case supplies a ``Mailbox`` whose folders, UIDs, bodies and flags are
scripted per pass, so the collector's decisions -- what to fetch, what to carry,
what to tombstone, what to refuse -- are what is tested. The real ``imaplib``
wrapper has no test-only branch in the logic below it.
"""

from __future__ import annotations

import json
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import unittest
from dataclasses import dataclass, field
from unittest import mock
from pathlib import Path

from data_plane.collectors.raw import RawReplica, previous_replica
from data_plane.collectors.raw.mail import SOURCE_ID
from data_plane.collectors.staging import StagingGeneration
from data_plane.collectors.stream import (
    IdleLine,
    Mailbox,
    collect_mailbox,
    message_headers,
    pinned_tls_context,
    normalize_flags,
    parse_idle_line,
    uid_diff,
    validate_folder,
)
from data_plane.errors import EpochError, ManifestError, PublishError, ValidationError

CAPTURED = "2026-11-19T00:00:00+00:00"
LATER = "2026-11-20T00:00:00+00:00"


def _message(uid: str) -> bytes:
    return (
        "From: someone@example.com\r\n"
        f"Message-ID: <{uid}@example.com>\r\n"
        "Date: Wed, 18 Nov 2026 10:00:00 +0000\r\n"
        f"Subject: message {uid}\r\n"
        f"\r\nbody {uid}\r\n"
    ).encode("utf-8")


@dataclass
class ScriptedFolder:
    """One folder's state for one pass."""

    uidvalidity: int
    messages: dict[str, bytes]
    flags: dict[str, tuple[str, ...]] = field(default_factory=dict)


class ScriptedMailbox(Mailbox):
    """A provider-shaped ``Mailbox`` that records what the collector asked for.

    ``fetched`` is the whole point: a pass over an unchanged mailbox must record
    no body fetch at all, and a pass with one new UID must record exactly one.
    """

    def __init__(self, folders: dict[str, ScriptedFolder]) -> None:
        self._folders = folders
        self._selected: str | None = None
        self.selected: list[str] = []
        self.fetched: list[tuple[str, str]] = []
        self.flag_fetches = 0

    def folders(self) -> list[str]:
        return list(self._folders)

    def select(self, folder: str) -> int:
        if folder not in self._folders:
            raise AssertionError(f"the collector selected {folder!r}, which does not exist")
        self._selected = folder
        self.selected.append(folder)
        return self._folders[folder].uidvalidity

    def _folder(self) -> ScriptedFolder:
        if self._selected is None:
            raise AssertionError("the collector used the mailbox without selecting a folder")
        return self._folders[self._selected]

    def uid_search_all(self) -> list[str]:
        return list(self._folder().messages)

    def uid_fetch(self, uid: str) -> bytes:
        self.fetched.append((self._selected or "", uid))
        return self._folder().messages[uid]

    def uid_flags(self) -> dict[str, tuple[str, ...]]:
        self.flag_fetches += 1
        return dict(self._folder().flags)


def _publish(
    root: Path,
    mailbox: Mailbox,
    *,
    name: str = "gen-0001",
    captured_at: str = CAPTURED,
):
    generation = StagingGeneration(root, name, source_id=SOURCE_ID)
    report = collect_mailbox(mailbox, generation, previous_replica(generation), captured_at)
    generation.commit_next(complete=True)
    return report


class MailCollectionTests(unittest.TestCase):
    def test_first_pass_publishes_and_stores_the_epoch_map(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            mailbox = ScriptedMailbox(
                {
                    "INBOX": ScriptedFolder(
                        1, {"1": _message("1"), "2": _message("2")}
                    )
                }
            )
            generation = StagingGeneration(root, "gen-0001", source_id=SOURCE_ID)
            report = collect_mailbox(
                mailbox, generation, previous_replica(generation), CAPTURED
            )

            self.assertEqual(report.source_id, "tuta.mail")
            self.assertEqual(report.objects, 2)
            self.assertEqual(report.carried, 0)
            self.assertEqual(report.deleted, 0)
            self.assertEqual(report.details, {"folders": {"INBOX": 2}})
            # Collection and publication are separate steps: the collector never
            # commits, so nothing is visible before the caller does.
            self.assertIsNone(RawReplica.latest_generation(root))

            generation.commit_next(complete=True)
            replica = RawReplica(root)
            self.assertEqual(
                json.loads(replica.read("mail::_uidvalidity")), {"INBOX": 1}
            )
            self.assertEqual(replica.read("mail::INBOX::1"), _message("1"))
            metadata = replica.metadata("mail::INBOX::2")
            self.assertEqual(metadata["source_id"], "tuta.mail")
            self.assertEqual(metadata["folder"], "INBOX")
            self.assertEqual(metadata["key"], "2")
            self.assertEqual(metadata["uidvalidity"], 1)
            self.assertEqual(metadata["message_id"], "<2@example.com>")
            self.assertEqual(metadata["date"], "Wed, 18 Nov 2026 10:00:00 +0000")
            self.assertEqual(metadata["captured_at"], CAPTURED)
            self.assertEqual(metadata["size"], len(_message("2")))

    def test_second_pass_fetches_only_new_uids_and_carries_the_rest(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            first = ScriptedMailbox(
                {
                    "INBOX": ScriptedFolder(
                        1,
                        {"1": _message("1"), "2": _message("2")},
                        {"1": (), "2": ()},
                    )
                }
            )
            _publish(root, first)

            second = ScriptedMailbox(
                {
                    "INBOX": ScriptedFolder(
                        1,
                        {
                            "1": _message("1"),
                            "2": _message("2"),
                            "3": _message("3"),
                        },
                        {"1": ("\\Seen",), "2": (), "3": ("\\Flagged",)},
                    )
                }
            )
            generation = StagingGeneration(root, "gen-0002", source_id=SOURCE_ID)
            report = collect_mailbox(
                second, generation, previous_replica(generation), LATER
            )

            self.assertEqual(second.fetched, [("INBOX", "3")])
            self.assertEqual(report.objects, 3)
            self.assertEqual(report.carried, 2)
            self.assertEqual(report.deleted, 0)
            self.assertEqual(second.flag_fetches, 1)

            generation.commit_next(complete=True)
            replica = RawReplica(root)
            # The carried body and the time it was first captured do not move.
            self.assertEqual(replica.read("mail::INBOX::2"), _message("2"))
            self.assertEqual(
                replica.metadata("mail::INBOX::2")["captured_at"], CAPTURED
            )
            # A flag change is metadata, not a re-fetch.
            self.assertEqual(replica.metadata("mail::INBOX::1")["flags"], ["\\Seen"])
            self.assertEqual(replica.metadata("mail::INBOX::3")["flags"], ["\\Flagged"])

    def test_a_vanished_uid_in_a_stable_epoch_is_tombstoned(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _publish(
                root,
                ScriptedMailbox(
                    {
                        "INBOX": ScriptedFolder(
                            1, {"1": _message("1"), "2": _message("2")}
                        )
                    }
                ),
            )

            mailbox = ScriptedMailbox(
                {"INBOX": ScriptedFolder(1, {"1": _message("1")})}
            )
            generation = StagingGeneration(root, "gen-0002", source_id=SOURCE_ID)
            report = collect_mailbox(
                mailbox, generation, previous_replica(generation), LATER
            )
            self.assertEqual(report.deleted, 1)
            self.assertEqual(mailbox.fetched, [])
            generation.commit_next(complete=True)

            replica = RawReplica(root)
            self.assertNotIn("mail::INBOX::2", replica.object_ids())
            self.assertIn(
                {"object_id": "mail::INBOX::2", "tombstone": True},
                replica.manifest["tombstones"],
            )
            with self.assertRaises(ManifestError):
                replica.read("mail::INBOX::2")

    def test_a_changed_uidvalidity_raises_epoch_error_and_aborts(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _publish(
                root,
                ScriptedMailbox(
                    {"INBOX": ScriptedFolder(1, {"1": _message("1")})}
                ),
            )

            mailbox = ScriptedMailbox(
                {"INBOX": ScriptedFolder(2, {"1": _message("1")})}
            )
            generation = StagingGeneration(root, "gen-0002", source_id=SOURCE_ID)
            with self.assertRaises(EpochError):
                collect_mailbox(mailbox, generation, previous_replica(generation), LATER)
            generation.abort()

            self.assertEqual(mailbox.fetched, [])
            self.assertEqual(RawReplica.latest_generation(root), "gen-0001")
            self.assertFalse((root / ".staging" / "gen-0002").exists())
            self.assertEqual(
                json.loads(RawReplica(root).read("mail::_uidvalidity")), {"INBOX": 1}
            )

    def test_a_vanished_folder_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _publish(
                root,
                ScriptedMailbox(
                    {
                        "INBOX": ScriptedFolder(1, {"1": _message("1")}),
                        "Sent": ScriptedFolder(1, {"9": _message("9")}),
                    }
                ),
            )

            mailbox = ScriptedMailbox(
                {"INBOX": ScriptedFolder(1, {"1": _message("1")})}
            )
            generation = StagingGeneration(root, "gen-0002", source_id=SOURCE_ID)
            with self.assertRaises(PublishError) as refusal:
                collect_mailbox(mailbox, generation, previous_replica(generation), LATER)
            self.assertIn("disappeared", str(refusal.exception))
            generation.abort()

            self.assertEqual(mailbox.fetched, [])
            self.assertEqual(RawReplica.latest_generation(root), "gen-0001")

    def test_object_ids_never_contain_a_slash(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _publish(
                root,
                ScriptedMailbox(
                    {
                        "INBOX": ScriptedFolder(1, {"1": _message("1")}),
                        "Archive 2026": ScriptedFolder(1, {"7": _message("7")}),
                    }
                ),
            )
            for object_id in RawReplica(root).object_ids():
                self.assertNotIn("/", object_id)

    def test_a_folder_name_that_cannot_be_an_object_id_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            mailbox = ScriptedMailbox(
                {"Lists/News": ScriptedFolder(1, {"1": _message("1")})}
            )
            generation = StagingGeneration(root, "gen-0001", source_id=SOURCE_ID)
            with self.assertRaises(ValidationError):
                collect_mailbox(mailbox, generation, previous_replica(generation), CAPTURED)
            generation.abort()
            self.assertEqual(mailbox.fetched, [])
            self.assertIsNone(RawReplica.latest_generation(root))

    def test_flags_are_stored_sorted(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _publish(
                root,
                ScriptedMailbox(
                    {
                        "INBOX": ScriptedFolder(
                            1,
                            {"1": _message("1")},
                            {"1": ("\\Seen", "\\Flagged", "\\Seen")},
                        )
                    }
                ),
            )
            self.assertEqual(
                RawReplica(root).metadata("mail::INBOX::1")["flags"],
                ["\\Flagged", "\\Seen"],
            )


class PureRuleTests(unittest.TestCase):
    def test_uid_diff_is_numeric_and_stable(self) -> None:
        added, removed = uid_diff(["1", "9", "10"], ["2", "10", "11"])
        self.assertEqual(added, ["2", "11"])
        self.assertEqual(removed, ["1", "9"])
        self.assertEqual(uid_diff([], []), ([], []))
        with self.assertRaises(ValidationError):
            uid_diff([], ["not-a-uid"])

    def test_folder_names_that_cannot_be_keys_are_refused(self) -> None:
        self.assertEqual(validate_folder("INBOX"), "INBOX")
        self.assertEqual(validate_folder("Archive 2026"), "Archive 2026")
        for name in ("", " ", ".", "..", "Lists/News", "Lists::News", "a\x00b"):
            with self.assertRaises(ValidationError):
                validate_folder(name)

    def test_flags_are_normalized_sorted_and_deduplicated(self) -> None:
        self.assertEqual(
            normalize_flags(["\\Seen", " \\Seen ", "", "\\Draft"]),
            ("\\Draft", "\\Seen"),
        )
        self.assertEqual(normalize_flags([]), ())

    def test_message_headers_reads_message_id_and_date(self) -> None:
        message_id, date = message_headers(_message("4"))
        self.assertEqual(message_id, "<4@example.com>")
        self.assertEqual(date, "Wed, 18 Nov 2026 10:00:00 +0000")


class IdleParserTests(unittest.TestCase):
    def test_idle_parser_accepts_exists_expunge_and_terminates_on_a_tagged_ok(self) -> None:
        tag = b"IDLE7"
        self.assertEqual(parse_idle_line(b"* 3 EXISTS\r\n", tag), IdleLine(changed=True))
        self.assertEqual(parse_idle_line(b"* 4 EXPUNGE\r\n", tag), IdleLine(changed=True))
        self.assertEqual(parse_idle_line(b"* 5 exists\r\n", tag), IdleLine(changed=True))
        self.assertEqual(
            parse_idle_line(b"IDLE7 OK IDLE terminated\r\n", tag),
            IdleLine(terminated=True),
        )
        self.assertEqual(parse_idle_line(b"* OK Still here\r\n", tag), IdleLine())
        self.assertEqual(parse_idle_line(b"IDLE8 OK not ours\r\n", tag), IdleLine())


class CarryTests(unittest.TestCase):
    """A carried message must cost an inode, not a read of the mailbox."""

    def test_a_second_pass_reads_no_body_back(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            first = ScriptedMailbox({"INBOX": ScriptedFolder(1, {"1": _message("1")})})
            _publish(root, first)

            second = ScriptedMailbox({"INBOX": ScriptedFolder(1, {"1": _message("1")})})
            # The epoch map is a small object the pass must read; a message body
            # is what a carry must never read back.
            original = RawReplica.read

            def guarded(self, object_id):
                if object_id.startswith("mail::INBOX::"):
                    raise AssertionError(f"carry read the body of {object_id}")
                return original(self, object_id)

            with mock.patch.object(RawReplica, "read", guarded):
                report = _publish(root, second, name="gen-0002")

            self.assertEqual(report.objects, 1)
            self.assertEqual(report.carried, 1)
            self.assertEqual(second.fetched, [])

    def test_a_carried_object_shares_the_previous_inode(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _publish(
                root,
                ScriptedMailbox({"INBOX": ScriptedFolder(1, {"1": _message("1")})}),
            )
            _publish(
                root,
                ScriptedMailbox({"INBOX": ScriptedFolder(1, {"1": _message("1")})}),
                name="gen-0002",
            )

            first = root / "published" / "gen-0001" / "objects" / "mail%3A%3AINBOX%3A%3A1"
            second = root / "published" / "gen-0002" / "objects" / "mail%3A%3AINBOX%3A%3A1"
            self.assertEqual(first.stat().st_ino, second.stat().st_ino)
            self.assertEqual(second.read_bytes(), _message("1"))

def _self_signed(directory: Path, san: str) -> Path:
    """A self-signed certificate for ``san``, written to ``directory``."""

    directory.mkdir(parents=True, exist_ok=True)
    cert = directory / "cert.pem"
    subprocess.run(
        [
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-subj", "/CN=localhost",
            "-addext", f"subjectAltName={san}",
            "-keyout", str(directory / "key.pem"),
            "-out", str(cert),
        ],
        check=True,
        capture_output=True,
    )
    return cert


class _TlsServer:
    """A one-shot TLS listener presenting ``cert``, for the pin's cases."""

    def __init__(self, cert: Path) -> None:
        self._cert = cert

    def __enter__(self) -> tuple[str, int]:
        self._socket = socket.socket()
        self._socket.bind(("127.0.0.1", 0))
        self._socket.listen(1)
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()
        address: tuple[str, int] = self._socket.getsockname()
        return address

    def _serve(self) -> None:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self._cert, self._cert.with_name("key.pem"))
        try:
            connection, _ = self._socket.accept()
        except OSError:
            return
        with connection:
            try:
                with context.wrap_socket(connection, server_side=True):
                    pass
            except ssl.SSLError:
                pass

    def __exit__(self, *_exc: object) -> None:
        self._socket.close()
        self._thread.join(timeout=5)


@unittest.skipUnless(shutil.which("openssl"), "openssl generates the fixture certificates")
class PinnedCertificateTests(unittest.TestCase):
    """What ``--ca-file`` promises: that certificate, not that name.

    The bridge's certificate hardcodes its subject alternative names to
    ``localhost`` and ``127.0.0.1``, so the collector dials a name no
    certificate it will ever be handed covers. The pin is the byte-exact
    certificate instead, and these cases hold both halves of that: a foreign
    name still verifies, a foreign certificate does not.
    """

    def test_a_name_the_certificate_does_not_cover_still_verifies(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cert = _self_signed(Path(tmp), "DNS:localhost,IP:127.0.0.1")
            with _TlsServer(cert) as address:
                context = pinned_tls_context(cert)
                self.assertFalse(context.check_hostname)
                self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
                with socket.create_connection(address) as raw:
                    with context.wrap_socket(raw, server_hostname="smortress-agent-tmail"):
                        pass

    def test_a_different_certificate_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            trusted = _self_signed(Path(tmp) / "trusted", "DNS:localhost")
            other = _self_signed(Path(tmp) / "other", "DNS:localhost")
            with _TlsServer(other) as address:
                context = pinned_tls_context(trusted)
                with socket.create_connection(address) as raw:
                    with self.assertRaises(ssl.SSLCertVerificationError):
                        context.wrap_socket(raw, server_hostname="smortress-agent-tmail")


if __name__ == "__main__":
    unittest.main()
