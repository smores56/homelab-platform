"""The REST surface of Tuta's calendar, as far as a read-only dumper needs it.

The provider has no CalDAV, so the only supported path is its own JSON API over
numeric field ids: a salt, a session, an optional TOTP challenge, then one
group-root lookup and paged event lists. The field numbers and the login flow
were established by a spike against the live provider (and cross-read against
``peix2/tutaproxy-public``, AGPL-3.0, ``tuta/api.py``); they are not guesses and
must not be re-derived from the web client's minified bundle.

Two rules shape this module:

* **A refusal names the endpoint, never the credential.** A message ends up in a
  journal, and the access token in a sealed session is the whole account. Status
  codes map to named exceptions (:class:`~.errors.VersionFloorError`,
  ``ModelMismatchError``, ``SessionRejectedError``) whose text carries the method,
  the path and the status -- never a header, a body or the token.
* **Pagination is bounded twice.** The page size is fixed, and a walk that would
  exceed :data:`MAX_PAGES` or that is handed a page marker it has already asked
  for stops with :class:`~.errors.PaginationError` instead of looping.

The transport is injected so the tests can drive every page shape and every
status without a network: ``transport(method, url, headers, body)`` returns
``(status, body_bytes)``.
"""

from __future__ import annotations

import base64
import hashlib
import json
import time
import urllib.error
import urllib.request
from urllib.parse import quote, urlsplit
from collections.abc import Callable, Iterator, Mapping, Sequence
from dataclasses import dataclass
from typing import Any

from .crypto import b64url_decode, b64url_encode, unwrap_key
from .errors import (
    ApiError,
    CalendarError,
    ModelMismatchError,
    PaginationError,
    SessionRejectedError,
    VersionFloorError,
)

BASE_URL = "https://app.tuta.com"

# The versions Tuta compares before it answers. A build below the server's
# minimum gets HTTP 474 and nothing else, which is why they are module
# constants a rebuild can move rather than a runtime negotiation.
SYS_MODEL_VERSION = "150"
TUTANOTA_MODEL_VERSION = "108"
CLIENT_VERSION = "359.260904.0"
CLIENT_PLATFORM = "5"

# What sessionservice records as the client. Tuta accepts a short opaque
# identifier; it is not a secret and it is not a version.
CLIENT_IDENTIFIER = "tuta-calendar"

# Tuta's own page ceiling for a list read. Sending more is ignored, sending
# fewer costs more round trips, so the number is the server's, not ours.
PAGE_SIZE = 200
# 50 pages is 10 000 events per list: far above a personal calendar, and low
# enough that a broken marker ends the walk instead of the process budget.
MAX_PAGES = 50
# The id Tuta's client sends to ask for a list's first page.
START_MARKER = "AAAAAAAAAAAA"

# An access token is an IdTuple in disguise: the session's element id is the
# hash of everything after the first nine bytes. SecondFactorAuthData needs it.
_GENERATED_ID_BYTES = 9
_B64_STD = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
_B64_EXT = "-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz"
_STD_TO_EXT = str.maketrans(_B64_STD, _B64_EXT)


@dataclass(frozen=True)
class LoginAttempt:
    """What ``sessionservice`` answers: a session, maybe still locked."""

    access_token: str
    user_id: str
    challenges: tuple[Mapping[str, Any], ...] = ()

    @property
    def locked(self) -> bool:
        """A non-empty challenge list means the session exists but is not usable."""

        return bool(self.challenges)

    @property
    def has_totp_challenge(self) -> bool:
        """``SecondFactorType`` is 0 u2f, 1 totp, 2 webauthn; only TOTP is headless."""

        return any(str(challenge.get("1189", "")) == "1" for challenge in self.challenges)


