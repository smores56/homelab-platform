"""Disk-backed sources: a published raw generation answering as one source.

The fixture adapters exist so the facade has a complete, deterministic tool
surface before any provider plumbing runs. This is the other half: when a
deployment has a published generation for a source, the same ``SourceAdapter``
contract is answered from those objects instead.

Two rules keep the substitution honest:

* A source can only be replaced inside the deployment's own table. The adapter is
  built from that table's contract, so a personal facade cannot gain a general
  source by being pointed at a directory, and ``Catalog`` still refuses a catalog
  holding another deployment's adapter.
* What is returned is a *projection* -- title and body for search and for a
  readable record -- computed from the raw object. The bytes stay in the
  generation, where they can be re-read or re-projected; nothing is written back.

Provenance is exactly the three fields a memory record may cite: the source id
with the record, the record's revision (the sha256 of the object that produced
it) and the capture time the collector stamped.

Search is answered by a substring scan over the projections, or -- when the
adapter has an index root -- by the derived FTS5 index in ``source_index``. The
index is trigram-tokenized, so it can only stand in for queries whose every word
is at least three characters; a shorter word scans. That boundary is the price
of parity, and parity is the requirement.
"""

from __future__ import annotations

import email
import email.policy
import hashlib
import json
import time
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Any, Callable, Mapping

from data_plane.collectors.raw import RawReplica
from data_plane.errors import ContractError, ValidationError

from . import contracts, source_index, sources

#: A projected record body is capped: the facade already caps what it returns,
#: and a 30 MB attachment must not become a search haystack in memory.
MAX_PROJECTED_CHARS = 4000
#: The index is trigram-tokenized, so it cannot match a word shorter than this:
#: such a query is answered by the scan, which finds exactly what it finds today.
MIN_INDEXED_WORD = source_index.MIN_WORD_CHARS
#: The derived objects that are not records: epoch maps, ICS projections,
#: summaries and the database dump itself.
_NOT_RECORDS = (
    "mail::_uidvalidity",
    "finance::accountset",
)


@dataclass(frozen=True)
class Projection:
    """One record's searchable and readable text."""

    title: str
    body: str


def _clip(text: str) -> str:
    return text[:MAX_PROJECTED_CHARS]


def _mail_text(data: bytes) -> tuple[str, str]:
    message = email.message_from_bytes(data, policy=email.policy.default)
    subject = str(message.get("Subject") or "").strip()
    body = ""
    if message.is_multipart():
        for part in message.walk():
            if part.get_content_type() == "text/plain":
                payload = part.get_payload(decode=True) or b""
                body = payload.decode(part.get_content_charset() or "utf-8", "replace")
                break
    else:
        payload = message.get_payload(decode=True) or b""
        if payload:
            body = payload.decode(message.get_content_charset() or "utf-8", "replace")
    return subject, _clip(body)


def _project_mail(metadata: Mapping[str, Any], data: bytes) -> Projection | None:
    subject, body = _mail_text(data)
    title = subject or str(metadata.get("message_id") or metadata.get("key") or "")
    return Projection(title=title, body=body)


def _project_calendar(metadata: Mapping[str, Any], data: bytes) -> Projection | None:
    if metadata.get("kind") != "sdk-entity":
        return None
    entity = json.loads(data.decode("utf-8"))
    title = str(entity.get("summary") or entity.get("uid") or "")
    lines = []
    if entity.get("dtstart"):
        lines.append(f"starts {entity['dtstart']}")
    if entity.get("dtend"):
        lines.append(f"ends {entity['dtend']}")
    if entity.get("rrule"):
        lines.append(f"repeats {entity['rrule']}")
    if entity.get("description"):
        lines.append(str(entity["description"]))
    if entity.get("location"):
        lines.append(f"at {entity['location']}")
    return Projection(title=title, body=_clip("\n".join(lines)))


def _project_finance(metadata: Mapping[str, Any], data: bytes) -> Projection | None:
    if metadata.get("kind") != "transaction":
        return None
    record = json.loads(data.decode("utf-8"))
    title = str(
        record.get("description")
        or record.get("payee")
        or record.get("memo")
        or metadata.get("transaction_id")
        or ""
    )
    parts = [f"amount {record.get('amount', '')}"]
    if record.get("currency"):
        parts.append(f"currency {record['currency']}")
    parts.append(f"account {metadata.get('account_id', '')}")
    if metadata.get("pending"):
        parts.append("pending")
    if metadata.get("posted"):
        parts.append(f"posted {metadata['posted']}")
    return Projection(title=title, body=_clip(" ".join(parts)))


