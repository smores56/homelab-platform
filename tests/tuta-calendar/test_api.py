"""API tests: pagination termination and the status-to-refusal mapping.

No network: every call goes through an injected transport, so the page markers
and the status codes are asserted on the request the client actually builds. The
token used here is deliberately distinct from anything else, and each refusal is
checked for it: a message ends up in a journal, and the token is the account.
"""

from __future__ import annotations

import base64
import hashlib
import json
import unittest
from typing import Any, Mapping
from urllib.parse import parse_qs, urlsplit

from apps.tuta_calendar import api as api_module
from apps.tuta_calendar import crypto
from apps.tuta_calendar.api import START_MARKER, TutaApi
from apps.tuta_calendar.crypto import Padding
from apps.tuta_calendar.errors import (
    ApiError,
    ModelMismatchError,
    PaginationError,
    SessionRejectedError,
    VersionFloorError,
)

TOKEN = "TOKEN-value-that-must-not-be-echoed"
LIST_ID = "shortListAAA"


def body_of(url: str) -> Mapping[str, Any]:
    query = parse_qs(urlsplit(url).query)
    return json.loads(query["_body"][0]) if "_body" in query else {}


def entry(marker: str) -> dict[str, Any]:
    return {"935": [LIST_ID, marker]}


class Recorder:
    """A transport that answers from a table and keeps every request it saw."""

    def __init__(self, answers: Mapping[str, tuple[int, Any]]) -> None:
        self.answers = answers
        self.calls: list[tuple[str, str, Mapping[str, str], Mapping[str, Any]]] = []

    def __call__(self, method: str, url: str, headers: Mapping[str, str], body: bytes | None) -> tuple[int, bytes]:
        requested = body_of(url)
        self.calls.append((method, url, headers, requested))
        # The first page is asked for by Tuta's own start-of-list marker; the
        # answers table spells that case "" so a page can be named by its id.
        key = requested.get("start", "")
        status, payload = self.answers["" if key == START_MARKER else key]
        if isinstance(payload, bytes):
            return status, payload
        return status, json.dumps(payload).encode("utf-8")

    @property
    def markers(self) -> list[str]:
        return [call[3].get("start", "") for call in self.calls]


def a_page(page_size: int, first: int, marker_prefix: str = "m", last_marker: str | None = None) -> list:
    page = [entry(f"{marker_prefix}{index}") for index in range(first, first + page_size)]
    if last_marker is not None and page:
        page[-1] = entry(last_marker)
    return page


