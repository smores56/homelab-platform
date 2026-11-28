"""The dumper: Tuta calendar entities become one JSON file per event.

This is the provider half of ``data_plane.collectors.raw.calendar``. That
collector reads a directory of ``*.json`` files, one entity per file, requires an
``id`` or ``uid``, tombstones ``deleted: true``, and derives the ICS projection
itself; this module is what puts the entity there. Nothing here writes to Tuta
and nothing here projects a recurrence.

The two commands:

* ``init --store DIR`` -- interactive once. Asks for the address, the password
  (never echoed, never an argument, never written) and, only if the server
  answers with a challenge, one TOTP code. It stores what the next run needs,
  sealed (:mod:`.session`), and prints the address and the seal path: no token,
  no key, no password.
* ``dump --store DIR --out DIR`` -- unattended twice-daily work: unseal, walk both
  event lists, write one ``<listId>-<elementId>.json`` per event with sorted keys,
  then remove any ``*.json`` in ``--out`` this run did not write, so an event the
  provider stopped listing cannot linger as if it were still there.

**Field names.** The collector keys on ``dtstart``, ``dtend``, ``revision`` and
``rrule``, so those are written; the same three values appear a second time under
the provider-facing names ``start``, ``end`` and ``sequence`` because the two
halves of this source disagree about what to call them, and neither is going to
relabel. ``recurrence`` is not a rename of anything: it holds the repeat rule's
fields as the provider sent them (frequency, end type/value, interval, time zone,
excluded dates), while ``rrule`` is the single-line projection the collector
writes into ``RRULE:``. Keeping both means a projection that turns out to be
wrong can be rebuilt without another fetch.

**Deferred to a later milestone**, deliberately and visibly: recurrence is not
expanded (no instances, no ``COUNT`` arithmetic), altered instances are not
reconciled against their series, and alarms and attendees are not read at all --
an event carries no attendee list because none was decrypted, not because it has
none. Deletion is not represented either: Tuta's list read never says an event
was deleted, so the collector carries an absent event forward with a reason
instead of tombstoning it (``libs/data_plane/collectors/raw/calendar.py``).

Timestamps are UTC and second-precision (``2026-03-01T09:00:00Z``); an all-day
event is date-only (``2026-03-01``), which is exactly how the collector decides
``VALUE=DATE``. Tuta marks an all-day event by putting both ends at midnight UTC,
and that is the only test this dumper applies to them.
"""

from __future__ import annotations

import argparse
import base64
import getpass
import json
import os
import sys
from collections.abc import Iterable, Mapping, Sequence
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import crypto, session as session_store
from .api import TutaApi
from .errors import CalendarError
from .session import Session

# CalendarEvent field ids, as the provider numbers them. Named here once so a
# reader can match a document against the model instead of a magic number.
FIELD_ID = "935"
FIELD_OWNER_SESSION_KEY = "939"
FIELD_SUMMARY = "940"
FIELD_DESCRIPTION = "941"
FIELD_START = "942"
FIELD_END = "943"
FIELD_LOCATION = "944"
FIELD_REPEAT_RULE = "945"
FIELD_UID = "988"
FIELD_SEQUENCE = "1089"
FIELD_RECURRENCE_ID = "1320"

# CalendarRepeatRule field ids.
FIELD_RR_FREQUENCY = "928"
FIELD_RR_END_TYPE = "929"
FIELD_RR_END_VALUE = "930"
FIELD_RR_INTERVAL = "931"
FIELD_RR_TIME_ZONE = "932"
FIELD_RR_EXCLUDED = "1319"
FIELD_RR_EXCLUDED_DATE = "2075"

# RepeatRuleFrequency and RepeatRuleEndType, as the model enumerates them.
RRULE_FREQUENCIES = {0: "DAILY", 1: "WEEKLY", 2: "MONTHLY", 3: "YEARLY"}
RRULE_END_NEVER = 0
RRULE_END_COUNT = 1
RRULE_END_UNTIL = 2

_DAY_MS = 86_400_000


def _utc(milliseconds: int) -> datetime:
    seconds, _ = divmod(milliseconds, 1000)
    return datetime.fromtimestamp(seconds, tz=timezone.utc)


