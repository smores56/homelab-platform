"""The far-side epoch, read from the sync tool's own state.

mbsync records the far side's UIDVALIDITY in a state file inside each Maildir
box (``SyncState *``), which is the only place it exists: the collector's
contract is that a UIDVALIDITY is the provider's, never something a caller
invented, and an operator-supplied number would silently invalidate the whole
deletion rule the moment it drifted.

The header is a strict key/value block terminated by an empty line, followed by
one fixed-format record per message. isync refuses any header key it does not
know, and so does this reader: a format change must stop the collector rather
than be guessed at.
"""

from __future__ import annotations

from pathlib import Path

from ...errors import ValidationError
from .mail import maildir_folders
from .replica import resolve_source_dir

STATE_FILE = ".mbsyncstate"

#: Every key isync writes. ``MaxExpiredFarUid`` and ``MaxExpiredNearUid`` are
#: two spellings of the same field: 1.5 writes the Near one by default and 1.4
#: writes the Far one.
HEADER_KEYS = frozenset(
    {
        "FarUidValidity",
        "NearUidValidity",
        "MaxPulledUid",
        "MaxPushedUid",
        "MaxExpiredFarUid",
        "MaxExpiredNearUid",
    }
)

#: Siblings that mean the state on disk is not the state that was committed: a
#: journal is replayed on the next run and a ``.new`` file is a save in flight.
#: The ``.lock`` sibling is deliberately not one of them -- it is an fcntl lock,
#: not a marker, and a stale one survives a clean exit.
IN_FLIGHT_SUFFIXES = (".journal", ".new")


def _header(state: Path, folder: str) -> dict[str, int]:
    try:
        text = state.read_text(encoding="utf-8", errors="strict")
    except (OSError, UnicodeDecodeError) as exc:
        raise ValidationError(f"folder {folder}: cannot read {state}: {exc}") from exc
    values: dict[str, int] = {}
    terminated = False
    for line in text.splitlines():
        if not line.strip():
            # The blank line ends the header; everything after it is a message
            # record, whose first field is a UID that must not be read as a key.
            terminated = True
            break
        key, _, raw = line.partition(" ")
        if key not in HEADER_KEYS:
            raise ValidationError(
                f"folder {folder}: {state} has the header key {key!r}, which this "
                "isync state format does not define; reconcile the sync tool's "
                "version before publishing"
            )
        if key in values:
            raise ValidationError(f"folder {folder}: {state} repeats {key}")
        try:
            values[key] = int(raw.strip())
        except ValueError as exc:
            raise ValidationError(
                f"folder {folder}: {key} in {state} is not an integer"
            ) from exc
    if not values:
        raise ValidationError(f"folder {folder}: {state} has no header")
    if not terminated:
        raise ValidationError(
            f"folder {folder}: {state} has no blank line after its header, so the "
            "state is not one isync wrote completely"
        )
    if "FarUidValidity" not in values:
        raise ValidationError(
            f"folder {folder}: {state} has no FarUidValidity; the epoch is not on disk"
        )
    epoch = values["FarUidValidity"]
    if epoch < 1:
        raise ValidationError(
            f"folder {folder}: FarUidValidity {epoch} is not positive"
        )
    return values


def read_uidvalidity(maildir_root: str | Path) -> dict[str, int]:
    """Every folder's far-side UIDVALIDITY, in the shape ``collect_maildir`` wants.

    Refuses anything it cannot prove: a folder without state was never synced,
    and a state with a journal is one a crash left behind.
    """

    root = resolve_source_dir(maildir_root, "maildir")
    folders = maildir_folders(root)
    if not folders:
        raise ValidationError(f"maildir {root} has no folder with cur/ or new/")
    mapping: dict[str, int] = {}
    for name, path in folders:
        state = path / STATE_FILE
        if state.is_symlink():
            raise ValidationError(f"folder {name}: {state} is a symlink")
        if not state.is_file():
            raise ValidationError(
                f"folder {name}: no {STATE_FILE} in {path}; the sync has never "
                "written this folder, so its epoch is unknown"
            )
        for suffix in IN_FLIGHT_SUFFIXES:
            if state.with_name(state.name + suffix).exists():
                raise ValidationError(
                    f"folder {name}: {state.name}{suffix} is present, so this "
                    "state is mid-write or awaiting replay; run the sync again "
                    "before publishing"
                )
        mapping[name] = _header(state, name)["FarUidValidity"]
    return mapping
