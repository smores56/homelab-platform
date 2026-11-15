"""Migration gates: ordered phases, the plan-driven backup gate, verification.

The package never executes a destructive step. ``preflight`` proves the backup
chain from the host plan; the phase gates consume its single readiness fact.
The migration plan, the data-loss gate, and the old-system rollback can be
reviewed and tested before an operator runs anything.
"""

from __future__ import annotations

from .phases import (
    PHASES,
    PHASE_NAMES,
    Gate,
    GateBlocked,
    GateFailure,
    MigrationError,
    Phase,
    advance,
    check_advance,
    confirmation_missing,
    confirmation_phases,
    evidence_keys_for,
    irreversible_phases,
    next_phase,
    phase,
    required_evidence_keys,
)
from .preflight import (
    GateReport,
    GateRunner,
    GroupCheck,
    ReadDataCheck,
    ResticGateRunner,
    run_gate,
)
from .rollback import (
    ROLLBACK_CONFIRMATION,
    ROLLBACK_STEP_NAMES,
    RollbackBackend,
    RollbackError,
    RollbackPlan,
    RollbackStep,
    apply_rollback,
    load_plan,
    plan_rollback,
)
from .verify import (
    Comparison,
    DataLossError,
    Snapshot,
    SnapshotEntry,
    Tombstone,
    assert_no_data_loss,
    compare,
    compare_evidence,
)

__all__ = [
    "Comparison",
    "DataLossError",
    "Gate",
    "GateBlocked",
    "GateFailure",
    "GateReport",
    "GateRunner",
    "GroupCheck",
    "MigrationError",
    "PHASES",
    "PHASE_NAMES",
    "Phase",
    "ROLLBACK_CONFIRMATION",
    "ROLLBACK_STEP_NAMES",
    "ReadDataCheck",
    "ResticGateRunner",
    "RollbackBackend",
    "RollbackError",
    "RollbackPlan",
    "RollbackStep",
    "Snapshot",
    "SnapshotEntry",
    "Tombstone",
    "advance",
    "apply_rollback",
    "assert_no_data_loss",
    "check_advance",
    "compare",
    "compare_evidence",
    "confirmation_missing",
    "confirmation_phases",
    "evidence_keys_for",
    "irreversible_phases",
    "load_plan",
    "next_phase",
    "phase",
    "plan_rollback",
    "required_evidence_keys",
    "run_gate",
]