def _brave_rows(metadata: Mapping[str, Any], data: bytes) -> list[tuple[str, str, str]]:
    """Every URL row as ``(id, title, url)``, keyed by the table's own id column."""

    if metadata.get("kind") != "table" or metadata.get("table") != "urls":
        return []
    dump = json.loads(data.decode("utf-8"))
    columns = [str(name) for name in dump.get("columns") or ()]
    if "id" not in columns:
        return []
    index = columns.index("id")
    title_index = columns.index("title") if "title" in columns else None
    url_index = columns.index("url") if "url" in columns else None
    rows: list[tuple[str, str, str]] = []
    for row in dump.get("rows") or ():
        identifier = row[index]
        title = row[title_index] if title_index is not None else ""
        url = row[url_index] if url_index is not None else ""
        rows.append((f"urls::{identifier}", str(title or ""), str(url or "")))
    return rows


_PROJECTORS: Mapping[str, Callable[[Mapping[str, Any], bytes], Projection | None]] = (
    MappingProxyType(
        {
            "mail": _project_mail,
            "calendar": _project_calendar,
            "finance": _project_finance,
        }
    )
)

#: Sources whose records come from one table dump rather than one object each.
ROW_PROJECTORS: Mapping[str, Callable[[Mapping[str, Any], bytes], list[tuple[str, str, str]]]] = (
    MappingProxyType({"brave": _brave_rows})
)


class RefreshingReplica:
    """A replica root that resolves its newest published generation on demand.

    A collector publishes by rename, so a facade that cached the generation id at
    startup would serve yesterday's bytes until it restarted. This wrapper checks
    the directory at most once per ``refresh_seconds`` and rebuilds ``RawReplica``
    only when the newest generation changes. Before the first publication it
    raises ``SourceUnavailable`` on use, which keeps the facade (and memory) up.
    """

    def __init__(self, root: str | Path, refresh_seconds: float = 2.0) -> None:
        if refresh_seconds < 0:
            raise ValueError("refresh_seconds must not be negative")
        self._root = Path(root)
        self._refresh_seconds = refresh_seconds
        self._replica: RawReplica | None = None
        self._checked = 0.0

    def current(self) -> RawReplica:
        now = time.monotonic()
        if self._replica is not None and now - self._checked < self._refresh_seconds:
            return self._replica
        self._checked = now
        latest = RawReplica.latest_generation(self._root)
        if latest is None:
            self._replica = None
            raise sources.SourceUnavailable(
                f"source has no published generation at {self._root}"
            )
        if self._replica is None or self._replica.generation_id != latest:
            self._replica = RawReplica(self._root, latest)
        return self._replica

    @property
    def generation_id(self) -> str:
        return self.current().generation_id

    def entries(self):
        return self.current().entries()

    def read(self, object_id: str) -> bytes:
        return self.current().read(object_id)


