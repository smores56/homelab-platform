"""Publish the mail replica where the agent's own shell can read it.

The streaming collector stores what the bridge returned as content-addressed
objects and a SQLite index: the provider's own bytes, verified, but not
something ``cat`` or ``rg`` can read. The agent's data plane is its shell, not a
tool call, so the tree it reads has to hold the messages themselves. This writes
a Maildir beside the collector's layout -- which stays the authority, unchanged --
and one bounded JSONL index for a newest-first scan that never walks a mailbox.

Three properties the reader relies on:

* the index is bounded: a shell reads a window, and ``truncated`` says that the
  window is what it got rather than that the mailbox is that small;
* every write is atomic (temp file plus ``os.replace``), so a pass that dies
  mid-way leaves the previous index intact rather than a half-written one;
* the bytes are a function of the committed state alone, so a rerun over an
  unchanged replica produces the same files. The one exception is ``last_run``,
  which is what the field is for.

The Maildir is written incrementally: a message whose ``.eml`` is already beside
its key with the recorded size is not rewritten, so a pass after one pushed
message costs one delivery, not re-encoding the mailbox. A file the state no
longer holds is removed -- the mirror is the current state, and the collector's
objects are where the history lives.
"""

from __future__ import annotations

import argparse
import email
import email.parser
import email.policy
import email.utils
import json
import os
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping

from ...errors import DataPlaneError, ValidationError
from ..state import ReplicaState

SOURCE = "mail"
#: Both mail collectors write these object ids, so this module reads either.
MESSAGE_PREFIX = "mail::"
#: The per-folder uidvalidity map: bookkeeping in the same id space.
EPOCH_OBJECT = "mail::_uidvalidity"
#: How many messages the index describes. The Maildir is not bounded: it is the
#: native form of what the replica holds, and the window is the index's.
LIMIT = 5000
MAILDIR = "maildir"
MESSAGES = "messages.jsonl"
STATE = "state.json"
#: Maildir's own spools. ``tmp`` is empty between passes: a delivery is a
#: rename out of it, never a file left in it.
SPOOLS = ("cur", "new", "tmp")

_STAMP = "%Y-%m-%dT%H:%M:%SZ"


@dataclass(frozen=True)
class Message:
    """One live message: where its ``.eml`` goes, and what the index says of it."""

    mailbox: str
    key: str
    object_id: str
    size: int
    stamp: datetime | None
    path: Path


def _now() -> str:
    return datetime.now(timezone.utc).strftime(_STAMP)


def _iso(stamp: datetime | None) -> str:
    if stamp is None:
        return ""
    return stamp.astimezone(timezone.utc).strftime(_STAMP)


def _parse_date(value: str) -> datetime | None:
    """An RFC 5322 ``Date`` as a UTC instant, or None if it names none."""

    try:
        stamp = email.utils.parsedate_to_datetime(value)
    except (TypeError, ValueError):
        return None
    if stamp is None:
        return None
    if stamp.tzinfo is None:
        return stamp.replace(tzinfo=timezone.utc)
    return stamp.astimezone(timezone.utc)


def _stamp(metadata: Mapping[str, Any]) -> datetime | None:
    """The message's own ``Date``, or when the collector captured it.

    A dateless message still belongs somewhere in a newest-first list, and the
    capture time is when it arrived: that is later than the epoch and earlier
    than everything that came after it.
    """

    for field in ("date", "captured_at"):
        value = metadata.get(field)
        if isinstance(value, str):
            stamp = _parse_date(value)
            if stamp is not None:
                return stamp
    return None


def _component(value: str, label: str) -> str:
    """One path component from a provider-supplied name.

    IMAP folder names are hierarchical (``Archive/2024``) and this tree is one
    directory per mailbox, so the separator becomes Maildir++'s dot. Everything
    that could escape the tree, name a parent, or hide a file is refused rather
    than escaped: a name this publisher has to guess at is a state this module
    does not understand.
    """

    name = value.replace("/", ".").replace("\0", "")
    if (
        not name
        or name in (".", "..")
        or any(character < " " or character == "\x7f" for character in name)
    ):
        raise ValidationError(f"mailbox {label} {value!r} is not a usable file name")
    return name