def _stamp(milliseconds: int | None) -> str | None:
    return None if milliseconds is None else _utc(milliseconds).strftime("%Y-%m-%dT%H:%M:%SZ")


def _day(milliseconds: int) -> str:
    return _utc(milliseconds).strftime("%Y-%m-%d")


def _all_day(start: int | None, end: int | None) -> bool:
    """Both ends at midnight UTC and a whole number of days apart is Tuta's all-day."""

    if start is None or end is None:
        return False
    if start % _DAY_MS or end % _DAY_MS:
        return False
    return end > start


def _rrule(recurrence: Mapping[str, Any]) -> str:
    """The single-line RRULE the collector writes verbatim, or a refusal.

    An unknown frequency is refused rather than dropped: a repeating event
    exported as a single one is a wrong calendar that still looks complete.
    """

    frequency = recurrence["frequency"]
    if frequency not in RRULE_FREQUENCIES:
        raise CalendarError(
            f"a repeat rule has frequency {frequency!r}, which this build does not project "
            f"({sorted(RRULE_FREQUENCIES)}); add it instead of exporting the series as one event"
        )
    parts = [f"FREQ={RRULE_FREQUENCIES[frequency]}"]
    interval = recurrence["interval"]
    if interval and interval != 1:
        parts.append(f"INTERVAL={interval}")
    end_type = recurrence["end_type"]
    end_value = recurrence["end_value"]
    if end_type == RRULE_END_COUNT:
        if end_value is None:
            raise CalendarError("a repeat rule ends by COUNT but carries no end value")
        parts.append(f"COUNT={end_value}")
    elif end_type == RRULE_END_UNTIL:
        if end_value is None:
            raise CalendarError("a repeat rule ends by UNTIL but carries no end value")
        parts.append(f"UNTIL={_utc(end_value).strftime('%Y%m%dT%H%M%SZ')}")
    elif end_type != RRULE_END_NEVER:
        raise CalendarError(
            f"a repeat rule has end type {end_type!r}, which this build does not project "
            f"({RRULE_END_NEVER}=never, {RRULE_END_COUNT}=count, {RRULE_END_UNTIL}=until)"
        )
    return ";".join(parts)


