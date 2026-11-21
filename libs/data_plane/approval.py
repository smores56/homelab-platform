"""Signed, single-use approvals that work across pods.

The in-process :class:`data_plane.confirmation.ConfirmationGate` binds an
approval to a token held in one process. A confirmation surface and a write
broker run in different pods, so the broker must verify an approval it never
issued. This module carries the same binding as an HMAC-signed claim set:

* the normalized operation hash, its intent id, and the source epoch are in the
  signed payload, so any change to the operation invalidates the approval;
* ``issued_at``/``expires_at`` bound how long the claim is live, and the
  verifier refuses a claim issued in the future or with a lifetime beyond
  ``max_ttl``;
* spending the nonce is the intent journal's transaction
  (:meth:`data_plane.intents.IntentStore.reserve`), so a second broker cannot
  replay an approval and a crash cannot spend one without reserving the effect.

:class:`ApprovalAuthority` is the human surface. It renders the operation the
effect owner stored (:class:`PendingApproval`) and signs exactly that; it takes
no operation argument, so the runtime that provoked the intent cannot show one
diff and have another approved.

Nothing here knows a source adapter or reaches the network. SQLite is the same
stdlib dependency the intent journal already uses.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import re
import secrets
import sqlite3
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, Protocol, runtime_checkable

from .confirmation import (
    Approval as GateApproval,
    NormalizedOperation,
    operation_hash,
    render,
)
from .errors import ConfirmationError
from .identity import canonical_json
from .model import IntentState

MAX_APPROVAL_TTL_SECONDS = 900
DEFAULT_APPROVAL_TTL_SECONDS = 900

_NONCE_PATTERN = re.compile(r"\A[0-9A-Za-z_-]{8,128}\Z")
_HASH_PATTERN = re.compile(r"\A[0-9a-f]{64}\Z")
_BUSY_TIMEOUT_MS = 5000

_SCHEMA = """
CREATE TABLE IF NOT EXISTS used_approvals (
    nonce TEXT PRIMARY KEY,
    intent_id TEXT NOT NULL,
    operation_hash TEXT NOT NULL,
    consumed_at REAL NOT NULL
);
"""


def _b64encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _b64decode(text: str) -> bytes:
    padding = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + padding)


def _key_bytes(key: bytes | str) -> bytes:
    raw = key.encode("utf-8") if isinstance(key, str) else bytes(key)
    if not raw:
        raise ConfirmationError("approval key is empty")
    return raw


@dataclass(frozen=True)
class ApprovalClaims:
    """The signed facts an operator surface issues and a broker verifies."""

    intent_id: str
    operation_hash: str
    epoch: int
    approved_by: str
    issued_at: int
    expires_at: int
    nonce: str

    def __post_init__(self) -> None:
        if not isinstance(self.intent_id, str) or not self.intent_id.strip():
            raise ConfirmationError("approval intent id is required")
        if not isinstance(self.operation_hash, str) or not _HASH_PATTERN.match(
            self.operation_hash
        ):
            raise ConfirmationError("approval operation hash is not a SHA-256")
        if isinstance(self.epoch, bool) or not isinstance(self.epoch, int) or self.epoch < 1:
            raise ConfirmationError("approval epoch must be a positive integer")
        if not isinstance(self.approved_by, str) or not self.approved_by.strip():
            raise ConfirmationError("approval must name an approver")
        for name in ("issued_at", "expires_at"):
            value = getattr(self, name)
            if isinstance(value, bool) or not isinstance(value, int):
                raise ConfirmationError(f"approval {name} must be an integer")
        if self.expires_at <= self.issued_at:
            raise ConfirmationError("approval expiry must be after its issue time")
        if not isinstance(self.nonce, str) or not _NONCE_PATTERN.match(self.nonce):
            raise ConfirmationError("approval nonce is malformed")

    @property
    def approved_at(self) -> int:
        """Alias so the broker's audit record works for either approval type."""

        return self.issued_at

    @property
    def ttl(self) -> int:
        return self.expires_at - self.issued_at

    def to_dict(self) -> dict[str, Any]:
        return {
            "intent_id": self.intent_id,
            "operation_hash": self.operation_hash,
            "epoch": self.epoch,
            "approved_by": self.approved_by,
            "issued_at": self.issued_at,
            "expires_at": self.expires_at,
            "nonce": self.nonce,
        }

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> "ApprovalClaims":
        try:
            return cls(
                intent_id=str(value["intent_id"]),
                operation_hash=str(value["operation_hash"]),
                epoch=int(value["epoch"]),
                approved_by=str(value["approved_by"]),
                issued_at=int(value["issued_at"]),
                expires_at=int(value["expires_at"]),
                nonce=str(value["nonce"]),
            )
        except (KeyError, TypeError, ValueError) as exc:
            raise ConfirmationError(f"malformed approval claims: {exc}") from exc


