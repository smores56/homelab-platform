"""Raw portable replicas: provider bytes, staged and published whole.

Each collector enumerates one provider into a ``StagingGeneration`` and returns
a report; publication is the caller's single ``commit_next(complete=True)``.
Nothing here normalizes a record: a derived index can always be rebuilt from
these objects, and cannot be rebuilt from a projection that dropped what it did
not understand.
"""

from .brave import collect_brave_db
from .calendar import collect_calendar
from .finance import collect_simplefin
from .mail import collect_maildir
from .media import MAX_MEDIA_OBJECTS
from .music import collect_music
from .notes import collect_notes
from .photos import collect_photos
from .replica import (
    ABSENCE_REASON,
    ABSENCE_NO_TOMBSTONE,
    ABSENCE_PROVIDER_WINDOW,
    ABSENCE_RETENTION,
    ABSENT_SINCE,
    CollectReport,
    RawObject,
    RawReplica,
    canonical_json,
    carry_forward,
    previous_replica,
)
from .tasks import collect_tasks

__all__ = [
    "ABSENCE_NO_TOMBSTONE",
    "ABSENCE_PROVIDER_WINDOW",
    "ABSENCE_REASON",
    "ABSENCE_RETENTION",
    "ABSENT_SINCE",
    "MAX_MEDIA_OBJECTS",
    "CollectReport",
    "RawObject",
    "RawReplica",
    "canonical_json",
    "carry_forward",
    "collect_brave_db",
    "collect_calendar",
    "collect_maildir",
    "collect_music",
    "collect_notes",
    "collect_photos",
    "collect_simplefin",
    "collect_tasks",
    "previous_replica",
]