class _EventReader:
    """Decrypts one entity; keeps the base64 and padding rules in one place."""

    def __init__(self, group_key: bytes) -> None:
        self._group_key = group_key

    def _session_key(self, raw: Mapping[str, Any], list_id: str, element_id: str) -> bytes:
        envelope = raw.get(FIELD_OWNER_SESSION_KEY, "")
        if not envelope:
            raise CalendarError(
                f"event {list_id}-{element_id} carries no _ownerEncSessionKey ({FIELD_OWNER_SESSION_KEY})"
            )
        return crypto.unwrap_key(self._group_key, base64.b64decode(envelope))

    @staticmethod
    def _value(session_key: bytes, raw: Mapping[str, Any], field: str) -> bytes:
        value = raw.get(field, "")
        if not value:
            return b""
        return crypto.decrypt_value(session_key, base64.b64decode(value))

    def _text(self, session_key: bytes, raw: Mapping[str, Any], field: str) -> str:
        return self._value(session_key, raw, field).decode("utf-8")

    def _integer(self, session_key: bytes, raw: Mapping[str, Any], field: str) -> int | None:
        """A field the model encrypts as a decimal string: a timestamp or a count."""

        value = self._value(session_key, raw, field).decode("utf-8").strip()
        if not value:
            return None
        try:
            return int(value)
        except ValueError as exc:
            raise CalendarError(
                f"field {field} decrypted to {value!r}, which is not a decimal number"
            ) from exc

    def _recurrence(self, session_key: bytes, raw: Mapping[str, Any]) -> dict[str, Any] | None:
        rule = raw.get(FIELD_REPEAT_RULE) or []
        if isinstance(rule, list):
            rule = rule[0] if rule else None
        if not isinstance(rule, Mapping):
            return None

        def number(field: str, default: int) -> int:
            value = self._integer(session_key, rule, field)
            return default if value is None else value

        excluded: list[int] = []
        for wrapper in rule.get(FIELD_RR_EXCLUDED) or []:
            if not isinstance(wrapper, Mapping):
                continue
            date = self._integer(session_key, wrapper, FIELD_RR_EXCLUDED_DATE)
            if date is not None:
                excluded.append(date)
        return {
            "frequency": number(FIELD_RR_FREQUENCY, 0),
            "end_type": number(FIELD_RR_END_TYPE, RRULE_END_NEVER),
            # A count or a millisecond instant, depending on end_type; kept as the
            # provider's number so a projection mistake stays fixable offline.
            "end_value": self._integer(session_key, rule, FIELD_RR_END_VALUE),
            "interval": number(FIELD_RR_INTERVAL, 1),
            "time_zone": self._text(session_key, rule, FIELD_RR_TIME_ZONE) or "UTC",
            # Sorted so two runs over the same rule write the same bytes; the
            # provider's order is not meaningful for a set of excluded dates.
            "excluded_dates": sorted(excluded),
        }

    def document(self, raw: Mapping[str, Any]) -> dict[str, Any]:
        """One event as the collector's entity: no projection beyond the repeat rule."""

        list_id, element_id = element_ids(raw)
        session_key = self._session_key(raw, list_id, element_id)
        start = self._integer(session_key, raw, FIELD_START)
        end = self._integer(session_key, raw, FIELD_END)
        all_day = _all_day(start, end)
        recurrence = self._recurrence(session_key, raw)

        def range_value(value: int | None) -> str | None:
            if value is None:
                return None
            return _day(value) if all_day else _stamp(value)

        sequence = 0
        sequence_text = self._text(session_key, raw, FIELD_SEQUENCE).strip()
        if sequence_text:
            sequence = int(sequence_text)
        recurrence_id = self._integer(session_key, raw, FIELD_RECURRENCE_ID)
        start_value = range_value(start)
        end_value = range_value(end)
        return {
            "id": f"{list_id}-{element_id}",
            "uid": self._text(session_key, raw, FIELD_UID) or element_id,
            "summary": self._text(session_key, raw, FIELD_SUMMARY),
            "description": self._text(session_key, raw, FIELD_DESCRIPTION),
            "location": self._text(session_key, raw, FIELD_LOCATION),
            "start": start_value,
            "end": end_value,
            "dtstart": start_value,
            "dtend": end_value,
            "sequence": sequence,
            "revision": sequence,
            "recurrence": recurrence,
            "rrule": _rrule(recurrence) if recurrence else None,
            "recurrence_id": _stamp(recurrence_id),
        }


def element_ids(raw: Mapping[str, Any]) -> tuple[str, str]:
    """``[listId, elementId]`` from the entity's own ``_id`` (field 935)."""

    value = raw.get(FIELD_ID, "")
    if isinstance(value, Sequence) and not isinstance(value, str) and len(value) >= 2:
        return str(value[0]), str(value[1])
    raise CalendarError(
        f"an event carries no usable _id ({FIELD_ID}): {value!r}; without it the object id "
        "and the page marker would have to be guessed"
    )


def documents(api: TutaApi, session: Session) -> list[dict[str, Any]]:
    """Every event in both of the account's lists, decrypted, in provider order."""

    group_id, group_key = api.calendar_group(
        session.user_id, session.access_token, session.user_group_key()
    )
    reader = _EventReader(group_key)
    records: list[dict[str, Any]] = []
    seen: set[str] = set()
    for list_id in api.calendar_list_ids(group_id, session.access_token):
        for raw in api.calendar_events(list_id, session.access_token):
            record = reader.document(raw)
            if record["id"] in seen:
                raise CalendarError(
                    f"two events claim the id {record['id']!r}; the replica would lose one of them"
                )
            seen.add(record["id"])
            records.append(record)
    return records


