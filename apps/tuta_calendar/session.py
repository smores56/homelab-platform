"""What survives between runs, and the seal that protects it.

A Tuta session is opened with a password and, on most accounts, a TOTP code.
Neither may be stored: the code is a one-time value and the password is the
account. What has to survive is everything the *next* unattended run needs:

* the access token, which authenticates the REST calls,
* the user id, which the calendar group lookup is keyed by,
* the passphrase key -- the KDF output the account password produces -- because
  it is what unwraps the user group key, and therefore the calendar group key,
  without the password being present, and
* the user group key as the passphrase key encrypts it (``symEncGKey``, field 27
  of the user's group membership) exactly as the server holds it, so unwrapping
  it again never needs a fresh derivation from a password that is not here.

That is the account's plaintext-equivalent material, so it is sealed, not merely
stored: a passphrase-less GPG key generated inside the store encrypts it, the
same shape TutaBridge uses for the session on its own volume. The key is
passphrase-less because the container starts unattended; what it buys is that a
copy of the file -- a backup, a stray `podman cp`, a mistaken `cat` -- is not a
session. The store directory holds ``gnupg/`` (mode 0700) and ``session.gpg``
(mode 0600), and both live on the quarantined volume, never in git.

When the seal cannot be opened, this module refuses by name and says what to do:
a tampered ciphertext, a missing keyring and a truncated document are all "run
``init`` again", never a partially-decoded session.
"""

from __future__ import annotations

import base64
import json
import os
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .crypto import unwrap_user_group_key
from .errors import SealError

SEAL_DIRNAME = "gnupg"
SEAL_FILENAME = "session.gpg"
SEAL_TMP_FILENAME = "session.gpg.tmp"
SEAL_UID = "tuta-calendar session seal"
SEAL_MODE = 0o600
SEAL_DIR_MODE = 0o700
DOCUMENT_VERSION = 1


@dataclass(frozen=True)
class Session:
    """Everything one unattended run needs after a single interactive ``init``."""

    address: str
    user_id: str
    access_token: str
    kdf_type: int
    salt: bytes
    passphrase_key: bytes
    encrypted_passphrase_key: bytes

    def to_document(self) -> dict[str, Any]:
        """The sealed payload. Field order is fixed here and sorted on the way out."""

        return {
            "version": DOCUMENT_VERSION,
            "address": self.address,
            "userId": self.user_id,
            "accessToken": self.access_token,
            "kdfType": self.kdf_type,
            "salt": base64.b64encode(self.salt).decode("ascii"),
            "passphraseKey": base64.b64encode(self.passphrase_key).decode("ascii"),
            "encryptedPassphraseKey": base64.b64encode(self.encrypted_passphrase_key).decode(
                "ascii"
            ),
        }

    @classmethod
    def from_document(cls, document: Any) -> "Session":
        if not isinstance(document, dict):
            raise SealError("the seal does not hold a session document")
        version = document.get("version")
        if version != DOCUMENT_VERSION:
            raise SealError(
                f"the seal holds document version {version!r}; this build writes "
                f"{DOCUMENT_VERSION}. Run `init` again against this store."
            )
        try:
            return cls(
                address=str(document["address"]),
                user_id=str(document["userId"]),
                access_token=str(document["accessToken"]),
                kdf_type=int(document["kdfType"]),
                salt=base64.b64decode(document["salt"]),
                passphrase_key=base64.b64decode(document["passphraseKey"]),
                encrypted_passphrase_key=base64.b64decode(document["encryptedPassphraseKey"]),
            )
        except (KeyError, TypeError, ValueError) as exc:
            raise SealError(f"the seal's session document is incomplete: {exc}") from exc

    def user_group_key(self) -> bytes:
        """Unwrap the user group key. A wrong passphrase key fails here, not later."""

        return unwrap_user_group_key(self.passphrase_key, self.encrypted_passphrase_key)


def session_path(store: Path) -> Path:
    return store / SEAL_FILENAME


def seal_keyring(store: Path) -> Path:
    return store / SEAL_DIRNAME


