"""Tuta calendar exporter: the provider half of the raw calendar collector.

Tuta serves no CalDAV, so the only way to keep a personal copy of its calendar is
to read the provider's own JSON entities and store them. ``init`` signs in once
and seals a session on a volume; ``dump`` unseals it, walks both event lists and
writes one JSON file per event for ``data_plane.collectors.raw.calendar``. See
``docs/raw-replicas.md`` for the shape and ``hosts/server/runbook.md``,
"Collector sign-ins", for the operator's half.
"""

__all__ = ["api", "crypto", "dump", "errors", "session"]
