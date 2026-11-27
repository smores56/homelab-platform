#!/usr/bin/env bats
# bats file_tags=stream
# What one pass does when a folder changes shape (SDLC #983 follow-up).
#
# On 2026-11-27 a post-reboot pass asked the Tuta bridge for Archive before it
# was serving, got an empty listing for a folder holding 73,517 messages, read
# that as 73,517 provider expunges, and tombstoned the replica. The published
# view pruned the matching .eml files and the store collected the objects: 5 GB
# of mail became 52 MB until a later pass re-fetched it.
#
# The rule these tests pin: an empty listing for a folder the replica holds
# messages for is a refusal, not an expunge. An operator can still record it.

load ../helpers

setup() {
    export PYTHONPATH="$repo_root/libs${PYTHONPATH:+:$PYTHONPATH}"
    export PYTHONDONTWRITEBYTECODE=1
    root=$BATS_TEST_TMPDIR/replica
}

# A provider-shaped mailbox with no IMAP under it, which is the seam
# collect_mailbox is written against.
stub_module() {
    cat <<'PY'
from data_plane.collectors.stream.imap import Mailbox


class Stub(Mailbox):
    def __init__(self, uids, epoch=7):
        self.uids = list(uids)
        self.epoch = epoch
        self.selected = None

    def folders(self):
        return ["Archive"]

    def select(self, folder):
        self.selected = folder
        return self.epoch

    def uid_search_all(self):
        return list(self.uids)

    def uid_fetch(self, uid):
        return f"From: someone\r\nSubject: {uid}\r\n\r\nbody {uid}\r\n".encode()

    def uid_flags(self):
        return {uid: ("\\Seen",) for uid in self.uids}

    def close(self):
        pass


def seed(root, uids):
    from data_plane.collectors.stream import imap

    state = imap.ReplicaState(root, source_id="tuta.mail")
    try:
        return imap.collect_mailbox(
            Stub(uids), state, "2026-11-27T00:00:00+00:00"
        )
    finally:
        state.close()


def live(root, folder="Archive"):
    from data_plane.collectors.stream import imap

    state = imap.ReplicaState(root, read_only=True)
    try:
        return len(state.live_rows(f"mail::{imap.folder_key(folder)}::"))
    finally:
        state.close()
PY
}

@test "a folder that lists nothing refuses instead of tombstoning the mailbox" {
    stub_module >"$BATS_TEST_TMPDIR/stub.py"
    run python3 - "$root" "$BATS_TEST_TMPDIR/stub.py" <<'PY'
import sys

root, stub = sys.argv[1], sys.argv[2]
sys.path.insert(0, stub.rsplit("/", 1)[0])
from stub import Stub, live, seed
from data_plane.collectors.stream import imap
from data_plane.errors import PublishError

seed(root, ["1", "2", "3"])
assert live(root) == 3, live(root)

state = imap.ReplicaState(root, source_id="tuta.mail")
try:
    try:
        imap.collect_mailbox(Stub([]), state, "2026-11-27T01:00:00+00:00")
    except PublishError as error:
        text = str(error)
        assert "Archive" in text, text
        assert "3 messages" in text, text
        assert "--allow-empty-folder" in text, text
    else:
        raise AssertionError("an empty listing was accepted as an expunge")
finally:
    state.close()

# Refused, so nothing was committed: the rows are exactly as they were.
assert live(root) == 3, live(root)
print("refused")
PY
    assert_success
    assert_contains "$output" refused
}

@test "an operator can record a folder that really was emptied" {
    stub_module >"$BATS_TEST_TMPDIR/stub.py"
    run python3 - "$root" "$BATS_TEST_TMPDIR/stub.py" <<'PY'
import sys

root, stub = sys.argv[1], sys.argv[2]
sys.path.insert(0, stub.rsplit("/", 1)[0])
from stub import Stub, live, seed
from data_plane.collectors.stream import imap

seed(root, ["1", "2", "3"])

state = imap.ReplicaState(root, source_id="tuta.mail")
try:
    report = imap.collect_mailbox(
        Stub([]),
        state,
        "2026-11-27T01:00:00+00:00",
        allow_empty_folders=frozenset({"Archive"}),
    )
finally:
    state.close()

assert report.deleted == 3, report
assert live(root) == 0, live(root)
print("recorded")
PY
    assert_success
    assert_contains "$output" recorded
}

@test "a folder that shrank is still an expunge" {
    stub_module >"$BATS_TEST_TMPDIR/stub.py"
    run python3 - "$root" "$BATS_TEST_TMPDIR/stub.py" <<'PY'
import sys

root, stub = sys.argv[1], sys.argv[2]
sys.path.insert(0, stub.rsplit("/", 1)[0])
from stub import Stub, live, seed
from data_plane.collectors.stream import imap

seed(root, ["1", "2", "3"])

state = imap.ReplicaState(root, source_id="tuta.mail")
try:
    report = imap.collect_mailbox(Stub(["1", "2"]), state, "2026-11-27T01:00:00+00:00")
finally:
    state.close()

assert report.deleted == 1, report
assert live(root) == 2, live(root)
print("pruned")
PY
    assert_success
    assert_contains "$output" pruned
}

@test "the stream takes the escape hatch from its command line" {
    run python3 - <<'PY'
from data_plane.collectors.stream import imap

base = [
    "--host", "h", "--user", "u", "--password-file", "/dev/null",
    "--ca-file", "/dev/null", "--root", "/tmp/none",
]
args = imap._parser().parse_args(base)
assert args.allow_empty_folder == [], args
args = imap._parser().parse_args(base + ["--allow-empty-folder", "Archive"])
assert args.allow_empty_folder == ["Archive"], args
print("flag")
PY
    assert_success
    assert_contains "$output" flag
}
