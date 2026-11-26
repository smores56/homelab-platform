"""Raw portable replicas: provider bytes, kept verbatim.

A collector enumerates one provider, writes the live replica state
(``ReplicaState``: content-addressed objects plus one transactional index) and
commits its own complete pass.

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
    canonical_json,
    commit_pass,
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
    "commit_pass",
    "canonical_json",
    "collect_brave_db",
    "collect_calendar",
    "collect_maildir",
    "collect_music",
    "collect_notes",
    "collect_photos",
    "collect_simplefin",
    "collect_tasks",
]
