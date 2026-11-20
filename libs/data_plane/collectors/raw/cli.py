"""Run one raw collector: enumerate a provider's output and publish a generation.

The library never commits and never guesses where its input is; this is the
operator surface that supplies both. It is what a systemd unit runs, and what a
human runs by hand against a fixture directory.

Publication is one step, and it is the last one: the generation is written under
``.staging``, every object's size and sha256 goes into the manifest, and a single
rename makes it visible. ``--dry-run`` stops before the rename, so a first run
against a real provider can be inspected without publishing anything.

Refusals are exit code 3 with the reason on stderr: a partial enumeration, a
changed UIDVALIDITY, an error list, a database that was still being written. The
point of the command is that those never become a published generation.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Mapping

from ...errors import DataPlaneError, ValidationError
from ..staging import StagingGeneration
from .brave import SOURCE_ID as BRAVE_SOURCE
from .brave import collect_brave_db
from .calendar import SOURCE_ID as CALENDAR_SOURCE
from .calendar import collect_calendar
from .finance import SOURCE_ID as FINANCE_SOURCE
from .finance import collect_simplefin
from .mail import SOURCE_ID as MAIL_SOURCE
from .mail import collect_maildir
from .mbsync import read_uidvalidity
from .replica import CollectReport, RawReplica
from .simplefin import AccessUrl, fetch_accountset

EXIT_REFUSED = 3
#: Days of overlap on the provider request, so a boundary transaction is not lost.
_WINDOW_OVERLAP_DAYS = 7

_SOURCE_IDS = {
    "mail": MAIL_SOURCE,
    "calendar": CALENDAR_SOURCE,
    "finance": FINANCE_SOURCE,
    "brave": BRAVE_SOURCE,
}


def _captured_at() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _generation_id() -> str:
    return datetime.now(timezone.utc).strftime("gen-%Y%m%dT%H%M%SZ")


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


def _publish(generation: StagingGeneration, *, dry_run: bool) -> Path | None:
    if dry_run:
        generation.abort()
        return None
    return generation.commit_next(complete=True)


def _report(report: CollectReport, published: Path | None, *, dry_run: bool) -> dict:
    payload = {
        "source_id": report.source_id,
        "generation_id": report.generation_id,
        "objects": report.objects,
        "carried": report.carried,
        "deleted": report.deleted,
        "details": dict(report.details),
        "published": str(published) if published is not None else None,
        "dry_run": dry_run,
    }
    return payload


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="data_plane.collectors.raw",
        description="Collect one provider's output into a raw generation.",
    )
    parser.add_argument(
        "--root",
        required=True,
        help="replica root; the generation lands in ROOT/published/<generation>",
    )
    parser.add_argument("--generation", default=None, help="generation id (default: now)")
    parser.add_argument(
        "--captured-at",
        default=None,
        help="capture timestamp recorded on every object (default: now, UTC)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="enumerate and validate, then discard the staging generation",
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
    mail.add_argument(
        "--uidvalidity-from-maildir",
        action="store_true",
        help="read every folder's UIDVALIDITY from the .mbsyncstate the sync "
        "tool wrote beside it, instead of being told one",
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
    finance.add_argument("--window-days", type=int, default=90)
    finance.add_argument("--now", type=int, default=None, help="epoch seconds, for replay")

    brave = subparsers.add_parser("brave", help="a Brave History copy")
    brave.add_argument("--database", required=True)
    brave.add_argument("--device", required=True)
    brave.add_argument("--profile", required=True)
    return parser


def _access_url(args: argparse.Namespace) -> AccessUrl:
    try:
        raw = Path(args.access_url_file).read_text(encoding="utf-8")
    except OSError as exc:
        raise ValidationError(f"{args.access_url_file} is unreadable") from exc
    return AccessUrl.parse(raw)


def _fetched_accountset(access: AccessUrl, args: argparse.Namespace) -> Mapping:
    """Read one AccountSet over the network, with an explicit bounded window."""

    now = args.now if args.now is not None else int(datetime.now(timezone.utc).timestamp())
    # The overlap is deliberate: the provider's window is inclusive by date, and
    # a transaction that posts just after midnight must not fall between two runs.
    start = datetime.fromtimestamp(
        now - (args.window_days + _WINDOW_OVERLAP_DAYS) * 86400, timezone.utc
    ).date()
    end = datetime.fromtimestamp(now, timezone.utc).date()
    return fetch_accountset(
        access,
        start_date=start.isoformat(),
        end_date=end.isoformat(),
        pending=args.include_pending,
    )


def run(args: argparse.Namespace) -> int:
    root = Path(args.root)
    generation = StagingGeneration(
        root,
        args.generation or _generation_id(),
        source_id=_SOURCE_IDS[args.source],
    )
    captured_at = args.captured_at or _captured_at()

    try:
        return _collect(args, generation, captured_at)
    except DataPlaneError:
        # A refusal must not leave a staging generation behind: it would be
        # picked up by nothing, and a run in the same second would write into it.
        generation.abort()
        raise


def _collect(
    args: argparse.Namespace, generation: StagingGeneration, captured_at: str
) -> int:
    if args.source == "mail":
        if bool(args.uidvalidity) == bool(args.uidvalidity_from_maildir):
            raise ValidationError(
                "mail wants exactly one of --uidvalidity and "
                "--uidvalidity-from-maildir"
            )
        uidvalidity = (
            read_uidvalidity(args.maildir)
            if args.uidvalidity_from_maildir
            else _uidvalidity(args.uidvalidity)
        )
        report = collect_maildir(
            args.maildir,
            generation,
            uidvalidity=uidvalidity,
            captured_at=captured_at,
        )
    elif args.source == "calendar":
        report = collect_calendar(args.entities, generation, captured_at=captured_at)
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
            generation,
            accountset_url=args.accountset_url,
            captured_at=captured_at,
            include_pending=args.include_pending,
            window_days=args.window_days,
            now=args.now,
        )
    elif args.source == "brave":
        report = collect_brave_db(
            args.database,
            generation,
            device=args.device,
            profile=args.profile,
            captured_at=captured_at,
        )
    else:  # pragma: no cover - argparse rejects an unknown subcommand first
        raise ValidationError(f"unknown source {args.source!r}")

    published = _publish(generation, dry_run=args.dry_run)
    print(json.dumps(_report(report, published, dry_run=args.dry_run), sort_keys=True))
    return 0


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(list(sys.argv[1:] if argv is None else argv))
    try:
        return run(args)
    except DataPlaneError as error:
        print(f"raw-collect: {error}", file=sys.stderr)
        return EXIT_REFUSED


def latest(root: str | Path) -> str | None:
    """The newest published generation under ``root``, for an operator to check."""

    return RawReplica.latest_generation(root)


if __name__ == "__main__":
    raise SystemExit(main())
