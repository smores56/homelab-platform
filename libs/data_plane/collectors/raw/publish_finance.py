"""Finance as plain files: the raw replica, republished as a bounded view.

The agent's shell can read the raw replica with ``sqlite3`` and ``cat``, but the
objects behind it are content-addressed JSON keyed by an object id, which is the
wrong shape for a question. This module writes the current state of the finance
replica as three plain files beside the raw artifact:

* ``accounts.jsonl`` -- one line per live account,
* ``transactions.jsonl`` -- one line per transaction inside the window,
* ``state.json`` -- what this run read, so a reader can tell a stale view from a
  failing one.

It is a view and only a view. Nothing here decides what a transaction is: the
account's balance and the transaction's amount are the provider's own decimal
text, carried through as strings, because a JSON number would round a value the
bank sent and a "cleanup" would be a second, quieter bank. A transaction the
provider never dated keeps a null date rather than being dated today, and a
pending item is kept whatever its date, because pending is the present tense.

Bounds are part of the contract, not a policy: the last ``--window-days`` of
dated transactions and at most ``MAX_TRANSACTIONS`` lines, newest first. A
truncation is recorded in ``state.json`` so a reader that finds a transaction
list ending mid-history knows it was this file's bound and not the bank's.

Publication is one rename per file: a temp file in the same directory, then
``os.replace``, so a reader never sees half a file and a failed run leaves the
previous view intact. The bytes are a function of the replica and ``--now``
alone -- every object sorted, every key sorted -- so two runs over one state
produce the same files.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping

from ...errors import DataPlaneError, PublishError
from ..state import ReplicaState

#: The source this view names in `state.json`, and the directory it publishes to.
SOURCE = "finance"

#: A refusal publishes nothing, the same code the collectors and the hledger
#: projection use for the same reason.
EXIT_REFUSED = 3

#: The provider's normal reach is a few months; a view is for the recent past,
#: and the raw replica keeps everything the collector ever saw.
DEFAULT_WINDOW_DAYS = 180
#: Past this many lines the file stops being something a shell can read, so the
#: oldest in-window transactions are dropped and the drop is recorded.
MAX_TRANSACTIONS = 20000

ACCOUNTS_FILE = "accounts.jsonl"
TRANSACTIONS_FILE = "transactions.jsonl"
STATE_FILE = "state.json"

#: SimpleFIN names the balance's date with a hyphen; the collector stores the
#: account verbatim, so both spellings have to be read.
_BALANCE_DATE_KEYS = ("balance-date", "balance_date", "balanceDate")
#: The provider's posting time, in the collector's own preference order.
_POSTED_KEYS = ("posted", "transacted_at", "posted_at")


def _epoch(value: Any) -> int | None:
    """A provider timestamp in seconds, or ``None`` when there is no date.

    Zero is what the provider writes for a row it never dated, and a view that
    printed 1970-01-01 would turn "no date" into a fact about the bank.
    """

    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, int):
        return value if value > 0 else None
    if isinstance(value, str):
        try:
            parsed = int(float(value.strip()))
        except ValueError:
            return None
        return parsed if parsed > 0 else None
    return None


def _date_text(epoch: int | None) -> str | None:
    """UTC ``YYYY-MM-DD``, or ``None`` for an undated record."""

    if epoch is None:
        return None
    try:
        return datetime.fromtimestamp(epoch, timezone.utc).date().isoformat()
    except (OverflowError, OSError, ValueError):
        return None


def _posted_epoch(
    metadata: Mapping[str, Any], record: Mapping[str, Any]
) -> int | None:
    """The record's own time, from the collector's field and then its words."""

    epoch = _epoch(metadata.get("posted"))
    if epoch is None:
        for key in _POSTED_KEYS:
            epoch = _epoch(record.get(key))
            if epoch is not None:
                break
    return epoch


def _text(value: Any) -> str | None:
    """A provider string, trimmed; anything else becomes null rather than a guess."""

    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, str):
        return value.strip() or None
    if isinstance(value, (int, float)):
        return str(value)
    return None


def _description(record: Mapping[str, Any]) -> str | None:
    """The payee text as one line: the provider's words, never its structure."""

    for key in ("description", "payee"):
        value = record.get(key)
        if isinstance(value, str) and value.strip():
            return " ".join(value.split())
    return None


