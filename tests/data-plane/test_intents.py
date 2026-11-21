"""Intent journal state machine, idempotency, and expiry tests."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from data_plane.errors import (
    ConfirmationError,
    ConfirmationRequired,
    IdempotencyConflict,
    OutcomeUnknown,
    ValidationError,
)
from data_plane.event_log import EventLog
from data_plane.intents import IntentStore, TransitionError, UnknownIntent
from data_plane.model import IntentState


class IntentStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.path = Path(self._tmp.name) / "journal" / "intents.db"
        self.now = 1_000_000.0
        self.store = IntentStore(self.path, clock=lambda: self.now)
        self.addCleanup(self.store.close)

    def propose(self, **overrides):
        values = dict(
            source_id="books",
            capability="update",
            operation_hash="hash-1",
            idempotency_key="op-1",
            base_revision="rev-4",
            ttl=900,
        )
        values.update(overrides)
        return self.store.propose(**values)

    def apply(self, intent) -> None:
        self.store.mark_applying(intent.intent_id)

    def test_propose_records_a_fresh_proposal(self):
        intent = self.propose()
        self.assertTrue(intent.intent_id)
        self.assertEqual(intent.state, IntentState.PROPOSED)
        self.assertEqual(intent.source_id, "books")
        self.assertEqual(intent.capability, "update")
        self.assertEqual(intent.base_revision, "rev-4")
        self.assertEqual(intent.attempts, 0)
        self.assertIsNone(intent.result)
        self.assertIsNone(intent.error)
        self.assertEqual(intent.created_at, self.now)
        self.assertEqual(intent.updated_at, self.now)
        self.assertEqual(intent.expires_at, self.now + 900)
        self.assertFalse(intent.terminal)
        self.assertEqual(self.store.get(intent.intent_id), intent)

    def test_happy_path(self):
        intent = self.propose()
        applying = self.store.mark_applying(intent.intent_id)
        self.assertEqual(applying.state, IntentState.APPLYING)
        self.assertEqual(applying.attempts, 1)
        applied = self.store.mark_applied(intent.intent_id, {"affected": 1})
        self.assertEqual(applied.state, IntentState.APPLIED)
        self.assertEqual(applied.result, {"affected": 1})
        self.assertEqual(applied.attempts, 1)
        self.assertTrue(applied.terminal)

    def test_confirmation_path(self):
        intent = self.propose()
        awaiting = self.store.transition(
            intent.intent_id, IntentState.AWAITING_CONFIRMATION
        )
        self.assertEqual(awaiting.state, IntentState.AWAITING_CONFIRMATION)
        with self.assertRaises(TransitionError):
            self.store.transition(intent.intent_id, IntentState.APPLIED)
        with self.assertRaises(TransitionError):
            self.store.mark_applying(intent.intent_id)
        approved = self.store.transition(intent.intent_id, IntentState.APPROVED)
        self.assertEqual(approved.state, IntentState.APPROVED)
        self.assertEqual(
            self.store.mark_applying(intent.intent_id).state, IntentState.APPLYING
        )

    def test_transitions_accept_the_string_form_of_a_state(self):
        intent = self.propose()
        self.assertEqual(
            self.store.transition(intent.intent_id, "rejected").state,
            IntentState.REJECTED,
        )
        with self.assertRaises(ValidationError):
            self.store.transition(intent.intent_id, "not-a-state")

    def test_illegal_transitions_are_refused(self):
        intent = self.propose()
        with self.assertRaises(TransitionError):
            self.store.transition(intent.intent_id, IntentState.APPLIED)
        with self.assertRaises(TransitionError):
            self.store.transition(intent.intent_id, IntentState.OUTCOME_UNKNOWN)
        with self.assertRaises(TransitionError):
            self.store.mark_applied(intent.intent_id, {"affected": 1})
        self.assertEqual(self.store.get(intent.intent_id).state, IntentState.PROPOSED)
        self.apply(intent)
        with self.assertRaises(TransitionError):
            self.store.transition(intent.intent_id, IntentState.PROPOSED)
        self.store.mark_applied(intent.intent_id)
        with self.assertRaises(TransitionError):
            self.store.mark_applying(intent.intent_id)
        with self.assertRaises(TransitionError):
            self.store.transition(intent.intent_id, IntentState.FAILED)
        self.assertEqual(self.store.get(intent.intent_id).state, IntentState.APPLIED)
        self.assertEqual(self.store.get(intent.intent_id).attempts, 1)

    def test_failed_is_terminal(self):
        intent = self.propose()
        self.apply(intent)
        failed = self.store.mark_failed(intent.intent_id, "provider rejected")
        self.assertEqual(failed.state, IntentState.FAILED)
        self.assertEqual(failed.error, "provider rejected")
        self.assertTrue(failed.terminal)
        with self.assertRaises(TransitionError):
            self.store.mark_applying(intent.intent_id)
        with self.assertRaises(TransitionError):
            self.store.mark_applied(intent.intent_id, {"affected": 1})

    def test_mark_failed_requires_an_error(self):
        intent = self.propose()
        with self.assertRaises(ValidationError):
            self.store.mark_failed(intent.intent_id, "  ")
        self.assertEqual(self.store.get(intent.intent_id).state, IntentState.PROPOSED)

    def test_unknown_outcome_blocks_a_blind_replay(self):
        intent = self.propose()
        self.apply(intent)
        unknown = self.store.mark_outcome_unknown(intent.intent_id, "timeout")
        self.assertEqual(unknown.state, IntentState.OUTCOME_UNKNOWN)
        self.assertEqual(unknown.error, "timeout")
        with self.assertRaises(OutcomeUnknown):
            self.store.mark_applying(intent.intent_id)
        with self.assertRaises(OutcomeUnknown):
            self.store.transition(intent.intent_id, IntentState.APPLYING)
        stored = self.store.get(intent.intent_id)
        self.assertEqual(stored.state, IntentState.OUTCOME_UNKNOWN)
        self.assertEqual(stored.attempts, 1)

    def test_resolve_unknown_requires_a_result(self):
        intent = self.propose()
        self.apply(intent)
        self.store.mark_outcome_unknown(intent.intent_id)
        with self.assertRaises(ValidationError):
            self.store.resolve_unknown(intent.intent_id, None)
        with self.assertRaises(TransitionError):
            self.store.transition(intent.intent_id, IntentState.APPLIED)
        self.assertEqual(
            self.store.get(intent.intent_id).state, IntentState.OUTCOME_UNKNOWN
        )
        resolved = self.store.resolve_unknown(intent.intent_id, {"verified": True})
        self.assertEqual(resolved.state, IntentState.APPLIED)
        self.assertEqual(resolved.result, {"verified": True})
        self.assertTrue(resolved.terminal)
        with self.assertRaises(TransitionError):
            self.store.resolve_unknown(intent.intent_id, {"verified": True})

    def test_resolve_unknown_requires_the_unknown_state(self):
        intent = self.propose()
        with self.assertRaises(TransitionError):
            self.store.resolve_unknown(intent.intent_id, {"verified": True})
        self.assertEqual(self.store.get(intent.intent_id).state, IntentState.PROPOSED)

    def test_repeated_propose_is_idempotent(self):
        first = self.propose()
        self.assertEqual(self.propose(), first)

    def test_find_looks_an_intent_up_by_idempotency_key(self):
        intent = self.propose()
        self.assertEqual(self.store.find("op-1"), intent)
        self.assertIsNone(self.store.find("op-missing"))

    def test_same_key_with_a_different_operation_conflicts(self):
        self.propose()
        with self.assertRaises(IdempotencyConflict):
            self.propose(operation_hash="hash-2")

    def test_overdue_and_expiry(self):
        intent = self.propose(ttl=60)
        self.assertEqual(self.store.overdue(), [])
        self.now += 61
        self.assertEqual(
            [item.intent_id for item in self.store.overdue()], [intent.intent_id]
        )
        expired = self.store.transition(intent.intent_id, IntentState.EXPIRED)
        self.assertEqual(expired.state, IntentState.EXPIRED)
        self.assertTrue(expired.terminal)
        self.assertEqual(self.store.overdue(), [])
        with self.assertRaises(TransitionError):
            self.store.mark_applying(intent.intent_id)

    def test_overdue_accepts_an_explicit_now(self):
        intent = self.propose(ttl=60)
        self.assertEqual(self.store.overdue(now=self.now + 59), [])
        self.assertEqual(
            [item.intent_id for item in self.store.overdue(now=self.now + 60)],
            [intent.intent_id],
        )

    def test_applied_intents_are_never_overdue(self):
        intent = self.propose(ttl=1)
        self.apply(intent)
        self.store.mark_applied(intent.intent_id)
        self.now += 10
        self.assertEqual(self.store.overdue(), [])

    def test_applying_intents_are_not_expired(self):
        intent = self.propose(ttl=10)
        self.apply(intent)
        self.now += 11
        self.assertEqual(self.store.overdue(), [])
        self.assertEqual(self.store.get(intent.intent_id).state, IntentState.APPLYING)

    def test_state_survives_a_reopen(self):
        intent = self.propose()
        self.apply(intent)
        self.store.close()
        reopened = IntentStore(self.path, clock=lambda: self.now)
        self.addCleanup(reopened.close)
        stored = reopened.get(intent.intent_id)
        self.assertEqual(stored.state, IntentState.APPLYING)
        self.assertEqual(stored.attempts, 1)

    def test_propose_rejects_empty_fields_and_bad_ttl(self):
        with self.assertRaises(ValidationError):
            self.propose(source_id="")
        with self.assertRaises(ValidationError):
            self.propose(capability=" ")
        with self.assertRaises(ValidationError):
            self.propose(operation_hash="")
        with self.assertRaises(ValidationError):
            self.propose(idempotency_key="  ")
        with self.assertRaises(ValidationError):
            self.propose(ttl=0)

    def test_shares_a_database_file_with_the_event_log(self):
        intent = self.propose()
        with EventLog(self.path) as log:
            event = log.append("book.updated", "book-1", {"title": "Dune"})
            self.assertEqual(event.position, 1)
        self.assertEqual(self.store.get(intent.intent_id), intent)

    def test_unknown_intent_is_reported(self):
        with self.assertRaises(UnknownIntent):
            self.store.get("intent-missing")
        with self.assertRaises(UnknownIntent):
            self.store.transition("intent-missing", IntentState.APPLYING)
        with self.assertRaises(UnknownIntent):
            self.store.mark_applying("intent-missing")


class ApprovalJournalTests(unittest.TestCase):
    """The journal is the effect owner's approval ledger.

    An approval is a row the broker writes, spends once, and reads back after a
    restart. Consumption happens in the same transaction that reserves the
    effect, so a crash between the two cannot leave an unspent approval behind a
    reserved effect.
    """

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.path = Path(self._tmp.name) / "journal" / "intents.db"
        self.now = 1_000_000.0
        self.store = IntentStore(self.path, clock=lambda: self.now)
        self.addCleanup(self.store.close)

    def propose(self, **overrides):
        values = dict(
            source_id="notes",
            capability="update",
            operation_hash="a" * 64,
            idempotency_key="op-1",
            base_revision="rev-1",
            ttl=900,
        )
        values.update(overrides)
        return self.store.propose(**values)

    def approval(self, intent, **overrides):
        values = dict(
            intent_id=intent.intent_id,
            operation_hash=intent.operation_hash,
            epoch=1,
            approved_by="smores",
            issued_at=int(self.now),
            expires_at=int(self.now) + 60,
            nonce="n" * 32,
        )
        values.update(overrides)
        return values

    def awaiting(self, **overrides):
        intent = self.propose(**overrides)
        self.store.update_state(
            intent.intent_id,
            IntentState.AWAITING_CONFIRMATION,
            operation={"intent_id": intent.intent_id, "epoch": 1},
        )
        return self.store.get(intent.intent_id)

    def test_pre_image_and_run_are_persisted(self):
        intent = self.propose(run_id="run-1")
        pre_image = {"note-1": {"revision": "rev-1", "record": {"title": "Old"}}}
        updated = self.store.set_pre_image(intent.intent_id, pre_image)

        self.assertIsNone(intent.pre_image)
        self.assertEqual(updated.pre_image, pre_image)
        self.assertEqual(updated.run_id, "run-1")
        self.assertEqual(self.store.get(intent.intent_id).pre_image, pre_image)

    def test_editing_the_pre_image_invalidates_a_recorded_approval(self):
        intent = self.awaiting()
        self.store.approve(intent.intent_id, self.approval(intent), now=self.now)

        edited = self.store.set_pre_image(intent.intent_id, {"note-1": {"record": {}}})

        self.assertIsNone(edited.approval)

    def test_approve_records_the_approval_once(self):
        intent = self.awaiting()
        approval = self.approval(intent)

        approved = self.store.approve(intent.intent_id, approval, now=self.now)

        self.assertEqual(approved.state, IntentState.APPROVED)
        self.assertEqual(approved.approval["approved_by"], "smores")
        self.assertEqual(approved.approval["nonce"], approval["nonce"])
        self.assertEqual(self.store.get(intent.intent_id).approval, approved.approval)

    def test_a_nonce_is_single_use_across_reopen(self):
        intent = self.awaiting()
        approval = self.approval(intent)
        self.store.approve(intent.intent_id, approval, now=self.now)
        self.store.close()

        reopened = IntentStore(self.path, clock=lambda: self.now)
        self.addCleanup(reopened.close)
        with self.assertRaises(ConfirmationError):
            reopened.reserve(intent.intent_id, approval, now=self.now)

    def test_approval_for_another_operation_is_refused(self):
        intent = self.awaiting()
        with self.assertRaises(ConfirmationError):
            self.store.approve(
                intent.intent_id, self.approval(intent, operation_hash="b" * 64),
                now=self.now,
            )
        with self.assertRaises(ConfirmationError):
            self.store.approve(
                intent.intent_id, self.approval(intent, epoch=2), now=self.now
            )
        with self.assertRaises(ConfirmationError):
            self.store.approve(
                intent.intent_id, self.approval(intent, intent_id="intent-other"),
                now=self.now,
            )
        self.assertEqual(
            self.store.get(intent.intent_id).state, IntentState.AWAITING_CONFIRMATION
        )

    def test_a_malformed_approval_is_refused(self):
        intent = self.awaiting()
        for broken in (
            self.approval(intent, approved_by=""),
            self.approval(intent, nonce="short"),
            self.approval(intent, expires_at=int(self.now)),
            self.approval(intent, epoch=0),
        ):
            with self.assertRaises(ConfirmationError):
                self.store.approve(intent.intent_id, broken, now=self.now)

    def test_expired_intent_cannot_be_approved(self):
        intent = self.awaiting(ttl=60)
        self.now += 61
        with self.assertRaises(ConfirmationError):
            self.store.approve(intent.intent_id, self.approval(intent), now=self.now)
        self.assertEqual(self.store.get(intent.intent_id).state, IntentState.EXPIRED)

    def test_approval_that_outlives_the_intent_is_refused(self):
        intent = self.awaiting(ttl=60)
        with self.assertRaises(ConfirmationError):
            self.store.approve(
                intent.intent_id,
                self.approval(intent, expires_at=int(self.now) + 120),
                now=self.now,
            )
        self.assertEqual(
            self.store.get(intent.intent_id).state, IntentState.AWAITING_CONFIRMATION
        )

    def test_reserve_consumes_the_approval_and_reserves_the_effect(self):
        intent = self.awaiting()
        approval = self.approval(intent)

        reserved = self.store.reserve(intent.intent_id, approval, now=self.now)

        self.assertEqual(reserved.state, IntentState.APPLYING)
        self.assertEqual(reserved.attempts, 1)
        self.assertEqual(reserved.approval["nonce"], approval["nonce"])
        with self.assertRaises(ConfirmationError):
            self.store.reserve(intent.intent_id, approval, now=self.now)

    def test_reserve_without_an_approval_is_refused(self):
        intent = self.awaiting()
        with self.assertRaises(ConfirmationRequired):
            self.store.reserve(intent.intent_id, None, now=self.now)
        self.assertEqual(
            self.store.get(intent.intent_id).state, IntentState.AWAITING_CONFIRMATION
        )

    def test_reserve_of_an_approved_intent_needs_no_second_approval(self):
        intent = self.awaiting()
        self.store.approve(intent.intent_id, self.approval(intent), now=self.now)

        reserved = self.store.reserve(intent.intent_id, None, now=self.now)

        self.assertEqual(reserved.state, IntentState.APPLYING)
        self.assertEqual(reserved.approval["approved_by"], "smores")

    def test_routine_effects_are_counted_per_run(self):
        first = self.propose(idempotency_key="op-1", run_id="run-1")
        self.propose(idempotency_key="op-2", run_id="run-1")
        self.propose(idempotency_key="op-3", run_id="run-2")

        self.assertEqual(self.store.routine_effects("run-1"), 0)
        self.store.transition(first.intent_id, IntentState.APPROVED)
        self.store.reserve(first.intent_id, None, now=self.now)

        self.assertEqual(self.store.routine_effects("run-1"), 1)
        self.assertEqual(
            self.store.routine_effects("run-1", exclude_intent_id=first.intent_id), 0
        )

    def test_confirmed_effects_do_not_spend_the_routine_budget(self):
        intent = self.propose(idempotency_key="op-1", run_id="run-1")
        self.store.update_state(
            intent.intent_id,
            IntentState.AWAITING_CONFIRMATION,
            requires_confirmation=True,
        )
        self.store.approve(intent.intent_id, self.approval(intent), now=self.now)
        self.store.reserve(intent.intent_id, None, now=self.now)

        self.assertEqual(self.store.routine_effects("run-1"), 0)

    def test_cancel_pending_invalidates_every_unstarted_approval(self):
        waiting = self.awaiting(idempotency_key="op-1")
        approved = self.awaiting(idempotency_key="op-2")
        self.store.approve(approved.intent_id, self.approval(approved), now=self.now)
        applied = self.propose(idempotency_key="op-3")
        self.store.transition(applied.intent_id, IntentState.APPROVED)
        self.store.reserve(applied.intent_id, None, now=self.now)

        cancelled = self.store.cancel_pending(reason="restore")

        self.assertEqual(
            sorted(cancelled), sorted([waiting.intent_id, approved.intent_id])
        )
        self.assertEqual(self.store.get(waiting.intent_id).state, IntentState.EXPIRED)
        self.assertEqual(self.store.get(approved.intent_id).state, IntentState.EXPIRED)
        self.assertEqual(self.store.get(applied.intent_id).state, IntentState.APPLYING)


if __name__ == "__main__":
    unittest.main()
