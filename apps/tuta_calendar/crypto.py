"""The subset of Tuta's cryptography that a calendar read needs.

Adapted from ``peix2/tutaproxy-public`` (AGPL-3.0,
https://github.com/peix2/tutaproxy-public): ``tuta/crypto.py`` supplied the
verifier construction (password -> bcrypt/argon2id -> SHA-256 -> base64url), the
bcrypt base64 alphabet, the ``AesCbcThenHmac`` envelope and the two padding
modes that Tuta's ``encryptKey`` and ``encryptBytes`` use. Nothing here was
copied without being read, and the mail-only parts of that file (LZ4 bodies, the
ECC/Kyber key paths, bucket keys, TOTP) are deliberately absent: this milestone
holds no mail and stores no second factor.

The padding split is why this module exists rather than a one-liner. Tuta
encrypts *values* with PKCS#5 padding and *symmetric keys* with none at all. A
decrypt that strips PKCS#5 from a 32-byte key truncates the key roughly once in
256 (when the last byte happens to read as valid padding), and the truncation
surfaces much later as an event that will not decrypt. So the two modes are two
names -- :func:`decrypt_value` and :func:`unwrap_key` -- never a defaulted
argument that the next caller gets wrong.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
from enum import Enum

from cryptography.hazmat.primitives import padding as _padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

from .errors import CryptoError

KDF_BCRYPT = 0
KDF_ARGON2ID = 1

AES128_KEY_LEN = 16
AES256_KEY_LEN = 32

# AesCbcThenHmac: [0x01][IV 16][ciphertext][HMAC-SHA256 32].
_VERSION_AES_CBC_THEN_HMAC = 0x01
_ENVELOPE_MIN_LEN = 1 + 16 + 32


class Padding(Enum):
    """Tuta's two padding modes, named so a call site cannot pick one by accident."""

    NONE = "none"
    PKCS5 = "pkcs5"


# bcrypt's own base64 alphabet, which is not the standard one. A salt formatted
# with the standard alphabet produces a hash the server will not agree with, and
# nothing about the failure says why.
_STANDARD_B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
_BCRYPT_B64 = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
_STD_TO_BCRYPT = str.maketrans(_STANDARD_B64, _BCRYPT_B64)
_BCRYPT_TO_STD = str.maketrans(_BCRYPT_B64, _STANDARD_B64)


def b64url_encode(data: bytes) -> str:
    """url-safe base64 without padding, the encoding Tuta's verifier uses."""

    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def b64url_decode(text: str) -> bytes:
    padded = text.replace("-", "+").replace("_", "/")
    padded += "=" * (-len(padded) % 4)
    return base64.b64decode(padded)


def _bcrypt_b64(value: str) -> str:
    return value.translate(_STD_TO_BCRYPT)


def _bcrypt_salt(salt: bytes) -> str:
    """A 16-byte Tuta salt as a bcrypt salt string: cost 8, bcrypt alphabet."""

    encoded = _bcrypt_b64(base64.b64encode(salt).decode("ascii").rstrip("="))
    return f"$2b$08${encoded[:22].ljust(22, '.')}"


def _bcrypt_raw(passphrase: str, salt: bytes) -> bytes:
    """The bcrypt output for a passphrase: SHA-256 first, then hash at cost 8."""

    try:
        import bcrypt
    except ImportError as exc:  # pragma: no cover - packaging failure, not a runtime state
        raise CryptoError("bcrypt is not installed; the image pins it at build time") from exc
    digest = hashlib.sha256(passphrase.encode("utf-8")).digest()
    return bcrypt.hashpw(digest, _bcrypt_salt(salt).encode("ascii"))


def _argon2_raw(passphrase: str, salt: bytes, length: int) -> bytes:
    try:
        import argon2.low_level as argon2
    except ImportError as exc:  # pragma: no cover - packaging failure, not a runtime state
        raise CryptoError("argon2-cffi is not installed; the image pins it at build time") from exc
    return argon2.hash_secret_raw(
        secret=passphrase.encode("utf-8"),
        salt=salt,
        time_cost=4,
        memory_cost=32 * 1024,
        parallelism=1,
        hash_len=length,
        type=argon2.Type.ID,
    )


def _check_kdf(kdf_type: int) -> None:
    if kdf_type not in (KDF_BCRYPT, KDF_ARGON2ID):
        raise CryptoError(f"unknown kdfType {kdf_type}; saltservice answered 0 or 1")


def verifier(passphrase: str, salt: bytes, kdf_type: int) -> str:
    """The value ``sessionservice`` compares: a one-way derivative of the password.

    bcrypt accounts send ``base64url(SHA-256(bcrypt_output))``; argon2id accounts
    send ``base64url(SHA-256(argon2id_key))``. Neither can be turned back into the
    password, and the derived *key* below is a different value from the same input.
    """

    _check_kdf(kdf_type)
    if kdf_type == KDF_BCRYPT:
        material = _bcrypt_raw(passphrase, salt)
    else:
        material = _argon2_raw(passphrase, salt, AES256_KEY_LEN)
    return b64url_encode(hashlib.sha256(material).digest())


