"""Credential resolution for a static enrollment.

Every enrollment reads one file from the projected Secret; a host may declare
its secret optional, in which case the lookup raises rather than serving the
request uncredentialed. The broker's redaction set is every value it read.
"""

from __future__ import annotations

from typing import Mapping, Protocol

from .config import Enrollment


class CredentialUnavailable(Exception):
    """The enrollment's credential is not provisioned for this request."""


class Credentials(Protocol):
    def value(self, enrollment: Enrollment) -> str: ...

    def values(self) -> dict[str, str]: ...


class StaticCredentials:
    def __init__(self, secrets: Mapping[str, str]) -> None:
        self._secrets = dict(secrets)

    def value(self, enrollment: Enrollment) -> str:
        if not enrollment.secret_name:
            return ""
        return self._secrets.get(enrollment.secret_name, "")

    def values(self) -> dict[str, str]:
        return dict(self._secrets)
