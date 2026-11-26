"""The hledger projection over a published finance replica.

One ``finance::txn::<account>::<transaction>`` object becomes one journal
transaction; the generation stays the authority for what a bank actually said,
and this file is a view of it that can be rebuilt whenever the accounting format
changes. Nothing here reads a clock, so the same generation always renders the
same bytes.

**Sign.** SimpleFIN's ``amount`` sign is the provider's own and this module
writes it through unchanged onto the mapped asset account, posting the exact
negation to the counter-account. That is a deliberate refusal to guess, not an
oversight: SimpleFIN normalizes nothing, the convention differs between
institutions, and a projection that flipped a sign on a hunch would be a ledger
that agrees with itself and disagrees with the bank. A debit therefore appears
with whatever sign SimpleFIN sent -- and, symmetrically, so does a credit. The
counter-account is ``expenses:unknown`` for every transaction, because calling a
row income rather than expense is the same guess written somewhere else. An
operator who needs the classification reclassifies downstream; this module never
invents one.

**Names.** The mapped account is the operator's, from
``index/hledger/accounts.json`` (``{"<simplefin account id>": "<hledger account
name>"}``). An account the file does not map falls back to
``assets:unknown:<sanitized id>``, which is visible in the journal as an account
nobody meant to have. A name that would turn a posting line into something else
-- empty, a leading ``-``, ``!`` or ``;``, or a control character -- is a
refusal, never a repaired name.

**Dates and status.** ``posted`` epoch seconds become the UTC date. A record
with no date at all uses its own ``transacted_at``, then its own ``posted``, and
a record that has neither is skipped and counted rather than dated "today": an
invented date is a wrong entry in the one place a reader will trust. An epoch of
``0`` counts as no date, because that is what the provider writes for a row it
never dated and 1970-01-01 would read as a fact about the bank. Pending records
carry hledger's ``!``, cleared ones ``*``.

**Money.** The currency comes from the account object, else from the transaction
itself. A transaction that names neither is a refusal: emitting a commodity-less
posting beside a commodity'd one is a journal that does not balance, and hledger's
job is to balance.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Iterable, Mapping

from ..collectors.state import ReplicaState
from ..errors import DataPlaneError, PublishError, ValidationError

#: A refusal publishes nothing: a bad mapping, an unreadable replica, an
#: unwritable journal. The same code the collectors use for the same reason.
EXIT_REFUSED = 3

#: Where a transaction lands when the operator has not mapped its account.
FALLBACK_ROOT = "assets:unknown"
#: The other side of every transaction. One account, because picking between
#: income and expense is a guess about the provider's sign (see the module doc).
COUNTER_ACCOUNT = "expenses:unknown"

CLEARED = "*"
PENDING = "!"

#: hledger's own indentation for a posting.
_POSTING_INDENT = "    "
#: At least this much space between an account name and its amount.
_AMOUNT_GAP = 2
#: The account-directive and posting grammar breaks on these; anything else the
#: provider used in an account id is replaced, so the fallback name is one level.
_UNSAFE_ACCOUNT_CHARS = re.compile(r"[^A-Za-z0-9._-]")
#: The characters that turn a line into a directive or a comment when they lead
#: it, plus the controls that would break the line itself.
_UNSAFE_LEADING = frozenset("-!;")
#: A commodity is whatever hledger prints after the amount, so it has to survive
#: as one token and mean the same thing to the next reader.
_SAFE_COMMODITY = re.compile(r"[A-Za-z0-9._-]+")


@dataclass(frozen=True)
class JournalReport:
    """What one render produced, for the unit and the operator's JSON line."""

    snapshot: str
    #: Transaction objects in the generation.
    objects: int
    #: Those that carried no usable date and were left out.
    skipped: int
    #: Distinct hledger account names the journal declares and posts to.
    accounts: int


@dataclass(frozen=True)
class _Posting:
    account: str
    amount: Decimal
    commodity: str


@dataclass(frozen=True)
class _Entry:
    date: str
    status: str
    description: str
    account_id: str
    transaction_id: str
    asset: _Posting
    counter: _Posting

    @property
    def order(self) -> tuple[str, str, str]:
        return (self.date, self.account_id, self.transaction_id)


def validate_account(name: str) -> str:
    """The name as hledger should read it, or a refusal naming what is wrong."""

    if not isinstance(name, str):
        raise ValidationError(f"an hledger account name must be a string, not {name!r}")
    trimmed = name.strip()
    if not trimmed:
        raise ValidationError("an hledger account name cannot be empty")
    if trimmed[0] in _UNSAFE_LEADING:
        raise ValidationError(
            f"hledger account name {trimmed!r} starts with {trimmed[0]!r}, "
            "which hledger reads as a directive or a comment"
        )
    for character in trimmed:
        if character < " " or character == "\x7f":
            raise ValidationError(
                f"hledger account name {trimmed!r} contains the control character "
                f"{character!r}; a name is one line"
            )
    return trimmed


