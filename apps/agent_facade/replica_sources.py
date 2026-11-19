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
"""

from __future__ import annotations

import email
import email.policy
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Any, Callable, Mapping

from data_plane.collectors.raw import RawReplica
from data_plane.errors import ContractError, ValidationError

from . import contracts, sources

#: A projected record body is capped: the facade already caps what it returns,
#: and a 30 MB attachment must not become a search haystack in memory.
MAX_PROJECTED_CHARS = 4000
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


class ReplicaAdapter:
    """One source answered from one published generation.

    Records are projected on first use and kept, because a published generation
    is immutable: the directory is a specific generation id, and a new collection
    publishes a new one.
    """

    def __init__(self, contract, replica: RawReplica) -> None:
        contract.validate()
        if contract.source_id not in _PROJECTORS and contract.source_id not in ROW_PROJECTORS:
            raise ContractError(
                f"source {contract.source_id!r} has no raw projection; a replica "
                "cannot answer for it"
            )
        self.contract = contract
        self.replica = replica
        self._records: dict[str, sources.SourceRecord] | None = None

    @property
    def name(self) -> str:
        return self.contract.source_id

    def read(self, record_id: str) -> sources.SourceRecord:
        record = self._built().get(record_id)
        if record is None:
            raise sources.SourceNotFound(
                f"source {self.name!r} has no record {record_id!r}"
            )
        return record

    def search(self, query: str, limit: int) -> tuple[sources.SearchHit, ...]:
        if limit < 1:
            raise ValidationError("limit must be at least 1")
        words = contracts.query_words(query)
        if not words:
            raise ValidationError("query must contain at least one word")
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
    deployment, roots: Mapping[str, str | Path]
) -> Mapping[str, ReplicaAdapter]:
    """Build one adapter per ``source -> replica root``, from the table's contracts.

    The contract comes from the deployment's own table, so the visibility of the
    resulting adapter is not a new decision: it is the one the table already
    made.
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
        built[name] = ReplicaAdapter(base.contract, RawReplica(root))
    return MappingProxyType(built)