class _UrlOpenTransport:
    """The real transport: one request, no redirects followed, no retries."""

    def __call__(
        self, method: str, url: str, headers: Mapping[str, str], body: bytes | None
    ) -> tuple[int, bytes]:
        request = urllib.request.Request(url, data=body, headers=dict(headers), method=method)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:  # noqa: S310 - fixed https host
                return response.status, response.read()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read()
        except urllib.error.URLError as exc:
            raise CalendarError(f"{method} {_path(url)} did not complete: {exc.reason}") from exc


def _path(url: str) -> str:
    """The part of a URL safe to print: the path, with no host and no query."""

    return urlsplit(url).path


def _last_marker(page: Sequence[Mapping[str, Any]]) -> str | None:
    """The ``_id`` (field 935) of a page's last element, which starts the next page."""

    if not page:
        return None
    marker = page[-1].get("935")
    if isinstance(marker, list):
        marker = marker[-1] if marker else None
    if marker is None:
        return None
    marker = str(marker).strip()
    return marker or None


class TutaApi:
    """A calendar reader. Nothing here writes to the provider."""

    def __init__(
        self,
        *,
        base_url: str = BASE_URL,
        transport: Callable[..., tuple[int, bytes]] | None = None,
        page_size: int = PAGE_SIZE,
        max_pages: int = MAX_PAGES,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.transport = transport or _UrlOpenTransport()
        if page_size < 1:
            raise CalendarError("the page size must be positive")
        self.page_size = page_size
        self.max_pages = max_pages

    # -- requests ---------------------------------------------------------

    def _url(self, app: str, service: str, *ids: str) -> str:
        return "/".join([self.base_url, "rest", app, service, *(ids)])

    def _headers(self, app: str, token: str = "") -> dict[str, str]:
        version = SYS_MODEL_VERSION if app == "sys" else TUTANOTA_MODEL_VERSION
        headers = {
            "v": version,
            "cp": CLIENT_PLATFORM,
            "cv": CLIENT_VERSION,
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        if token:
            headers["accessToken"] = token
        return headers

    def _call(
        self,
        method: str,
        url: str,
        *,
        app: str,
        token: str = "",
        body: Mapping[str, Any] | None = None,
    ) -> Any:
        payload = None if body is None else json.dumps(body).encode("utf-8")
        status, raw = self.transport(method, url, self._headers(app, token), payload)
        # 201 is the same answer from a create-shaped POST; anything else is a
        # refusal, mapped by the caller-visible endpoint rather than the body.
        if status not in (200, 201):
            self._refuse(method, url, status)
        try:
            return json.loads(raw.decode("utf-8")) if raw else {}
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ApiError(f"{method} {_path(url)} answered 200 with a body that is not JSON") from exc

    def _refuse(self, method: str, url: str, status: int) -> None:
        """Map a status onto a refusal that names the endpoint and nothing else."""

        endpoint = f"{method} {_path(url)}"
        if status == 474:
            raise VersionFloorError(
                f"{endpoint} answered HTTP 474 InvalidSoftwareVersionError: this build sends "
                f"client version {CLIENT_VERSION}, below the minimum the server now accepts. "
                "Raise CLIENT_VERSION in apps/tuta_calendar/api.py, rebuild "
                "images/tuta-calendar/Containerfile and repin the digest."
            )
        if status == 412:
            raise ModelMismatchError(
                f"{endpoint} answered HTTP 412: the model version this build sends "
                f"(sys {SYS_MODEL_VERSION}, tutanota {TUTANOTA_MODEL_VERSION}) is not the one "
                "the server expects. Raise the matching constant in apps/tuta_calendar/api.py, "
                "rebuild the image and repin the digest."
            )
        if status in (401, 403):
            raise SessionRejectedError(
                f"{endpoint} answered HTTP {status}: the stored session was rejected. "
                "Run `init --store DIR` again to sign in; nothing else about the store changes."
            )
        raise ApiError(f"{endpoint} answered HTTP {status}")

    def _get(self, url: str, *, app: str, token: str = "", body: Mapping[str, Any] | None = None) -> Any:
        # Tuta's GET endpoints take their request document in `_body`; the query
        # string is how a GET carries one, and json.dumps is what keeps a quoted
        # address from breaking the request.
        if body is not None:
            url = f"{url}?_body={quote(json.dumps(body))}"
        return self._call("GET", url, app=app, token=token)

    def _post(self, url: str, body: Mapping[str, Any], *, app: str, token: str = "") -> Any:
        return self._call("POST", url, app=app, token=token, body=body)

    # -- login ------------------------------------------------------------

    def salt(self, address: str) -> tuple[int, bytes]:
        """The account's KDF type and salt, which decide the verifier's shape."""

        answer = self._get(
            self._url("sys", "saltservice"), app="sys", body={"418": "0", "419": address}
        )
        kdf_type = int(str(answer.get("2133", answer.get("421", "0"))))
        salt_b64 = str(answer.get("422", ""))
        if not salt_b64:
            raise ApiError("GET /rest/sys/saltservice answered without a salt")
        try:
            salt = base64.b64decode(salt_b64)
        except ValueError as exc:
            raise ApiError("GET /rest/sys/saltservice answered a salt that is not base64") from exc
        return kdf_type, salt

    def login(self, address: str, verifier_value: str) -> LoginAttempt:
        """Open a session. A non-empty challenge list means it is still locked."""

        answer = self._post(
            self._url("sys", "sessionservice"),
            {
                "1212": "0",
                "1213": address,
                "1214": verifier_value,
                "1215": CLIENT_IDENTIFIER,
                "1216": None,
                "1217": None,
                "1218": [],
                "1417": None,
            },
            app="sys",
        )
        token = str(answer.get("1221", ""))
        if not token:
            raise ApiError(
                "POST /rest/sys/sessionservice answered without an access token; "
                "the verifier for this password was not accepted"
            )
        user_ids = answer.get("1223") or []
        if isinstance(user_ids, str):
            user_ids = [user_ids]
        challenges = answer.get("1222") or []
        return LoginAttempt(
            access_token=token,
            user_id=str(user_ids[-1]) if user_ids else "",
            challenges=tuple(challenges),
        )

    def submit_totp(self, access_token: str, code: str) -> None:
        """Answer a TOTP challenge. U2F and WebAuthn need hardware and are refused."""

        self._post(
            self._url("sys", "secondfactorauthservice"),
            {
                "542": "0",
                "1230": "1",
                "1243": str(code),
                "1231": [],
                "1232": [_session_id(access_token)],
                "1905": [],
            },
            app="sys",
        )

    def await_second_factor(self, access_token: str, *, attempts: int = 10) -> None:
        """Poll until the server stops reporting a pending second factor."""

        url = self._url("sys", "secondfactorauthservice")
        for attempt in range(attempts):
            answer = self._get(
                url, app="sys", token=access_token, body={"1234": "0", "1235": access_token}
            )
            if str(answer.get("1238", "")).lower() in ("0", "false"):
                return
            if attempt + 1 < attempts:
                time.sleep(1)
        raise SessionRejectedError(
            "GET /rest/sys/secondfactorauthservice kept answering secondFactorPending after "
            f"{attempts} polls: the TOTP code was not accepted"
        )

    # -- calendar reads ---------------------------------------------------

    def user(self, user_id: str, access_token: str) -> Mapping[str, Any]:
        return self._get(self._url("sys", "user", user_id), app="sys", token=access_token)

    def calendar_group(self, user_id: str, access_token: str, user_group_key: bytes) -> tuple[str, bytes]:
        """The calendar group's id and its unwrapped key, from the user's memberships."""

        record = self.user(user_id, access_token)
        memberships = record.get("96") or []
        if isinstance(memberships, Mapping):
            memberships = [memberships]
        for membership in memberships:
            if str(membership.get("1030", "")) != "9":  # GroupType.Calendar
                continue
            encrypted = membership.get("27", "")
            if not encrypted:
                raise ApiError(
                    f"GET /rest/sys/user/{user_id} lists a calendar membership with no "
                    "encrypted group key"
                )
            group = membership.get("29", "")
            group_id = str(group[-1] if isinstance(group, list) and group else group)
            return group_id, unwrap_key(user_group_key, base64.b64decode(encrypted))
        raise ApiError(
            f"GET /rest/sys/user/{user_id} lists no calendar group: this account has no "
            "calendar to dump"
        )

    def calendar_list_ids(self, group_id: str, access_token: str) -> tuple[str, ...]:
        """``954`` shortEvents and ``955`` longEvents: the two lists an account has."""

        root = self._get(
            self._url("tutanota", "calendargrouproot", group_id), app="tutanota", token=access_token
        )
        ids: list[str] = []
        for field in ("954", "955"):
            value = root.get(field, "")
            if isinstance(value, list):
                value = value[-1] if value else ""
            if value:
                ids.append(str(value))
        if not ids:
            raise ApiError(
                f"GET /rest/tutanota/calendargrouproot/{group_id} names no event list "
                "(954, 955); the calendar group is empty or the model moved"
            )
        return tuple(ids)

    def events_page(
        self, list_id: str, access_token: str, start: str, count: int | None = None
    ) -> Sequence[Mapping[str, Any]]:
        """One page of ``calendarevent``, oldest first."""

        # A list range is query parameters, not a service call: Tuta's own
        # client sends start/count/reverse in the query, and `?_body=` here is a
        # 400 ("GET /rest/tutanota/calendarevent/<list> answered HTTP 400").
        target = (
            f"{self._url('tutanota', 'calendarevent', list_id)}"
            f"?start={quote(start)}&count={count or self.page_size}&reverse=false"
        )
        page = self._call("GET", target, app="tutanota", token=access_token)
        if isinstance(page, Mapping) or not isinstance(page, Sequence):
            raise PaginationError(
                f"GET /rest/tutanota/calendarevent/{list_id} answered "
                f"{type(page).__name__}, not a list of events"
            )
        return [entry for entry in page if isinstance(entry, Mapping)]

    def calendar_events(self, list_id: str, access_token: str) -> Iterator[Mapping[str, Any]]:
        """Walk one list page by page, stopping on a short page or a repeated marker."""

        start = START_MARKER
        requested: set[str] = set()
        for _ in range(self.max_pages):
            if start in requested:
                raise PaginationError(
                    f"GET /rest/tutanota/calendarevent/{list_id} handed back the page marker "
                    f"{start!r} twice; stopping rather than walking in a circle"
                )
            requested.add(start)
            page = self.events_page(list_id, access_token, start)
            yield from page
            if len(page) < self.page_size:
                return
            marker = _last_marker(page)
            if marker is None:
                raise PaginationError(
                    f"GET /rest/tutanota/calendarevent/{list_id} returned a full page whose "
                    "last element has no _id (935); there is no next-page marker to send"
                )
            start = marker
        raise PaginationError(
            f"GET /rest/tutanota/calendarevent/{list_id} still had more pages after "
            f"{self.max_pages} of {self.page_size}; raise MAX_PAGES deliberately, not by reflex"
        )


def _session_id(access_token: str) -> list[str]:
    """The session's IdTuple: nine bytes of list id, the hash of the rest."""

    try:
        raw = b64url_decode(access_token)
    except ValueError as exc:
        raise ApiError("the access token is not base64url; it cannot identify a session") from exc
    prefix = base64.b64encode(raw[:_GENERATED_ID_BYTES]).decode("ascii")
    list_id = prefix.replace("=", "").translate(_STD_TO_EXT)
    element_id = b64url_encode(hashlib.sha256(raw[_GENERATED_ID_BYTES:]).digest())
    return [list_id, element_id]
