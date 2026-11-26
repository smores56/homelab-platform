"""Raw mail: one quarantined Maildir becomes one committed replica state.

The input is a Maildir -- a provider sync's output, or the fixture that stands
in for one -- that nothing else writes while this runs. What is stored is the
provider's own RFC822 bytes -- headers,
structure, encodings and attachments untouched -- because anything derived from
them (a body projection, a search index) is disposable and can be rebuilt, while
a re-encoded attachment cannot.

Three refusals matter more than the happy path:

* ``tmp/`` must be empty. A file there is a message being delivered, and
  committing a pass while a writer is active would record half a maildir.
* Every folder needs a UIDVALIDITY. A far-side UIDVALIDITY change renumbers every
  message and makes "the file with this key is gone" meaningless, so the value is
  persisted in the replica state and a change raises ``EpochError`` instead of
  committing a state that looks like mass deletion.
* Two files that map to one object id are a refusal, not a last-writer-wins.
  That is what a duplicated key looks like, and silently dropping one copy is how
  a replica loses a message while reporting success.

Deletion is recorded only where Maildir records it: a message the previous
state held and this one does not, in a folder whose UIDVALIDITY did not
change, is an expunge -- real provider evidence. The caller names those
tombstones; ``DBSync``-style absence elsewhere is not enough.
"""

from __future__ import annotations

import email
import email.parser
import email.policy
import json
import os
from pathlib import Path
from typing import Iterable, Mapping

from ...errors import EpochError, PublishError, ValidationError
from ...model import FidelityLimit
from ..state import ReplicaState
from .replica import CollectReport, canonical_json, commit_pass, resolve_source_dir

SOURCE_ID = "tuta.mail"
#: The per-folder epoch map is a store object, so a restore carries it.
UIDVALIDITY_OBJECT = "mail::_uidvalidity"

_SPOOL_DIRS = ("cur", "new")


def _flags(name: str) -> tuple[str, ...]:
    """The Maildir flags in a filename, without the version suffix."""

    _, separator, suffix = name.partition(":2,")
    if not separator:
        return ()
    return tuple(sorted(set(suffix)))


def _key(name: str) -> str:
    return name.partition(":")[0]


def maildir_folders(root: Path) -> list[tuple[str, Path]]:
    """Every folder as ``(name, path)``, INBOX first.

    Maildir++ keeps subfolders as ``.Folder.Sub`` directories beside the root;
    both that and a plain nested layout are accepted because the directory shape
    is decided by the sync tool, not by this collector.
    """

    found: list[tuple[str, Path]] = []
    if any((root / directory).is_dir() for directory in _SPOOL_DIRS):
        found.append(("INBOX", root))
    # Walk directories only and prune the spools: a maildir with a hundred
    # thousand messages must not be described by stat-ing every message.
    for current, directories, _ in os.walk(root):
        path = Path(current)
        if path != root:
            if any((path / directory).is_dir() for directory in _SPOOL_DIRS):
                # The on-disk name, not Maildir++'s dotted display form: the
                # directory is what the sync tool wrote, and the two forms are
                # only the same until a folder is nested.
                name = path.relative_to(root).as_posix()
                if name and name != "INBOX":
                    found.append((name, path))
        directories[:] = sorted(
            directory
            for directory in directories
            if directory not in _SPOOL_DIRS
            and not (path / directory).is_symlink()
        )
    found.sort(key=lambda item: (item[0] != "INBOX", item[0]))
    return found


def _headers(raw: bytes) -> tuple[str, str]:
    """The two header fields the object metadata carries, parsed from the bytes."""

    header = email.parser.BytesHeaderParser(policy=email.policy.default).parsebytes(raw)
    message_id = str(header.get("Message-ID") or header.get("Message-Id") or "").strip()
    date = str(header.get("Date") or "").strip()
    return message_id, date


def epoch_map(state: ReplicaState) -> dict[str, int]:
    """The per-folder UIDVALIDITY the last committed pass recorded."""

    if state.dry_run or not state.path.is_file():
        # Nothing has ever been committed here, and a dry run must not create
        # the database just to discover that.
        return {}
    row = state.get(UIDVALIDITY_OBJECT)
    if row is None or not row["present"]:
        return {}
    try:
        value = json.loads(state.read(UIDVALIDITY_OBJECT).decode("utf-8"))
        if not isinstance(value, dict):
            raise ValueError("not an object")
        return {str(name): int(epoch) for name, epoch in value.items()}
    except (ValueError, UnicodeDecodeError, TypeError) as exc:
        raise PublishError("the replica's uidvalidity map is unreadable") from exc


