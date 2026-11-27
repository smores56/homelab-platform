#!/usr/bin/env bats
# bats file_tags=mail
# The agent's mail, where its own shell can read it (SDLC #995): a Maildir of the
# provider's bytes beside the collector's replica, plus one bounded newest-first
# index over it.
#
# Behavioral for everything that only needs a filesystem: the raw tree is a real
# ReplicaState, built by the repository's own Maildir collector, so the row
# metadata the publisher reads is the shape the host produces. The mount
# namespace it runs in on smortress is asserted statically, not reproduced here.
load ../helpers

module=data_plane.collectors.raw.publish_mail
unit=units/systemd/smortress-agent-mail-stream.service

# The suites import from libs/ the way the collector containers do.
export PYTHONPATH="$repo_root/libs${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1

setup_file() {
    # Four hand-written messages, ordered so that file order is not date order:
    # one RFC 2047 subject, one ISO-8859-1 message whose charset is not UTF-8,
    # one flagged (the key in a maildir name is the part before `:2,`), and one
    # in a second mailbox.
    fixture "$BATS_FILE_TMPDIR/one" 0
    replica "$BATS_FILE_TMPDIR/one/maildir" "$BATS_FILE_TMPDIR/one/raw"
    # Two messages more than the index's bound, so "the most recent 5000" is a
    # decision the publisher has to make rather than everything it has.
    fixture "$BATS_FILE_TMPDIR/many" 4998
    replica "$BATS_FILE_TMPDIR/many/maildir" "$BATS_FILE_TMPDIR/many/raw"
}

# fixture <dir> <extra>: a Maildir with four realistic messages, plus <extra>
# generated ones dated before all four.
fixture() {
    python3 - "$1" "$2" <<'PY'
import email.utils
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

root = Path(sys.argv[1]) / "maildir"
extra = int(sys.argv[2])


def deliver(mailbox, name, raw):
    spool = root / "cur" if mailbox == "INBOX" else root / mailbox / "cur"
    spool.mkdir(parents=True, exist_ok=True)
    (spool / name).write_bytes(raw)


# RFC 2047 in the subject and in the display name of the sender.
deliver(
    "INBOX",
    "1",
    b"From: =?ISO-8859-1?Q?Caf=E9?= <cafe@example.com>\r\n"
    b"To: me@example.com\r\n"
    b"Subject: =?ISO-8859-1?Q?Caf=E9_au_lait?=\r\n"
    b"Date: Tue, 03 Jun 2025 10:00:00 +0200\r\n"
    b"Message-ID: <one@example.com>\r\n"
    b"\r\n"
    b"first body\r\n",
)
# A body and a header both in ISO-8859-1: the message names its own charset.
deliver(
    "INBOX",
    "2",
    b"From: Ren\xe9 <rene@example.com>\r\n"
    b"To: me@example.com\r\n"
    b"Subject: =?iso-8859-1?B?Q2Fm6Q==?=\r\n"
    b"Date: Tue, 03 Jun 2025 12:00:00 +0000\r\n"
    b"Content-Type: text/plain; charset=iso-8859-1\r\n"
    b"Content-Transfer-Encoding: 8bit\r\n"
    b"Message-ID: <two@example.com>\r\n"
    b"\r\n"
    b"caf\xe9 au lait\r\n",
)
# Newest of all four, and plain: the newest-first assertion has an answer.
deliver(
    "INBOX",
    "3",
    b"From: Alice <alice@example.com>\r\n"
    b"To: me@example.com\r\n"
    b"Subject: Third message\r\n"
    b"Date: Thu, 05 Jun 2025 09:30:00 +0000\r\n"
    b"Message-ID: <three@example.com>\r\n"
    b"\r\n"
    b"third body\r\n",
)
# A second mailbox, and a flagged name: the key is what precedes `:2,`.
deliver(
    ".Sent",
    "5:2,S",
    b"From: Bob <bob@example.com>\r\n"
    b"To: them@example.com\r\n"
    b"Subject: Sent message\r\n"
    b"Date: Wed, 04 Jun 2025 08:00:00 +0000\r\n"
    b"Message-ID: <five@example.com>\r\n"
    b"\r\n"
    b"fifth body\r\n",
)

for index in range(extra):
    # Strictly increasing, so the two the bound drops are the first two and the
    # assertion names them instead of hoping for the oldest.
    stamp = email.utils.format_datetime(
        datetime(2024, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=index)
    )
    deliver(
        "INBOX",
        str(100 + index),
        (
            f"From: bulk{index}@example.com\r\n"
            f"To: me@example.com\r\n"
            f"Subject: generated {index}\r\n"
            f"Date: {stamp}\r\n"
            f"Message-ID: <generated{index}@example.com>\r\n"
            "\r\n"
            f"generated body {index}\r\n"
        ).encode("ascii"),
    )
PY
}