class PaginationTest(unittest.TestCase):
    def test_a_short_page_ends_the_walk(self) -> None:
        full = a_page(2, 0)
        short = [entry("tail")]
        transport = Recorder({"": (200, full), "m1": (200, short)})
        client = TutaApi(transport=transport, page_size=2, max_pages=5)

        events = list(client.calendar_events(LIST_ID, TOKEN))

        self.assertEqual([entry("m0"), entry("m1"), entry("tail")], events)
        self.assertEqual([START_MARKER, "m1"], transport.markers)

    def test_an_empty_page_ends_the_walk_without_a_second_request(self) -> None:
        transport = Recorder({"": (200, [])})
        client = TutaApi(transport=transport, page_size=2, max_pages=5)

        self.assertEqual([], list(client.calendar_events(LIST_ID, TOKEN)))
        self.assertEqual([START_MARKER], transport.markers)

    def test_the_page_size_and_direction_are_the_client_s_constants(self) -> None:
        transport = Recorder({"": (200, [])})
        client = TutaApi(transport=transport)
        list(client.calendar_events(LIST_ID, TOKEN))

        requested = transport.calls[0][3]
        self.assertEqual(str(api_module.PAGE_SIZE), requested["count"])
        self.assertEqual("200", requested["count"])
        self.assertEqual("false", requested["reverse"])

    def test_a_marker_that_comes_back_again_stops_the_walk(self) -> None:
        """A full page whose last id repeats the marker would loop forever."""

        transport = Recorder({"": (200, a_page(2, 0, last_marker="m1")), "m1": (200, a_page(2, 0, last_marker="m1"))})
        client = TutaApi(transport=transport, page_size=2, max_pages=5)

        with self.assertRaises(PaginationError) as caught:
            list(client.calendar_events(LIST_ID, TOKEN))

        self.assertIn("twice", str(caught.exception))
        # Two requests: the marker is never asked for a third time.
        self.assertEqual([START_MARKER, "m1"], transport.markers)

    def test_a_full_page_with_no_marker_is_refused(self) -> None:
        transport = Recorder({"": (200, [{"_id": "no-935"}] * 2)})
        client = TutaApi(transport=transport, page_size=2, max_pages=5)

        with self.assertRaises(PaginationError) as caught:
            list(client.calendar_events(LIST_ID, TOKEN))

        self.assertIn("935", str(caught.exception))

    def test_the_page_count_is_bounded(self) -> None:
        answers = {"": (200, a_page(2, 0, last_marker="p1"))}
        for index in range(1, 10):
            answers[f"p{index}"] = (200, a_page(2, 0, last_marker=f"p{index + 1}"))
        transport = Recorder(answers)
        client = TutaApi(transport=transport, page_size=2, max_pages=3)

        with self.assertRaises(PaginationError) as caught:
            list(client.calendar_events(LIST_ID, TOKEN))

        self.assertIn("MAX_PAGES", str(caught.exception))
        self.assertEqual(3, len(transport.calls))

    def test_a_page_that_is_not_a_list_is_refused(self) -> None:
        transport = Recorder({"": (200, {"935": [LIST_ID, "x"]})})
        client = TutaApi(transport=transport, page_size=2)

        with self.assertRaises(PaginationError):
            list(client.calendar_events(LIST_ID, TOKEN))


class RefusalTest(unittest.TestCase):
    def assert_refusal(self, status: int, exception: type[Exception]) -> str:
        transport = Recorder({"": (status, b'{"error": "InvalidSoftwareVersionError"}')})
        client = TutaApi(transport=transport, page_size=2)
        with self.assertRaises(exception) as caught:
            list(client.calendar_events(LIST_ID, TOKEN))
        message = str(caught.exception)
        self.assertNotIn(TOKEN, message)
        self.assertNotIn("accessToken", message)
        self.assertIn(f"/rest/tutanota/calendarevent/{LIST_ID}", message)
        return message

    def test_474_names_the_endpoint_and_the_version_floor(self) -> None:
        message = self.assert_refusal(474, VersionFloorError)
        self.assertIn("474", message)
        self.assertIn(api_module.CLIENT_VERSION, message)
        self.assertIn("apps/tuta_calendar/api.py", message)

    def test_412_names_the_endpoint_and_the_model_versions(self) -> None:
        message = self.assert_refusal(412, ModelMismatchError)
        self.assertIn("412", message)
        self.assertIn(api_module.SYS_MODEL_VERSION, message)
        self.assertIn(api_module.TUTANOTA_MODEL_VERSION, message)

    def test_a_rejected_session_points_at_init(self) -> None:
        message = self.assert_refusal(401, SessionRejectedError)
        self.assertIn("init --store", message)

    def test_any_other_status_is_a_plain_refusal_with_the_endpoint(self) -> None:
        message = self.assert_refusal(500, ApiError)
        self.assertIn("HTTP 500", message)

    def test_a_200_that_is_not_json_is_refused(self) -> None:
        transport = Recorder({"": (200, b"<html>")})
        client = TutaApi(transport=transport, page_size=2)
        with self.assertRaises(ApiError) as caught:
            list(client.calendar_events(LIST_ID, TOKEN))
        self.assertIn("not JSON", str(caught.exception))