class ReplicaAdapter:
    """One source answered from one published generation.

    Records are projected on first use and kept until the published generation
    changes; a generation is immutable, so a new one is the only reason to
    rebuild. A ``RefreshingReplica`` is checked on each read/search (bounded by
    its own TTL) and the caches are dropped when it moves forward.

    ``index_root`` adds the derived full-text index (``source_index``): searches
    over words a trigram can match use it, and everything else keeps scanning.
    """

    def __init__(
        self,
        contract,
        replica: RawReplica | RefreshingReplica,
        index_root: str | Path | None = None,
    ) -> None:
        contract.validate()
        if contract.source_id not in _PROJECTORS and contract.source_id not in ROW_PROJECTORS:
            raise ContractError(
                f"source {contract.source_id!r} has no raw projection; a replica "
                "cannot answer for it"
            )
        self.contract = contract
        self.replica = replica
        self.index_root = None if index_root is None else Path(index_root)
        self._generation_id = replica.generation_id if isinstance(replica, RawReplica) else None
        self._records: dict[str, sources.SourceRecord] | None = None
        self._index: source_index.SourceIndex | None = None
        self._index_attempted = False

    @property
    def name(self) -> str:
        return self.contract.source_id

    def _refresh(self) -> None:
        """Pick up a newer generation and drop everything derived from the old one."""

        if not isinstance(self.replica, RefreshingReplica):
            return
        current = self.replica.current()
        if current.generation_id == self._generation_id:
            return
        self._generation_id = current.generation_id
        self._records = None
        self._index = None
        self._index_attempted = False

    def read(self, record_id: str) -> sources.SourceRecord:
        self._refresh()
        record = self._built().get(record_id)
        if record is None:
            raise sources.SourceNotFound(
                f"source {self.name!r} has no record {record_id!r}"
            )
        return record

    def search(self, query: str, limit: int) -> tuple[sources.SearchHit, ...]:
        self._refresh()
        if limit < 1:
            raise ValidationError("limit must be at least 1")
        words = contracts.query_words(query)
        if not words:
            raise ValidationError("query must contain at least one word")
        # A short word is not an error and must not narrow the result: it is the
        # reason to scan. Parity with the scan is what makes the index optional.
        indexable = all(len(word) >= MIN_INDEXED_WORD for word in words)
        index = self._source_index() if indexable else None
        if index is not None:
            try:
                ids = index.search(words, limit)
            except source_index.SourceIndexUnavailable:
                return self._scan(words, limit)
            found = (self._hit(record_id, words) for record_id in ids)
            return tuple(hit for hit in found if hit is not None)
        return self._scan(words, limit)

    def _scan(self, words: tuple[str, ...], limit: int) -> tuple[sources.SearchHit, ...]:
        """The whole-generation substring scan: what the adapter did before any index."""

        hits: list[sources.SearchHit] = []
        for record in self._built().values():
            haystack = f"{record.title}\n{record.body}"
            folded = haystack.casefold()
            if not all(word.casefold() in folded for word in words):
                continue
            hits.append(
                sources.SearchHit(
                    id=record.id,
                    title=record.title,
                    snippet=contracts.snippet(haystack, words[0]),
                )
            )
            if len(hits) == limit:
                break
        return tuple(hits)

    def _hit(self, record_id: str, words: tuple[str, ...]) -> sources.SearchHit | None:
        """One hit from the projection the index was built from.

        The index is derived, so an id it lists that this projection no longer
        produces is dropped rather than raised: the caller gets fewer hits, never
        a failure.
        """

        record = self._built().get(record_id)
        if record is None:
            return None
        return sources.SearchHit(
            id=record.id,
            title=record.title,
            snippet=contracts.snippet(f"{record.title}\n{record.body}", words[0]),
        )

    def _source_index(self) -> source_index.SourceIndex | None:
        """The derived index, built at most once per adapter; None if there is none."""

        if self._index_attempted:
            return self._index
        self._index_attempted = True
        if self.index_root is None:
            return None
        try:
            index = source_index.SourceIndex(
                self.index_root, self.name, self.replica.generation_id
            )
            index.build(self._built())
        except source_index.SourceIndexUnavailable:
            # An unwritable root, a foreign schema, a full disk: the scan answers.
            return None
        self._index = index
        return index

    def _built(self) -> dict[str, sources.SourceRecord]:
        if self._records is None:
            self._records = self._project()
        return self._records

    def _project(self) -> dict[str, sources.SourceRecord]:
        projector = _PROJECTORS.get(self.name)
        rows = ROW_PROJECTORS.get(self.name)
        records: dict[str, sources.SourceRecord] = {}
        for entry in self.replica.entries():
            object_id = entry["object_id"]
            if object_id in _NOT_RECORDS:
                continue
            metadata = entry["metadata"]
            data = self.replica.read(object_id)
            if rows is not None:
                for record_id, title, body in rows(metadata, data):
                    records[record_id] = self._record(record_id, title, body, data, metadata)
                continue
            projection = projector(metadata, data) if projector is not None else None
            if projection is None:
                continue
            records[object_id] = self._record(
                object_id, projection.title, projection.body, data, metadata
            )
        return records

    def _record(
        self,
        record_id: str,
        title: str,
        body: str,
        data: bytes,
        metadata: Mapping[str, Any],
    ) -> sources.SourceRecord:
        captured_at = str(metadata.get("captured_at") or "")
        if not captured_at:
            raise ContractError(
                f"object {record_id!r} in {self.name!r} carries no capture time"
            )
        revision = hashlib.sha256(data).hexdigest()
        return sources.SourceRecord(
            id=record_id,
            source=self.name,
            title=title,
            body=body,
            provenance=MappingProxyType(
                {
                    "source_id": f"{self.name}/{record_id}",
                    "revision": revision,
                    "captured_at": captured_at,
                }
            ),
            revision=revision,
        )


def adapters_for(
    deployment,
    roots: Mapping[str, str | Path],
    index_root: str | Path | None = None,
    refresh_seconds: float = 2.0,
) -> Mapping[str, ReplicaAdapter]:
    """Build one adapter per ``source -> replica root``, from the table's contracts.

    The contract comes from the deployment's own table, so the visibility of the
    resulting adapter is not a new decision: it is the one the table already
    made. ``index_root`` is shared: each adapter indexes its own source and
    generation below it, and none of them needs it to answer.
    """

    table = sources.SOURCES_BY_DEPLOYMENT[deployment]
    built: dict[str, ReplicaAdapter] = {}
    for name, root in roots.items():
        base = table.get(name)
        if base is None:
            raise ContractError(
                f"source {name!r} is not reachable from the {deployment.value} "
                f"deployment; it serves {', '.join(sorted(table))}"
            )
        built[name] = ReplicaAdapter(
            base.contract, RefreshingReplica(root, refresh_seconds), index_root
        )
    return MappingProxyType(built)
