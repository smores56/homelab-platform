"""SimpleFIN transport: the setup token, the access URL, and one AccountSet read.

SimpleFIN has two credentials and they are not interchangeable:

* a **setup token** is base64 of a claim URL. It is single-use: POST the claim
  URL once and the provider answers with an access URL.
* the **access URL** embeds the account's username and password. It is the
  long-lived credential, and it is the thing that must never be logged, printed
  in an error, or written into the replica state -- which is why every message here
  names the endpoint by host and path only.

Nothing in this module decides when to collect, how wide the window is or whether
a response is complete: that is ``finance.collect_simplefin``, which refuses a
partial AccountSet. This is only the read.
"""

from __future__ import annotations

import base64
import binascii
import json
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable, Mapping

from ...errors import AuthenticationError, ValidationError

DEFAULT_TIMEOUT = 30
#: The bridge is behind Cloudflare, which answers Error 1010 ("blocked based on
#: your browser's signature", status 403) for the default `Python-urllib` agent.
#: Name the caller instead of borrowing a browser's.
USER_AGENT = "homelab-platform-agent/1.0 (+https://github.com/smores56/homelab-platform)"
#: A bearer that never expires is still one the log must not see.
_REDACTED = "<redacted>"

Opener = Callable[..., Any]


@dataclass(frozen=True)
class AccessUrl:
    """An access URL split into the endpoint and the basic-auth pair.

    ``url`` carries no userinfo, so it is the only form safe to log, store in the
    replica state's metadata, or show in a refusal.
    """

    url: str
    username: str
    password: str

    @classmethod
    def parse(cls, raw: str) -> AccessUrl:
        text = raw.strip()
        if not text:
            raise ValidationError("the SimpleFIN access URL is empty")
        parts = urllib.parse.urlsplit(text)
        if parts.scheme != "https":
            raise ValidationError("the SimpleFIN access URL must be https")
        if not parts.hostname:
            raise ValidationError("the SimpleFIN access URL has no host")
        if not parts.username or not parts.password:
            raise ValidationError(
                "the SimpleFIN access URL carries no credentials; claim the setup "
                "token first"
            )
        host = parts.hostname
        if ":" in host:
            host = f"[{host}]"
        if parts.port:
            host = f"{host}:{parts.port}"
        clean = urllib.parse.urlunsplit(
            (parts.scheme, host, parts.path or "", parts.query, parts.fragment)
        )
        return cls(
            url=clean,
            username=urllib.parse.unquote(parts.username),
            password=urllib.parse.unquote(parts.password),
        )

    def accounts_url(
        self,
        *,
        start_date: str | None = None,
        end_date: str | None = None,
        pending: bool = True,
    ) -> str:
        """The URL for one read, with the requested window as query parameters."""

        query: dict[str, str] = {}
        if start_date:
            query["start-date"] = start_date
        if end_date:
            query["end-date"] = end_date
        # SimpleFIN only returns pending transactions when they are asked for.
        query["pending"] = "1" if pending else "0"
        base = f"{self.url.rstrip('/')}/accounts"
        return f"{base}?{urllib.parse.urlencode(query)}"


def _authorization(access: AccessUrl) -> str:
    token = base64.b64encode(
        f"{access.username}:{access.password}".encode("utf-8")
    ).decode("ascii")
    return f"Basic {token}"


def claim_setup_token(
    setup_token: str,
    *,
    opener: Opener = urllib.request.urlopen,
    timeout: int = DEFAULT_TIMEOUT,
) -> AccessUrl:
    """Turn a single-use setup token into the access URL it claims.

    The token is never echoed: a refusal names the claim URL's host, not the
    token, and the response is only accepted when it parses as an https URL with
    credentials.
    """

    token = setup_token.strip()
    if not token:
        raise ValidationError("the SimpleFIN setup token is empty")
    try:
        claim_url = base64.b64decode(token, validate=True).decode("utf-8")
    except (binascii.Error, UnicodeDecodeError) as exc:
        raise ValidationError(
            "the SimpleFIN setup token is not base64 of a claim URL"
        ) from exc
    parts = urllib.parse.urlsplit(claim_url.strip())
    if parts.scheme != "https" or not parts.hostname:
        raise ValidationError("the SimpleFIN claim URL is not https")
    request = urllib.request.Request(
        claim_url.strip(),
        data=b"",
        method="POST",
        headers={"User-Agent": USER_AGENT},
    )
    try:
        with opener(request, timeout=timeout) as response:
            body = response.read().decode("utf-8")
    except (urllib.error.URLError, OSError) as exc:
        raise AuthenticationError(
            f"claiming the SimpleFIN token at {parts.hostname} failed: "
            f"{getattr(exc, 'reason', exc)}"
        ) from exc
    return AccessUrl.parse(body)


def fetch_accountset(
    access: AccessUrl,
    *,
    start_date: str | None = None,
    end_date: str | None = None,
    pending: bool = True,
    opener: Opener = urllib.request.urlopen,
    timeout: int = DEFAULT_TIMEOUT,
) -> Mapping[str, Any]:
    """Read one AccountSet. The caller decides whether it is publishable."""

    url = access.accounts_url(
        start_date=start_date, end_date=end_date, pending=pending
    )
    request = urllib.request.Request(
        url,
        method="GET",
        headers={
            "Authorization": _authorization(access),
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with opener(request, timeout=timeout) as response:
            body = response.read()
    except urllib.error.HTTPError as exc:
        raise AuthenticationError(
            f"SimpleFIN answered {exc.code} for "
            f"{urllib.parse.urlsplit(url).path}{_provider_reason(exc)}"
        ) from exc
    except (urllib.error.URLError, OSError) as exc:
        raise ValidationError(
            f"SimpleFIN read from {urllib.parse.urlsplit(url).hostname} failed: "
            f"{getattr(exc, 'reason', exc)}"
        ) from exc
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValidationError("SimpleFIN did not answer a JSON document") from exc
    if not isinstance(payload, Mapping):
        raise ValidationError("the SimpleFIN response is not an object")
    return payload


def _provider_reason(error: urllib.error.HTTPError) -> str:
    """The provider's own reason from the error body, if it names one.

    SimpleFIN answers a refusal as ``{"errors": [...]}``. Only that list is
    repeated: the rest of the body belongs to the account, not to a journal line.
    """

    try:
        body = error.read(4096)
    except (OSError, ValueError):
        return ""
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return ""
    if not isinstance(payload, Mapping):
        return ""
    errors = payload.get("errors")
    if not isinstance(errors, list):
        return ""
    text = "; ".join(str(item) for item in errors if isinstance(item, (str, int, float)))
    return f": {text[:200]}" if text else ""


def redact(text: str) -> str:
    """Replace any userinfo in a URL-shaped string, for messages and logs."""

    parts = urllib.parse.urlsplit(text)
    if not parts.username:
        return text
    host = parts.hostname or ""
    if ":" in host:
        host = f"[{host}]"
    if parts.port:
        host = f"{host}:{parts.port}"
    return urllib.parse.urlunsplit((parts.scheme, f"{_REDACTED}@{host}", parts.path, "", ""))