def collect_maildir(
    maildir_root: str | Path,
    state: ReplicaState,
    *,
    uidvalidity: Mapping[str, int],
    captured_at: str,
) -> CollectReport:
    """Enumerate every folder into ``state`` and commit the pass.

    ``uidvalidity`` is the provider's per-folder epoch, supplied by the caller
    (``--uidvalidity FOLDER=INT``): this collector will not guess it, because a
    guessed epoch turns every renumbering into silent deletion evidence.
    """

    root = resolve_source_dir(maildir_root, "maildir")
    folders = maildir_folders(root)
    if not folders:
        raise PublishError(f"maildir {root} has no folder with cur/ or new/")

    known = {name for name, _ in folders}
    missing = sorted(known - set(uidvalidity))
    if missing:
        raise ValidationError(
            "no uidvalidity for folders: " + ", ".join(missing)
        )
    extra = sorted(set(uidvalidity) - known)
    if extra:
        raise ValidationError(
            "uidvalidity given for folders the maildir does not have: "
            + ", ".join(extra)
        )

    earlier = epoch_map(state)
    if earlier:
        for name in sorted(known & set(earlier)):
            if int(earlier[name]) != int(uidvalidity[name]):
                raise EpochError(
                    f"folder {name} uidvalidity changed {earlier[name]} -> "
                    f"{uidvalidity[name]}; reconcile the source as a new epoch"
                )
        # The sync is pull-only with far-side create/remove/expunge disabled, so
        # a folder cannot disappear because of anything this host did. It means
        # the maildir was replaced or only half mounted, and tombstoning every
        # message in it would record that as a mass deletion.
        vanished = sorted(set(earlier) - known)
        if vanished:
            raise PublishError(
                "folders disappeared from the maildir: "
                + ", ".join(vanished)
                + "; the sync cannot remove a folder, so this is a replaced or "
                "half-mounted maildir"
            )

    counts: dict[str, int] = {}
    produced: set[str] = set()
    for name, path in folders:
        spool_tmp = path / "tmp"
        if spool_tmp.is_dir() and any(spool_tmp.iterdir()):
            raise PublishError(
                f"folder {name} has messages in tmp/; the maildir is being written"
            )
        seen: set[str] = set()
        count = 0
        for directory in _SPOOL_DIRS:
            spool = path / directory
            if not spool.is_dir():
                continue
            for item in sorted(spool.iterdir()):
                if item.is_symlink():
                    raise PublishError(f"{item} is a symlink; refusing to follow it")
                if not item.is_file():
                    continue
                key = _key(item.name)
                object_id = f"mail::{name}::{key}"
                if object_id in seen:
                    raise PublishError(
                        f"folder {name} holds two messages with the key {key!r}"
                    )
                seen.add(object_id)
                raw = item.read_bytes()
                message_id, date = _headers(raw)
                produced.add(object_id)
                state.put(
                    object_id,
                    raw,
                    {
                        "source_id": SOURCE_ID,
                        "folder": name,
                        "key": key,
                        "filename": item.name,
                        "flags": list(_flags(item.name)),
                        "uidvalidity": int(uidvalidity[name]),
                        "size": len(raw),
                        "message_id": message_id,
                        "date": date,
                        "captured_at": captured_at,
                    },
                )
                count += 1
        counts[name] = count

    state.put(
        UIDVALIDITY_OBJECT,
        canonical_json({name: int(value) for name, value in uidvalidity.items()}),
        {
            "source_id": SOURCE_ID,
            "kind": "epoch-map",
            "captured_at": captured_at,
        },
    )
    produced.add(UIDVALIDITY_OBJECT)

    _name_expunges(state, produced)
    return commit_pass(
        state,
        source_id=SOURCE_ID,
        objects=sum(counts.values()),
        details={"folders": counts},
        captured_at=captured_at,
    )


def _name_expunges(state: ReplicaState, produced: set[str]) -> int:
    """Tombstone what a stable-epoch folder no longer holds.

    This is the only place a mail object is deleted, and it is deliberate: a
    UIDVALIDITY change already refused publication, so a missing key in a folder
    that still syncs is an expunge the provider performed.
    """

    if state.dry_run:
        return 0
    deleted = 0
    for row in state.live_rows("mail::"):
        object_id = row["object_id"]
        if object_id in produced:
            continue
        state.tombstone(object_id, "provider expunge")
        deleted += 1
    return deleted


FIDELITY_LIMITS: tuple[FidelityLimit, ...] = (
    FidelityLimit(
        field="provider.tuta_metadata",
        reason="IMAP exposes no Tuta-specific fields, and no metadata sidecar is populated",
    ),
    FidelityLimit(
        field="expunge.reason",
        reason="a Maildir records an expunge as absence; why it happened is unknown",
    ),
)


def fidelity_fields() -> Iterable[str]:
    """The fields this replica preserves, for an explicit fidelity declaration."""

    return (
        "folder",
        "key",
        "flags",
        "uidvalidity",
        "message_id",
        "date",
        "mime.raw",
    )
