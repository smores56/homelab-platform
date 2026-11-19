"""The two deployment source tables, and the fixture adapters over them.

The safety rule this module exists for: a deployment's reachable sources are
two fixed tables, and the personal table contains no general source at all --
not an adapter that refuses ``books``, but no adapter to refuse it. A
``Catalog`` is bound to one deployment and refuses to be constructed from an
adapter whose contract declares another visibility, so a personal facade holding
a repos or books adapter is not a state the service can reach. A lookup miss is
a missing key in that deployment's table, not a policy branch a later edit could
invert.

Every adapter is a fixture: deterministic records held in process, no network,
no filesystem walk, and no live personal data. A source declares its own
visibility in a ``SourceContract``, so the table and the contract are checked
against each other at import time.
"""

from __future__ import annotations

from dataclasses import dataclass
from types import MappingProxyType
from typing import Any, Mapping, Protocol, Sequence, runtime_checkable

from data_plane.errors import ContractError, ValidationError
from data_plane.model import (
    Capability,
    EffectClass,
    SourceContract,
    Visibility,
    validate_many,
)

from . import contracts

#: Every fixture record is stamped with the same capture time so a run is
#: reproducible; provenance has the shape a memory record can cite directly.
FIXTURE_CAPTURED_AT = "2026-11-01T00:00:00+00:00"
FIXTURE_REVISION = "1"


class UnknownSource(ValidationError):
    """A source name that this deployment's table does not contain."""


class SourceNotFound(ValidationError):
    """The source has no record with that id."""


class SourceUnsupported(ValidationError):
    """The source does not expose the requested read or search capability."""


@dataclass(frozen=True)
class SourceRecord:
    """One source record, with provenance in the memory-record field names."""

    id: str
    source: str
    title: str
    body: str
    provenance: Mapping[str, str]
    revision: str


@dataclass(frozen=True)
class SearchHit:
    """A search result: id, title and excerpt only, never the record body."""

    id: str
    title: str
    snippet: str

    def as_dict(self) -> dict[str, str]:
        return {"id": self.id, "title": self.title, "snippet": self.snippet}


@dataclass(frozen=True)
class SourceDescription:
    name: str
    kind: str
    read: bool
    search: bool

    def as_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "kind": self.kind,
            "read": self.read,
            "search": self.search,
        }


@runtime_checkable
class SourceAdapter(Protocol):
    """What the facade needs from a source.

    ``describe`` is optional: the catalog derives the same description from the
    adapter's contract, which is the declaration every adapter must carry.
    """

    contract: SourceContract

    def read(self, record_id: str) -> SourceRecord:
        """Return one record, or raise ``SourceNotFound``."""

    def search(self, query: str, limit: int) -> tuple[SearchHit, ...]:
        """Return at most ``limit`` hits for records containing every word."""


def _capabilities(*, readable: bool, searchable: bool) -> tuple[Capability, ...]:
    declared: list[Capability] = []
    if readable:
        declared.append(
            Capability(
                name="read",
                effect=EffectClass.READ,
                description="read one record by id",
            )
        )
    if searchable:
        declared.append(
            Capability(
                name="search",
                effect=EffectClass.SEARCH,
                description="search titles and bodies, returning snippets",
            )
        )
    return tuple(declared)


def _contract(
    name: str, deployment: Visibility, *, readable: bool, searchable: bool
) -> SourceContract:
    contract = SourceContract(
        source_id=name,
        visibility=deployment,
        version=1,
        recovery_group=f"agent-{deployment.value}",
        stable_id_fields=("id",),
        capabilities=_capabilities(readable=readable, searchable=searchable),
        revision_field="revision",
    )
    contract.validate()
    return contract


@dataclass(frozen=True)
class SourceFixture:
    """A source: its name, kind, capabilities, and deterministic records."""

    name: str
    kind: str
    readable: bool
    searchable: bool
    records: tuple[tuple[str, str, str], ...] = ()


class FixtureAdapter:
    """In-process source used until a real adapter is provisioned.

    It never contacts the source it stands in for: the records are passed in at
    construction, ordered, and matched with a case-insensitive substring test,
    so the same query always yields the same hits.
    """

    def __init__(self, contract: SourceContract, records: Sequence[SourceRecord]) -> None:
        contract.validate()
        self.contract = contract
        self._records = tuple(records)
        for record in self._records:
            if record.source != contract.source_id:
                raise ContractError(
                    f"record {record.id!r} belongs to {record.source!r}, "
                    f"not {contract.source_id!r}"
                )
        self._by_id = MappingProxyType({record.id: record for record in self._records})

    @property
    def name(self) -> str:
        return self.contract.source_id

    def describe(self) -> SourceDescription:
        return _describe(self.contract)

    def read(self, record_id: str) -> SourceRecord:
        if not _declares(self.contract, EffectClass.READ):
            raise SourceUnsupported(f"source {self.name!r} does not expose read")
        record = self._by_id.get(record_id)
        if record is None:
            raise SourceNotFound(f"source {self.name!r} has no record {record_id!r}")
        return record

    def search(self, query: str, limit: int) -> tuple[SearchHit, ...]:
        if not _declares(self.contract, EffectClass.SEARCH):
            raise SourceUnsupported(f"source {self.name!r} does not expose search")
        if limit < 1:
            raise ValidationError("limit must be at least 1")
        words = contracts.query_words(query)
        if not words:
            raise ValidationError("query must contain at least one word")

        hits: list[SearchHit] = []
        for record in self._records:
            haystack = f"{record.title}\n{record.body}"
            folded = haystack.casefold()
            if not all(word.casefold() in folded for word in words):
                continue
            hits.append(
                SearchHit(
                    id=record.id,
                    title=record.title,
                    snippet=contracts.snippet(haystack, words[0]),
                )
            )
            if len(hits) == limit:
                break
        return tuple(hits)


