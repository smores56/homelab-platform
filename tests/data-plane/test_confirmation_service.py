"""Operator-only confirmation surface: authentication, validation, TTL, signing.

Every server binds 127.0.0.1 on an ephemeral port. The signing key and operator
token are test literals; no network or cluster is involved.
"""

from __future__ import annotations

import json
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
for candidate in (str(ROOT), str(ROOT / "libs")):
    if candidate not in sys.path:
        sys.path.insert(0, candidate)

from apps.data_plane import common, confirmation_service  # noqa: E402
from data_plane.approval import (  # noqa: E402
    SignedApprovalVerifier,
    UsedApprovalStore,
    pending_from_intent,
)
from data_plane.confirmation import NormalizedOperation, operation_hash  # noqa: E402
from data_plane.errors import ConfirmationError  # noqa: E402
from data_plane.intents import Intent as JournalIntent  # noqa: E402
from data_plane.intents import IntentStore  # noqa: E402
from data_plane.model import (  # noqa: E402
    Authority,
    Capability,
    EffectClass,
    FieldAuthority,
    IntentState,
    SourceContract,
    Visibility,
)

NOW = 1_000_000
OPERATOR_TOKEN = "separate-operator-token"
OPERATOR_KEY = b"separate-operator-signing-key"


class Harness:
    def __init__(self, service: object) -> None:
        self.server = common.build_server(
            "test", common.handler_for(service), port=0
        )
        self.thread = threading.Thread(
            target=lambda: self.server.serve_forever(poll_interval=0.02),
            daemon=True,
        )

    def __enter__(self) -> "Harness":
        self.thread.start()
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)

    def request(
        self,
        method: str,
        path: str,
        *,
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, object]:
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.server.server_address[1]}{path}",
            data=body,
            method=method,
            headers=dict(headers or {}),
        )
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                raw = response.read()
                return response.status, json.loads(raw) if raw else None
        except urllib.error.HTTPError as exc:
            try:
                raw = exc.read()
            finally:
                exc.close()
            return exc.code, json.loads(raw) if raw else None


def contract() -> SourceContract:
    return SourceContract(
        source_id="books",
        visibility=Visibility.GENERAL,
        version=1,
        recovery_group="books",
        stable_id_fields=("id",),
        capabilities=(
            Capability(name="read", effect=EffectClass.READ),
            Capability(name="create", effect=EffectClass.CREATE, reversible=True),
            Capability(
                name="delete",
                effect=EffectClass.DELETE,
                reversible=False,
                requires_confirmation=True,
            ),
        ),
        authority=(FieldAuthority(field="title", authority=Authority.PORTABLE_FILE),),
        revision_field="rev",
        tombstone_field="deleted_at",
        epoch=1,
    )


def operation(**overrides) -> dict:
    values = {
        "intent_id": "intent-1",
        "source_id": "books",
        "capability": "delete",
        "targets": ["book-1"],
        "base_revision": "rev-1",
        "field_diff": [["title", "Old", "New"]],
        "affected_count": 1,
        "epoch": 1,
        "recurrence": None,
        "attendee_scope": [],
        "destination": None,
    }
    values.update(overrides)
    return values


