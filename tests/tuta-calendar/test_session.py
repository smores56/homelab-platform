"""Session store tests: the seal round trip, the refusals, and what is never stored.

The seal is real GPG, in a temporary ``GNUPGHOME`` this test creates (that is
what the store holds in production too), so a "sealed" file here is sealed the
way the volume's is: no network, no passphrase, no fixture pretending the crypto
works. The user group key these tests wrap is synthetic, built with the module's
own primitives.
"""

from __future__ import annotations

import os
import shutil
import stat
import tempfile
import unittest
from pathlib import Path

from apps.tuta_calendar import crypto, dump
from apps.tuta_calendar.crypto import Padding
from apps.tuta_calendar.errors import SealError
from apps.tuta_calendar.session import (
    SEAL_DIRNAME,
    SEAL_FILENAME,
    Session,
    seal,
    session_path,
    unseal,
)

from fixtures import GROUP_KEY, PASSPHRASE_KEY

TOKEN = "access-token-that-must-never-be-readable-on-disk"


def a_session() -> Session:
    return Session(
        address="someone@example.com",
        user_id="userIdAAA",
        access_token=TOKEN,
        kdf_type=crypto.KDF_ARGON2ID,
        salt=bytes(range(16)),
        passphrase_key=PASSPHRASE_KEY,
        encrypted_passphrase_key=crypto.encrypt(PASSPHRASE_KEY, GROUP_KEY, padding=Padding.NONE),
    )


HAVE_GPG = shutil.which("gpg") is not None


@unittest.skipUnless(HAVE_GPG, "gpg is the seal's runtime dependency and is not installed")
class SealTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.store = Path(self.directory.name) / "store"

    def tearDown(self) -> None:
        self.directory.cleanup()

    def test_round_trip_keeps_every_field(self) -> None:
        original = a_session()
        seal(self.store, original)
        self.assertEqual(original, unseal(self.store))

    def test_the_seal_and_the_keyring_are_owner_only(self) -> None:
        seal(self.store, a_session())
        seal_mode = stat.S_IMODE(os.stat(session_path(self.store)).st_mode)
        keyring_mode = stat.S_IMODE(os.stat(self.store / SEAL_DIRNAME).st_mode)
        self.assertEqual(0o600, seal_mode)
        self.assertEqual(0o700, keyring_mode)

    def test_no_secret_appears_in_the_sealed_file(self) -> None:
        seal(self.store, a_session())
        sealed = session_path(self.store).read_bytes()
        self.assertNotIn(TOKEN.encode("utf-8"), sealed)
        self.assertNotIn(PASSPHRASE_KEY, sealed)
        self.assertNotIn(b"example.com", sealed)

    def test_resealing_replaces_the_previous_session(self) -> None:
        seal(self.store, a_session())
        replacement = Session(
            address="other@example.com",
            user_id="userIdBBB",
            access_token="second-token",
            kdf_type=crypto.KDF_BCRYPT,
            salt=bytes(range(16)),
            passphrase_key=PASSPHRASE_KEY[:16],
            encrypted_passphrase_key=crypto.encrypt(PASSPHRASE_KEY, GROUP_KEY, padding=Padding.NONE),
        )
        seal(self.store, replacement)
        self.assertEqual(replacement, unseal(self.store))
        self.assertEqual([SEAL_FILENAME], [path.name for path in self.store.glob("*.gpg*")])

    def test_a_tampered_seal_is_refused_with_the_remedy(self) -> None:
        seal(self.store, a_session())
        sealed = bytearray(session_path(self.store).read_bytes())
        sealed[-3] ^= 0xFF
        session_path(self.store).write_bytes(bytes(sealed))

        with self.assertRaises(SealError) as caught:
            unseal(self.store)
        message = str(caught.exception)
        self.assertIn("could not be opened", message)
        self.assertIn(str(session_path(self.store)), message)
        self.assertIn("init --store", message)

    def test_a_missing_store_names_init(self) -> None:
        with self.assertRaises(SealError) as caught:
            unseal(self.store)
        self.assertIn("no session seal", str(caught.exception))
        self.assertIn("init --store", str(caught.exception))

    def test_a_missing_keyring_is_refused_rather_than_guessed(self) -> None:
        seal(self.store, a_session())
        shutil.rmtree(self.store / SEAL_DIRNAME)
        with self.assertRaises(SealError) as caught:
            unseal(self.store)
        self.assertIn("seal key", str(caught.exception))

    def test_the_stored_key_material_unwraps_the_group_key(self) -> None:
        seal(self.store, a_session())
        self.assertEqual(GROUP_KEY, unseal(self.store).user_group_key())


class InitSurfaceTest(unittest.TestCase):
    """``init`` must not be able to receive a secret from argv or the environment."""

    def test_init_takes_only_a_store_path(self) -> None:
        parser = dump.build_parser()
        commands = [
            action for action in parser._actions if hasattr(action, "choices") and action.choices
        ]
        self.assertEqual(1, len(commands))
        init = commands[0].choices["init"]
        options = {option for action in init._actions for option in action.option_strings}
        self.assertEqual({"-h", "--help", "--store"}, options)

    def test_dump_takes_a_store_and_an_output_directory(self) -> None:
        parser = dump.build_parser()
        args = parser.parse_args(["dump", "--store", "/s", "--out", "/o"])
        self.assertEqual((Path("/s"), Path("/o")), (args.store, args.out))

    def test_no_command_mentions_a_password_or_a_code(self) -> None:
        parser = dump.build_parser()
        commands = [
            action for action in parser._actions if hasattr(action, "choices") and action.choices
        ]
        for name, command in commands[0].choices.items():
            for action in command._actions:
                for option in action.option_strings:
                    self.assertNotIn("password", option, name)
                    self.assertNotIn("passphrase", option, name)
                    self.assertNotIn("totp", option, name)
                    self.assertNotIn("token", option, name)