@dataclass(frozen=True)
class Catalog:
    """One deployment's sources. Bound at construction to its own tables."""

    deployment: Visibility
    adapters: Mapping[str, SourceAdapter]

    def __post_init__(self) -> None:
        if self.deployment not in DEPLOYMENTS:
            raise ContractError(
                f"deployment must be one of {', '.join(item.value for item in DEPLOYMENTS)}, "
                f"got {self.deployment!r}"
            )
        seen = {adapter.contract.source_id for adapter in self.adapters.values()}
        if len(seen) != len(self.adapters):
            raise ContractError("a catalog cannot list two adapters under one source id")
        for name, adapter in self.adapters.items():
            if adapter.contract.source_id != name:
                raise ContractError(
                    f"catalog entry {name!r} holds source {adapter.contract.source_id!r}"
                )
            if adapter.contract.visibility is not self.deployment:
                # The structural check: a personal catalog cannot be built from
                # a general adapter, so no handler needs to remember the split.
                raise ContractError(
                    f"source {name!r} is {adapter.contract.visibility.value}; "
                    f"a {self.deployment.value} catalog refuses it"
                )

    @classmethod
    def for_deployment(
        cls,
        deployment: Visibility,
        *,
        replacements: Mapping[str, SourceAdapter] | None = None,
    ) -> Catalog:
        """One deployment's catalog, optionally with sources answered from disk.

        A replacement may only take the place of a source this deployment's table
        already names, and it must carry that table's contract: the visibility of
        the result is therefore the table's decision, not the caller's.
        """

        table = SOURCES_BY_DEPLOYMENT.get(deployment)
        if table is None:
            raise ContractError(
                f"deployment must be one of {', '.join(item.value for item in DEPLOYMENTS)}, "
                f"got {deployment!r}"
            )
        if not replacements:
            return cls(deployment=deployment, adapters=table)
        merged = dict(table)
        for name, replacement in replacements.items():
            incumbent = merged.get(name)
            if incumbent is None:
                raise UnknownSource(
                    f"source {name!r} is not reachable from the {deployment.value} "
                    f"deployment; it serves {', '.join(sorted(table))}"
                )
            if replacement.contract != incumbent.contract:
                raise ContractError(
                    f"replacement for {name!r} does not carry the deployment's contract"
                )
            merged[name] = replacement
        return cls(deployment=deployment, adapters=MappingProxyType(merged))

    def names(self) -> tuple[str, ...]:
        return tuple(self.adapters)

    def adapter(self, name: str) -> SourceAdapter:
        if not isinstance(name, str):
            raise UnknownSource("source must be a string")
        adapter = self.adapters.get(name)
        if adapter is None:
            raise UnknownSource(
                f"source {name!r} is not reachable from the {self.deployment.value} "
                f"deployment; it serves {', '.join(self.names())}"
            )
        return adapter

    def describe(self) -> tuple[SourceDescription, ...]:
        return tuple(_describe(self.adapters[name].contract) for name in self.names())

    def read(self, source: str, record_id: str) -> SourceRecord:
        return self.adapter(source).read(record_id)

    def search(self, source: str, query: str, limit: int) -> tuple[SearchHit, ...]:
        return self.adapter(source).search(query, limit)


def _declares(contract: SourceContract, effect: EffectClass) -> bool:
    return any(capability.effect is effect for capability in contract.capabilities)


def _describe(contract: SourceContract) -> SourceDescription:
    # A source the fixture table does not name has no kind to report; "source"
    # is the honest answer, and never a guess at what it might be.
    return SourceDescription(
        name=contract.source_id,
        kind=KINDS.get(contract.source_id, "source"),
        read=_declares(contract, EffectClass.READ),
        search=_declares(contract, EffectClass.SEARCH),
    )


def _adapters(
    deployment: Visibility, fixtures: Sequence[SourceFixture]
) -> Mapping[str, SourceAdapter]:
    adapters: dict[str, SourceAdapter] = {}
    for fixture in fixtures:
        contract = _contract(
            fixture.name,
            deployment,
            readable=fixture.readable,
            searchable=fixture.searchable,
        )
        records = tuple(
            SourceRecord(
                id=record_id,
                source=fixture.name,
                title=title,
                body=body,
                provenance=MappingProxyType(
                    {
                        "source_id": f"{fixture.name}/{record_id}",
                        "revision": FIXTURE_REVISION,
                        "captured_at": FIXTURE_CAPTURED_AT,
                    }
                ),
                revision=FIXTURE_REVISION,
            )
            for record_id, title, body in fixture.records
        )
        adapters[fixture.name] = FixtureAdapter(contract, records)
    validate_many(adapter.contract for adapter in adapters.values())
    return MappingProxyType(adapters)


