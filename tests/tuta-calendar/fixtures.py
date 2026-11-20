"""Fixture builders for the exporter's tests.

Every entity here is *encrypted with the module's own primitives*, the way the
provider's are: a calendar group key wraps a per-event session key (no padding),
and that session key wraps each value (PKCS#5). Nothing is copied from a real
account and nothing touches a network, so a failure is about this code and not
about what Tuta happens to hold.
"""

from __future__ import annotations

import base64
from datetime import datetime, timezone
from typing import Any

from apps.tuta_calendar import crypto
from apps.tuta_calendar.crypto import Padding

# The group key a calendar membership hands out, and one event's session key.
GROUP_KEY = bytes(range(32))
SESSION_KEY = bytes(range(64, 96))
PASSPHRASE_KEY = bytes(range(96, 128))


def ms(text: str) -> int:
    """``2026-03-01T09:00:00Z`` as the millisecond integer Tuta stores."""

    return int(datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp() * 1000)


def value(session_key: bytes, text: str) -> str:
    """One encrypted field value, base64 the way the API carries it."""

    return base64.b64encode(crypto.encrypt(session_key, text.encode("utf-8"), padding=Padding.PKCS5)).decode(
        "ascii"
    )


def key(group_key: bytes, session_key: bytes) -> str:
    """One wrapped session key: a symmetric key, so no padding."""

    return base64.b64encode(crypto.encrypt(group_key, session_key, padding=Padding.NONE)).decode("ascii")


def event(
    *,
    list_id: str = "shortList",
    element_id: str = "elemAAA",
    uid: str = "uid-one",
    summary: str = "Standup",
    description: str = "daily sync",
    location: str = "Room 1",
    start: int | None = None,
    end: int | None = None,
    sequence: int = 0,
    recurrence: dict[str, Any] | None = None,
    recurrence_id: int | None = None,
    group_key: bytes = GROUP_KEY,
    session_key: bytes = SESSION_KEY,
) -> dict[str, Any]:
    """A synthetic ``CalendarEvent`` in the provider's numeric field ids."""

    start = ms("2026-03-01T09:00:00Z") if start is None else start
    end = ms("2026-03-01T09:30:00Z") if end is None else end
    raw: dict[str, Any] = {
        "935": [list_id, element_id],
        "939": key(group_key, session_key),
        "940": value(session_key, summary),
        "941": value(session_key, description),
        "942": value(session_key, str(start)),
        "943": value(session_key, str(end)),
        "944": value(session_key, location),
        "988": value(session_key, uid),
        "1089": value(session_key, str(sequence)),
    }
    if recurrence is not None:
        rule: dict[str, Any] = {
            "927": "ruleId",
            "928": value(session_key, str(recurrence.get("frequency", 1))),
            "929": value(session_key, str(recurrence.get("end_type", 0))),
            "931": value(session_key, str(recurrence.get("interval", 1))),
            "932": value(session_key, recurrence.get("time_zone", "Europe/Berlin")),
        }
        if recurrence.get("end_value") is not None:
            rule["930"] = value(session_key, str(recurrence["end_value"]))
        rule["1319"] = [
            {"2074": f"excluded-{index}", "2075": value(session_key, str(date))}
            for index, date in enumerate(recurrence.get("excluded_dates", []))
        ]
        raw["945"] = [rule]
    if recurrence_id is not None:
        raw["1320"] = value(session_key, str(recurrence_id))
    return raw