def _object(replica: ReplicaState, object_id: str) -> Mapping[str, Any]:
    try:
        value = json.loads(replica.read(object_id))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise PublishError(f"{object_id} is not readable JSON") from exc
    if not isinstance(value, Mapping):
        raise PublishError(f"{object_id} is not a JSON object")
    return value


def _account_row(account_id: str, record: Mapping[str, Any]) -> dict[str, Any]:
    """One account line. The balance stays the provider's text, verbatim."""

    balance_date: Any = None
    for key in _BALANCE_DATE_KEYS:
        if record.get(key) is not None:
            balance_date = record[key]
            break
    return {
        "id": account_id,
        "name": _text(record.get("name")),
        "currency": _text(record.get("currency")),
        "balance": _text(record.get("balance")),
        "balance_date": _date_text(_epoch(balance_date)),
    }


def _transaction_row(
    metadata: Mapping[str, Any], record: Mapping[str, Any]
) -> dict[str, Any]:
    return {
        "account_id": str(metadata.get("account_id", "")),
        "amount": _text(record.get("amount")),
        "date": _date_text(_posted_epoch(metadata, record)),
        "description": _description(record),
        "pending": bool(metadata.get("pending")),
    }


def _order(row: Mapping[str, Any]) -> tuple[str, str, str, str]:
    """Newest first; an undated row sorts last, its own fields breaking ties.

    The tuple is also the determinism guarantee: two runs over one state and one
    stable sort cannot disagree about the order of equal dates.
    """

    return (
        str(row["date"] or ""),
        str(row["account_id"]),
        str(row["amount"] or ""),
        str(row["description"] or ""),
    )


def build_view(
    replica: ReplicaState, *, now: int, window_days: int = DEFAULT_WINDOW_DAYS
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    """The three views of one replica state: accounts, transactions, and state."""

    if window_days < 1:
        raise PublishError("window_days must be positive")
    cutoff = now - window_days * 86400

    accounts: list[dict[str, Any]] = []
    transactions: list[dict[str, Any]] = []
    for entry in replica.entries():
        metadata = entry.get("metadata") or {}
        kind = metadata.get("kind")
        if kind == "account":
            account_id = metadata.get("account_id")
            if not isinstance(account_id, str):
                continue
            accounts.append(_account_row(account_id, _object(replica, entry["object_id"])))
        elif kind == "transaction":
            record = _object(replica, entry["object_id"])
            row = _transaction_row(metadata, record)
            # Pending is the present tense and is kept whatever its date; a dated
            # transaction outside the window is history the raw replica still has.
            if not row["pending"]:
                epoch = _posted_epoch(metadata, record)
                if epoch is not None and epoch < cutoff:
                    continue
            transactions.append(row)

    accounts.sort(key=lambda row: str(row["id"]))
    transactions.sort(key=_order, reverse=True)
    dropped = max(0, len(transactions) - MAX_TRANSACTIONS)
    transactions = transactions[:MAX_TRANSACTIONS]

    state = {
        "source": SOURCE,
        "last_run": _timestamp(now),
        "ok": True,
        "accounts": len(accounts),
        "transactions": len(transactions),
        "window_days": window_days,
        "truncated": dropped > 0,
        "dropped": dropped,
    }
    return accounts, transactions, state


def _timestamp(now: int) -> str:
    try:
        return datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (OverflowError, OSError, ValueError) as exc:
        raise PublishError(f"--now {now} is not a timestamp") from exc


def _jsonl(rows: Iterable[Mapping[str, Any]]) -> str:
    return "".join(
        json.dumps(row, sort_keys=True, ensure_ascii=False) + "\n" for row in rows
    )


def _json(document: Mapping[str, Any]) -> str:
    return json.dumps(document, sort_keys=True, ensure_ascii=False, indent=2) + "\n"


def write_atomic(text: str, path: str | Path) -> bool:
    """Replace ``path`` in one rename; report whether the bytes changed.

    A temp file in the same directory, fsynced and then renamed, so a reader sees
    either the previous file or the new one and a crash leaves neither truncated.
    Identical bytes leave the inode alone, which keeps a two-hourly rerun from
    touching an unchanged file's mtime.
    """

    target = Path(path)
    payload = text.encode("utf-8")
    if target.is_symlink():
        raise PublishError(f"{target} is a symlink; refusing to write through it")
    temporary: str | None = None
    try:
        parent = target.parent
        if not parent.is_dir():
            # `mkdir`'s mode is filtered by the unit's umask of 0077; the group
            # bit is the one this dataset exists for.
            parent.mkdir(mode=0o750, parents=True, exist_ok=True)
            os.chmod(parent, 0o750)
        if target.is_file() and target.read_bytes() == payload:
            return False
        handle = tempfile.NamedTemporaryFile(
            dir=parent, prefix=f".{target.name}.", suffix=".tmp", delete=False
        )
        temporary = handle.name
        with handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, target)
        temporary = None
    except OSError as exc:
        if temporary is not None:
            with contextlib.suppress(OSError):
                os.unlink(temporary)
        raise PublishError(f"{target} is not writable: {exc.strerror or exc}") from exc
    return True


