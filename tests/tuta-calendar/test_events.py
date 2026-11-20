"""Entity mapping tests: the numeric field ids become the collector's document.

The entities are synthetic and encrypted with the module's own primitives
(``fixtures.py``); nothing here is a recording of a real account. Each case
asserts the whole document, so an extra or missing key fails, and the last test
runs the collected ``to_ics()`` from ``libs/data_plane`` over the document: the
shape is only right if the consumer accepts it.
"""

from __future__ import annotations

import unittest

from apps.tuta_calendar import crypto
from apps.tuta_calendar.crypto import Padding
from apps.tuta_calendar.dump import _EventReader, element_ids
from apps.tuta_calendar.errors import CalendarError
from data_plane.collectors.raw.calendar import to_ics

import fixtures

GROUP_KEY = fixtures.GROUP_KEY
DOCUMENT_KEYS = {
    "description",
    "dtend",
    "dtstart",
    "end",
    "id",
    "location",
    "recurrence",
    "recurrence_id",
    "revision",
    "rrule",
    "sequence",
    "start",
    "summary",
    "uid",
}


class PlainEventTest(unittest.TestCase):
    def document(self, raw=None):
        return _EventReader(GROUP_KEY).document(raw or fixtures.event())

    def test_the_document_is_exactly_the_contract(self) -> None:
        document = self.document()
        self.assertEqual(DOCUMENT_KEYS, set(document))
        self.assertEqual("shortList-elemAAA", document["id"])
        self.assertEqual("uid-one", document["uid"])
        self.assertEqual("Standup", document["summary"])
        self.assertEqual("daily sync", document["description"])
        self.assertEqual("Room 1", document["location"])
        self.assertEqual("2026-03-01T09:00:00Z", document["start"])
        self.assertEqual("2026-03-01T09:30:00Z", document["end"])
        self.assertEqual(document["start"], document["dtstart"])
        self.assertEqual(document["end"], document["dtend"])
        self.assertEqual(0, document["sequence"])
        self.assertEqual(0, document["revision"])
        self.assertIsNone(document["recurrence"])
        self.assertIsNone(document["rrule"])
        self.assertIsNone(document["recurrence_id"])

    def test_an_empty_field_is_an_empty_string_not_null(self) -> None:
        document = self.document(fixtures.event(description="", location=""))
        self.assertEqual("", document["description"])
        self.assertEqual("", document["location"])

    def test_the_sequence_is_carried_as_a_number(self) -> None:
        document = self.document(fixtures.event(sequence=4))
        self.assertEqual(4, document["sequence"])
        self.assertEqual(4, document["revision"])

    def test_a_missing_uid_falls_back_to_the_element_id(self) -> None:
        document = self.document(fixtures.event(uid=""))
        self.assertEqual("elemAAA", document["uid"])

    def test_an_all_day_event_is_date_only_on_both_ends(self) -> None:
        document = self.document(
            fixtures.event(start=fixtures.ms("2026-03-01T00:00:00Z"), end=fixtures.ms("2026-03-02T00:00:00Z"))
        )
        self.assertEqual("2026-03-01", document["start"])
        self.assertEqual("2026-03-02", document["end"])

    def test_a_midnight_meeting_that_lasts_hours_is_not_all_day(self) -> None:
        document = self.document(
            fixtures.event(start=fixtures.ms("2026-03-01T00:00:00Z"), end=fixtures.ms("2026-03-01T01:00:00Z"))
        )
        self.assertEqual("2026-03-01T00:00:00Z", document["start"])
        self.assertEqual("2026-03-01T01:00:00Z", document["end"])


