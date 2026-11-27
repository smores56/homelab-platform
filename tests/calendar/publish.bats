#!/usr/bin/env bats
# bats file_tags=calendar
# The calendar view (SDLC #995): the replica's derived `.ics` objects republished
# as a vdir of one VEVENT per file, which is what the agent's own shell reads.
#
# The fixture is the collector's own writer -- ReplicaState plus the object ids,
# metadata and bytes `collect_calendar` produces, derived with the same `to_ics`
# -- so the files under test come out of a replica shaped exactly like the one
# the unit leaves on disk.

load ../helpers

module=data_plane.collectors.raw.publish_calendar
#: 2025-11-19T00:00:00Z, and what --now is set to in every assertion below.
NOW=1763510400

setup() {
    export PYTHONPATH="$repo_root/libs${PYTHONPATH:+:$PYTHONPATH}"
    export PYTHONDONTWRITEBYTECODE=1
    replica=$BATS_TEST_TMPDIR/replica/calendar
    out=$BATS_TEST_TMPDIR/out
}

# make_replica <root> [<entities json>]: one committed calendar replica, the way
# `collect_calendar` commits one -- the entity verbatim, its ICS derived beside
# it, and one absence reason for the whole pass.
make_replica() {
    local root=$1 entities=${2:-[]}
    python3 - "$root" "$entities" <<'PY'
import json
import sys
from pathlib import Path

from data_plane.collectors.raw.calendar import to_ics
from data_plane.collectors.raw.replica import ABSENCE_NO_TOMBSTONE, canonical_json
from data_plane.collectors.state import ReplicaState

root, entities = sys.argv[1], json.loads(sys.argv[2])
captured = "2025-11-19T00:00:00+00:00"

state = ReplicaState(Path(root), source_id="tuta.calendar")
for entity in entities:
    entity_id = entity["uid"]
    raw_id = f"calendar::{entity_id}"
    state.put(
        raw_id,
        canonical_json(entity),
        {
            "source_id": "tuta.calendar",
            "kind": "sdk-entity",
            "uid": entity_id,
            "revision": "",
            "recurrence_id": str(entity.get("recurrence_id") or ""),
            "dtstart": str(entity.get("dtstart") or ""),
            "dtend": str(entity.get("dtend") or ""),
            "rrule": str(entity.get("rrule") or ""),
            "summary": str(entity.get("summary") or ""),
            "captured_at": captured,
        },
    )
    state.put(
        f"{raw_id}::ics",
        to_ics(entity),
        {
            "source_id": "tuta.calendar",
            "kind": "derived-ics",
            "of": raw_id,
            "captured_at": captured,
        },
    )
state.commit(
    complete=True, absence_reason=ABSENCE_NO_TOMBSTONE, captured_at=captured
)
PY
}

# drop_event <root> <uid>: the tombstone a pass writes when the SDK says an
# entity was deleted, for both the entity and its derived ICS.
drop_event() {
    python3 - "$1" "$2" <<'PY'
import sys
from pathlib import Path

from data_plane.collectors.state import ReplicaState
from data_plane.collectors.raw.replica import ABSENCE_NO_TOMBSTONE

root, uid = sys.argv[1], sys.argv[2]
raw_id = f"calendar::{uid}"
reason = "the SDK marked the entity deleted"
state = ReplicaState(Path(root), source_id="tuta.calendar")
state.tombstone(raw_id, reason)
state.tombstone(f"{raw_id}::ics", reason)
# The rest of the pass saw nothing new, which is the absence reason it carries.
state.commit(
    complete=True,
    absence_reason=ABSENCE_NO_TOMBSTONE,
    captured_at="2025-11-19T01:00:00+00:00",
)
PY
}

# hand_written <root> <raw id> <ics text>: an object the collector would never
# write, so the publisher's own guard is what is under test.
hand_written() {
    python3 - "$1" "$2" "$3" <<'PY'
import json
import sys
from pathlib import Path

from data_plane.collectors.state import ReplicaState

root, raw_id, body = sys.argv[1], sys.argv[2], sys.argv[3]
state = ReplicaState(Path(root), source_id="tuta.calendar")
state.put(
    f"{raw_id}::ics",
    body.encode("utf-8"),
    {
        "source_id": "tuta.calendar",
        "kind": "derived-ics",
        "of": raw_id,
        "captured_at": "2025-11-19T00:00:00+00:00",
    },
)
state.commit(
    complete=True,
    absence_reason="provider-supplies-no-tombstone",
    captured_at="2025-11-19T00:00:00+00:00",
)
PY
}

publish() {
    python3 -m "$module" --raw "$replica" --out "$out" --now "$NOW" "$@"
}

EVENTS='[
  {"uid": "evt-coffee", "summary": "Coffee", "location": "Cafe",
   "dtstart": "2025-11-16T09:00:00Z", "dtend": "2025-11-16T10:00:00Z"},
  {"uid": "evt-standup", "summary": "Standup", "dtstart": "2025-11-03T09:00:00Z",
   "rrule": "FREQ=WEEKLY;BYDAY=MO"}
]'

