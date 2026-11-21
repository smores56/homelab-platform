"""Operator-only confirmation surface for signed, cross-pod approvals.

The write broker runs in another pod and never holds the operator key. This
service is the only place an approval is minted:

* it authenticates with ``X-Operator-Token``, a secret distinct from the
  workload identity key and the event-service token;
* it renders the operation from the **effect owner's** stored intent, never from
  the request. A caller that supplies ``operation`` or ``operation_hash`` is
  refused, so a runtime that shows one diff to a human cannot have another
  approved;
* it checks that stored operation against the source catalog, so a malformed,
  unknown, or epoch-stale record is refused before it is signed;
* it signs an :class:`~data_plane.approval.ApprovalClaims` bound to the
  operation hash, intent id, and epoch, with a lifetime that never outlives the
  intent. The broker spends the nonce in the same transaction that reserves the
  effect, so a token works once and only for the stored operation.

``GET /healthz`` is the only unauthenticated route and names nothing else.
There is deliberately no route that accepts a workload token: a tenant cannot
reach this surface through the broker, and no request without the operator
token can mint an approval or reject an intent.
"""

from __future__ import annotations

import hmac
import time
from dataclasses import dataclass
from typing import Any, Callable, Mapping

from data_plane.approval import (
    DEFAULT_APPROVAL_TTL_SECONDS,
    MAX_APPROVAL_TTL_SECONDS,
    ApprovalAuthority,
    PendingApproval,
)
from data_plane.errors import ConfirmationError, DataPlaneError
from data_plane.model import EffectClass, SourceContract

from . import common

OPERATOR_TOKEN_HEADER = "x-operator-token"

_READ_EFFECTS = frozenset({EffectClass.READ, EffectClass.SEARCH})
# Keys that would let the caller describe the effect instead of the owner.
_CALLER_OPERATION_KEYS = ("operation", "operation_hash", "targets", "field_diff")


def _secret_bytes(secret: bytes | str | None) -> bytes | None:
    if secret is None:
        return None
    raw = secret.encode("utf-8") if isinstance(secret, str) else bytes(secret)
    return raw or None