# replica <maildir> <root>: the raw tree a collector commits, built by the
# Maildir collector itself so the metadata is the real shape and not a guess.
replica() {
    python3 - "$1" "$2" <<'PY'
import sys
from pathlib import Path

from data_plane.collectors.raw.mail import collect_maildir, maildir_folders
from data_plane.collectors.state import ReplicaState

maildir, root = Path(sys.argv[1]), Path(sys.argv[2])
state = ReplicaState(root, source_id="tuta.mail")
try:
    folders = [name for name, _ in maildir_folders(maildir)]
    collect_maildir(
        maildir,
        state,
        uidvalidity={name: 1 for name in folders},
        captured_at="2025-06-06T00:00:00Z",
    )
finally:
    state.close()
PY
}

# publish <out> <raw>: the module as the unit runs it.
publish() {
    python3 -m "$module" --raw "$2" --out "$1"
}

@test "messages.jsonl is one JSON object per message, naming an .eml beside it" {
    run publish "$BATS_TEST_TMPDIR/out" "$BATS_FILE_TMPDIR/one/raw"
    assert_success
    run python3 - "$BATS_TEST_TMPDIR/out" <<'PY'
import json, os, sys
from pathlib import Path

out = Path(sys.argv[1])
lines = (out / "messages.jsonl").read_text(encoding="utf-8").splitlines()
records = [json.loads(line) for line in lines]
assert len(records) == 4, records
for record in records:
    assert set(record) == {
        "mailbox", "path", "date", "from", "to", "subject", "size"
    }, sorted(record)
    path = Path(record["path"])
    assert path.is_absolute(), record
    assert path.is_file(), record
    assert path.parent.name == "cur", record
    assert path.suffix == ".eml", record
    assert path.stat().st_size == record["size"], record
    assert record["date"].endswith("Z"), record
    assert record["from"] and record["to"], record
assert {record["mailbox"] for record in records} == {"INBOX", ".Sent"}, records
PY
}

@test "the RFC 2047 and non-UTF-8 subjects are decoded, not raised on" {
    run publish "$BATS_TEST_TMPDIR/out" "$BATS_FILE_TMPDIR/one/raw"
    assert_success
    run python3 - "$BATS_TEST_TMPDIR/out/messages.jsonl" <<'PY'
import json, sys

records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
subjects = {record["subject"] for record in records}
assert "Café au lait" in subjects, subjects
assert "Café" in subjects, subjects
senders = {record["from"] for record in records}
assert "Café <cafe@example.com>" in senders, senders
PY
}

@test "the index is newest first" {
    run publish "$BATS_TEST_TMPDIR/out" "$BATS_FILE_TMPDIR/one/raw"
    assert_success
    run python3 - "$BATS_TEST_TMPDIR/out/messages.jsonl" <<'PY'
import json, sys

records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
dates = [record["date"] for record in records]
assert dates == sorted(dates, reverse=True), dates
assert records[0]["subject"] == "Third message", records[0]
assert records[1]["subject"] == "Sent message", records[1]
PY
}

@test "the index is bounded to the most recent 5000 and says so" {
    run publish "$BATS_TEST_TMPDIR/out" "$BATS_FILE_TMPDIR/many/raw"
    assert_success
    run python3 - "$BATS_TEST_TMPDIR/out" <<'PY'
import json, sys
from pathlib import Path

out = Path(sys.argv[1])
lines = (out / "messages.jsonl").read_text(encoding="utf-8").splitlines()
assert len(lines) == 5000, len(lines)
records = [json.loads(line) for line in lines]
# The two messages over the bound are the oldest ones, so the four hand-written
# messages are all still described: the bound drops the tail, not the window.
subjects = {record["subject"] for record in records}
assert {
    "Café au lait", "Café", "Third message", "Sent message"
} <= subjects, sorted(subjects)[:10]
assert "generated 0" not in subjects, "the oldest generated message survived"
state = json.loads((out / "state.json").read_text(encoding="utf-8"))
assert state["source"] == "mail", state
assert state["ok"] is True, state
assert state["messages"] == 5000, state
assert state["truncated"] is True, state
assert state["mailboxes"] == [".Sent", "INBOX"], state
assert state["last_run"].endswith("Z"), state
PY
}

@test "an unbroken publish leaves no temporary file behind" {
    run publish "$BATS_TEST_TMPDIR/out" "$BATS_FILE_TMPDIR/one/raw"
    assert_success
    # Nothing but the two index files and the messages themselves: a temp file
    # from `mkstemp` is `<name>.<random>` beside the index, or `.x.tmp` in a
    # maildir spool, and both would show up here.
    run find "$BATS_TEST_TMPDIR/out" -type f \
        ! -name '*.eml' ! -name messages.jsonl ! -name state.json
    assert_output ""
}