def publish(
    raw: str | Path,
    out: str | Path,
    *,
    now: int,
    window_days: int = DEFAULT_WINDOW_DAYS,
) -> dict[str, Any]:
    """Read one finance replica and write the three files under ``out``.

    The replica is opened the way the hledger projection opens it: read-only,
    ``query_only``, every object verified against its recorded size and sha256. A
    replica that is missing or damaged is a refusal, and a refusal writes nothing
    here, so a reader never sees a view of a state that was not there.
    """

    replica = ReplicaState(raw, read_only=True)
    accounts, transactions, state = build_view(
        replica, now=now, window_days=window_days
    )
    directory = Path(out)
    written = write_atomic(_jsonl(accounts), directory / ACCOUNTS_FILE)
    written |= write_atomic(_jsonl(transactions), directory / TRANSACTIONS_FILE)
    # state.json goes last: a reader that finds it agrees with the two files it
    # describes, because the run that wrote them already finished.
    written |= write_atomic(_json(state), directory / STATE_FILE)
    return {
        "accounts": state["accounts"],
        "transactions": state["transactions"],
        "dropped": state["dropped"],
        "changed": written,
        "path": str(directory),
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="data_plane.collectors.raw.publish_finance",
        description="Publish a finance replica as accounts.jsonl, "
        "transactions.jsonl and state.json.",
    )
    parser.add_argument(
        "--raw",
        required=True,
        help="the finance replica root; its committed state is read",
    )
    parser.add_argument("--out", required=True, help="the directory to publish into")
    parser.add_argument(
        "--now",
        type=int,
        default=None,
        help="epoch seconds the run is dated with; the unit omits it, a test pins it",
    )
    parser.add_argument(
        "--window-days",
        type=int,
        default=DEFAULT_WINDOW_DAYS,
        help=f"how many days of transactions to publish (default {DEFAULT_WINDOW_DAYS})",
    )
    return parser


def run(args: argparse.Namespace) -> int:
    now = int(time.time()) if args.now is None else args.now
    report = publish(args.raw, args.out, now=now, window_days=args.window_days)
    print(json.dumps(report, sort_keys=True))
    return 0


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(list(sys.argv[1:] if argv is None else argv))
    try:
        return run(args)
    except DataPlaneError as error:
        print(f"publish-finance: {error}", file=sys.stderr)
        return EXIT_REFUSED


if __name__ == "__main__":
    sys.exit(main())