def write_documents(records: Iterable[Mapping[str, Any]], out_dir: Path) -> tuple[int, int]:
    """Write one file per record, then drop the files this run did not write."""

    out_dir.mkdir(parents=True, exist_ok=True)
    written: set[str] = set()
    count = 0
    for record in records:
        name = f"{record['id']}.json"
        payload = json.dumps(record, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        temporary = out_dir / f".{name}.tmp"
        with open(temporary, "w", encoding="utf-8") as sink:
            sink.write(payload)
            sink.flush()
            os.fsync(sink.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, out_dir / name)
        written.add(name)
        count += 1
    removed = 0
    for stale in sorted(out_dir.glob("*.json")):
        if stale.name in written:
            continue
        # A symlink is removed, not followed: the collector refuses to read one,
        # and a stale link pointing outside the directory is not this run's to keep.
        stale.unlink()
        removed += 1
    return count, removed


def run_dump(store: Path, out_dir: Path, *, api: TutaApi | None = None) -> int:
    sealed = session_store.unseal(store)
    records = documents(api or TutaApi(), sealed)
    count, removed = write_documents(records, out_dir)
    print(
        json.dumps(
            {
                "command": "dump",
                "out": str(out_dir),
                "objects": count,
                "removed": removed,
            },
            sort_keys=True,
        )
    )
    return 0


def run_init(store: Path, *, api: TutaApi | None = None) -> int:
    """One interactive login. Nothing secret is printed, stored unwrapped or in argv."""

    client = api or TutaApi()
    address = input("Tuta address: ").strip()
    passphrase = getpass.getpass("Tuta password: ")
    if not address or not passphrase:
        raise CalendarError("an empty address or password cannot open a session")
    try:
        kdf_type, salt = client.salt(address)
        attempt = client.login(address, crypto.verifier(passphrase, salt, kdf_type))
        if attempt.locked:
            if not attempt.has_totp_challenge:
                raise CalendarError(
                    "the account's second factor is U2F or WebAuthn only; this dumper can "
                    "answer a TOTP code and nothing that needs a hardware key"
                )
            code = input("TOTP code: ").strip()
            client.submit_totp(attempt.access_token, code)
            client.await_second_factor(attempt.access_token)
        if not attempt.user_id:
            raise CalendarError(
                "POST /rest/sys/sessionservice answered without a user id; the session cannot "
                "be tied to an account"
            )
        passphrase_key = crypto.passphrase_key(passphrase, salt, kdf_type)
    finally:
        del passphrase
    sealed = Session(
        address=address,
        user_id=attempt.user_id,
        access_token=attempt.access_token,
        kdf_type=kdf_type,
        salt=salt,
        passphrase_key=passphrase_key,
        encrypted_passphrase_key=_encrypted_group_key(client, attempt, address),
    )
    # Prove the password unwraps the group key before anything is sealed: a wrong
    # password otherwise produces a store that only fails at the first dump.
    sealed.user_group_key()
    path = session_store.seal(store, sealed)
    print(f"session for {address} sealed at {path}")
    return 0


def _encrypted_group_key(api: TutaApi, attempt: Any, address: str) -> bytes:
    """``user.userGroup.symEncGKey``: field 27 of the 95 aggregate, base64 in the JSON."""

    record = api.user(attempt.user_id, attempt.access_token)
    groups = record.get("95") or []
    if isinstance(groups, Mapping):
        groups = [groups]
    for group in groups:
        if isinstance(group, Mapping) and group.get("27"):
            return base64.b64decode(group["27"])
    raise CalendarError(
        f"GET /rest/sys/user/{attempt.user_id} for {address} carries no symEncGKey (field 27); "
        "the account's key material is in a layout this build does not read"
    )


def build_parser() -> argparse.ArgumentParser:
    """Only ``--store`` and ``--out``: no password or code can reach argv."""

    parser = argparse.ArgumentParser(
        prog="python3 -m apps.tuta_calendar",
        description="Dump Tuta calendar entities as JSON for the raw calendar collector.",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    init = commands.add_parser(
        "init", help="sign in once and seal the session on the store"
    )
    init.add_argument("--store", type=Path, required=True, help="directory holding the seal")
    dump = commands.add_parser("dump", help="write one JSON entity per calendar event")
    dump.add_argument("--store", type=Path, required=True, help="directory holding the seal")
    dump.add_argument("--out", type=Path, required=True, help="directory to write entities into")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "init":
            return run_init(args.store)
        return run_dump(args.store, args.out)
    except CalendarError as exc:
        # A refusal is one line naming what to fix, and exit 3 is what the
        # collector's own CLI uses for "nothing was published".
        print(f"tuta-calendar: {exc}", file=sys.stderr)
        return 3
    except OSError as exc:
        # The store and the output directory are volumes: an unreadable one is a
        # refusal with a path in it, not a traceback in a journal.
        print(f"tuta-calendar: {exc}", file=sys.stderr)
        return 3