def sign_approval(claims: ApprovalClaims, key: bytes | str) -> str:
    """Sign claims into ``payload.signature`` with HMAC-SHA256."""

    payload = _b64encode(canonical_json(claims.to_dict()))
    signature = _b64encode(
        hmac.new(_key_bytes(key), payload.encode("ascii"), hashlib.sha256).digest()
    )
    return f"{payload}.{signature}"


def verify_approval(
    token: str,
    key: bytes | str,
    now: int | None = None,
    max_ttl: int = MAX_APPROVAL_TTL_SECONDS,
) -> ApprovalClaims:
    """Verify a signed approval and return its claims.

    Rejects a tampered payload or signature, a token issued in the future, an
    expired token, and a lifetime longer than ``max_ttl``. Single use is the
    store's job; this function never mutates state.
    """

    if isinstance(max_ttl, bool) or not isinstance(max_ttl, int) or max_ttl < 1:
        raise ConfirmationError("approval max_ttl must be a positive integer")
    key_bytes = _key_bytes(key)
    try:
        payload, signature = token.split(".", 1)
    except (ValueError, AttributeError) as exc:
        raise ConfirmationError("malformed approval token") from exc
    if not payload or not signature:
        raise ConfirmationError("malformed approval token")
    try:
        payload_bytes = payload.encode("ascii")
        provided = _b64decode(signature)
        decoded = json.loads(_b64decode(payload))
    except (UnicodeEncodeError, binascii.Error, ValueError, json.JSONDecodeError) as exc:
        raise ConfirmationError("malformed approval token") from exc
    expected = hmac.new(key_bytes, payload_bytes, hashlib.sha256).digest()
    if not hmac.compare_digest(expected, provided):
        raise ConfirmationError("approval signature does not match")
    if not isinstance(decoded, dict):
        raise ConfirmationError("malformed approval payload")
    claims = ApprovalClaims.from_dict(decoded)

    current = int(time.time()) if now is None else int(now)
    if claims.issued_at > current:
        raise ConfirmationError("approval was issued in the future")
    if claims.expires_at <= current:
        raise ConfirmationError("approval has expired")
    if claims.expires_at - claims.issued_at > max_ttl:
        raise ConfirmationError(
            f"approval lifetime exceeds the {max_ttl}-second maximum"
        )
    return claims


def claims_for(
    operation: NormalizedOperation,
    approved_by: str,
    *,
    issued_at: int,
    ttl: int = DEFAULT_APPROVAL_TTL_SECONDS,
    nonce: str | None = None,
) -> ApprovalClaims:
    """Build claims bound to one normalized operation."""

    if isinstance(ttl, bool) or not isinstance(ttl, int) or ttl < 1:
        raise ConfirmationError("approval ttl must be a positive integer")
    return ApprovalClaims(
        intent_id=operation.intent_id,
        operation_hash=operation_hash(operation),
        epoch=operation.epoch,
        approved_by=approved_by,
        issued_at=int(issued_at),
        expires_at=int(issued_at) + ttl,
        nonce=nonce if nonce is not None else secrets.token_hex(16),
    )


class UsedApprovalStore:
    """A shared SQLite table of consumed nonces, keyed by nonce.

    The primary key makes the first insert the only successful one, so two
    processes (or two threads) cannot both consume the same approval even when
    they share one database file.
    """

    def __init__(self, path: str | Path = ":memory:") -> None:
        self._path = str(path)
        if self._path != ":memory:":
            Path(self._path).parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(
            self._path, check_same_thread=False, isolation_level=None
        )
        self._conn.execute(f"PRAGMA busy_timeout = {_BUSY_TIMEOUT_MS}")
        self._conn.executescript(_SCHEMA)

    def consume(
        self,
        nonce: str,
        *,
        intent_id: str = "",
        operation_hash: str = "",
        now: float | None = None,
    ) -> None:
        """Mark ``nonce`` used; a second use raises ``ConfirmationError``.

        ``intent_id`` and ``operation_hash`` are stored beside the nonce so an
        audit can prove which operation the one-time approval paid for.
        """

        if not isinstance(nonce, str) or not _NONCE_PATTERN.match(nonce):
            raise ConfirmationError("approval nonce is malformed")
        consumed_at = float(time.time() if now is None else now)
        with self._lock:
            try:
                self._conn.execute(
                    "INSERT INTO used_approvals "
                    "(nonce, intent_id, operation_hash, consumed_at) "
                    "VALUES (?, ?, ?, ?)",
                    (nonce, str(intent_id), str(operation_hash), consumed_at),
                )
            except sqlite3.IntegrityError as exc:
                raise ConfirmationError(
                    "approval was already used; request a new confirmation"
                ) from exc

    def used(self, nonce: str) -> bool:
        with self._lock:
            row = self._conn.execute(
                "SELECT 1 FROM used_approvals WHERE nonce = ?", (nonce,)
            ).fetchone()
        return row is not None

    def close(self) -> None:
        with self._lock:
            self._conn.close()


