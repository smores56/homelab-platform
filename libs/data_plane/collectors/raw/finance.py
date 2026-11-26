"""Raw finance: a SimpleFIN AccountSet becomes one published generation.

The provider's record is stored whole -- ``extra``, connection metadata, pending
transactions and the error lists included -- because the interesting question
later is usually "what did Schwab actually say", and a projection cannot answer
it. Observations are keyed by ``(accountset_url, conn_id, account_id,
transaction_id)`` and each one carries the sha256 of its complete record, so a
pending transaction that posts is visible as the same key with a different hash
rather than as a new row that hides the transition.

Publication is refused, not degraded, when the provider reports a problem:

* a non-empty ``errlist`` at the document level,
* a non-empty error list on one account, or
* ``act.missingdata`` anywhere on it.

An AccountSet with a partial account is a partial enumeration, and publishing it
would look like a generation in which transactions disappeared.

Everything is requested explicitly: pending items are part of the response only
because the caller asked for them, so ``include_pending`` must be set rather than
defaulted. A 90-day window is the provider's normal reach, and a transaction that
falls out of it is carried forward as absent-for-window, never deleted.
"""

from __future__ import annotations

import hashlib
import time
from typing import Any, Iterable, Mapping

from ...errors import PublishError, ValidationError
from ...model import FidelityLimit
from ..state import ReplicaState
from .replica import (
    ABSENCE_PROVIDER_WINDOW,
    CollectReport,
    commit_pass,
    canonical_json,
)

SOURCE_ID = "finance.ledger"

FIDELITY_LIMITS: tuple[FidelityLimit, ...] = (
    FidelityLimit(
        field="statement.pdf",
        reason="SimpleFIN exposes no statements; institution PDFs stay outside this replica",
    ),
    FidelityLimit(
        field="history.beyond_window",
        reason="only what the provider returns in the requested window was ever observed",
    ),
    FidelityLimit(
        field="deletion",
        reason="a transaction missing from a window is absence, not provider tombstone",
    ),
)

_ERROR_KEYS = ("errlist", "errors", "error")
_MISSING_DATA_KEYS = ("missingdata", "missing_data", "act_missing_data")


def _errors(mapping: Mapping[str, Any]) -> list[str]:
    found: list[str] = []
    for key in _ERROR_KEYS:
        value = mapping.get(key)
        if value in (None, "", (), [], {}):
            continue
        found.append(f"{key}={value!r}")
    return found


def _missing_data(mapping: Mapping[str, Any]) -> list[str]:
    found: list[str] = []
    for key in _MISSING_DATA_KEYS:
        if mapping.get(key) not in (None, "", (), [], {}):
            found.append(f"{key}={mapping[key]!r}")
    for container in ("extra", "act"):
        nested = mapping.get(container)
        if isinstance(nested, Mapping):
            found.extend(_missing_data(nested))
    return found


def _connection_id(account: Mapping[str, Any], connections: Mapping[str, Mapping[str, Any]]) -> str:
    for key in ("conn_id", "connection_id", "conn"):
        value = account.get(key)
        if value not in (None, ""):
            return str(value)
    nested = account.get("extra")
    if isinstance(nested, Mapping):
        for key in ("conn_id", "connection_id"):
            value = nested.get(key)
            if value not in (None, ""):
                return str(value)
    # The beta bridge sends no `connections` array at all: an account names its
    # institution in `org` instead, and the domain is the part that survives a
    # renamed organization.
    org = account.get("org")
    if isinstance(org, Mapping):
        for key in ("domain", "id", "name"):
            value = org.get(key)
            if value not in (None, ""):
                return str(value)
    if len(connections) == 1:
        return next(iter(connections))
    if not connections:
        raise ValidationError("account names no connection and the document has none")
    raise ValidationError("account names no connection and the document has several")


def _transaction_time(record: Mapping[str, Any]) -> int | None:
    for key in ("posted", "transacted_at", "posted_at"):
        value = record.get(key)
        if isinstance(value, bool):
            continue
        if isinstance(value, int):
            return value
        if isinstance(value, str):
            try:
                return int(float(value))
            except ValueError:
                continue
    return None


def _requires_id(record: Mapping[str, Any], account_id: str) -> str:
    value = record.get("id")
    if value in (None, ""):
        raise PublishError(
            f"account {account_id} has a transaction the provider did not identify"
        )
    text = str(value)
    if "/" in text or "\x00" in text:
        raise ValidationError(f"account {account_id} has an unusable transaction id {text!r}")
    return text