@dataclass(frozen=True)
class ConfirmationService:
    """Routes for one operator surface and its signing key."""

    key: bytes | str
    operator_secret: bytes | str | None
    sources: Mapping[str, SourceContract]
    pending_record: Callable[[str], PendingApproval] | None = None
    reject_intent: Callable[[str, str], Any] | None = None
    max_ttl: int = MAX_APPROVAL_TTL_SECONDS
    clock: Callable[[], float] = time.time

    def __post_init__(self) -> None:
        if isinstance(self.max_ttl, bool) or not isinstance(self.max_ttl, int):
            raise ValueError("max_ttl must be a positive integer")
        if self.max_ttl < 1 or self.max_ttl > MAX_APPROVAL_TTL_SECONDS:
            raise ValueError(
                f"max_ttl must be between 1 and {MAX_APPROVAL_TTL_SECONDS} seconds"
            )
        if not _secret_bytes(self.key):
            raise ValueError("operator signing key is empty")

    @property
    def routes(self) -> common.Routes:
        return {
            ("GET", "/pending"): self.pending,
            ("POST", "/approve"): self.approve,
            ("POST", "/reject"): self.reject,
            ("GET", "/healthz"): self.health,
        }

    def _require_operator(self, request: Any) -> None:
        secret = _secret_bytes(self.operator_secret)
        if secret is None:
            # Fail closed: a surface with no operator token can never mint one.
            raise common.HttpError(
                503, "unavailable", "confirmation has no operator token configured"
            )
        presented = request.headers.get(OPERATOR_TOKEN_HEADER, "").strip()
        if not presented:
            raise common.HttpError(401, "unauthorized", "missing operator token")
        if not hmac.compare_digest(
            presented.encode("utf-8", "ignore"), secret
        ):
            raise common.HttpError(403, "forbidden", "operator token does not match")

    def _authority(self, ttl: int) -> ApprovalAuthority:
        if self.pending_record is None:
            raise common.HttpError(
                503, "unavailable", "confirmation has no pending intents to read"
            )
        return ApprovalAuthority(
            self.pending_record,
            self.key,
            ttl=ttl,
            max_ttl=self.max_ttl,
            clock=self.clock,
        )

    def _record(self, intent_id: str, ttl: int) -> PendingApproval:
        """Load and validate the effect owner's canonical pending operation."""

        try:
            record = self._authority(ttl).record(intent_id)
        except ConfirmationError as exc:
            raise common.HttpError(409, "conflict", str(exc)) from exc
        self._validate(record)
        return record

    def _validate(self, record: PendingApproval) -> None:
        operation = record.operation
        if not operation.intent_id.strip():
            raise common.HttpError(400, "validation", "operation has no intent id")
        if not operation.targets:
            raise common.HttpError(400, "validation", "operation has no targets")
        if operation.affected_count != len(operation.targets):
            raise common.HttpError(
                400, "validation", "operation affected_count does not match targets"
            )
        contract = self.sources.get(operation.source_id)
        if contract is None:
            raise common.HttpError(
                400, "validation", f"unknown source {operation.source_id!r}"
            )
        try:
            capability = contract.capability(operation.capability)
        except DataPlaneError as exc:
            raise common.HttpError(400, "validation", str(exc)) from exc
        if capability.effect in _READ_EFFECTS:
            raise common.HttpError(
                400,
                "validation",
                f"capability {capability.name!r} is {capability.effect.value}, not a write",
            )
        if operation.epoch != contract.epoch:
            raise common.HttpError(
                409,
                "epoch",
                f"source {operation.source_id!r} is at epoch {contract.epoch}, "
                f"not {operation.epoch}",
            )

    @staticmethod
    def _forbid_supplied_operation(body: Mapping[str, Any]) -> None:
        for key in _CALLER_OPERATION_KEYS:
            if key in body:
                raise common.HttpError(
                    400,
                    "validation",
                    "this surface renders the effect owner's stored operation;"
                    f" {key!r} cannot be supplied",
                )

    @staticmethod
    def _approved_by(body: Mapping[str, Any]) -> str:
        approved_by = common.field_str(body, "approved_by")
        if len(approved_by) > 128 or any(ord(ch) < 32 for ch in approved_by):
            raise common.HttpError(
                400, "validation", "approved_by must be printable and at most 128 chars"
            )
        return approved_by

    def pending(self, request: Any, query: common.Query) -> tuple[int, Any]:
        self._require_operator(request)
        intent_id = common.query_str(query, "intent_id", required=True)
        record = self._record(intent_id, self.max_ttl)
        return 200, {"pending": record.as_dict(), "render": record.render()}

    def approve(self, request: Any, query: common.Query) -> tuple[int, Any]:
        self._require_operator(request)
        body = common.read_json_object(request)
        self._forbid_supplied_operation(body)
        intent_id = common.field_str(body, "intent_id")
        approved_by = self._approved_by(body)
        ttl = common.field_optional_int(body, "ttl")
        if ttl is None:
            ttl = min(self.max_ttl, DEFAULT_APPROVAL_TTL_SECONDS)
        if ttl < 1 or ttl > self.max_ttl:
            raise common.HttpError(
                400,
                "validation",
                f"ttl must be between 1 and {self.max_ttl} seconds",
            )
        record = self._record(intent_id, ttl)
        try:
            claims, token = self._authority(ttl).approve(intent_id, approved_by)
        except ConfirmationError as exc:
            raise common.HttpError(409, "conflict", str(exc)) from exc
        return 200, {
            "approval_token": token,
            "claims": claims.to_dict(),
            "pending": record.as_dict(),
        }

    def reject(self, request: Any, query: common.Query) -> tuple[int, Any]:
        self._require_operator(request)
        body = common.read_json_object(request)
        self._forbid_supplied_operation(body)
        intent_id = common.field_str(body, "intent_id")
        approved_by = self._approved_by(body)
        if self.reject_intent is None:
            raise common.HttpError(
                503, "unavailable", "confirmation has no intent journal to reject in"
            )
        reason = common.field_optional_str(body, "reason") or f"rejected by {approved_by}"
        try:
            self.reject_intent(intent_id, reason)
        except DataPlaneError as exc:
            raise common.HttpError(409, "conflict", str(exc)) from exc
        return 200, {"intent_id": intent_id, "state": "rejected"}

    def health(self, request: Any, query: common.Query) -> tuple[int, Any]:
        return 200, {"status": "ok", "service": "confirmation"}