@runtime_checkable
class ApprovalVerifier(Protocol):
    """What the broker needs to verify a signed approval cross-pod."""

    def verify(self, token: str, operation: NormalizedOperation) -> ApprovalClaims:
        """Return the claims when they match ``operation`` and consume the nonce."""


class SignedApprovalVerifier:
    """Verify signed approvals against one key and one shared nonce store."""

    def __init__(
        self,
        key: bytes | str,
        store: UsedApprovalStore,
        *,
        clock: Callable[[], float] = time.time,
        max_ttl: int = MAX_APPROVAL_TTL_SECONDS,
    ) -> None:
        if isinstance(max_ttl, bool) or not isinstance(max_ttl, int) or max_ttl < 1:
            raise ConfirmationError("approval max_ttl must be a positive integer")
        self._key = _key_bytes(key)
        self._store = store
        self._clock = clock
        self._max_ttl = max_ttl

    @property
    def max_ttl(self) -> int:
        return self._max_ttl

    def issue(
        self,
        operation: NormalizedOperation,
        approved_by: str,
        *,
        ttl: int | None = None,
    ) -> tuple[ApprovalClaims, str]:
        """Issue one approval for an operation; the caller is the operator."""

        lifetime = self._max_ttl if ttl is None else ttl
        if lifetime < 1 or lifetime > self._max_ttl:
            raise ConfirmationError(
                f"approval ttl must be between 1 and {self._max_ttl} seconds"
            )
        claims = claims_for(
            operation,
            approved_by,
            issued_at=int(self._clock()),
            ttl=lifetime,
        )
        return claims, sign_approval(claims, self._key)

    def verify(self, token: str, operation: NormalizedOperation) -> ApprovalClaims:
        claims = self.inspect(token, operation)
        # Only a fully matched approval spends its nonce, so a wrong intent or
        # hash cannot burn a valid operator approval.
        self._store.consume(
            claims.nonce,
            intent_id=claims.intent_id,
            operation_hash=claims.operation_hash,
        )
        return claims

    def inspect(self, token: str, operation: NormalizedOperation) -> ApprovalClaims:
        """Verify the signature and binding without spending the nonce.

        The broker uses this when the intent journal owns consumption: the
        journal spends the nonce in the same transaction that reserves the
        effect, so a failed revision check cannot burn an operator approval and
        a crash cannot spend one without reserving the effect.
        """

        claims = verify_approval(
            token, self._key, now=int(self._clock()), max_ttl=self._max_ttl
        )
        if claims.intent_id != operation.intent_id:
            raise ConfirmationError("approval was issued for another intent")
        if claims.operation_hash != operation_hash(operation):
            raise ConfirmationError("approval does not match the operation")
        if claims.epoch != operation.epoch:
            raise ConfirmationError("source epoch changed; re-confirm the operation")
        return claims


def approval_record(approval: ApprovalClaims | GateApproval | Any) -> dict[str, Any]:
    """Normalize a signed or in-process approval into the journal's row shape."""

    issued_at = getattr(approval, "issued_at", None)
    if issued_at is None:
        issued_at = getattr(approval, "approved_at", None)
    if issued_at is None:
        raise ConfirmationError("approval has no issue time")
    return {
        "intent_id": str(approval.intent_id),
        "operation_hash": str(approval.operation_hash),
        "epoch": int(approval.epoch),
        "approved_by": str(approval.approved_by),
        "issued_at": int(issued_at),
        "expires_at": int(approval.expires_at),
        "nonce": str(approval.nonce),
    }