def _gpg(home: Path, *args: str, stdin: bytes = b"") -> tuple[int, bytes, bytes]:
    """One gpg invocation against the store's own keyring, never the user's."""

    program = shutil.which("gpg")
    if program is None:
        raise SealError(
            "gpg is not on PATH; the session seal needs it (the image installs gnupg at "
            "build time)"
        )
    command = [
        program,
        "--homedir",
        str(home),
        "--batch",
        "--yes",
        "--no-tty",
        "--quiet",
        "--pinentry-mode",
        "loopback",
        "--passphrase",
        "",
        *args,
    ]
    completed = subprocess.run(  # noqa: S603 - fixed argv, no shell
        command, input=stdin, capture_output=True, check=False
    )
    return completed.returncode, completed.stdout, completed.stderr


def _secret_key_ids(home: Path) -> list[str]:
    if not home.is_dir():
        return []
    code, out, _ = _gpg(home, "--list-secret-keys", "--with-colons")
    if code != 0:
        return []
    return [
        line.split(":")[4]
        for line in out.decode("utf-8", errors="replace").splitlines()
        if line.startswith("sec:")
    ]


def ensure_seal_key(store: Path) -> None:
    """Create the store's keyring and its passphrase-less key, once.

    ``default default never`` is GnuPG's modern key: an Ed25519 primary with a
    Curve25519 encryption subkey and no expiry. It is generated here rather than
    imported so the store is self-contained: a copy of the directory can be
    restored and read without any other material.
    """

    home = seal_keyring(store)
    home.mkdir(mode=SEAL_DIR_MODE, parents=True, exist_ok=True)
    os.chmod(home, SEAL_DIR_MODE)
    if _secret_key_ids(home):
        return
    code, _, err = _gpg(home, "--quick-generate-key", SEAL_UID, "default", "default", "never")
    if code != 0 or not _secret_key_ids(home):
        detail = err.decode("utf-8", errors="replace").strip().splitlines()
        reason = detail[-1] if detail else f"exit {code}"
        raise SealError(f"gpg could not generate the seal key under {home}: {reason}")


def seal(store: Path, session: Session) -> Path:
    """Encrypt the session into ``session.gpg``; the plaintext never reaches disk."""

    store.mkdir(parents=True, exist_ok=True)
    ensure_seal_key(store)
    document = json.dumps(session.to_document(), sort_keys=True, separators=(",", ":"))
    code, out, err = _gpg(
        seal_keyring(store),
        "--trust-model",
        "always",
        "--output",
        "-",
        "--encrypt",
        "--recipient",
        SEAL_UID,
        stdin=document.encode("utf-8"),
    )
    if code != 0 or not out:
        detail = err.decode("utf-8", errors="replace").strip().splitlines()
        reason = detail[-1] if detail else f"exit {code}"
        raise SealError(f"gpg could not seal the session under {store}: {reason}")
    target = session_path(store)
    # Written beside the target and renamed: a run that dies mid-write leaves the
    # previous seal intact rather than a half-encrypted one.
    handle, temporary = tempfile.mkstemp(dir=store, prefix=SEAL_TMP_FILENAME)
    try:
        with os.fdopen(handle, "wb") as sink:
            sink.write(out)
            sink.flush()
            os.fsync(sink.fileno())
        os.chmod(temporary, SEAL_MODE)
        os.replace(temporary, target)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise
    return target


def unseal(store: Path) -> Session:
    """Read the sealed session, or refuse with what the operator has to do."""

    path = session_path(store)
    if not path.is_file():
        raise SealError(
            f"no session seal at {path}; run `init --store {store}` to sign in once"
        )
    if not _secret_key_ids(seal_keyring(store)):
        raise SealError(
            f"the seal key under {seal_keyring(store)} is missing, so {path} cannot be "
            f"opened. Run `init --store {store}` again; nothing in the store was read."
        )
    code, out, _ = _gpg(seal_keyring(store), "--output", "-", "--decrypt", str(path))
    if code != 0:
        # gpg's own stderr is not repeated: the interesting part is the exit code
        # and the remedy, and a manipulation warning can quote ciphertext context.
        raise SealError(
            f"the session seal at {path} could not be opened (gpg exited {code}): the file "
            "was modified, truncated, or sealed with a key this store no longer holds. "
            f"Nothing was read from it. Run `init --store {store}` to sign in again."
        )
    try:
        document = json.loads(out.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SealError(f"the session seal at {path} does not hold a JSON document") from exc
    return Session.from_document(document)