@test "a refused publish leaves the previous index byte-identical" {
    cp -a "$BATS_FILE_TMPDIR/one/raw" "$BATS_TEST_TMPDIR/raw"
    run publish "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/raw"
    assert_success
    published=$(cksum <"$BATS_TEST_TMPDIR/out/messages.jsonl")

    # One object gone is a damaged replica: the reader verifies every object it
    # describes, so the pass refuses instead of publishing a line whose bytes
    # are not there.
    victim=$(python3 - "$BATS_TEST_TMPDIR/raw" <<'OBJ'
import sys
from data_plane.collectors.state import ReplicaState

state = ReplicaState(sys.argv[1], read_only=True)
try:
    row = state.live_rows("mail::INBOX::3")[0]
finally:
    state.close()
print(f"{sys.argv[1]}/objects/{row['sha256'][:2]}/{row['sha256']}")
OBJ
    )
    rm -f "$victim"
    run publish "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/raw"
    assert_failure
    assert_contains "$output" "no object"

    assert_equal "$(cksum <"$BATS_TEST_TMPDIR/out/messages.jsonl")" "$published"
    run find "$BATS_TEST_TMPDIR/out" -type f \
        ! -name '*.eml' ! -name messages.jsonl ! -name state.json
    assert_output ""
}

@test "a missing raw tree exits non-zero and publishes nothing" {
    run publish "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/absent"
    assert_failure
    assert_contains "$output" "no replica state"
    [[ ! -e $BATS_TEST_TMPDIR/out/messages.jsonl ]]
    [[ ! -e $BATS_TEST_TMPDIR/out/state.json ]]
}

@test "two runs over an unchanged replica are byte-identical" {
    cp -a "$BATS_FILE_TMPDIR/one/raw" "$BATS_TEST_TMPDIR/raw"
    run publish "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/raw"
    assert_success
    cp -a "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/first"
    run publish "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/raw"
    assert_success

    assert_equal \
        "$(cksum <"$BATS_TEST_TMPDIR/first/messages.jsonl")" \
        "$(cksum <"$BATS_TEST_TMPDIR/out/messages.jsonl")"
    diff -r "$BATS_TEST_TMPDIR/first/maildir" "$BATS_TEST_TMPDIR/out/maildir"
    # `last_run` is the one field a rerun is allowed to move: that is what it is.
    run python3 - "$BATS_TEST_TMPDIR/first/state.json" "$BATS_TEST_TMPDIR/out/state.json" <<'PY'
import json, sys

first, second = (json.load(open(path, encoding="utf-8")) for path in sys.argv[1:])
first.pop("last_run")
second.pop("last_run")
assert first == second, (first, second)
PY
}

@test "a message the state no longer holds is removed from the maildir" {
    cp -a "$BATS_FILE_TMPDIR/one/raw" "$BATS_TEST_TMPDIR/raw"
    run publish "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/raw"
    assert_success
    [[ -f $BATS_TEST_TMPDIR/out/maildir/INBOX/cur/3.eml ]]

    run python3 - "$BATS_TEST_TMPDIR/raw" <<'PY'
import sys
from data_plane.collectors.state import ReplicaState

state = ReplicaState(sys.argv[1], source_id="tuta.mail")
try:
    state.tombstone("mail::INBOX::3", "provider expunge")
    # Everything else is carried rather than tombstoned: one expunge says nothing
    # about the rest of the mailbox.
    state.commit(
        complete=True,
        absence_reason="provider-window",
        captured_at="2025-06-07T00:00:00Z",
    )
finally:
    state.close()
PY
    assert_success

    run publish "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/raw"
    assert_success
    [[ ! -e $BATS_TEST_TMPDIR/out/maildir/INBOX/cur/3.eml ]]
    run grep -c . "$BATS_TEST_TMPDIR/out/messages.jsonl"
    assert_output "3"
}

@test "the unit publishes into the tree the gateway mounts, from a read-only raw tree" {
    grep -qF -- '--volume /var/lib/agent/local/sources/mail:/sources:z' "$unit" &&
        grep -qF -- '-m data_plane.collectors.stream --root /sources' "$unit" &&
        assert_equal "$(grep -cE '^ExecStart=' "$unit")" 1 &&
        grep -qF -- 'publish_mail.publish(state.root, state.root)' \
            libs/data_plane/collectors/stream/imap.py
}

@test "both stages of the unit run the image's own package" {
    assert_equal "$(grep -cE '^ExecStart=' "$unit")" 1
    grep -qF -- '--env PYTHONPATH=/usr/lib/data-plane/libs:/usr/lib/data-plane' "$unit" &&
        grep -qF -- '--user 1000:1000' "$unit" &&
        grep -qF -- '--cap-drop=all' "$unit"
}
