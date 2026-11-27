#!/usr/bin/env bats
# bats file_tags=brave
# The plain-file view beside the Brave snapshot (SDLC #995): the visits an agent
# reads with cat/rg rather than SQLite, and the document that says which pass it
# came from.
#
# Static and behavioral, and no browser: the History database is one these tests
# write in the schema the pinned artifact writes, the snapshot's consistent copy is
# the fixture itself, and the publisher runs as the unit runs it -- as a module
# from `libs/`, over real files.
#
#   bats tests/brave/publish.bats
load ../helpers

module=data_plane.collectors.raw.publish_brave

# The pass's clock, fixed: every assertion about a timestamp or a window is
# arithmetic on this value rather than on the machine's clock.
NOW=1795000000

setup() {
    export PYTHONPATH="$repo_root/libs${PYTHONPATH:+:$PYTHONPATH}"
    export PYTHONDONTWRITEBYTECODE=1
    quarantine=$BATS_TEST_TMPDIR/quarantine
    out=$BATS_TEST_TMPDIR/out
    mkdir -p "$quarantine"
    history=$quarantine/History
}

# publish [args...]: run the module against this test's copy and output dir.
publish() {
    python3 -m "$module" --history "$history" --out "$out" "$@"
}

# make_history <count> <newest-epoch>: <count> visits one second apart, the newest
# at <newest-epoch>, in the schema `history_fixture.py` records for the pinned
# browser. Visit 0 is the newest, so page/<n> is one second older than page/<n-1>.
make_history() {
    python3 - "$history" "$1" "$2" <<'PY'
import sqlite3, sys
from pathlib import Path

sys.path.insert(0, "tests/brave")
from history_fixture import SCHEMA

path, count, newest = Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
urls, visits = [], []
for index in range(count):
    chromium = (newest - index + 11_644_473_600) * 1_000_000
    urls.append(
        (index + 1, f"https://www.example.com/page/{index}", f"Page {index}", index + 1, chromium)
    )
    visits.append((index + 1, index + 1, chromium))
path.parent.mkdir(parents=True, exist_ok=True)
connection = sqlite3.connect(str(path))
try:
    for statement in SCHEMA:
        connection.execute(statement)
    connection.executemany(
        "INSERT INTO urls (id, url, title, visit_count, last_visit_time)"
        " VALUES (?, ?, ?, ?, ?)",
        urls,
    )
    connection.executemany(
        "INSERT INTO visits (id, url, visit_time, transition) VALUES (?, ?, ?, 805306368)",
        visits,
    )
    connection.commit()
finally:
    connection.close()
PY
}

# make_history_rows <json>: a History holding exactly the rows given, each
# {"url": ..., "title": ..., "visit_count": ..., "epoch": <unix seconds>}.
make_history_rows() {
    python3 - "$history" "$1" <<'PY'
import json, sqlite3, sys
from pathlib import Path

sys.path.insert(0, "tests/brave")
from history_fixture import SCHEMA

path, rows = Path(sys.argv[1]), json.loads(sys.argv[2])
path.parent.mkdir(parents=True, exist_ok=True)
connection = sqlite3.connect(str(path))
try:
    for statement in SCHEMA:
        connection.execute(statement)
    for index, row in enumerate(rows):
        chromium = (int(row["epoch"]) + 11_644_473_600) * 1_000_000
        connection.execute(
            "INSERT INTO urls (id, url, title, visit_count, last_visit_time)"
            " VALUES (?, ?, ?, ?, ?)",
            (index + 1, row["url"], row.get("title", ""), row.get("visit_count", 1), chromium),
        )
        connection.execute(
            "INSERT INTO visits (id, url, visit_time, transition) VALUES (?, ?, ?, 805306368)",
            (index + 1, index + 1, chromium),
        )
    connection.commit()
finally:
    connection.close()
PY
}

# json_field <file> <key>: one value from a JSON document, as it would be typed.
json_field() {
    python3 - "$1" "$2" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]]
print("true" if value is True else "false" if value is False else value)
PY
}

@test "the view is one JSON line per visit, newest first" {
    make_history 5 "$NOW"
    run publish --now "$NOW"
    assert_success
    python3 - "$out/visits.jsonl" "$NOW" <<'PY'
import json, sys
from datetime import datetime, timezone

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
records = [json.loads(line) for line in lines]
now = int(sys.argv[2])
assert len(records) == 5, records
keys = {"ts", "url", "title", "host", "visit_count"}
assert [set(record) for record in records] == [keys] * 5, records
stamps = [record["ts"] for record in records]
expected = [
    datetime.fromtimestamp(now - index, timezone.utc)
    .isoformat(timespec="seconds")
    .replace("+00:00", "Z")
    for index in range(5)
]
assert stamps == expected, (stamps, expected)
assert records[0]["url"] == "https://www.example.com/page/0", records[0]
assert records[0]["title"] == "Page 0", records[0]
assert records[0]["visit_count"] == 1, records[0]
assert records[4]["url"] == "https://www.example.com/page/4", records[4]
PY
}