class SessionIdTest(unittest.TestCase):
    def test_the_list_id_is_translated_not_indexed(self) -> None:
        # `str.maketrans` builds a table keyed by ordinals, so `_STD_TO_EXT[c]`
        # raised `KeyError: 'a'` right after the TOTP step and `init` stored
        # nothing. The mapping is the extended alphabet Tuta's IdTuple uses.
        raw = bytes(range(9)) + b"the rest of the session"
        token = base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")
        prefix = base64.b64encode(raw[:9]).decode("ascii").replace("=", "")

        list_id, element_id = api_module._session_id(token)

        self.assertEqual(list_id, prefix.translate(api_module._STD_TO_EXT))
        self.assertEqual(
            element_id, crypto.b64url_encode(hashlib.sha256(raw[9:]).digest())
        )
        self.assertNotIn("+", list_id)
        self.assertNotIn("/", list_id)
        self.assertTrue(any(character.islower() for character in list_id))


class LoginTest(unittest.TestCase):
    def test_a_locked_session_reports_its_totp_challenge(self) -> None:
        answer = {
            "1221": TOKEN,
            "1222": [{"1189": "0"}, {"1189": "1"}],
            "1223": ["userIdAAA"],
        }
        transport = Recorder({"": (200, answer)})
        client = TutaApi(transport=transport)

        attempt = client.login("someone@example.com", "verifier-value")

        self.assertTrue(attempt.locked)
        self.assertTrue(attempt.has_totp_challenge)
        self.assertEqual("userIdAAA", attempt.user_id)
        self.assertEqual(TOKEN, attempt.access_token)

    def test_a_session_without_a_token_is_refused_without_echoing_the_verifier(self) -> None:
        transport = Recorder({"": (200, {"1222": [], "1223": []})})
        client = TutaApi(transport=transport)

        with self.assertRaises(ApiError) as caught:
            client.login("someone@example.com", "verifier-value")

        self.assertNotIn("verifier-value", str(caught.exception))
        self.assertIn("/rest/sys/sessionservice", str(caught.exception))

    def test_a_u2f_only_account_is_not_totp(self) -> None:
        answer = {"1221": TOKEN, "1222": [{"1189": "0"}], "1223": ["userIdAAA"]}
        attempt = TutaApi(transport=Recorder({"": (200, answer)})).login("a@example.com", "v")
        self.assertFalse(attempt.has_totp_challenge)

    def test_salt_is_parsed_from_the_numeric_fields(self) -> None:
        answer = {"421": "0", "422": "AAECAwQFBgcICQoLDA0ODw==", "2133": "1"}
        client = TutaApi(transport=Recorder({"": (200, answer)}))
        kdf_type, salt = client.salt("someone@example.com")
        self.assertEqual(1, kdf_type)
        self.assertEqual(bytes(range(16)), salt)


class CalendarGroupTest(unittest.TestCase):
    def test_the_calendar_membership_is_the_one_with_group_type_nine(self) -> None:
        user_group_key = bytes(range(32))
        group_key = bytes(range(32, 64))
        encrypted = crypto.encrypt(user_group_key, group_key, padding=Padding.NONE)
        answer = {
            "96": [
                {"1030": "2", "27": base64.b64encode(b"mail").decode(), "29": ["mailList", "mailGroup"]},
                {
                    "1030": "9",
                    "27": base64.b64encode(encrypted).decode(),
                    "29": ["calendarList", "calendarGroup"],
                },
            ]
        }
        client = TutaApi(transport=Recorder({"": (200, answer)}))

        group_id, unwrapped = client.calendar_group("userIdAAA", TOKEN, user_group_key)

        self.assertEqual("calendarGroup", group_id)
        self.assertEqual(group_key, unwrapped)

    def test_an_account_without_a_calendar_is_refused(self) -> None:
        client = TutaApi(transport=Recorder({"": (200, {"96": [{"1030": "2"}]})}))
        with self.assertRaises(ApiError) as caught:
            client.calendar_group("userIdAAA", TOKEN, bytes(range(32)))
        self.assertIn("no calendar group", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