class ConfirmationServiceTests(unittest.TestCase):
    """The surface signs the journal's canonical record, never the request."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.journal = IntentStore(
            Path(self._tmp.name) / "intents.db", clock=lambda: NOW
        )
        self.addCleanup(self.journal.close)
        self.service = self._service()
        self.harness = Harness(self.service)
        self.harness.__enter__()
        self.addCleanup(self.harness.__exit__, None, None, None)

    def _service(self, operator_token: str | None = OPERATOR_TOKEN):
        return confirmation_service.ConfirmationService(
            OPERATOR_KEY,
            operator_token,
            {"books": contract()},
            pending_record=lambda intent_id: pending_from_intent(
                self.journal.get_or_none(intent_id)
            ),
            reject_intent=lambda intent_id, reason: self.journal.update_state(
                intent_id, IntentState.REJECTED, error=reason
            ),
            max_ttl=900,
            clock=lambda: NOW,
        )

    def seed(self, intent_id: str = "intent-1", expires_at: int = NOW + 900, **overrides):
        values = operation(intent_id=intent_id)
        values.update(overrides)
        op = NormalizedOperation.from_normalized(values)
        self.journal.create(
            JournalIntent(
                intent_id=intent_id,
                source_id=op.source_id,
                capability=op.capability,
                state=IntentState.AWAITING_CONFIRMATION,
                operation_hash=operation_hash(op),
                idempotency_key=f"key-{intent_id}",
                base_revision=op.base_revision,
                created_at=NOW,
                updated_at=NOW,
                expires_at=expires_at,
                attempts=0,
                result=None,
                error=None,
                operation=op.normalized(),
                requires_confirmation=True,
                run_id="run-1",
                pre_image={
                    "book-1": {"revision": "rev-1", "record": {"title": "Old"}}
                },
            )
        )
        return op

    def approve(
        self,
        payload: dict,
        *,
        token: str | None = OPERATOR_TOKEN,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, object]:
        merged = (
            dict(headers)
            if headers is not None
            else ({} if token is None else {confirmation_service.OPERATOR_TOKEN_HEADER: token})
        )
        return self.harness.request(
            "POST", "/approve", body=json.dumps(payload).encode(), headers=merged
        )

    def operator_headers(self) -> dict[str, str]:
        return {confirmation_service.OPERATOR_TOKEN_HEADER: OPERATOR_TOKEN}

    def test_operator_token_is_required(self) -> None:
        self.seed()
        payload = {"intent_id": "intent-1", "approved_by": "smores"}
        status, body = self.approve(payload, token=None)
        self.assertEqual(status, 401)
        self.assertEqual(body["error"]["code"], "unauthorized")

        status, body = self.approve(payload, token="wrong")
        self.assertEqual(status, 403)
        self.assertEqual(body["error"]["code"], "forbidden")
        self.assertNotIn("approval_token", body)

    def test_a_bearer_token_is_not_the_operator_header(self) -> None:
        self.seed()
        status, body = self.approve(
            {"intent_id": "intent-1", "approved_by": "smores"},
            headers={"Authorization": f"Bearer {OPERATOR_TOKEN}"},
        )
        self.assertEqual(status, 401)
        self.assertEqual(body["error"]["code"], "unauthorized")

    def test_a_service_without_an_operator_token_fails_closed(self) -> None:
        self.seed()
        with Harness(self._service(operator_token=None)) as harness:
            status, body = harness.request("POST", "/approve", body=b"{}")
        self.assertEqual(status, 503)
        self.assertEqual(body["error"]["code"], "unavailable")

    def test_pending_renders_the_stored_operation_and_pre_image(self) -> None:
        self.seed()
        status, body = self.harness.request(
            "GET", "/pending?intent_id=intent-1", headers=self.operator_headers()
        )

        self.assertEqual(status, 200)
        self.assertEqual(body["pending"]["intent_id"], "intent-1")
        self.assertIn('"book-1"', body["render"])
        self.assertIn("pre-image", body["render"])
        self.assertIn("Old", body["render"])

    def test_pending_requires_the_operator_and_a_known_intent(self) -> None:
        status, body = self.harness.request(
            "GET", "/pending?intent_id=intent-1", headers=self.operator_headers()
        )
        self.assertEqual(status, 409)

        self.seed()
        status, body = self.harness.request("GET", "/pending?intent_id=intent-1")
        self.assertEqual(status, 401)

    def test_a_caller_supplied_operation_is_refused(self) -> None:
        self.seed()
        for key in ("operation", "operation_hash", "targets", "field_diff"):
            status, body = self.approve(
                {"intent_id": "intent-1", "approved_by": "smores", key: operation()}
            )
            self.assertEqual(status, 400, key)
            self.assertEqual(body["error"]["code"], "validation")

    def test_tampered_intent_is_refused(self) -> None:
        self.seed("intent-src", source_id="other")
        status, _ = self.approve(
            {"intent_id": "intent-src", "approved_by": "smores"}
        )
        self.assertEqual(status, 400)

        self.seed("intent-epoch", epoch=99)
        status, body = self.approve(
            {"intent_id": "intent-epoch", "approved_by": "smores"}
        )
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "epoch")

        self.seed("intent-count", affected_count=5)
        status, _ = self.approve(
            {"intent_id": "intent-count", "approved_by": "smores"}
        )
        self.assertEqual(status, 400)

    def test_ttl_is_capped_by_the_service_and_the_intent(self) -> None:
        self.seed()
        status, body = self.approve(
            {"intent_id": "intent-1", "approved_by": "smores", "ttl": 901}
        )
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "validation")

        status, _ = self.approve(
            {"intent_id": "intent-1", "approved_by": "smores", "ttl": 0}
        )
        self.assertEqual(status, 400)

        status, body = self.approve(
            {"intent_id": "intent-1", "approved_by": "smores", "ttl": 60}
        )
        self.assertEqual(status, 200)
        self.assertEqual(
            body["claims"]["expires_at"] - body["claims"]["issued_at"], 60
        )

        self.seed("intent-soon", expires_at=NOW + 30)
        status, body = self.approve(
            {"intent_id": "intent-soon", "approved_by": "smores", "ttl": 300}
        )
        self.assertEqual(status, 200)
        self.assertEqual(body["claims"]["expires_at"], NOW + 30)

    def test_expired_intent_cannot_be_approved(self) -> None:
        self.seed(expires_at=NOW)
        status, body = self.approve(
            {"intent_id": "intent-1", "approved_by": "smores"}
        )
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "conflict")

    def test_signed_token_verifies_against_the_stored_operation(self) -> None:
        op = self.seed()
        status, body = self.approve(
            {"intent_id": "intent-1", "approved_by": "smores"}
        )
        self.assertEqual(status, 200)
        self.assertEqual(body["claims"]["operation_hash"], operation_hash(op))
        self.assertEqual(body["claims"]["approved_by"], "smores")

        store = UsedApprovalStore()
        self.addCleanup(store.close)
        verifier = SignedApprovalVerifier(
            OPERATOR_KEY, store, clock=lambda: NOW, max_ttl=900
        )
        verified = verifier.verify(body["approval_token"], op)
        self.assertEqual(verified.approved_by, "smores")
        with self.assertRaises(ConfirmationError):
            verifier.verify(body["approval_token"], op)

    def test_reject_is_operator_only_and_settles_the_intent(self) -> None:
        self.seed()
        status, body = self.harness.request(
            "POST",
            "/reject",
            body=json.dumps({"intent_id": "intent-1", "approved_by": "smores"}).encode(),
        )
        self.assertEqual(status, 401)

        status, body = self.harness.request(
            "POST",
            "/reject",
            body=json.dumps(
                {"intent_id": "intent-1", "approved_by": "smores", "reason": "no"}
            ).encode(),
            headers=self.operator_headers(),
        )
        self.assertEqual(status, 200)
        self.assertIs(
            self.journal.get("intent-1").state, IntentState.REJECTED
        )

        status, _ = self.approve(
            {"intent_id": "intent-1", "approved_by": "smores"}
        )
        self.assertEqual(status, 409)

    def test_healthz_is_minimal_and_needs_no_token(self) -> None:
        status, body = self.harness.request("GET", "/healthz")
        self.assertEqual(status, 200)
        self.assertEqual(body, {"status": "ok", "service": "confirmation"})

    def test_only_the_operator_routes_exist(self) -> None:
        self.assertEqual(
            set(self.service.routes),
            {
                ("GET", "/pending"),
                ("POST", "/approve"),
                ("POST", "/reject"),
                ("GET", "/healthz"),
            },
        )
        status, _ = self.harness.request(
            "POST",
            "/confirm",
            body=json.dumps({"intent_id": "intent-1"}).encode(),
            headers=self.operator_headers(),
        )
        self.assertEqual(status, 404)


if __name__ == "__main__":
    unittest.main()
