"""Run one raw collector: enumerate a provider's output into its replica state.

The library never guesses where its input is; this is the operator surface that
supplies it. It is what a systemd unit runs, and what a human runs by hand
against a fixture directory.

A run is one complete pass: it writes only the bytes the replica does not hold,
records what it enumerated, and commits the rows, the tombstones and the version
together into ``ROOT/state.sqlite``. A refusal commits nothing.

``--dry-run`` enumerates and validates, then publishes nothing: no object bytes
and no database.

Refusals are exit code 3 with the reason on stderr: a partial enumeration, a
changed UIDVALIDITY, an error list, a database that was still being written. The
point of the command is that those never become a committed state.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Mapping

from ...errors import DataPlaneError, ValidationError
from ..state import ReplicaState
from .brave import SOURCE_ID as BRAVE_SOURCE
from .brave import collect_brave_db
from .calendar import SOURCE_ID as CALENDAR_SOURCE
from .calendar import collect_calendar
from .finance import SOURCE_ID as FINANCE_SOURCE
from .finance import collect_simplefin
from .mail import SOURCE_ID as MAIL_SOURCE
from .mail import collect_maildir
from .music import SOURCE_ID as MUSIC_SOURCE
from .music import collect_music
from .notes import SOURCE_ID as NOTES_SOURCE
from .notes import collect_notes
from .photos import SOURCE_ID as PHOTOS_SOURCE
from .photos import collect_photos
from .replica import CollectReport
from .simplefin import AccessUrl, fetch_accountset
from .tasks import SOURCE_ID as TASKS_SOURCE
from .tasks import collect_tasks

EXIT_REFUSED = 3

#: Days of overlap on the provider request, so a boundary transaction is not lost.
_WINDOW_OVERLAP_DAYS = 7
#: SimpleFIN answers a longer read with an entry in the AccountSet's `errors`
#: ("Requested date range exceeds recommended range of 45 days. In the future,
#: this may be capped."), and this collector refuses an AccountSet that carries
#: one. The overlap is part of the span, not added to it.
_WINDOW_CAP_DAYS = 45

_SOURCE_IDS = {
    "mail": MAIL_SOURCE,
    "calendar": CALENDAR_SOURCE,
    "finance": FINANCE_SOURCE,
    "brave": BRAVE_SOURCE,
    "notes": NOTES_SOURCE,
    "tasks": TASKS_SOURCE,
    "photos": PHOTOS_SOURCE,
    "music": MUSIC_SOURCE,
}


def _captured_at() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _uidvalidity(values: Iterable[str]) -> dict[str, int]:
    mapping: dict[str, int] = {}
    for value in values:
        folder, separator, epoch = value.partition("=")
        if not separator or not folder:
            raise ValidationError(f"--uidvalidity wants FOLDER=INT, got {value!r}")
        try:
            parsed = int(epoch)
        except ValueError as exc:
            raise ValidationError(f"--uidvalidity {folder!r} is not an integer") from exc
        if parsed < 1:
            raise ValidationError(f"--uidvalidity {folder!r} must be positive")
        if folder in mapping:
            raise ValidationError(f"--uidvalidity names {folder!r} twice")
        mapping[folder] = parsed
    return mapping


def _report(report: CollectReport, published: Path | None, *, dry_run: bool) -> dict:
    payload = {
        "source_id": report.source_id,
        "objects": report.objects,
        "carried": report.carried,
        "deleted": report.deleted,
        "version": report.version,
        "details": dict(report.details),
        "published": str(published) if published is not None else None,
        "dry_run": dry_run,
    }
    return payload


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="data_plane.collectors.raw",
        description="Collect one provider's output into a raw replica state.",
    )
    parser.add_argument(
        "--root",
        required=True,
        help="replica root; the state lands in ROOT/state.sqlite",
    )
    parser.add_argument(
        "--captured-at",
        default=None,
        help="capture timestamp recorded on every object (default: now, UTC)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="enumerate and validate, then publish nothing",
    )
    subparsers = parser.add_subparsers(dest="source", required=True)

    mail = subparsers.add_parser("mail", help="a quarantined Maildir")
    mail.add_argument("--maildir", required=True)
    mail.add_argument(
        "--uidvalidity",
        action="append",
        default=[],
        metavar="FOLDER=INT",
        help="per-folder UIDVALIDITY, repeatable; required for every folder",
    )

    calendar = subparsers.add_parser("calendar", help="Tuta SDK entity JSON files")
    calendar.add_argument("--entities", required=True)

    finance = subparsers.add_parser("finance", help="a SimpleFIN AccountSet document")
    finance.add_argument(
        "--accountset", default=None, help="path to an AccountSet JSON already on disk"
    )
    finance.add_argument(
        "--access-url-file",
        default=None,
        help="read the AccountSet from SimpleFIN with the access URL in this file",
    )
    finance.add_argument(
        "--accountset-url",
        default=None,
        help="the credential-free access URL used in the observation key "
        "(default: derived from --access-url-file)",
    )
    finance.add_argument(
        "--include-pending",
        action="store_true",
        help="the response was requested with pending items included",
    )
    finance.add_argument("--window-days", type=int, default=37)
    finance.add_argument("--now", type=int, default=None, help="epoch seconds, for replay")

    brave = subparsers.add_parser("brave", help="a Brave History copy")
    brave.add_argument("--database", required=True)
    brave.add_argument("--device", required=True)
    brave.add_argument("--profile", required=True)

    notes = subparsers.add_parser("notes", help="a Markdown notes vault")
    notes.add_argument("--entities", required=True, help="the vault root")

    tasks = subparsers.add_parser("tasks", help="a todo.txt directory")
    tasks.add_argument("--entities", required=True, help="the todo.txt directory")

    photos = subparsers.add_parser("photos", help="a photo library")
    photos.add_argument("--entities", required=True, help="the library root")

    music = subparsers.add_parser("music", help="a music library")
    music.add_argument("--entities", required=True, help="the library root")
    return parser


def _access_url(args: argparse.Namespace) -> AccessUrl:
    try:
        raw = Path(args.access_url_file).read_text(encoding="utf-8")
    except OSError as exc:
        raise ValidationError(f"{args.access_url_file} is unreadable") from exc
    return AccessUrl.parse(raw)


def _window(now: int, window_days: int) -> tuple[int, int]:
    """The provider window in epoch seconds, which is what SimpleFIN accepts.

    It refuses an ISO date outright: "Invalid start-date provided. It must be a
    UNIX timestamp integer." The overlap is deliberate -- a transaction that
    posts just after the start boundary must not fall between two runs.
    """

    span = min(window_days + _WINDOW_OVERLAP_DAYS, _WINDOW_CAP_DAYS)
    return now - span * 86400, now


def _fetched_accountset(access: AccessUrl, args: argparse.Namespace) -> Mapping:
    """Read one AccountSet over the network, with an explicit bounded window."""

    now = args.now if args.now is not None else int(datetime.now(timezone.utc).timestamp())
    start, end = _window(now, args.window_days)
    return fetch_accountset(
        access,
        start_date=str(start),
        end_date=str(end),
        pending=args.include_pending,
    )


def run(args: argparse.Namespace) -> int:
    """One pass of one source, committed into its live replica state."""

    root = Path(args.root)
    captured_at = args.captured_at or _captured_at()
    state = ReplicaState(root, source_id=_SOURCE_IDS[args.source], dry_run=args.dry_run)
    try:
        report = _collect(args, state, captured_at)
        published = None if args.dry_run else state.path
    finally:
        state.close()
    print(json.dumps(_report(report, published, dry_run=args.dry_run), sort_keys=True))
    return 0


def _collect(
    args: argparse.Namespace, state: ReplicaState, captured_at: str
) -> CollectReport:
    if args.source == "mail":
        report = collect_maildir(
            args.maildir,
            state,
            uidvalidity=_uidvalidity(args.uidvalidity),
            captured_at=captured_at,
        )
    elif args.source == "calendar":
        report = collect_calendar(args.entities, state, captured_at=captured_at)
    elif args.source == "finance":
        if bool(args.accountset) == bool(args.access_url_file):
            raise ValidationError(
                "finance wants exactly one of --accountset and --access-url-file"
            )
        if args.access_url_file:
            access = _access_url(args)
            accountset = _fetched_accountset(access, args)
            args.accountset_url = args.accountset_url or access.url
        else:
            try:
                accountset = json.loads(
                    Path(args.accountset).read_text(encoding="utf-8")
                )
            except (OSError, json.JSONDecodeError) as exc:
                raise ValidationError(f"{args.accountset} is not readable JSON") from exc
            if not isinstance(accountset, Mapping):
                raise ValidationError(f"{args.accountset} is not an object")
        if not args.accountset_url:
            raise ValidationError(
                "finance wants --accountset-url, or --access-url-file to derive it"
            )
        report = collect_simplefin(
            accountset,
            state,
            accountset_url=args.accountset_url,
            captured_at=captured_at,
            include_pending=args.include_pending,
            window_days=args.window_days,
            now=args.now,
        )
    elif args.source == "brave":
        report = collect_brave_db(
            args.database,
            state,
            device=args.device,
            profile=args.profile,
            captured_at=captured_at,
        )
    elif args.source == "notes":
        report = collect_notes(args.entities, state, captured_at=captured_at)
    elif args.source == "tasks":
        report = collect_tasks(args.entities, state, captured_at=captured_at)
    elif args.source == "photos":
        report = collect_photos(args.entities, state, captured_at=captured_at)
    elif args.source == "music":
        report = collect_music(args.entities, state, captured_at=captured_at)
    else:  # pragma: no cover - argparse rejects an unknown subcommand first
        raise ValidationError(f"unknown source {args.source!r}")

    return report


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(list(sys.argv[1:] if argv is None else argv))
    try:
        return run(args)
    except DataPlaneError as error:
        print(f"raw-collect: {error}", file=sys.stderr)
        return EXIT_REFUSED


if __name__ == "__main__":
    raise SystemExit(main())