def collect_simplefin(
    accountset: Mapping[str, Any],
    state: ReplicaState,
    *,
    accountset_url: str,
    captured_at: str,
    include_pending: bool = False,
    window_days: int = 90,
    now: int | None = None,
) -> CollectReport:
    """Enumerate one AccountSet into ``generation``; never commit it."""

    if not isinstance(accountset, Mapping):
        raise ValidationError("an AccountSet must be an object")
    if not accountset_url.strip():
        raise ValidationError("the AccountSet needs its access URL for the observation key")
    if not include_pending:
        raise ValidationError(
            "pending items must be requested explicitly; pass include_pending=True"
        )
    if window_days < 1:
        raise ValidationError("window_days must be positive")

    problems = _errors(accountset)
    if problems:
        raise PublishError("the AccountSet reports errors: " + "; ".join(problems))

    connections: dict[str, Mapping[str, Any]] = {}
    for connection in accountset.get("connections") or ():
        if not isinstance(connection, Mapping):
            raise ValidationError("a connection entry is not an object")
        identifier = connection.get("conn_id") or connection.get("id")
        if identifier in (None, ""):
            continue
        connections[str(identifier)] = connection
        state.put(
            f"finance::connection::{identifier}",
            canonical_json(connection),
            {
                "source_id": SOURCE_ID,
                "kind": "connection",
                "conn_id": str(identifier),
                "captured_at": captured_at,
            },
        )

    accounts = accountset.get("accounts")
    if not isinstance(accounts, list) or not accounts:
        raise PublishError("the AccountSet has no accounts")

    cutoff = (now if now is not None else int(time.time())) - window_days * 86400
    transactions = 0
    pending = 0
    accounts_seen = 0
    for account in accounts:
        if not isinstance(account, Mapping):
            raise ValidationError("an account entry is not an object")
        account_id = account.get("id")
        if account_id in (None, ""):
            raise ValidationError("an account has no id")
        account_id = str(account_id)
        problems = _errors(account) + _missing_data(account)
        if problems:
            raise PublishError(
                f"account {account_id} is incomplete: " + "; ".join(problems)
            )
        conn_id = _connection_id(account, connections)
        accounts_seen += 1
        state.put(
            f"finance::account::{account_id}",
            canonical_json(account),
            {
                "source_id": SOURCE_ID,
                "kind": "account",
                "account_id": account_id,
                "conn_id": conn_id,
                "sfin_url": accountset_url,
                "captured_at": captured_at,
            },
        )

        for record in account.get("transactions") or ():
            if not isinstance(record, Mapping):
                raise ValidationError(f"account {account_id} has a transaction that is not an object")
            transaction_id = _requires_id(record, account_id)
            raw = canonical_json(record)
            is_pending = bool(record.get("pending"))
            if is_pending:
                pending += 1
            posted = _transaction_time(record)
            if not is_pending and posted is not None and posted < cutoff:
                continue
            state.put(
                f"finance::txn::{account_id}::{transaction_id}",
                raw,
                {
                    "source_id": SOURCE_ID,
                    "kind": "transaction",
                    "accountset_url": accountset_url,
                    "conn_id": conn_id,
                    "account_id": account_id,
                    "transaction_id": transaction_id,
                    "pending": is_pending,
                    "posted": posted,
                    "record_sha256": hashlib.sha256(raw).hexdigest(),
                    "captured_at": captured_at,
                },
            )
            transactions += 1

    state.put(
        "finance::accountset",
        canonical_json(accountset),
        {
            "source_id": SOURCE_ID,
            "kind": "accountset",
            "accountset_url": accountset_url,
            "window_days": window_days,
            "captured_at": captured_at,
        },
    )

    return commit_pass(
        state,
        source_id=SOURCE_ID,
        objects=transactions,
        details={
            "accounts": accounts_seen,
            "connections": len(connections),
            "transactions": transactions,
            "pending": pending,
            "window_days": window_days,
        },
        captured_at=captured_at,
        absence_reason=ABSENCE_PROVIDER_WINDOW,
    )


def fidelity_fields() -> Iterable[str]:
    return (
        "account.raw",
        "account.extra",
        "connection.raw",
        "transaction.raw",
        "transaction.pending",
    )