@test "the host is the URL's host, lowercased, and empty for an opaque scheme" {
    make_history_rows "[
      {\"url\": \"https://News.Example.COM:8443/a?b=c#d\", \"title\": \"Mixed case\", \"visit_count\": 3, \"epoch\": $((NOW - 10))},
      {\"url\": \"file:///tmp/report.pdf\", \"title\": \"A file\", \"visit_count\": 1, \"epoch\": $((NOW - 20))},
      {\"url\": \"about:blank\", \"title\": \"\", \"visit_count\": 2, \"epoch\": $((NOW - 30))}
    ]"
    run publish --now "$NOW"
    assert_success
    python3 - "$out/visits.jsonl" <<'PY'
import json, sys

records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
hosts = [record["host"] for record in records]
assert hosts == ["news.example.com", "", ""], hosts
# The URL is carried verbatim: the view is a rendering, not a normalization.
assert records[0]["url"] == "https://News.Example.COM:8443/a?b=c#d", records[0]
assert records[2]["title"] == "", records[2]
PY
}

@test "the window keeps the recent visits and drops the rest" {
    make_history_rows "[
      {\"url\": \"https://example.com/recent\", \"epoch\": $((NOW - 86400))},
      {\"url\": \"https://example.com/old\", \"epoch\": $((NOW - 100 * 86400))}
    ]"
    run publish --now "$NOW"
    assert_success
    assert_equal "$(grep -c . "$out/visits.jsonl")" 1
    grep -qF 'https://example.com/recent' "$out/visits.jsonl"
    # `! cmd` in a bats test never fails it (SC2314), so the negative is `refute`.
    refute test -n "$(grep -F 'https://example.com/old' "$out/visits.jsonl")"
    assert_equal "$(json_field "$out/state.json" window_days)" 90
    assert_equal "$(json_field "$out/state.json" visits)" 1
    # A wider window is what brings the old visit back: the bound is the flag's,
    # not the database's.
    run publish --now "$NOW" --days 120
    assert_success
    assert_equal "$(grep -c . "$out/visits.jsonl")" 2
    assert_equal "$(json_field "$out/state.json" window_days)" 120
}

@test "the view holds 2000 visits and says the bound dropped more" {
    make_history 2100 "$NOW"
    run publish --now "$NOW"
    assert_success
    assert_equal "$(grep -c . "$out/visits.jsonl")" 2000
    assert_equal "$(json_field "$out/state.json" visits)" 2000
    assert_equal "$(json_field "$out/state.json" truncated)" true
    # The bound drops the oldest, never the newest: the file stays newest-first.
    python3 - "$out/visits.jsonl" "$NOW" <<'PY'
import json, sys
from datetime import datetime, timezone

records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert records[0]["url"] == "https://www.example.com/page/0", records[0]
assert records[-1]["url"] == "https://www.example.com/page/1999", records[-1]
oldest = datetime.fromtimestamp(int(sys.argv[2]) - 1999, timezone.utc)
assert records[-1]["ts"] == oldest.isoformat(timespec="seconds").replace("+00:00", "Z")
PY
}

@test "a view under the bound is not truncated" {
    make_history 3 "$NOW"
    run publish --now "$NOW"
    assert_success
    assert_equal "$(json_field "$out/state.json" truncated)" false
    assert_equal "$(json_field "$out/state.json" visits)" 3
}

@test "state.json names the source, the pass and the copy's digest" {
    make_history 2 "$NOW"
    run publish --now "$NOW"
    assert_success
    python3 - "$out/state.json" <<'PY'
import json, sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
assert sorted(state) == [
    "history_sha256",
    "last_run",
    "ok",
    "source",
    "truncated",
    "visits",
    "window_days",
], state
assert state["source"] == "brave", state
assert state["ok"] is True, state
assert state["visits"] == 2 and state["window_days"] == 90, state
assert state["truncated"] is False, state
assert state["last_run"] == "2026-11-18T11:06:40Z", state["last_run"]
PY
    # The digest is the published copy's own bytes, so a client can tell whether
    # the file under the view is the one the document describes.
    assert_equal "$(json_field "$out/state.json" history_sha256)" \
        "$(sha256sum "$out/History" | cut -d' ' -f1)"
}

@test "the copy is taken, not moved: the quarantine snapshot stays" {
    make_history 2 "$NOW"
    before=$(sha256sum "$history" | cut -d' ' -f1)
    run publish --now "$NOW"
    assert_success
    assert [ -f "$history" ]
    assert_equal "$(sha256sum "$history" | cut -d' ' -f1)" "$before"
    assert_equal "$(sha256sum "$out/History" | cut -d' ' -f1)" "$before"
    assert_equal "$(stat -c %a "$out/History")" 600
}

@test "a corrupt database is refused and leaves no visit file" {
    printf 'this is not a database\n' >"$history"
    run publish --now "$NOW"
    assert_failure 3
    assert_output --partial '"event": "refused"'
    assert [ ! -e "$out/visits.jsonl" ]
    assert [ ! -e "$out/state.json" ]
    assert [ ! -e "$out/History" ]
}

@test "a missing History is refused and leaves no visit file" {
    run publish --now "$NOW"
    assert_failure 3
    assert_output --partial "is missing"
    assert [ ! -e "$out/visits.jsonl" ]
}

@test "two passes over one copy publish byte-identical files" {
    make_history 4 "$NOW"
    run publish --now "$NOW"
    assert_success
    first=$BATS_TEST_TMPDIR/first
    mkdir -p "$first"
    cp "$out/visits.jsonl" "$out/state.json" "$first"
    run publish --now "$NOW"
    assert_success
    cmp "$first/visits.jsonl" "$out/visits.jsonl"
    cmp "$first/state.json" "$out/state.json"
}

@test "a copy that cannot be written is still read" {
    make_history 2 "$NOW"
    chmod 0444 "$history"
    run publish --now "$NOW"
    assert_success
    assert_equal "$(grep -c . "$out/visits.jsonl")" 2
    chmod 0644 "$history"
}
