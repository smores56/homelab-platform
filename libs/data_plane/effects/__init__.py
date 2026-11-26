"""File-backed effect owners: the broker's write path for local file sources.

An adapter here owns exactly one directory and never hands a path string back to
a caller; see :mod:`data_plane.effects.confine` for why.
"""

from .confine import ConfinedRoot, Snapshot
from .notes import NotesAdapter
from .tasks import TasksAdapter
from .tombstones import TombstoneLog

__all__ = ["ConfinedRoot", "NotesAdapter", "Snapshot", "TasksAdapter", "TombstoneLog"]