@test "one .ics per event, byte-identical to the bytes the store committed" {
    make_replica "$replica" "$EVENTS"
    run publish
    assert_success

    [[ -f $out/events/evt-coffee.ics ]]
    [[ -f $out/events/evt-standup.ics ]]
    run python3 - "$out/events/evt-coffee.ics" "$replica" <<'PY'
import sys
from pathlib import Path

from data_plane.collectors.state import ReplicaState

published = Path(sys.argv[1]).read_bytes()
state = ReplicaState(Path(sys.argv[2]), read_only=True)
assert published == state.read("calendar::evt-coffee::ics"), published
assert published.startswith(b"BEGIN:VCALENDAR\r\n")
assert b"SUMMARY:Coffee" in published
print("identical")
PY
    assert_success
    assert_contains "$output" identical
}

@test "state.json records the run and carries no index" {
    make_replica "$replica" "$EVENTS"
    run publish
    assert_success

    run python3 - "$out/state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state == {
    "events": 2,
    "last_run": "2025-11-19T00:00:00Z",
    "ok": True,
    "removed": 0,
    "source": "calendar",
}, state
print("state")
PY
    assert_success
    assert_contains "$output" state
    # An index of DTSTART would have to be wrong about a recurrence, so there is
    # none: the vdir is the answer.
    [[ ! -e $out/events.jsonl ]]
    [[ ! -e $out/calendar.jsonl ]]
}

@test "a recurrence keeps its RRULE unexpanded and an exception keeps RECURRENCE-ID" {
    make_replica "$replica" '[
      {"uid": "evt-standup", "summary": "Standup", "dtstart": "2025-11-03T09:00:00Z",
       "rrule": "FREQ=WEEKLY;BYDAY=MO"},
      {"uid": "evt-standup-moved", "summary": "Standup", "dtstart": "2025-11-11T10:00:00Z",
       "recurrence_id": "2025-11-10T09:00:00Z"}
    ]'
    run publish
    assert_success

    run python3 - "$out/events" <<'PY'
import sys
from pathlib import Path

directory = Path(sys.argv[1])
files = sorted(p.name for p in directory.iterdir())
assert files == ["evt-standup-moved.ics", "evt-standup.ics"], files
recurring = (directory / "evt-standup.ics").read_text(encoding="utf-8")
# One VEVENT, not one per occurrence.
assert recurring.count("BEGIN:VEVENT") == 1, recurring
assert "RRULE:FREQ=WEEKLY;BYDAY=MO" in recurring, recurring
moved = (directory / "evt-standup-moved.ics").read_text(encoding="utf-8")
assert "RECURRENCE-ID:20251110T090000Z" in moved, moved
print("recurrence")
PY
    assert_success
    assert_contains "$output" recurrence
}

@test "a tombstoned event leaves the view and the removal is counted" {
    make_replica "$replica" "$EVENTS"
    run publish
    assert_success
    [[ -f $out/events/evt-standup.ics ]]

    drop_event "$replica" evt-standup
    run publish
    assert_success

    [[ ! -e $out/events/evt-standup.ics ]]
    [[ -f $out/events/evt-coffee.ics ]]
    run python3 - "$out/state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state["events"] == 1, state
assert state["removed"] == 1, state
print("pruned")
PY
    assert_success
    assert_contains "$output" pruned
}

@test "an unchanged rerun rewrites nothing" {
    make_replica "$replica" "$EVENTS"
    run publish
    assert_success
    before=$(stat -c %i "$out/events/evt-coffee.ics")

    run publish
    assert_success
    after=$(stat -c %i "$out/events/evt-coffee.ics")
    [[ $before == "$after" ]]
    run python3 - "$output" <<'PY'
import json, sys
summary = json.loads(sys.argv[1])
assert summary["changed"] is False, summary
print("unchanged")
PY
    assert_success
    assert_contains "$output" unchanged
}

@test "a replica that is not there refuses and writes nothing" {
    run publish
    assert_failure
    [[ $status -eq 3 ]]
    [[ ! -e $out/events ]]
    [[ ! -e $out/state.json ]]
    assert_contains "$output" "no replica state"
}

@test "a store whose object file vanished refuses and leaves the previous view alone" {
    make_replica "$replica" "$EVENTS"
    run publish
    assert_success
    cp "$out/events/evt-coffee.ics" "$BATS_TEST_TMPDIR/previous.ics"

    # Damage, not a stale cache: the row is live but its bytes are gone.
    find "$replica/objects" -name "*" -type f ! -name state.sqlite -delete

    run publish
    assert_failure
    [[ $status -eq 3 ]]
    assert_contains "$output" "no object file"
    # The view a reader would have opened is still exactly as it was.
    run cmp "$out/events/evt-coffee.ics" "$BATS_TEST_TMPDIR/previous.ics"
    assert_success
}

@test "an event whose id would escape the view directory is refused" {
    make_replica "$replica" '[]'
    hand_written "$replica" "calendar::.." "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"
    run publish
    assert_failure
    [[ $status -eq 3 ]]
    [[ ! -e $out/events.jsonl ]]
    assert_contains "$output" "unusable"
}

@test "an event named state.json cannot clobber the run record" {
    make_replica "$replica" '[
      {"uid": "state.json", "summary": "Not the run record", "dtstart": "2025-11-16T09:00:00Z"}
    ]'
    run publish
    assert_success

    [[ -f $out/events/state.json.ics ]]
    run python3 - "$out/state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state["source"] == "calendar", state
assert state["events"] == 1, state
print("run-record")
PY
    assert_success
    assert_contains "$output" run-record
}