def passphrase_key(passphrase: str, salt: bytes, kdf_type: int) -> bytes:
    """The AES key that unwraps the user group key. It never leaves this host."""

    _check_kdf(kdf_type)
    if kdf_type == KDF_BCRYPT:
        # The 31 bcrypt-base64 characters after "$2b$08$" plus the 22-character
        # salt; its first 16 raw bytes are Tuta's AES-128 key.
        output = _bcrypt_raw(passphrase, salt)[29:]
        alphabet = output.decode("ascii").translate(_BCRYPT_TO_STD)
        alphabet += "=" * (-len(alphabet) % 4)
        raw = base64.b64decode(alphabet)
        if len(raw) < AES128_KEY_LEN:
            raise CryptoError("bcrypt returned less material than an AES-128 key")
        return raw[:AES128_KEY_LEN]
    return _argon2_raw(passphrase, salt, AES256_KEY_LEN)


def _subkeys(key: bytes) -> tuple[bytes, bytes]:
    """AES key and HMAC key from one key, the AesCbcThenHmac derivation."""

    if not key:
        raise CryptoError("an empty key cannot derive subkeys")
    derived = hashlib.sha512(key).digest()
    return derived[:32], derived[32:]


def encrypt(key: bytes, plaintext: bytes, *, padding: Padding) -> bytes:
    """The AesCbcThenHmac envelope, for tests and for a fixture builder."""

    enc_key, mac_key = _subkeys(key)
    iv = os.urandom(16)
    if padding is Padding.PKCS5:
        padder = _padding.PKCS7(128).padder()
        body = padder.update(plaintext) + padder.finalize()
    else:
        body = plaintext
        if len(body) % 16:
            raise CryptoError(f"{len(body)} bytes is not a whole number of AES blocks")
    encryptor = Cipher(algorithms.AES(enc_key), modes.CBC(iv)).encryptor()
    ciphertext = encryptor.update(body) + encryptor.finalize()
    mac = hmac.new(mac_key, iv + ciphertext, hashlib.sha256).digest()
    return bytes([_VERSION_AES_CBC_THEN_HMAC]) + iv + ciphertext + mac


def decrypt(key: bytes, payload: bytes, *, padding: Padding) -> bytes:
    """Open an AesCbcThenHmac envelope; the HMAC is checked, never bypassed."""

    if not payload or payload[0] != _VERSION_AES_CBC_THEN_HMAC:
        prefix = payload[0] if payload else None
        raise CryptoError(
            f"unsupported envelope version {prefix!r}; this build reads "
            f"{_VERSION_AES_CBC_THEN_HMAC:#04x} (AesCbcThenHmac) only"
        )
    if len(payload) < _ENVELOPE_MIN_LEN:
        raise CryptoError(f"{len(payload)} bytes is too short for an AesCbcThenHmac envelope")
    iv = payload[1:17]
    ciphertext = payload[17:-32]
    received = payload[-32:]
    enc_key, mac_key = _subkeys(key)
    expected = hmac.new(mac_key, iv + ciphertext, hashlib.sha256).digest()
    if not hmac.compare_digest(expected, received):
        raise CryptoError(
            "the authenticated envelope did not verify: the key is wrong or the "
            "ciphertext was modified"
        )
    try:
        decryptor = Cipher(algorithms.AES(enc_key), modes.CBC(iv)).decryptor()
        body = decryptor.update(ciphertext) + decryptor.finalize()
    except ValueError as exc:
        raise CryptoError(f"the ciphertext is not a whole number of AES blocks: {exc}") from exc
    if padding is Padding.NONE:
        return body
    unpadder = _padding.PKCS7(128).unpadder()
    try:
        return unpadder.update(body) + unpadder.finalize()
    except ValueError as exc:
        raise CryptoError("the value's PKCS#5 padding is invalid") from exc


def unwrap_key(group_key: bytes, encrypted_key: bytes) -> bytes:
    """Unwrap a symmetric key: no padding, and a length check that proves it."""

    key = decrypt(group_key, encrypted_key, padding=Padding.NONE)
    if len(key) not in (AES128_KEY_LEN, AES256_KEY_LEN):
        raise CryptoError(
            f"a symmetric key unwrapped to {len(key)} bytes, which is neither 16 nor 32; "
            "the group key is not the one this ciphertext was wrapped with"
        )
    return key


def decrypt_value(session_key: bytes, payload: bytes) -> bytes:
    """A field value: PKCS#5 padding, which every encrypted *value* carries."""

    return decrypt(session_key, payload, padding=Padding.PKCS5)


def unwrap_user_group_key(key: bytes, encrypted_group_key: bytes) -> bytes:
    """The user group key, unwrapped from ``user.userGroup.symEncGKey``.

    Only the versioned AesCbcThenHmac format is read. The pre-2019 layout (a bare
    32-byte ciphertext under a fixed IV) is refused by name rather than decrypted
    into 32 bytes of noise that would fail on the first event.
    """

    if not encrypted_group_key:
        raise CryptoError("the user record carries no symEncGKey")
    if encrypted_group_key[0] != _VERSION_AES_CBC_THEN_HMAC:
        raise CryptoError(
            "the user group key is in the legacy pre-AesCbcThenHmac format "
            f"({encrypted_group_key[:1]!r}, {len(encrypted_group_key)} bytes); this build "
            "reads the versioned format only"
        )
    return unwrap_key(key, encrypted_group_key)
