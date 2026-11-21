"""Routine effects, pre-images, and exact-effect approval over the real journal.

Everything here uses the production SQLite intent journal through
``BrokerJournal``; no adapter touches the network. The approval surface is
exercised as a library call, so the tests prove the broker's own binding rather
than an HTTP round trip.
"""

from __future__ import annotations

import tempfile
import threading
import time
import unittest
from pathlib import Path

from data_plane.approval import (
    ApprovalAuthority,
    SignedApprovalVerifier,
    UsedApprovalStore,
    pending_from_intent,
)
from data_plane.broker import Broker, WriteRequest
from data_plane.broker_journal import BrokerJournal
from data_plane.confirmation import FieldChange, NormalizedOperation
from data_plane.errors import (
    ConfirmationError,
    DataPlaneError,
    ConfirmationRequired,
    StaleError,
    ValidationError,
)
from data_plane.identity import LOCAL_PROFILE, IdentityIssuer
from data_plane.intents import IntentStore
from data_plane.model import (
    Authority,
    Capability,
    EffectClass,
    FieldAuthority,
    IntentState,
    SourceContract,
    Visibility,
)

KEY = b"broker-effects-test-key"
NOW = 1_000_000


def contract(source_id: str = "notes", visibility: Visibility = Visibility.PERSONAL):
    return SourceContract(
        source_id=source_id,
        visibility=visibility,
        version=1,
        recovery_group=source_id,
        stable_id_fields=("id",),
        capabilities=(
            Capability(name="read", effect=EffectClass.READ),
            Capability(name="create", effect=EffectClass.CREATE, reversible=True),
            Capability(name="update", effect=EffectClass.UPDATE, reversible=True),
            Capability(
                name="delete",
                effect=EffectClass.DELETE,
                reversible=False,
                requires_confirmation=True,
            ),
        ),
        authority=(
            FieldAuthority(field="title", authority=Authority.PORTABLE_FILE),
            FieldAuthority(field="owner", authority=Authority.HUMAN),
        ),
        revision_field="rev",
        tombstone_field="deleted_at",
    )


class FakeAdapter:
    def __init__(self, records: dict[str, dict] | None = None) -> None:
        self.records = {key: dict(value) for key, value in (records or {}).items()}
        self.applies: list[tuple[str, str]] = []
        self.delay = 0.0

    def revision(self, target: str) -> str | None:
        return self.records.get(target, {}).get("rev")

    def read(self, target: str) -> dict:
        return dict(self.records.get(target, {}))

    def search(self, query: str) -> list[dict]:
        return [
            dict(record)
            for record in self.records.values()
            if query.lower() in str(record.get("title", "")).lower()
        ]

    def apply(self, operation: NormalizedOperation, idempotency_key: str) -> dict:
        if self.delay:
            time.sleep(self.delay)
        self.applies.append((operation.intent_id, idempotency_key))
        for target in operation.targets:
            if operation.capability == "delete":
                self.records.pop(target, None)
                continue
            record = self.records.setdefault(target, {"id": target})
            for change in operation.field_diff:
                record[change.field] = change.after
            record["rev"] = f"rev-{len(self.applies) + 1}"
        return {"applied": len(operation.targets)}


class RecordingRecorder:
    def __init__(self) -> None:
        self.events: list[dict] = []

    def record(self, event: dict) -> None:
        if any(item.get("intent_id") == event.get("intent_id") for item in self.events):
            return
        self.events.append(dict(event))


class EffectPathTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.now = float(NOW)
        self.journal = IntentStore(
            Path(self._tmp.name) / "journal" / "intents.db", clock=lambda: self.now
        )
        self.addCleanup(self.journal.close)
        self.sources = {"notes": contract()}
        self.adapter = FakeAdapter(
            {
                "note-1": {"id": "note-1", "title": "Old", "rev": "rev-1"},
                "note-2": {"id": "note-2", "title": "Older", "rev": "rev-1"},
            }
        )
        self.issuer = IdentityIssuer(self.sources, KEY, clock=lambda: self.now)
        self.recorder = RecordingRecorder()
        self.approvals = UsedApprovalStore()
        self.addCleanup(self.approvals.close)
        self.verifier = SignedApprovalVerifier(
            KEY, self.approvals, clock=lambda: self.now, max_ttl=900
        )
        self.broker = self.broker_for(self.verifier)

    def broker_for(self, verifier) -> Broker:
        return Broker(
            self.sources,
            {"notes": self.adapter},
            self.issuer,
            None,
            BrokerJournal(self.journal),
            self.recorder,
            clock=lambda: self.now,
            approval_verifier=verifier,
        )

    def claims(self, *scopes: tuple[str, str]):
        return self.issuer.verify(
            self.issuer.issue(LOCAL_PROFILE, "agent", scopes)
        )

    def authority(self, ttl: int = 300) -> ApprovalAuthority:
        return ApprovalAuthority(
            lambda intent_id: pending_from_intent(
                self.journal.get_or_none(intent_id)
            ),
            KEY,
            ttl=ttl,
            clock=lambda: self.now,
        )

    def update(self, **overrides) -> WriteRequest:
        values = dict(
            source_id="notes",
            capability="update",
            targets=("note-1",),
            idempotency_key="update-1",
            field_diff=(FieldChange(field="title", before="Old", after="New"),),
            base_revision="rev-1",
            run_id="run-1",
        )
        values.update(overrides)
        return WriteRequest(**values)

    def delete(self, **overrides) -> WriteRequest:
        values = dict(
            source_id="notes",
            capability="delete",
            targets=("note-1",),
            idempotency_key="delete-1",
            base_revision="rev-1",
        )
        values.update(overrides)
        return WriteRequest(**values)

    # -- routine writes -------------------------------------------------

    def test_a_routine_write_records_the_pre_image_and_base_revision(self) -> None:
        write = self.update()
        intent, operation = self.broker.propose(
            self.claims(("notes", "update")), write
        )

        stored = self.journal.get(intent.intent_id)
        self.assertEqual(stored.run_id, "run-1")
        self.assertEqual(stored.base_revision, "rev-1")
        self.assertEqual(
            stored.pre_image,
            {"note-1": {"revision": "rev-1", "record": {"id": "note-1", "title": "Old", "rev": "rev-1"}}},
        )
        self.assertEqual(operation.base_revision, "rev-1")

        self.broker.apply(self.claims(("notes", "update")), write)

        event = self.recorder.events[0]
        self.assertEqual(event["pre_image"], stored.pre_image)
        self.assertEqual(self.adapter.records["note-1"]["title"], "New")

    def test_a_stale_pin_is_refused_before_the_intent_exists(self) -> None:
        self.adapter.records["note-1"]["rev"] = "rev-2"
        with self.assertRaises(StaleError):
            self.broker.propose(self.claims(("notes", "update")), self.update())
        self.assertIsNone(self.journal.find("update-1"))

    def test_a_routine_write_needs_a_run(self) -> None:
        with self.assertRaises(ValidationError):
            self.broker.propose(
                self.claims(("notes", "update")), self.update(run_id=None)
            )

    def test_a_create_without_pinning_the_absence_is_still_routine(self) -> None:
        write = self.update(
            capability="create",
            targets=("note-3",),
            base_revision=None,
            field_diff=(FieldChange(field="title", before=None, after="Draft"),),
            idempotency_key="create-1",
        )
        intent, _ = self.broker.propose(self.claims(("notes", "create")), write)

        self.assertIs(intent.state, IntentState.APPROVED)
        self.assertEqual(
            self.journal.get(intent.intent_id).pre_image,
            {"note-3": {"revision": None, "record": {}}},
        )

    # -- bulk is measured per user intent/run ---------------------------

    def test_two_targets_need_an_exact_target_set_approval(self) -> None:
        write = self.update(targets=("note-1", "note-2"), idempotency_key="bulk-1")
        intent, operation = self.broker.propose(
            self.claims(("notes", "update")), write
        )

        self.assertIs(intent.state, IntentState.AWAITING_CONFIRMATION)
        self.assertEqual(operation.targets, ("note-1", "note-2"))
        with self.assertRaises(ConfirmationRequired):
            self.broker.apply(self.claims(("notes", "update")), write)

        _, token = self.authority().approve(intent.intent_id, "smores")
        self.broker.apply(self.claims(("notes", "update")), write, token)

        self.assertEqual(self.adapter.records["note-2"]["title"], "New")

    def test_a_second_routine_effect_in_one_run_needs_approval(self) -> None:
        first = self.claims(("notes", "update"))
        self.broker.propose(first, self.update(idempotency_key="run-1-a"))
        self.broker.apply(first, self.update(idempotency_key="run-1-a"))

        second = self.update(
            targets=("note-2",), idempotency_key="run-1-b", base_revision="rev-1"
        )
        intent, _ = self.broker.propose(first, second)

        self.assertIs(intent.state, IntentState.AWAITING_CONFIRMATION)
        with self.assertRaises(ConfirmationRequired):
            self.broker.apply(first, second)

        _, token = self.authority().approve(intent.intent_id, "smores")
        self.broker.apply(first, second, token)
        self.assertEqual(self.adapter.records["note-2"]["title"], "New")

    def test_another_run_gets_its_own_budget(self) -> None:
        claims = self.claims(("notes", "update"))
        self.broker.propose(claims, self.update(idempotency_key="run-a"))
        self.broker.apply(claims, self.update(idempotency_key="run-a"))

        intent, _ = self.broker.propose(
            claims, self.update(targets=("note-2",), idempotency_key="run-b", run_id="run-2")
        )

        self.assertIs(intent.state, IntentState.APPROVED)

    # -- exact-effect approval -------------------------------------------

    def test_the_approval_surface_signs_the_journal_record(self) -> None:
        claims = self.claims(("notes", "delete"))
        write = self.delete()
        intent, _ = self.broker.propose(claims, write)

        card = self.authority().render(intent.intent_id)
        self.assertIn('"note-1"', card)
        self.assertIn("delete", card)

        approval, token = self.authority().approve(intent.intent_id, "smores")
        self.assertEqual(self.journal.used_approval(approval.nonce), False)

        self.broker.apply(claims, write, token)

        stored = self.journal.get(intent.intent_id)
        self.assertIs(stored.state, IntentState.APPLIED)
        self.assertEqual(stored.approval["approved_by"], "smores")
        self.assertEqual(stored.approval["nonce"], approval.nonce)
        self.assertTrue(self.journal.used_approval(approval.nonce))
        self.assertEqual(self.recorder.events[0]["approval"]["approved_by"], "smores")

    def test_a_confirmed_intent_applies_without_a_token_after_a_restart(self) -> None:
        claims = self.claims(("notes", "delete"))
        write = self.delete()
        intent, _ = self.broker.propose(claims, write)
        _, token = self.authority().approve(intent.intent_id, "smores")
        self.broker.confirm(claims, write, token)

        restarted = self.broker_for(
            SignedApprovalVerifier(
                KEY, self.approvals, clock=lambda: self.now, max_ttl=900
            )
        )
        effect = restarted.apply(claims, write)

        self.assertEqual(effect, {"applied": 1})
        self.assertIs(self.journal.get(intent.intent_id).state, IntentState.APPLIED)

    def test_a_token_for_another_intent_cannot_approve(self) -> None:
        claims = self.claims(("notes", "delete"))
        first, _ = self.broker.propose(claims, self.delete())
        other = self.delete(idempotency_key="delete-2", targets=("note-2",))
        second, _ = self.broker.propose(claims, other)
        _, token = self.authority().approve(first.intent_id, "smores")

        with self.assertRaises(ConfirmationError):
            self.broker.apply(claims, other, token)

        self.assertIs(
            self.journal.get(second.intent_id).state, IntentState.AWAITING_CONFIRMATION
        )

    def test_an_expired_approval_is_refused(self) -> None:
        claims = self.claims(("notes", "delete"))
        write = self.delete()
        intent, _ = self.broker.propose(claims, write)
        _, token = self.authority(ttl=60).approve(intent.intent_id, "smores")

        self.now += 61

        with self.assertRaises(ConfirmationError):
            self.broker.apply(claims, write, token)
        self.assertIn("note-1", self.adapter.records)
        self.assertIs(
            self.journal.get(intent.intent_id).state, IntentState.AWAITING_CONFIRMATION
        )

    def test_an_overdue_intent_expires_instead_of_applying(self) -> None:
        claims = self.claims(("notes", "delete"))
        write = self.delete()
        intent, _ = self.broker.propose(claims, write)

        self.now += 901

        with self.assertRaises(ConfirmationError):
            self.authority().approve(intent.intent_id, "smores")
        with self.assertRaises(ConfirmationError):
            self.broker.apply(claims, write)
        self.assertIs(self.journal.get(intent.intent_id).state, IntentState.EXPIRED)
        self.assertIn("note-1", self.adapter.records)

    def test_a_restore_cancels_pending_approvals(self) -> None:
        claims = self.claims(("notes", "delete"))
        write = self.delete()
        intent, _ = self.broker.propose(claims, write)
        _, token = self.authority().approve(intent.intent_id, "smores")

        self.journal.cancel_pending(reason="restore")

        with self.assertRaises(ConfirmationError):
            self.authority().render(intent.intent_id)
        with self.assertRaises(ConfirmationError):
            self.broker.apply(claims, write, token)
        self.assertIn("note-1", self.adapter.records)

    def test_one_approval_cannot_pay_for_two_applies(self) -> None:
        claims = self.claims(("notes", "delete"))
        write = self.delete()
        intent, _ = self.broker.propose(claims, write)
        _, token = self.authority().approve(intent.intent_id, "smores")
        other = self.broker_for(
            SignedApprovalVerifier(
                KEY, self.approvals, clock=lambda: self.now, max_ttl=900
            )
        )
        self.adapter.delay = 0.05

        results: list[object] = []

        def run(broker: Broker) -> None:
            try:
                results.append(broker.apply(claims, write, token))
            except Exception as exc:  # noqa: BLE001 - recorded for assertion
                results.append(exc)

        threads = [threading.Thread(target=run, args=(broker,)) for broker in (self.broker, other)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()

        self.assertEqual(len(self.adapter.applies), 1)
        for result in results:
            self.assertIsInstance(result, (dict, DataPlaneError), result)
        self.assertTrue(any(isinstance(result, dict) for result in results))

    def test_editing_an_approved_intent_reopens_the_approval(self) -> None:
        claims = self.claims(("notes", "delete"))
        write = self.delete()
        intent, _ = self.broker.propose(claims, write)
        _, token = self.authority().approve(intent.intent_id, "smores")
        self.broker.confirm(claims, write, token)

        edited = self.journal.set_pre_image(intent.intent_id, {"note-1": {"record": {}}})

        self.assertIs(edited.state, IntentState.AWAITING_CONFIRMATION)
        self.assertIsNone(edited.approval)
        with self.assertRaises(ConfirmationRequired):
            self.broker.apply(claims, write)
        with self.assertRaises(ConfirmationError):
            self.broker.apply(claims, write, token)
        self.assertIn("note-1", self.adapter.records)


if __name__ == "__main__":
    unittest.main()
