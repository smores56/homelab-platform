"""The refusals this exporter can end on.

Every one of them names what the operator has to act on -- an endpoint, a
format, a store path -- and none of them may carry a credential: a message ends
up in a journal, and the access token in a sealed session is the account.
"""

from __future__ import annotations


class CalendarError(Exception):
    """Base class: anything this exporter refuses to continue through."""


class UsageError(CalendarError):
    """The command was asked for something it does not do."""


class CryptoError(CalendarError):
    """Key material could not be derived, unwrapped or authenticated."""


class SealError(CalendarError):
    """The session seal under the store cannot be opened."""


class ApiError(CalendarError):
    """Tuta answered with a status this client does not handle."""


class VersionFloorError(ApiError):
    """HTTP 474: the client version this build sends is below the server minimum."""


class ModelMismatchError(ApiError):
    """HTTP 412: the model version this build sends is not the server's."""


class SessionRejectedError(ApiError):
    """HTTP 401/403: the stored session is no longer accepted."""


class PaginationError(CalendarError):
    """A list page came back in a shape that would not terminate the walk."""
