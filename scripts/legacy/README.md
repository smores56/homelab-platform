# Decommission evidence tools

These scripts are the recorded evidence path for the T0/T6 gates in
`docs/core/t0-gate.md` (#703) and the cold-restore matrix in
`docs/core/restic-plane.md` (#709). They are not part of normal operation and
must not be deleted while those checklists are open: `legacy-audit.sh` attaches
the inventory to #703, `verify-legacy-backups.sh` proves both legacy
repositories restore, and `retirement-gate.sh` runs the matrix.

`freeze-legacy.sh` and `restic-first-backup.sh` are retained for the same
reason, including the historical `kubectl` path in the latter.

When #703's exit criteria are checked and #709 closes, delete this directory
and remove the doc references in one change; until then it is excluded from
new check groups and shellchecked by the `lint` group.