class RepeatingEventTest(unittest.TestCase):
    def document(self, **recurrence):
        raw = fixtures.event(recurrence=recurrence, recurrence_id=fixtures.ms("2026-03-08T09:00:00Z"))
        return _EventReader(GROUP_KEY).document(raw)

    def test_a_weekly_series_counted_by_count(self) -> None:
        document = self.document(
            frequency=1,
            end_type=1,
            end_value=3,
            interval=2,
            time_zone="Europe/Berlin",
            excluded_dates=[fixtures.ms("2026-03-15T09:00:00Z")],
        )
        self.assertEqual("FREQ=WEEKLY;INTERVAL=2;COUNT=3", document["rrule"])
        self.assertEqual(
            {
                "frequency": 1,
                "end_type": 1,
                "end_value": 3,
                "interval": 2,
                "time_zone": "Europe/Berlin",
                "excluded_dates": [fixtures.ms("2026-03-15T09:00:00Z")],
            },
            document["recurrence"],
        )
        self.assertEqual("2026-03-08T09:00:00Z", document["recurrence_id"])

    def test_a_daily_series_ending_on_a_date(self) -> None:
        document = self.document(
            frequency=0, end_type=2, end_value=fixtures.ms("2026-04-01T00:00:00Z"), interval=1
        )
        self.assertEqual("FREQ=DAILY;UNTIL=20260401T000000Z", document["rrule"])

    def test_a_yearly_series_that_never_ends_has_no_count_or_until(self) -> None:
        document = self.document(frequency=3, end_type=0, interval=1)
        self.assertEqual("FREQ=YEARLY", document["rrule"])

    def test_defaults_fill_the_fields_the_provider_left_unset(self) -> None:
        document = self.document(frequency=2, time_zone="")
        self.assertEqual(0, document["recurrence"]["end_type"])
        self.assertEqual(1, document["recurrence"]["interval"])
        self.assertEqual("UTC", document["recurrence"]["time_zone"])
        self.assertEqual([], document["recurrence"]["excluded_dates"])

    def test_an_unknown_frequency_is_refused_instead_of_flattened(self) -> None:
        with self.assertRaises(CalendarError) as caught:
            self.document(frequency=9)
        self.assertIn("frequency 9", str(caught.exception))

    def test_an_unknown_end_type_is_refused(self) -> None:
        with self.assertRaises(CalendarError):
            self.document(frequency=1, end_type=7)


class BrokenEntityTest(unittest.TestCase):
    def test_an_entity_without_a_session_key_is_refused(self) -> None:
        raw = fixtures.event()
        del raw["939"]
        with self.assertRaises(CalendarError) as caught:
            _EventReader(GROUP_KEY).document(raw)
        self.assertIn("939", str(caught.exception))

    def test_an_entity_wrapped_for_another_group_key_is_refused(self) -> None:
        raw = fixtures.event(group_key=bytes(range(1, 33)))
        with self.assertRaises(CalendarError):
            _EventReader(GROUP_KEY).document(raw)

    def test_an_entity_with_no_id_is_refused(self) -> None:
        raw = fixtures.event()
        del raw["935"]
        with self.assertRaises(CalendarError) as caught:
            element_ids(raw)
        self.assertIn("935", str(caught.exception))

    def test_a_timestamp_that_is_not_a_number_is_refused(self) -> None:
        raw = fixtures.event()
        raw["942"] = fixtures.value(fixtures.SESSION_KEY, "not-a-timestamp")
        with self.assertRaises(CalendarError) as caught:
            _EventReader(GROUP_KEY).document(raw)
        self.assertIn("not a decimal number", str(caught.exception))


class CollectorContractTest(unittest.TestCase):
    """The replica's own derivation runs over these documents unchanged."""

    def ics(self, **fixtures_args) -> str:
        raw = fixtures.event(**fixtures_args)
        document = _EventReader(GROUP_KEY).document(raw)
        return to_ics(document).decode("utf-8")

    def test_a_plain_event_becomes_a_dated_vevent(self) -> None:
        ics = self.ics()
        self.assertIn("UID:uid-one\r\n", ics)
        self.assertIn("DTSTART:20260301T090000Z\r\n", ics)
        self.assertIn("DTEND:20260301T093000Z\r\n", ics)
        self.assertIn("SUMMARY:Standup\r\n", ics)

    def test_an_all_day_event_takes_value_date(self) -> None:
        ics = self.ics(
            start=fixtures.ms("2026-03-01T00:00:00Z"), end=fixtures.ms("2026-03-02T00:00:00Z")
        )
        self.assertIn("DTSTART;VALUE=DATE:20260301\r\n", ics)
        self.assertIn("DTEND;VALUE=DATE:20260302\r\n", ics)

    def test_a_series_keeps_its_rrule_and_its_exception(self) -> None:
        ics = self.ics(recurrence={"frequency": 1, "end_type": 1, "end_value": 3}, recurrence_id=fixtures.ms("2026-03-08T09:00:00Z"))
        self.assertIn("RRULE:FREQ=WEEKLY;COUNT=3\r\n", ics)
        self.assertIn("RECURRENCE-ID:20260308T090000Z\r\n", ics)

    def test_the_sequence_lands_in_the_ics(self) -> None:
        self.assertIn("SEQUENCE:2\r\n", self.ics(sequence=2))


if __name__ == "__main__":
    unittest.main()