def sanitized_account(account_id: str) -> str:
    """The fallback name for an account nobody mapped: visible, and one level."""

    cleaned = _UNSAFE_ACCOUNT_CHARS.sub("_", str(account_id).strip())
    return f"{FALLBACK_ROOT}:{cleaned or 'unknown'}"


def load_accounts(path: str | Path) -> dict[str, str]:
    """Read the operator's mapping file, refusing anything but strings to strings."""

    source = Path(path)
    try:
        text = source.read_text(encoding="utf-8")
    except OSError as exc:
        raise ValidationError(f"{source} is unreadable") from exc
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ValidationError(
            f"{source} is not JSON: line {exc.lineno} column {exc.colno}: {exc.msg}"
        ) from exc
    if not isinstance(parsed, dict):
        raise ValidationError(
            f"{source} must be a JSON object of SimpleFIN account id to hledger "
            f"account name, not {type(parsed).__name__}"
        )
    mapping: dict[str, str] = {}
    for account_id, name in parsed.items():
        if not isinstance(name, str):
            raise ValidationError(
                f"{source} maps account {account_id!r} to {name!r}, "
                "which is not a string"
            )
        mapping[account_id] = validate_account(name)
    return mapping


def render_journal(
    replica: ReplicaState, accounts: Mapping[str, str]
) -> tuple[str, JournalReport]:
    """Render one replica state as a journal; no I/O beyond reading the replica."""

    account_objects: dict[str, Mapping[str, Any]] = {}
    transactions: list[Mapping[str, Any]] = []
    for entry in replica.entries():
        metadata = entry.get("metadata") or {}
        kind = metadata.get("kind")
        if kind == "account":
            account_id = metadata.get("account_id")
            if isinstance(account_id, str):
                account_objects[account_id] = _json_object(
                    replica, entry["object_id"]
                )
        elif kind == "transaction":
            transactions.append(dict(entry))

    entries: list[_Entry] = []
    skipped = 0
    for entry in transactions:
        metadata = entry["metadata"]
        object_id = entry["object_id"]
        record = _json_object(replica, object_id)
        account_id = str(metadata.get("account_id", ""))
        transaction_id = str(metadata.get("transaction_id", ""))
        date = _date(metadata, record)
        if date is None:
            skipped += 1
            continue
        pending = bool(metadata.get("pending"))
        amount = _amount(record, object_id)
        commodity = _commodity(record, account_objects.get(account_id), object_id)
        entries.append(
            _Entry(
                date=date,
                status=PENDING if pending else CLEARED,
                description=_description(record),
                account_id=account_id,
                transaction_id=transaction_id,
                asset=_Posting(
                    account=_account_name(account_id, accounts),
                    amount=amount,
                    commodity=commodity,
                ),
                counter=_Posting(
                    account=COUNTER_ACCOUNT,
                    amount=-amount,
                    commodity=commodity,
                ),
            )
        )

    entries.sort(key=lambda item: item.order)
    names = sorted(
        {entry.asset.account for entry in entries}
        | ({COUNTER_ACCOUNT} if entries else set())
    )
    text = _render(replica, entries, names)
    return text, JournalReport(
        snapshot=replica.snapshot,
        objects=len(transactions),
        skipped=skipped,
        accounts=len(names),
    )


def write_journal(text: str, path: str | Path) -> bool:
    """Write the journal atomically; report whether the bytes changed.

    A two-hourly rerun over an unchanged generation must not rewrite the file:
    the bytes are compared first, and an identical journal leaves the inode --
    its mtime included -- alone. Anything else replaces the file in one rename,
    so a reader never sees half a journal and a crash never leaves a truncated
    one behind.
    """

    target = Path(path)
    payload = text.encode("utf-8")
    if target.is_symlink():
        raise PublishError(f"{target} is a symlink; refusing to write through it")
    temporary: str | None = None
    try:
        parent = target.parent
        if not parent.is_dir():
            # `mkdir`'s mode is filtered by the umask, and the unit sets 0077:
            # the group bit this directory exists for would be gone.
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


def _json_object(replica: ReplicaState, object_id: str) -> Mapping[str, Any]:
    try:
        value = json.loads(replica.read(object_id))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ValidationError(f"{object_id} is not readable JSON") from exc
    if not isinstance(value, Mapping):
        raise ValidationError(f"{object_id} is not a JSON object")
    return value


def _account_name(account_id: str, accounts: Mapping[str, str]) -> str:
    """The operator's name for the account, or the visible fallback."""

    mapped = accounts.get(account_id)
    if mapped is None:
        return sanitized_account(account_id)
    return validate_account(mapped)