@dataclass(frozen=True)
class PendingApproval:
    """The effect owner's canonical record of one waiting operation."""

    operation: NormalizedOperation
    expires_at: int
    pre_image: Mapping[str, Any] | None = None
    run_id: str | None = None

    @property
    def intent_id(self) -> str:
        return self.operation.intent_id

    @property
    def digest(self) -> str:
        return operation_hash(self.operation)

    def as_dict(self) -> dict[str, Any]:
        return {
            "intent_id": self.intent_id,
            "operation": self.operation.normalized(),
            "operation_hash": self.digest,
            "expires_at": self.expires_at,
            "run_id": self.run_id,
            "pre_image": None if self.pre_image is None else dict(self.pre_image),
        }

    def render(self) -> str:
        """Render the card the human reads, with no remote resources."""

        lines = [render(self.operation), f"expires at: {self.expires_at}"]
        if self.run_id:
            lines.append(f"run: {json.dumps(self.run_id, ensure_ascii=True)}")
        if self.pre_image is None:
            lines.append("pre-image: (none)")
        else:
            lines.append("pre-image: " + canonical_json(dict(self.pre_image)).decode("utf-8"))
        return "\n".join(lines)


def pending_from_intent(intent: Any | None) -> PendingApproval:
    """Project one journal row into the record a human approves.

    The surface never receives an operation from its caller; this is the only
    way it learns what an intent will do.
    """

    if intent is None:
        raise ConfirmationError("no pending intent under that id")
    try:
        state = IntentState(intent.state)
    except (TypeError, ValueError) as exc:
        raise ConfirmationError("pending intent has an unknown state") from exc
    if state is not IntentState.AWAITING_CONFIRMATION:
        raise ConfirmationError(
            f"intent {intent.intent_id} is {state.value}, not awaiting approval"
        )
    if intent.operation is None:
        raise ConfirmationError(
            f"intent {intent.intent_id} has no stored operation to approve"
        )
    pre_image = intent.pre_image
    if pre_image is not None and not isinstance(pre_image, Mapping):
        raise ConfirmationError(f"intent {intent.intent_id} has a malformed pre-image")
    return PendingApproval(
        operation=NormalizedOperation.from_normalized(intent.operation),
        expires_at=int(intent.expires_at),
        pre_image=None if pre_image is None else dict(pre_image),
        run_id=getattr(intent, "run_id", None),
    )


@dataclass(frozen=True)
class ApprovalAuthority:
    """The human-only surface: render what the effect owner stored, then sign.

    ``pending`` reads the effect owner's journal. There is deliberately no way
    to pass an operation in, so a runtime that renders a falsified diff cannot
    change what the human approves.
    """

    pending: Callable[[str], PendingApproval]
    key: bytes | str
    ttl: int = DEFAULT_APPROVAL_TTL_SECONDS
    max_ttl: int = MAX_APPROVAL_TTL_SECONDS
    clock: Callable[[], float] = time.time

    def __post_init__(self) -> None:
        _key_bytes(self.key)
        if isinstance(self.max_ttl, bool) or not isinstance(self.max_ttl, int):
            raise ConfirmationError("approval max_ttl must be a positive integer")
        if self.max_ttl < 1 or self.max_ttl > MAX_APPROVAL_TTL_SECONDS:
            raise ConfirmationError(
                f"approval max_ttl must be between 1 and {MAX_APPROVAL_TTL_SECONDS}"
            )
        if isinstance(self.ttl, bool) or not isinstance(self.ttl, int):
            raise ConfirmationError("approval ttl must be a positive integer")
        if self.ttl < 1 or self.ttl > self.max_ttl:
            raise ConfirmationError(
                f"approval ttl must be between 1 and {self.max_ttl} seconds"
            )

    def record(self, intent_id: str) -> PendingApproval:
        """Return the pending record, refusing one that has already expired."""

        record = self.pending(intent_id)
        if not isinstance(record, PendingApproval):
            raise ConfirmationError("the effect owner returned no pending operation")
        if record.expires_at <= int(self.clock()):
            raise ConfirmationError(
                f"intent {record.intent_id} expired before it was reviewed"
            )
        return record

    def render(self, intent_id: str) -> str:
        return self.record(intent_id).render()

    def approve(self, intent_id: str, approved_by: str) -> tuple[ApprovalClaims, str]:
        """Sign the stored operation; the token dies with the intent."""

        record = self.record(intent_id)
        now = int(self.clock())
        lifetime = min(self.ttl, record.expires_at - now)
        if lifetime < 1:
            raise ConfirmationError(
                f"intent {record.intent_id} expires too soon to approve"
            )
        claims = claims_for(
            record.operation, approved_by, issued_at=now, ttl=lifetime
        )
        return claims, sign_approval(claims, self.key)
