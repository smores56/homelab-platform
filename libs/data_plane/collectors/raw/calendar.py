"""Raw calendar: Tuta SDK entities become a generation, ICS is derived beside them.

Tuta has no supported CalDAV path, so the adapter stores what its SDK returns and
derives from that. Two rules decide the shape:

* Recurrence is never expanded. An ``RRULE`` with its ``RECURRENCE-ID``
  exceptions stays as the provider expressed it; an expanded list has no way
  back, and it silently becomes wrong the first time an exception or a ``COUNT``
  boundary moves.
* The SDK supplies no deletion evidence. An event that stops appearing is
  carried forward with a reason and an ``absent_since``, never tombstoned: only
  an explicit ``deleted`` flag is a deletion this replica can prove.

ICS is written as a second, derived object per event, so a calendar client can
read it without re-deriving, and so deleting every ``::ics`` object rebuilds
nothing that the raw entity does not already contain.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Iterable, Mapping

from ...errors import PublishError, ValidationError
from ...model import FidelityLimit
from ..staging import StagingGeneration
from .replica import (
    ABSENCE_NO_TOMBSTONE,
    CollectReport,
    canonical_json,
    carry_forward,
    previous_replica,
    resolve_source_dir,
)

SOURCE_ID = "tuta.calendar"

FIDELITY_LIMITS: tuple[FidelityLimit, ...] = (
    FidelityLimit(
        field="deletion",
        reason="the Tuta SDK supplies no tombstone; absence is recorded as reason-unknown",
    ),
    FidelityLimit(
        field="icalendar.expansion",
        reason="recurrence is kept as RRULE and exceptions, never expanded into instances",
    ),
)

_ICS_ESCAPES = (("\\", "\\\\"), (";", "\\;"), (",", "\\,"), ("\n", "\\n"))


def _escape(text: str) -> str:
    for source, target in _ICS_ESCAPES:
        text = text.replace(source, target)
    return text


def _fold(line: str) -> list[str]:
    """Fold one content line at 75 octets, continuation lines start with a space."""

    encoded = line.encode("utf-8")
    if len(encoded) <= 75:
        return [line]
    chunks: list[str] = []
    current = b""
    limit = 75
    for character in line:
        data = character.encode("utf-8")
        if len(current) + len(data) > limit:
            chunks.append(current.decode("utf-8"))
            current = b""
            limit = 74
        current += data
    if current:
        chunks.append(current.decode("utf-8"))
    return [chunks[0]] + [" " + chunk for chunk in chunks[1:]]


def _stamp(value: Any) -> str:
    """An ICS date-time: the provider's value with separators removed.

    A bare ``YYYY-MM-DD`` is an all-day value and keeps ``VALUE=DATE``; anything
    else is written as UTC so a floating local time cannot shift between readers.
    """

    text = str(value).strip()
    if len(text) == 10 and text[4] == "-" and text[7] == "-":
        return text.replace("-", "")
    text = text.replace("-", "").replace(":", "")
    if text.endswith("Z"):
        return text
    if "T" in text:
        return text + "Z"
    return text


def _attendees(entity: Mapping[str, Any]) -> list[str]:
    lines: list[str] = []
    for attendee in entity.get("attendees") or ():
        if isinstance(attendee, str):
            lines.append(f"ATTENDEE:mailto:{attendee}")
        elif isinstance(attendee, Mapping):
            address = str(attendee.get("email") or attendee.get("address") or "").strip()
            if not address:
                continue
            name = str(attendee.get("name") or "").strip()
            prefix = f';CN="{_escape(name)}"' if name else ""
            lines.append(f"ATTENDEE{prefix}:mailto:{address}")
    return lines


def _alarms(entity: Mapping[str, Any]) -> list[str]:
    lines: list[str] = []
    for alarm in entity.get("alarms") or ():
        if not isinstance(alarm, Mapping):
            continue
        trigger = str(alarm.get("trigger") or "").strip()
        if not trigger:
            continue
        lines.extend(
            [
                "BEGIN:VALARM",
                "ACTION:DISPLAY",
                "DESCRIPTION:Reminder",
                f"TRIGGER:{trigger}",
                "END:VALARM",
            ]
        )
    return lines


def to_ics(entity: Mapping[str, Any]) -> bytes:
    """One VEVENT from one raw entity, recurrence and exceptions kept intact."""

    lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//smortress//raw calendar//EN",
        "CALSCALE:GREGORIAN",
        "BEGIN:VEVENT",
    ]
    uid = str(entity.get("uid") or entity.get("id") or "").strip()
    if not uid:
        raise ValidationError("calendar entity has no uid")
    lines.append(f"UID:{_escape(uid)}")
    if entity.get("revision") not in (None, ""):
        lines.append(f"SEQUENCE:{int(entity['revision'])}")
    lines.append("DTSTAMP:19700101T000000Z")
    start = entity.get("dtstart")
    if start not in (None, ""):
        all_day = len(str(start).strip()) == 10
        parameter = ";VALUE=DATE" if all_day else ""
        lines.append(f"DTSTART{parameter}:{_stamp(start)}")
    end = entity.get("dtend")
    if end not in (None, ""):
        all_day = len(str(end).strip()) == 10
        parameter = ";VALUE=DATE" if all_day else ""
        lines.append(f"DTEND{parameter}:{_stamp(end)}")
    for field, prefix in (("summary", "SUMMARY"), ("description", "DESCRIPTION"), ("location", "LOCATION")):
        value = entity.get(field)
        if value not in (None, ""):
            lines.append(f"{prefix}:{_escape(str(value))}")
    if entity.get("rrule"):
        lines.append(f"RRULE:{str(entity['rrule']).strip()}")
    if entity.get("recurrence_id"):
        lines.append(f"RECURRENCE-ID:{_stamp(entity['recurrence_id'])}")
    lines.extend(_attendees(entity))
    lines.extend(_alarms(entity))
    lines.extend(["END:VEVENT", "END:VCALENDAR"])

    folded: list[str] = []
    for line in lines:
        folded.extend(_fold(line))
    return ("\r\n".join(folded) + "\r\n").encode("utf-8")


def _entity_id(entity: Mapping[str, Any], path: Path) -> str:
    value = str(entity.get("id") or entity.get("uid") or "").strip()
    if not value:
        raise ValidationError(f"{path.name} has no id or uid")
    if "/" in value or "\x00" in value:
        raise ValidationError(f"{path.name} has an unusable id {value!r}")
    return value


def collect_calendar(
    entities_dir: str | Path,
    generation: StagingGeneration,
    *,
    captured_at: str,
) -> CollectReport:
    """Enumerate every SDK entity into ``generation``; never commit it."""

    root = resolve_source_dir(entities_dir, "calendar entities")
    previous = previous_replica(generation)

    seen: set[str] = set()
    deleted = 0
    for path in sorted(root.glob("*.json")):
        if path.is_symlink():
            raise PublishError(f"{path} is a symlink; refusing to follow it")
        try:
            entity = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise PublishError(f"{path.name} is not readable JSON") from exc
        if not isinstance(entity, dict):
            raise ValidationError(f"{path.name} is not an object")
        entity_id = _entity_id(entity, path)
        if entity_id in seen:
            raise PublishError(f"two entities claim the id {entity_id!r}")
        seen.add(entity_id)

        raw_id = f"calendar::{entity_id}"
        ics_id = f"{raw_id}::ics"
        if entity.get("deleted") is True:
            generation.delete(raw_id)
            generation.delete(ics_id)
            deleted += 1
            continue

        raw = canonical_json(entity)
        generation.put(
            raw_id,
            raw,
            {
                "source_id": SOURCE_ID,
                "kind": "sdk-entity",
                "uid": str(entity.get("uid") or entity_id),
                "revision": "" if entity.get("revision") is None else str(entity.get("revision")),
                "recurrence_id": "" if entity.get("recurrence_id") is None else str(entity.get("recurrence_id")),
                "dtstart": "" if entity.get("dtstart") is None else str(entity.get("dtstart")),
                "dtend": "" if entity.get("dtend") is None else str(entity.get("dtend")),
                "rrule": "" if entity.get("rrule") is None else str(entity.get("rrule")),
                "summary": "" if entity.get("summary") is None else str(entity.get("summary")),
                "captured_at": captured_at,
            },
        )
        generation.put(
            ics_id,
            to_ics(entity),
            {
                "source_id": SOURCE_ID,
                "kind": "derived-ics",
                "of": raw_id,
                "captured_at": captured_at,
            },
        )

    carried = carry_forward(
        generation,
        previous,
        reason=ABSENCE_NO_TOMBSTONE,
        captured_at=captured_at,
    )
    return CollectReport(
        source_id=SOURCE_ID,
        generation_id=generation.generation_id,
        objects=len(seen) - deleted,
        carried=carried,
        deleted=deleted,
        details={"entities": len(seen)},
    )


def fidelity_fields() -> Iterable[str]:
    return (
        "entity.raw",
        "uid",
        "revision",
        "dtstart",
        "dtend",
        "rrule",
        "recurrence_id",
        "attendees",
        "alarms",
    )