def _epoch(value: Any) -> int | None:
    """A provider timestamp in seconds, or ``None`` when there is no date.

    Zero is not a date: it is what a provider writes for a row it never dated,
    and rendering it would put a pending transaction on 1970-01-01 while looking
    like a fact about the bank.
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


def _date(metadata: Mapping[str, Any], record: Mapping[str, Any]) -> str | None:
    """The UTC date of a transaction, or ``None`` when the provider gave none.

    The collector's ``posted`` is the record's own time in its own preference
    order. A record it could not date is retried here in the provider's words --
    ``transacted_at`` first -- because a pending row is exactly the case where
    the provider's posting date is still empty.
    """

    epoch = _epoch(metadata.get("posted"))
    if epoch is None:
        for key in ("transacted_at", "posted"):
            epoch = _epoch(record.get(key))
            if epoch is not None:
                break
    if epoch is None:
        return None
    try:
        return datetime.fromtimestamp(epoch, timezone.utc).date().isoformat()
    except (OverflowError, OSError, ValueError):
        return None


def _amount(record: Mapping[str, Any], object_id: str) -> Decimal:
    raw = record.get("amount")
    blank = isinstance(raw, str) and not raw.strip()
    if raw is None or isinstance(raw, bool) or blank:
        raise ValidationError(f"{object_id} has no amount to post")
    try:
        value = Decimal(str(raw).strip())
    except InvalidOperation as exc:
        raise ValidationError(
            f"{object_id} has an amount that is not a number: {raw!r}"
        ) from exc
    if not value.is_finite():
        raise ValidationError(f"{object_id} has a non-finite amount: {raw!r}")
    return value


def _commodity(
    record: Mapping[str, Any],
    account: Mapping[str, Any] | None,
    object_id: str,
) -> str:
    for source in (account, record):
        if not isinstance(source, Mapping):
            continue
        value = source.get("currency")
        if not isinstance(value, str) or not value.strip():
            continue
        name = value.strip()
        if not _SAFE_COMMODITY.fullmatch(name):
            raise ValidationError(
                f"{object_id} names the currency {name!r}, which is not one token"
            )
        return name
    raise ValidationError(
        f"{object_id} names no currency on its account or itself; a journal that "
        "posts a commodity against none does not balance"
    )


def _description(record: Mapping[str, Any]) -> str:
    for key in ("description", "payee"):
        value = record.get(key)
        if isinstance(value, str) and value.strip():
            # One line, and no control characters: the provider's text is not
            # structural, so it is flattened rather than refused.
            return " ".join(value.split())
    return ""


def _format_amount(value: Decimal) -> str:
    """Two decimals at least, whatever the provider sent beyond that, no zeros."""

    text = format(value, "f")
    whole, _, fraction = text.partition(".")
    fraction = fraction.rstrip("0")
    return f"{whole}.{fraction.ljust(2, '0')}"


def _render(
    replica: ReplicaState, entries: Iterable[_Entry], names: Iterable[str]
) -> str:
    lines = [
        "; hledger journal projected from a raw finance replica; never authoritative.",
        f"; source: {replica.source_id or 'finance'}, "
        f"replica {replica.snapshot}",
        "; sign: the provider's amount goes through unchanged onto the mapped account",
        f";       and {COUNTER_ACCOUNT} carries its exact negation, so a debit keeps",
        ";       whatever sign SimpleFIN sent. The mapping decides which side is out.",
        f"; status: {PENDING} is pending at the provider, {CLEARED} is cleared; a "
        "record the provider",
        ";         never dated is left out rather than dated today.",
    ]
    lines.extend(f"account {name}" for name in names)
    for entry in entries:
        width = max(len(entry.asset.account), len(entry.counter.account)) + _AMOUNT_GAP
        lines.append("")
        heading = f"{entry.date} {entry.status} {entry.description}".rstrip()
        lines.append(heading)
        for posting in (entry.asset, entry.counter):
            amount = f"{_format_amount(posting.amount)} {posting.commodity}"
            lines.append(f"{_POSTING_INDENT}{posting.account:<{width}}{amount}")
    return "\n".join(lines) + "\n"


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="data_plane.derived.hledger",
        description="Render a published finance replica as one hledger journal.",
    )
    parser.add_argument(
        "--replica",
        required=True,
        help="the finance replica root; its committed state is read",
    )
    parser.add_argument(
        "--accounts",
        required=True,
        help="JSON object mapping SimpleFIN account id to hledger account name",
    )
    parser.add_argument("--out", required=True, help="the journal to write")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="render and report, then write nothing",
    )
    return parser


def run(args: argparse.Namespace) -> int:
    accounts = load_accounts(args.accounts)
    replica = ReplicaState(args.replica, read_only=True)
    text, report = render_journal(replica, accounts)
    if not args.dry_run:
        write_journal(text, args.out)
    print(
        json.dumps(
            {
                "accounts": report.accounts,
                "objects": report.objects,
                "path": None if args.dry_run else str(Path(args.out)),
                "skipped": report.skipped,
            },
            sort_keys=True,
        )
    )
    return 0


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(list(sys.argv[1:] if argv is None else argv))
    try:
        return run(args)
    except DataPlaneError as error:
        print(f"hledger: {error}", file=sys.stderr)
        return EXIT_REFUSED


if __name__ == "__main__":
    raise SystemExit(main())
