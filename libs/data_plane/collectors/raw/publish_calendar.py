"""Calendar as plain files: the replica's derived ICS, republished as a vdir.

The collector already derives one ``.ics`` per entity and stores it beside the
raw SDK entity, but it stores it as a content-addressed object under a
``calendar::<id>::ics`` key: the bytes exist and nothing can open them. This
module writes the same bytes under the names a calendar client already knows, so
the agent's shell can list a directory and read one event:

* ``events/<id>.ics`` -- one VEVENT per file, in the vdir layout `khal` and any
  other client reads without conversion,
* ``state.json`` -- what this run saw, so a reader can tell a stale view from a
  failing one.

It is a view and only a view. No recurrence is expanded and no exception is
folded into its series: a ``RRULE`` is carried through exactly as the provider
stated it, and an overridden occurrence stays the separate object it already is
under its own ``RECURRENCE-ID``. Expanding a rule here would invent occurrences
the provider never confirmed and would make the file disagree with the store.

There is deliberately no index beside the files. Mail needs one because scanning
74k Maildir files is expensive; a calendar is two orders of magnitude smaller,
and an index keyed by ``DTSTART`` cannot state a recurring event's start without
lying about it.

Publication is one rename per file, so a reader never sees half an event, and a
file whose bytes did not change is left alone -- an hourly rerun must not touch
an unchanged event's mtime. A file for an event the store no longer holds is
removed, because the view is current state and not history.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Iterable, Mapping

from ...errors import DataPlaneError, PublishError
from ..state import ReplicaState

#: The source this view names in `state.json`.
SOURCE = "calendar"

#: A refusal publishes nothing, the same code the other publishers use.
EXIT_REFUSED = 3

#: The object the collector derives per entity, and the prefix its id carries.
ICS_KIND = "derived-ics"
RAW_PREFIX = "calendar::"

#: The vdir and the file that describes the run. The two cannot collide: an
#: event named `state.json` lands inside `events/`, not beside it.
EVENTS_DIR = "events"
STATE_FILE = "state.json"
SUFFIX = ".ics"

#: Names the filesystem would read as something other than a file name.
_UNSAFE_NAMES = frozenset({".", ".."})


def _event_name(object_id: str, metadata: Mapping[str, Any]) -> str:
    """The file name for one derived object, taken from the entity it describes.

    Metadata's ``of`` is the raw id the ICS was derived from, so the name is the
    entity's own id rather than a parse of the ICS bytes. The object id is
    rejected here even though the store allows ``calendar::..::ics``: a name of
    ``..`` would write outside the view directory.
    """

    raw_id = metadata.get("of")
    if not isinstance(raw_id, str) or not raw_id.startswith(RAW_PREFIX):
        raise PublishError(f"{object_id!r} names no calendar entity to publish")
    name = raw_id[len(RAW_PREFIX) :]
    if (
        not name.strip()
        or name in _UNSAFE_NAMES
        or "/" in name
        or "\x00" in name
    ):
        raise PublishError(f"{object_id!r} has an unusable name {name!r}")
    return name


def build_view(
    replica: ReplicaState, *, now: int
) -> tuple[dict[str, bytes], dict[str, Any]]:
    """Every live derived ICS, by name, and the record of what this run read."""

    events: dict[str, bytes] = {}
    for entry in replica.entries():
        metadata = entry.get("metadata") or {}
        if metadata.get("kind") != ICS_KIND:
            continue
        name = _event_name(str(entry["object_id"]), metadata)
        if name in events:
            raise PublishError(f"two objects publish as {name!r}")
        # `read` verifies the object against its recorded size and sha256, so a
        # damaged store refuses here rather than publishing a truncated event.
        events[name] = replica.read(str(entry["object_id"]))

    state = {
        "source": SOURCE,
        "last_run": _timestamp(now),
        "ok": True,
        "events": len(events),
    }
    return events, state


def _timestamp(now: int) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))


def _json(document: Mapping[str, Any]) -> str:
    return json.dumps(document, sort_keys=True, ensure_ascii=False, indent=2) + "\n"


def write_atomic(payload: bytes, path: str | Path) -> bool:
    """Replace ``path`` in one rename; report whether the bytes changed.

    A temp file in the same directory, fsynced and then renamed, so a reader sees
    either the previous file or the new one and a crash leaves neither truncated.
    Identical bytes leave the inode alone, which keeps a rerun from touching an
    unchanged event's mtime.
    """

    target = Path(path)
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


def _prune(directory: Path, keep: Iterable[str]) -> int:
    """Delete the `.ics` files of events the store no longer holds."""

    wanted = {f"{name}{SUFFIX}" for name in keep}
    removed = 0
    if not directory.is_dir():
        return 0
    for path in sorted(directory.glob(f"*{SUFFIX}")):
        if path.name in wanted or path.is_dir():
            continue
        path.unlink()
        removed += 1
    return removed


def publish(raw: str | Path, out: str | Path, *, now: int) -> dict[str, Any]:
    """Read one calendar replica and write the vdir under ``out``.

    The replica is opened read-only and every object verified against its
    recorded size and sha256. A replica that is missing or damaged is a refusal,
    and a refusal writes nothing here, so a reader never sees a view of a state
    that was not there.
    """

    replica = ReplicaState(raw, read_only=True)
    events, state = build_view(replica, now=now)

    directory = Path(out)
    events_dir = directory / EVENTS_DIR
    written = False
    for name in sorted(events):
        written |= write_atomic(events[name], events_dir / f"{name}{SUFFIX}")
    removed = _prune(events_dir, events)
    state["removed"] = removed
    # state.json goes last: a reader that finds it agrees with the files it
    # describes, because the run that wrote them already finished.
    written |= write_atomic(_json(state).encode("utf-8"), directory / STATE_FILE)
    return {
        "source": SOURCE,
        "path": str(directory),
        "events": state["events"],
        "removed": removed,
        "changed": written or removed > 0,
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="data_plane.collectors.raw.publish_calendar",
        description=(
            "Publish the calendar replica as one .ics per event, plus state.json, "
            "where the agent's shell reads it."
        ),
    )
    parser.add_argument(
        "--raw",
        required=True,
        help="the calendar replica root; its committed state is read",
    )
    parser.add_argument("--out", required=True, help="the directory to publish into")
    parser.add_argument(
        "--now",
        type=int,
        default=None,
        help="epoch seconds the run is dated with; the unit omits it, a test pins it",
    )
    return parser


def run(args: argparse.Namespace) -> int:
    now = int(time.time()) if args.now is None else args.now
    report = publish(args.raw, args.out, now=now)
    print(json.dumps(report, sort_keys=True))
    return 0


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(list(sys.argv[1:] if argv is None else argv))
    try:
        return run(args)
    except DataPlaneError as error:
        print(f"publish-calendar: {error}", file=sys.stderr)
        return EXIT_REFUSED


if __name__ == "__main__":
    sys.exit(main())