def _header_text(header: Any, field: str) -> str:
    """One decoded header field, on a single line.

    ``policy.default`` is what decodes RFC 2047 and a charset the message names
    but nobody knows. A field that still refuses to decode is empty rather than a
    failed index: one broken header must not cost the other 4999.
    """

    try:
        value = header.get(field, "")
        return " ".join(str(value).split())
    except (LookupError, TypeError, UnicodeError, ValueError):
        return ""


def _header_values(raw: bytes) -> tuple[str, str, str]:
    """``(From, To, Subject)`` as the message itself declares them."""

    header = email.parser.BytesHeaderParser(policy=email.policy.default).parsebytes(raw)
    return tuple(_header_text(header, field) for field in ("From", "To", "Subject"))


def _messages(state: ReplicaState, out: Path) -> list[Message]:
    """Every live message, with the path its ``.eml`` is published at."""

    messages: list[Message] = []
    published: set[Path] = set()
    for row in state.live_rows(MESSAGE_PREFIX):
        if row["object_id"] == EPOCH_OBJECT:
            continue
        metadata = row["metadata"]
        mailbox = metadata.get("folder")
        key = metadata.get("key")
        if not isinstance(mailbox, str) or not isinstance(key, str):
            # A bookkeeping object in the message id space: it names no message.
            continue
        path = (
            out
            / MAILDIR
            / _component(mailbox, "folder")
            / "cur"
            / f"{_component(key, 'key')}.eml"
        )
        if path in published:
            raise ValidationError(f"two messages publish to {path}")
        published.add(path)
        size = row["size"]
        messages.append(
            Message(
                mailbox=mailbox,
                key=key,
                object_id=str(row["object_id"]),
                # An unknown size always rewrites, which is the safe direction.
                size=size if isinstance(size, int) else -1,
                stamp=_stamp(metadata),
                path=path,
            )
        )
    return messages


def _order(message: Message) -> tuple[int, str, str]:
    """Newest first; ties broken by mailbox then key so two runs agree."""

    stamp = message.stamp
    return (-int(stamp.timestamp()) if stamp else 0, message.mailbox, message.key)


def _up_to_date(path: Path, size: int) -> bool:
    if size < 0 or path.is_symlink():
        return False
    try:
        return path.stat().st_size == size
    except OSError:
        return False


def _deliver(mailbox_dir: Path, name: str, raw: bytes) -> None:
    """One Maildir delivery: a temp file in ``tmp``, renamed into ``cur``."""

    spool_tmp = mailbox_dir / "tmp"
    handle, temporary = tempfile.mkstemp(dir=spool_tmp, prefix=".", suffix=".tmp")
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(raw)
        os.replace(temporary, mailbox_dir / "cur" / name)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def _publish_maildir(state: ReplicaState, messages: Iterable[Message]) -> int:
    """Write what is missing and return how many messages were delivered."""

    delivered = 0
    for message in messages:
        mailbox_dir = message.path.parents[1]
        for spool in SPOOLS:
            (mailbox_dir / spool).mkdir(mode=0o700, parents=True, exist_ok=True)
        if _up_to_date(message.path, message.size):
            continue
        _deliver(mailbox_dir, message.path.name, state.read(message.object_id))
        delivered += 1
    return delivered


def _prune(root: Path, expected: set[Path]) -> int:
    """Remove the ``.eml`` files this pass did not publish.

    Only this module's own naming is touched, so a mailbox directory a human
    dropped something into is left alone; what it does remove is every message
    the state expunged, because the mirror is the current state and not a history.
    """

    if not root.is_dir():
        return 0
    removed = 0
    for mailbox_dir in sorted(root.iterdir()):
        if mailbox_dir.is_symlink() or not mailbox_dir.is_dir():
            continue
        for spool in SPOOLS:
            directory = mailbox_dir / spool
            if not directory.is_dir() or directory.is_symlink():
                continue
            for path in sorted(directory.glob("*.eml")):
                if path not in expected:
                    path.unlink()
                    removed += 1
        # `tmp/` holds only this module's deliveries, so anything in it is a
        # delivery that a kill interrupted: the mirror is the current state, and
        # a half-written message is not part of it.
        for stale in sorted((mailbox_dir / "tmp").glob(".*.tmp")):
            stale.unlink()
    return removed


