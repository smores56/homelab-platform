"""Crypto tests: the verifier, both padding modes and the session-key unwrap.

The vectors are not from a provider run. Each expected value is computed here
from the *library primitives the module vendors* -- ``bcrypt.hashpw``,
``argon2.low_level.hash_secret_raw``, ``cryptography``'s AES-CBC with its own
PKCS#7 padder -- so the test pins the construction (SHA-256 first, bcrypt's own
base64 alphabet, cost 8, ``SHA-256`` of the bcrypt output, base64url without
padding) without a network and without pretending to know a real account's salt.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import unittest

import argon2.low_level
import bcrypt
from cryptography.hazmat.primitives import padding as pyca_padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

from apps.tuta_calendar import crypto
from apps.tuta_calendar.crypto import Padding
from apps.tuta_calendar.errors import CryptoError

PASSPHRASE = "correct horse battery staple"
SALT = bytes.fromhex("000102030405060708090a0b0c0d0e0f")
BCRYPT_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
BCRYPT_B64 = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"


def bcrypt_salt(salt: bytes) -> bytes:
    """The salt string rebuilt from the alphabet mapping documented upstream."""

    encoded = base64.b64encode(salt).decode("ascii").rstrip("=").translate(
        str.maketrans(BCRYPT_ALPHABET, BCRYPT_B64)
    )
    return f"$2b$08${encoded[:22].ljust(22, '.')}".encode("ascii")


class VerifierTest(unittest.TestCase):
    def test_bcrypt_verifier_matches_the_rebuilt_construction(self) -> None:
        bcrypt_output = bcrypt.hashpw(
            hashlib.sha256(PASSPHRASE.encode("utf-8")).digest(), bcrypt_salt(SALT)
        )
        expected = (
            base64.urlsafe_b64encode(hashlib.sha256(bcrypt_output).digest())
            .decode("ascii")
            .rstrip("=")
        )
        self.assertEqual(expected, crypto.verifier(PASSPHRASE, SALT, crypto.KDF_BCRYPT))

    def test_argon2id_verifier_hashes_the_derived_key(self) -> None:
        derived = argon2.low_level.hash_secret_raw(
            secret=PASSPHRASE.encode("utf-8"),
            salt=SALT,
            time_cost=4,
            memory_cost=32 * 1024,
            parallelism=1,
            hash_len=32,
            type=argon2.low_level.Type.ID,
        )
        expected = base64.urlsafe_b64encode(hashlib.sha256(derived).digest()).decode().rstrip("=")
        self.assertEqual(expected, crypto.verifier(PASSPHRASE, SALT, crypto.KDF_ARGON2ID))

    def test_verifier_is_not_the_key(self) -> None:
        """Sending the verifier must not ship the key that unwraps the account."""

        for kdf_type in (crypto.KDF_BCRYPT, crypto.KDF_ARGON2ID):
            verifier = crypto.b64url_decode(crypto.verifier(PASSPHRASE, SALT, kdf_type))
            key = crypto.passphrase_key(PASSPHRASE, SALT, kdf_type)
            self.assertNotEqual(verifier, key)

    def test_passphrase_keys_keep_their_lengths(self) -> None:
        self.assertEqual(
            crypto.AES128_KEY_LEN, len(crypto.passphrase_key(PASSPHRASE, SALT, crypto.KDF_BCRYPT))
        )
        self.assertEqual(
            crypto.AES256_KEY_LEN, len(crypto.passphrase_key(PASSPHRASE, SALT, crypto.KDF_ARGON2ID))
        )

    def test_a_different_salt_changes_both_values(self) -> None:
        other = bytes(range(16, 32))
        self.assertNotEqual(
            crypto.verifier(PASSPHRASE, SALT, crypto.KDF_BCRYPT),
            crypto.verifier(PASSPHRASE, other, crypto.KDF_BCRYPT),
        )

    def test_an_unknown_kdf_type_is_refused(self) -> None:
        with self.assertRaises(CryptoError):
            crypto.verifier(PASSPHRASE, SALT, 7)


class EnvelopeTest(unittest.TestCase):
    def test_pkcs5_round_trip_against_a_pyca_built_envelope(self) -> None:
        """A value envelope built with pyca directly, opened by the module."""

        key = bytes(range(32))
        plaintext = b"a calendar summary"
        iv = bytes(range(16))
        derived = hashlib.sha512(key).digest()
        padder = pyca_padding.PKCS7(128).padder()
        padded = padder.update(plaintext) + padder.finalize()
        encryptor = Cipher(algorithms.AES(derived[:32]), modes.CBC(iv)).encryptor()
        ciphertext = encryptor.update(padded) + encryptor.finalize()
        mac = hmac.new(derived[32:], iv + ciphertext, hashlib.sha256).digest()
        envelope = b"\x01" + iv + ciphertext + mac

        self.assertEqual(plaintext, crypto.decrypt_value(key, envelope))
        # The same bytes, read without unpadding, are the padded body: the two
        # modes are genuinely different reads of one envelope.
        self.assertEqual(padded, crypto.decrypt(key, envelope, padding=Padding.NONE))

    def test_unpadded_key_round_trip(self) -> None:
        key = bytes(range(32))
        session_key = bytes(range(32, 64))
        self.assertEqual(
            session_key, crypto.unwrap_key(key, crypto.encrypt(key, session_key, padding=Padding.NONE))
        )

    def test_the_padding_trap_truncates_and_the_key_path_does_not(self) -> None:
        """A 32-byte key whose last byte reads as PKCS#5 padding must survive intact.

        ``\\x01`` is a valid one-byte PKCS#5 pad, so a decrypt that always unpads
        returns 31 bytes: the truncation the module's two names exist to prevent.
        """

        key = bytes(range(32))
        trapped = bytes(range(32 - 1)) + b"\x01"
        envelope = crypto.encrypt(key, trapped, padding=Padding.NONE)

        self.assertEqual(trapped, crypto.unwrap_key(key, envelope))
        self.assertEqual(31, len(crypto.decrypt(key, envelope, padding=Padding.PKCS5)))

    def test_a_modified_ciphertext_is_refused(self) -> None:
        key = bytes(range(32))
        envelope = bytearray(crypto.encrypt(key, b"value", padding=Padding.PKCS5))
        envelope[20] ^= 0xFF
        with self.assertRaises(CryptoError):
            crypto.decrypt_value(key, bytes(envelope))

    def test_a_plaintext_envelope_version_is_refused(self) -> None:
        with self.assertRaises(CryptoError):
            crypto.decrypt_value(bytes(range(32)), b"\x00" + bytes(80))

    def test_an_unwrap_that_is_not_a_key_length_is_refused(self) -> None:
        key = bytes(range(32))
        # 40 bytes padded to 48: a ciphertext that decrypts cleanly but cannot be
        # a symmetric key, which is the check that catches a wrong group key here
        # instead of on the first event it fails to open.
        envelope = crypto.encrypt(key, b"x" * 40, padding=Padding.PKCS5)
        with self.assertRaises(CryptoError):
            crypto.unwrap_key(key, envelope)


class UserGroupKeyTest(unittest.TestCase):
    def test_a_versioned_group_key_unwraps(self) -> None:
        key = bytes(range(32))
        group_key = bytes(range(32, 64))
        envelope = crypto.encrypt(key, group_key, padding=Padding.NONE)
        self.assertEqual(group_key, crypto.unwrap_user_group_key(key, envelope))

    def test_the_legacy_layout_is_refused_by_name(self) -> None:
        with self.assertRaises(CryptoError) as caught:
            crypto.unwrap_user_group_key(bytes(range(32)), bytes(32))
        self.assertIn("legacy", str(caught.exception))

    def test_a_missing_group_key_is_refused(self) -> None:
        with self.assertRaises(CryptoError):
            crypto.unwrap_user_group_key(bytes(range(32)), b"")
