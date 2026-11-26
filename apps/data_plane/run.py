"""Entrypoint: ``python -m apps.data_plane.run <service>``.

One process runs one service. Configuration comes from flags or the matching
environment variable; a missing DB path or secret file aborts startup instead
of serving a half-configured endpoint. Logs go to stderr so a container can
keep stdout for nothing else and a read-only root filesystem only needs the
database to be a writable mount.

Every backend is local and offline: SQLite files and in-process adapters.
Nothing here shells out to restic, dials a provider, or reads a live source;
backups run from the ``data_plane`` CLI, not from a long-lived service.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sqlite3
import sys
import threading
from collections.abc import Iterable, Mapping
from pathlib import Path
from typing import Any

from data_plane.approval import (
    MAX_APPROVAL_TTL_SECONDS,
    SignedApprovalVerifier,
    UsedApprovalStore,
    pending_from_intent,
)
from data_plane.broker import Broker
from data_plane.broker_journal import BrokerJournal
from data_plane.collectors.relay import Relay
from data_plane.confirmation import ConfirmationGate, NormalizedOperation
from data_plane.effects import NotesAdapter, TasksAdapter
from data_plane.errors import DataPlaneError
from data_plane.event_log import EventLog
from data_plane.identity import IdentityIssuer
from data_plane.intents import IntentStore
from data_plane.model import (
    Authority,
    Capability,
    EffectClass,
    FidelityLimit,
    FieldAuthority,
    IntentState,
    SourceContract,
    Visibility,
)

from . import (
    broker_service,
    collector_service,
    common,
    confirmation_service,
    event_service,
    relay_service,
)

SERVICES = (
    "event",
    "broker",
    "relay",
    "confirmation",
    "collector",
)


class ConfigError(Exception):
    """Startup configuration is missing or invalid."""


def _env(name: str, default: str | None = None) -> str | None:
    value = os.environ.get(name)
    return default if value is None or not value.strip() else value


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m apps.data_plane.run",
        description="Run one offline data-plane HTTP service.",
    )
    parser.add_argument("service", choices=SERVICES)
    parser.add_argument("--host", default=_env("DATA_PLANE_HOST", "127.0.0.1"))
    parser.add_argument(
        "--port", type=int, default=int(_env("DATA_PLANE_PORT", "8080") or "8080")
    )
    parser.add_argument("--db", default=_env("DATA_PLANE_DB"))
    parser.add_argument("--secret-file", default=_env("DATA_PLANE_SECRET_FILE"))
    parser.add_argument(
        "--append-token-file",
        default=_env("DATA_PLANE_EVENT_APPEND_TOKEN_FILE")
        or _env("DATA_PLANE_APPEND_TOKEN_FILE"),
    )
    parser.add_argument(
        "--read-token-file",
        default=_env("DATA_PLANE_EVENT_READ_TOKEN_FILE")
        or _env("DATA_PLANE_READ_TOKEN_FILE"),
    )
    parser.add_argument("--schema", default=_env("DATA_PLANE_SCHEMA"))
    parser.add_argument("--catalog", default=_env("DATA_PLANE_CATALOG"))
    parser.add_argument(
        "--notes-root", default=_env("DATA_PLANE_NOTES_ROOT")
    )
    parser.add_argument(
        "--tasks-root", default=_env("DATA_PLANE_TASKS_ROOT")
    )
    parser.add_argument(
        "--operator-token-file",
        default=_env("DATA_PLANE_OPERATOR_TOKEN_FILE")
        or _env("DATA_PLANE_SECRET_FILE"),
    )
    parser.add_argument(
        "--operator-key-file", default=_env("DATA_PLANE_OPERATOR_KEY_FILE")
    )
    parser.add_argument(
        "--approval-ttl",
        type=int,
        default=int(
            _env("APPROVAL_TTL_SECONDS", str(MAX_APPROVAL_TTL_SECONDS))
            or str(MAX_APPROVAL_TTL_SECONDS)
        ),
    )
    parser.add_argument(
        "--approval-db", default=_env("DATA_PLANE_APPROVAL_DB")
    )
    parser.add_argument(
        "--source", default=_env("DATA_PLANE_SOURCE") or _env("SOURCE_ID")
    )
    parser.add_argument(
        "--proxy-url",
        default=_env("DATA_PLANE_PROXY_URL") or _env("SOURCE_PROXY_URL"),
    )
    parser.add_argument("--relay-url", default=_env("DATA_PLANE_RELAY_URL"))
    parser.add_argument(
        "--consumer-secrets-file", default=_env("DATA_PLANE_CONSUMER_SECRETS_FILE")
    )
    parser.add_argument(
        "--max-body-bytes",
        type=int,
        default=int(_env("DATA_PLANE_MAX_BODY_BYTES", str(common.MAX_BODY_BYTES)) or "0"),
    )
    return parser


def _required(value: str | None, name: str) -> str:
    if not value:
        raise ConfigError(f"{name} is required")
    return value


def _read_secret(path: str | None) -> bytes:
    target = Path(_required(path, "--secret-file (DATA_PLANE_SECRET_FILE)"))
    try:
        secret = target.read_bytes().rstrip(b"\r\n")
    except OSError as exc:
        raise ConfigError(f"cannot read secret file {target}: {exc.strerror}") from exc
    if not secret:
        raise ConfigError(f"secret file {target} is empty")
    return secret


def _read_required_file(path: str | None, name: str) -> bytes:
    target = Path(_required(path, name))
    try:
        raw = target.read_bytes().rstrip(b"\r\n")
    except OSError as exc:
        raise ConfigError(f"cannot read {name} file {target}: {exc.strerror}") from exc
    if not raw:
        raise ConfigError(f"{name} file {target} is empty")
    return raw


def _load_consumer_secrets(path: str | None) -> dict[str, bytes] | None:
    if not path:
        return None
    try:
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError(f"cannot load consumer secrets: {exc}") from exc
    if not isinstance(raw, dict) or not raw:
        raise ConfigError("consumer secrets must be a non-empty JSON object")
    result: dict[str, bytes] = {}
    for name, value in raw.items():
        if (
            not isinstance(name, str)
            or not name.strip()
            or not isinstance(value, str)
            or not value
        ):
            raise ConfigError("each consumer secret must name a non-empty string")
        result[name] = value.encode("utf-8")
    return result


def _source_contract(raw: Mapping[str, Any]) -> SourceContract:
    contract = SourceContract(
        source_id=str(raw["source_id"]),
        visibility=Visibility(str(raw["visibility"])),
        version=int(raw.get("version", 1)),
        recovery_group=str(raw["recovery_group"]),
        stable_id_fields=tuple(str(item) for item in raw.get("stable_id_fields", ())),
        capabilities=tuple(
            Capability(
                name=str(item["name"]),
                effect=EffectClass(str(item["effect"])),
                requires_confirmation=bool(item.get("requires_confirmation", False)),
                reversible=bool(item.get("reversible", True)),
                description=str(item.get("description", "")),
            )
            for item in raw.get("capabilities", ())
        ),
        authority=tuple(
            FieldAuthority(
                field=str(item["field"]),
                authority=Authority(str(item["authority"])),
                exportable=bool(item.get("exportable", True)),
                note=str(item.get("note", "")),
            )
            for item in raw.get("authority", ())
        ),
        revision_field=raw.get("revision_field"),
        tombstone_field=raw.get("tombstone_field"),
        attachment_hash_fields=tuple(
            str(item) for item in raw.get("attachment_hash_fields", ())
        ),
        fidelity_limits=tuple(
            FidelityLimit(field=str(item["field"]), reason=str(item["reason"]))
            for item in raw.get("fidelity_limits", ())
        ),
        epoch=int(raw.get("epoch", 1)),
        notes=str(raw.get("notes", "")),
    )
    contract.validate()
    return contract


def _load_catalog(path: str | None) -> dict[str, SourceContract]:
    target = Path(_required(path, "--catalog (DATA_PLANE_CATALOG)"))
    try:
        raw = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError(f"cannot read catalog {target}: {exc}") from exc
    items = raw.get("sources") if isinstance(raw, dict) else raw
    if not isinstance(items, list) or not items:
        raise ConfigError("catalog must contain a non-empty 'sources' list")
    sources: dict[str, SourceContract] = {}
    for item in items:
        if not isinstance(item, dict):
            raise ConfigError("catalog sources must be JSON objects")
        try:
            contract = _source_contract(item)
        except (KeyError, TypeError, ValueError, DataPlaneError) as exc:
            raise ConfigError(f"invalid catalog source: {exc}") from exc
        sources[contract.source_id] = contract
    return sources


class FixtureAdapter:
    """In-memory source used until a real adapter is provisioned.

    It implements the broker's four calls with a dict per target and a
    monotonic revision stub. It never contacts the source it stands in for.
    """

    def __init__(self, contract: SourceContract) -> None:
        self._contract = contract
        self._records: dict[str, dict[str, Any]] = {}
        self._writes = 0

    def revision(self, target: str) -> str | None:
        record = self._records.get(target)
        field = self._contract.revision_field
        if record is None or field is None:
            return None
        value = record.get(field)
        return None if value is None else str(value)

    def read(self, target: str) -> dict[str, Any]:
        return dict(self._records.get(target, {}))

    def search(self, query: str) -> list[dict[str, Any]]:
        needle = query.lower()
        return [
            dict(record)
            for record in self._records.values()
            if needle in str(record.get("title", "")).lower()
        ]

    def apply(
        self, operation: NormalizedOperation, idempotency_key: str
    ) -> dict[str, Any]:
        if operation.capability == "delete":
            for target in operation.targets:
                self._records.pop(target, None)
            return {"applied": len(operation.targets)}
        self._writes += 1
        for target in operation.targets:
            record = self._records.setdefault(target, {"id": target})
            for change in operation.field_diff:
                record[change.field] = change.after
            if self._contract.revision_field:
                record[self._contract.revision_field] = f"rev-{self._writes}"
        return {"applied": len(operation.targets)}


NOTES_SOURCE = "notes.markdown"
TASKS_SOURCE = "tasks.todo"


def build_adapters(
    sources: Mapping[str, SourceContract],
    *,
    notes_root: str | None = None,
    tasks_root: str | None = None,
) -> dict[str, Any]:
    """One adapter per catalog source, real where a root is configured.

    A configured root that the catalog does not declare, or that cannot be
    opened, fails the process. Falling back to the fixture would answer writes
    successfully while the file it claims to change is untouched, which is the
    failure this seam exists to remove.
    """

    adapters: dict[str, Any] = {
        source_id: FixtureAdapter(contract) for source_id, contract in sources.items()
    }
    owners = ((NOTES_SOURCE, notes_root, NotesAdapter), (TASKS_SOURCE, tasks_root, TasksAdapter))
    for source_id, root, factory in owners:
        if not root:
            continue
        if source_id not in adapters:
            raise ConfigError(
                f"a root is configured for {source_id} but the catalog has no such source"
            )
        adapters[source_id] = factory(root)
    return adapters


class JournalRecorder:
    """Effect recorder that appends to the local event log."""

    def __init__(self, log: EventLog) -> None:
        self._log = log

    def record(self, event: Mapping[str, Any]) -> None:
        intent_id = str(event.get("intent_id", ""))
        self._log.append(
            "broker.effect",
            intent_id,
            dict(event),
            idempotency_key=f"effect:{intent_id}",
        )


def _run_event(args: argparse.Namespace) -> int:
    log = EventLog(_required(args.db, "--db (DATA_PLANE_DB)"))
    append_secret = _read_secret(
        _required(
            args.append_token_file,
            "--append-token-file (DATA_PLANE_EVENT_APPEND_TOKEN_FILE)",
        )
    )
    read_secret = _read_secret(
        _required(
            args.read_token_file,
            "--read-token-file (DATA_PLANE_EVENT_READ_TOKEN_FILE)",
        )
    )
    if append_secret == read_secret:
        # One credential for both sides lets a producer read its own log and a
        # reader inject events, which is the split this service exists to make.
        raise ConfigError("event append and read tokens must differ")
    try:
        service = event_service.EventService(
            log,
            append_secret,
            read_secret,
            consumer_secrets=_load_consumer_secrets(args.consumer_secrets_file),
            max_body_bytes=args.max_body_bytes,
        )
        common.serve(
            "event", common.handler_for(service), port=args.port, host=args.host
        )
    finally:
        log.close()
    return 0


def _run_relay(args: argparse.Namespace) -> int:
    secret = _read_secret(args.secret_file)
    try:
        schema = relay_service.load_schema(
            _required(args.schema, "--schema (DATA_PLANE_SCHEMA)")
        )
    except (OSError, ValueError) as exc:
        raise ConfigError(f"cannot load relay schema: {exc}") from exc

    accepted: list[dict[str, Any]] = []

    def sink(record: dict[str, Any]) -> None:
        accepted.append(record)

    service = relay_service.RelayService(
        Relay(
            secret,
            schema,
            sink,
            source_id=_required(args.source, "--source (DATA_PLANE_SOURCE)"),
        ),
        max_body_bytes=args.max_body_bytes,
    )
    common.serve("relay", common.handler_for(service), port=args.port, host=args.host)
    return 0


def _run_broker(args: argparse.Namespace) -> int:
    secret = _read_secret(args.secret_file)
    sources = _load_catalog(args.catalog)
    db = Path(_required(args.db, "--db (DATA_PLANE_DB)"))
    journal = IntentStore(db)
    event_path = db
    event_log = EventLog(event_path)
    approval_store = None
    approval_verifier = None
    try:
        issuer = IdentityIssuer(sources, secret)
        gate = ConfirmationGate()
        if args.operator_key_file:
            approval_key = _read_required_file(
                args.operator_key_file,
                "--operator-key-file (DATA_PLANE_OPERATOR_KEY_FILE)",
            )
            try:
                approval_store = UsedApprovalStore(args.approval_db or db)
            except (OSError, sqlite3.Error) as exc:
                raise ConfigError(
                    f"cannot open the approval store: {exc}"
                ) from exc
            approval_verifier = SignedApprovalVerifier(
                approval_key, approval_store, max_ttl=args.approval_ttl
            )
        adapters = build_adapters(
            sources, notes_root=args.notes_root, tasks_root=args.tasks_root
        )
        broker = Broker(
            sources,
            adapters,
            issuer,
            gate,
            BrokerJournal(journal),
            JournalRecorder(event_log),
            approval_verifier=approval_verifier,
        )
        service = broker_service.BrokerService(broker, issuer)
        common.serve(
            "broker", common.handler_for(service), port=args.port, host=args.host
        )
    finally:
        if approval_store is not None:
            approval_store.close()
        event_log.close()
        journal.close()
    return 0


def _run_confirmation(args: argparse.Namespace) -> int:
    operator_token = _read_required_file(
        args.operator_token_file,
        "--operator-token-file (DATA_PLANE_OPERATOR_TOKEN_FILE)",
    )
    operator_key = _read_required_file(
        args.operator_key_file, "--operator-key-file (DATA_PLANE_OPERATOR_KEY_FILE)"
    )
    sources = _load_catalog(args.catalog)
    db = Path(_required(args.db, "--db (DATA_PLANE_DB)"))
    # The effect owner's journal holds the canonical operation for each pending
    # intent; this surface renders and signs that record, never a request body.
    journal = IntentStore(db)
    try:
        service = confirmation_service.ConfirmationService(
            operator_key,
            operator_token,
            sources,
            pending_record=lambda intent_id: pending_from_intent(
                journal.get_or_none(intent_id)
            ),
            reject_intent=lambda intent_id, reason: journal.update_state(
                intent_id, IntentState.REJECTED, error=reason
            ),
            max_ttl=args.approval_ttl,
        )
        common.serve(
            "confirmation",
            common.handler_for(service),
            port=args.port,
            host=args.host,
        )
    finally:
        journal.close()
    return 0


def _run_collector(args: argparse.Namespace) -> int:
    secret = _read_secret(args.secret_file)
    source = _required(
        args.source,
        "--source (DATA_PLANE_SOURCE)",
    )
    proxy_url = _required(
        args.proxy_url,
        "--proxy-url (DATA_PLANE_PROXY_URL)",
    )
    relay_url = _required(args.relay_url, "--relay-url (DATA_PLANE_RELAY_URL)")
    try:
        descriptor = collector_service.load_descriptor_source(
            args.schema or source, name=source
        )
    except (OSError, ValueError, DataPlaneError) as exc:
        raise ConfigError(f"cannot load collector schema: {exc}") from exc

    accepted: list[dict[str, Any]] = []
    relay = Relay(
        secret,
        descriptor.relay_schema(),
        accepted.append,
        source_id=descriptor.source_id,
    )
    collector = collector_service.Collector(
        source_id=source,
        descriptor=descriptor,
        proxy_url=proxy_url,
        relay=relay,
        fetcher=collector_service.fetch_json,
        submitter=collector_service.HttpRelaySubmitter(relay_url),
    )
    server = common.build_server(
        "collector",
        common.handler_for(
            relay_service.RelayService(relay, max_body_bytes=args.max_body_bytes)
        ),
        host=args.host,
        port=args.port,
    )
    thread = threading.Thread(
        target=server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True
    )
    thread.start()
    try:
        results = collector.collect()
        logging.getLogger("data_plane.collector").info(
            "collected %d records from %s", len(results), descriptor.source_id
        )
        thread.join()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        server.server_close()
        thread.join(5)
    return 0


_RUNNERS = {
    "event": _run_event,
    "broker": _run_broker,
    "relay": _run_relay,
    "confirmation": _run_confirmation,
    "collector": _run_collector,
}


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(list(sys.argv[1:] if argv is None else argv))
    if args.max_body_bytes < 1:
        print("data-plane: --max-body-bytes must be positive", file=sys.stderr)
        return 2
    logging.basicConfig(
        stream=sys.stderr,
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    try:
        return _RUNNERS[args.service](args)
    except (ConfigError, DataPlaneError) as exc:
        print(f"data-plane: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