def _record(state: ReplicaState, message: Message) -> dict[str, Any]:
    """One index line: the metadata a shell needs to decide what to open."""

    raw = state.read(message.object_id)
    sender, recipient, subject = _header_values(raw)
    return {
        "mailbox": message.mailbox,
        "path": str(message.path),
        "date": _iso(message.stamp),
        "from": sender,
        "to": recipient,
        "subject": subject,
        "size": len(raw),
    }


def _atomic_write(path: Path, data: bytes) -> None:
    """One file, replaced whole: a reader sees the old bytes or the new ones."""

    handle, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def _jsonl(records: Iterable[Mapping[str, Any]]) -> bytes:
    """One line per record, in the order given, as UTF-8 rather than escapes.

    A shell greps this file: a subject written as ``\u00e9`` would never match
    the word somebody typed, so the encoding is the message's own text.
    """

    lines = (
        json.dumps(record, sort_keys=True, ensure_ascii=False) for record in records
    )
    return "".join(f"{line}\n" for line in lines).encode("utf-8")


def publish(raw: Path, out: Path) -> dict[str, Any]:
    """Publish one pass and describe it; raises ``DataPlaneError`` on a refusal."""

    if out.is_symlink():
        raise ValidationError(f"{out} is a symlink; refusing to publish through it")
    out = out.resolve()
    out.mkdir(mode=0o750, parents=True, exist_ok=True)

    state = ReplicaState(raw, read_only=True)
    try:
        messages = _messages(state, out)
        delivered = _publish_maildir(state, messages)
        # The index is built from the byte-verified objects, so a damaged replica
        # refuses here instead of publishing a line whose bytes are not there.
        recent = sorted(messages, key=_order)[:LIMIT]
        records = [_record(state, message) for message in recent]
    finally:
        state.close()

    removed = _prune(out / MAILDIR, {message.path for message in messages})
    mailboxes = sorted({message.mailbox for message in messages})
    truncated = len(messages) > len(records)

    _atomic_write(out / MESSAGES, _jsonl(records))
    # `ok` is written only by a pass that published: a refusal exits non-zero and
    # leaves the previous index in place, and the unit's journal is where the
    # failure is read. A file that said `ok: false` would be a claim nothing on
    # this host updates afterwards.
    _atomic_write(
        out / STATE,
        (
            json.dumps(
                {
                    "source": SOURCE,
                    "last_run": _now(),
                    "ok": True,
                    "messages": len(records),
                    "mailboxes": mailboxes,
                    "truncated": truncated,
                },
                sort_keys=True,
                ensure_ascii=False,
                indent=2,
            )
            + "\n"
        ).encode("utf-8"),
    )
    return {
        "source": SOURCE,
        "published": str(out),
        "messages": len(records),
        "held": len(messages),
        "mailboxes": mailboxes,
        "truncated": truncated,
        "delivered": delivered,
        "removed": removed,
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="data_plane.collectors.raw.publish_mail",
        description=(
            "Publish the mail replica as a Maildir plus a bounded newest-first "
            "index, where the agent's shell reads it."
        ),
    )
    parser.add_argument(
        "--raw",
        required=True,
        metavar="DIR",
        help="the replica root the collector writes",
    )
    parser.add_argument(
        "--out", required=True, metavar="DIR", help="the tree the agent reads"
    )
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(list(sys.argv[1:] if argv is None else argv))
    try:
        summary = publish(Path(args.raw), Path(args.out))
    except DataPlaneError as error:
        print(f"publish-mail: {error}", file=sys.stderr)
        return 1
    print(json.dumps(summary, sort_keys=True, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