#: The personal deployment: local model, personal sources only, zero egress.
_PERSONAL = (
    SourceFixture(
        "notes",
        "notes",
        True,
        True,
        (
            ("note-1", "Groceries", "Buy milk, eggs and coffee before Friday."),
            ("note-2", "Garden", "Water the tomatoes on Tuesday and Thursday."),
        ),
    ),
    SourceFixture(
        "tasks",
        "tasks",
        True,
        True,
        (
            ("task-1", "Annual return", "File the tax return for the last year."),
            ("task-2", "Bike service", "Replace the rear brake pads."),
        ),
    ),
    SourceFixture(
        "mail",
        "mail",
        True,
        True,
        (
            ("mail-1", "Boiler inspection", "The boiler inspection is booked for the twelfth."),
            ("mail-2", "Invoice", "Payment received, thank you for the quick transfer."),
        ),
    ),
    SourceFixture(
        "calendar",
        "calendar",
        True,
        True,
        (
            ("event-1", "Dentist", "Appointment at 09:30 with the dentist."),
            ("event-2", "Standup", "Weekly standup every Monday at 10:00."),
        ),
    ),
    SourceFixture(
        "finance",
        "finance",
        True,
        True,
        (
            ("txn-1", "Corner shop", "Card payment of 23.40 to the corner shop."),
            ("txn-2", "Refund", "Store credit of 9.99 for the returned kettle."),
        ),
    ),
    # Search-only: the web search index is read through hits, never records.
    SourceFixture(
        "brave",
        "search",
        False,
        True,
        (
            ("web-1", "Solar forecast", "A geomagnetic storm is forecast for the weekend."),
            ("web-2", "Cycling", "Quiet bike routes to the north of the city."),
        ),
    ),
    SourceFixture(
        "photos",
        "photos",
        True,
        True,
        (
            ("photo-1", "Sunset", "Golden light over the harbour."),
            ("photo-2", "Ridge", "Mist on the ridge at dawn."),
        ),
    ),
    SourceFixture(
        "music",
        "music",
        True,
        True,
        (
            ("track-1", "Aurora", "Album: Homelab Sessions, track one."),
            ("track-2", "Midnight", "Album: Night Shift, track four."),
        ),
    ),
    SourceFixture(
        "workspace",
        "workspace",
        True,
        True,
        (
            ("doc-1", "Runbook draft", "Restore steps for the file server."),
            ("doc-2", "Invoices", "Quarterly invoice summary for the accountant."),
        ),
    ),
)

#: The general deployment: hosted model, general sources only.
_GENERAL = (
    SourceFixture(
        "repos",
        "repository",
        True,
        True,
        (
            ("repo-1", "homelab-platform", "Flux manifests, policy checks and cluster docs."),
            ("repo-2", "dotfiles", "Editor settings and shell configuration."),
        ),
    ),
    SourceFixture(
        "books",
        "book",
        True,
        True,
        (
            ("book-1", "A Pattern Language", "A catalogue of building patterns."),
            ("book-2", "Dune", "A desert planet, a spice, and a dynasty."),
        ),
    ),
)

#: Source name to kind, for the ``sources.describe`` answer only.
KINDS: Mapping[str, str] = MappingProxyType(
    {fixture.name: fixture.kind for fixture in _PERSONAL + _GENERAL}
)


def _registry() -> Mapping[Visibility, Mapping[str, SourceAdapter]]:
    tables = {
        Visibility.PERSONAL: _adapters(Visibility.PERSONAL, _PERSONAL),
        Visibility.GENERAL: _adapters(Visibility.GENERAL, _GENERAL),
    }
    personal = set(tables[Visibility.PERSONAL])
    general = set(tables[Visibility.GENERAL])
    overlap = personal & general
    if overlap:
        # A name in both tables would let one deployment's table answer for the
        # other. Importing this module is the check; the service cannot start.
        raise ContractError(
            f"source name(s) in both deployment tables: {', '.join(sorted(overlap))}"
        )
    return MappingProxyType(tables)


#: The adapter registry, keyed by deployment. A deployment's own table is the
#: only thing its catalog can hold.
SOURCES_BY_DEPLOYMENT: Mapping[Visibility, Mapping[str, SourceAdapter]] = _registry()

#: The two deployments, and nothing else: ``infrastructure`` is not a facade.
DEPLOYMENTS: tuple[Visibility, ...] = tuple(SOURCES_BY_DEPLOYMENT)


def deployment(name: object) -> Visibility:
    """Parse a deployment name, refusing anything that is not a facade."""

    if not isinstance(name, str) or name not in {item.value for item in DEPLOYMENTS}:
        raise ContractError(
            f"deployment must be one of {', '.join(item.value for item in DEPLOYMENTS)}, "
            f"got {name!r}"
        )
    return Visibility(name)
