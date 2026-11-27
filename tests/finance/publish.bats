#!/usr/bin/env bats
# bats file_tags=finance
# The finance view (SDLC #995): the raw replica republished as accounts.jsonl,
# transactions.jsonl and state.json, which is what the agent's own shell reads.
#
# The fixture is the collector's own writer -- ReplicaState plus the object ids
# and metadata `collect_simplefin` produces -- so the files under test are read
# out of a replica shaped exactly like the one the unit leaves on disk. Dates are
# pinned with --now, which is also what makes two runs comparable byte for byte.
load ../helpers

module=data_plane.collectors.raw.publish_finance
#: 2025-11-19T00:00:00Z, and what --now is set to in every assertion below.
NOW=1763510400

setup() {
    export PYTHONPATH="$repo_root/libs${PYTHONPATH:+:$PYTHONPATH}"
    export PYTHONDONTWRITEBYTECODE=1
    replica=$BATS_TEST_TMPDIR/replica/finance
    out=$BATS_TEST_TMPDIR/out
}

# make_replica <root> [<now>]: one committed finance replica, the way
# `collect_simplefin` commits one -- accounts and transactions stored verbatim,
# pending requested, a 90-day window applied at collection time.
make_replica() {
    local root=$1 now=${2:-$NOW}
    python3 - "$root" "$now" <<'PY'
import sys

from data_plane.collectors.raw.replica import canonical_json
from data_plane.collectors.state import ReplicaState

root, now = sys.argv[1], int(sys.argv[2])
captured = "2025-11-19T00:00:00+00:00"
day = 86400


def account(account_id, name, balance, transactions):
    return {
        "id": account_id,
        "name": name,
        "currency": "USD",
        "balance": balance,
        # SimpleFIN spells this with a hyphen, and the collector stores the
        # account as the provider sent it.
        "balance-date": now - day,
        "extra": {"provider": "schwab"},
        "transactions": transactions,
    }


accounts = [
    account(
        "acct-checking",
        "Checking",
        "100.00",
        [
            # Outside the default window: history, kept in the raw replica.
            {"id": "txn-old", "amount": "-1.00", "description": "Ancient",
             "posted": now - 400 * day},
            {"id": "txn-60d", "amount": "-2.00", "description": "A month or two back",
             "posted": now - 60 * day},
            {"id": "txn-recent", "amount": "-12.34", "description": "Coffee",
             "posted": now - 10 * day},
            # Pending is the present tense: the provider never dated it.
            {"id": "txn-pending", "amount": "-1.00", "description": "Pending thing",
             "pending": True, "posted": 0},
        ],
    ),
    account(
        "acct-savings",
        "Savings",
        "-5.50",
        [
            {"id": "txn-savings", "amount": "25.00",
             "description": "Transfer\nfrom checking", "posted": now - 3 * day},
        ],
    ),
]

connections = {"conn-1": {"conn_id": "conn-1", "name": "Schwab"}}
accountset_url = "https://bridge.example/simplefin/claim/x"

with ReplicaState(root, source_id="finance.ledger") as state:
    state.put(
        "finance::connection::conn-1",
        canonical_json(connections["conn-1"]),
        {"source_id": "finance.ledger", "kind": "connection", "conn_id": "conn-1",
         "captured_at": captured},
    )
    for entry in accounts:
        state.put(
            f"finance::account::{entry['id']}",
            canonical_json(entry),
            {"source_id": "finance.ledger", "kind": "account",
             "account_id": entry["id"], "conn_id": "conn-1",
             "sfin_url": accountset_url, "captured_at": captured},
        )
        for record in entry["transactions"]:
            state.put(
                f"finance::txn::{entry['id']}::{record['id']}",
                canonical_json(record),
                {"source_id": "finance.ledger", "kind": "transaction",
                 "accountset_url": accountset_url, "conn_id": "conn-1",
                 "account_id": entry["id"], "transaction_id": record["id"],
                 "pending": bool(record.get("pending")),
                 "posted": record.get("posted"), "captured_at": captured},
            )
    state.put(
        "finance::accountset",
        canonical_json({"connections": list(connections.values()), "accounts": accounts}),
        {"source_id": "finance.ledger", "kind": "accountset",
         "accountset_url": accountset_url, "window_days": 90, "captured_at": captured},
    )
    # One pass commits whole; nothing is visible in the state until it does.
    state.commit(
        complete=True, absence_reason="provider-window", captured_at=captured
    )
PY
}

publish() {
    python3 -m "$module" --raw "$replica" --out "$out" --now "$NOW" "$@"
}

@test "one line per account, with the provider's own balance text" {
    make_replica "$replica"
    run publish
    assert_success
    [[ -f $out/accounts.jsonl ]]

    run python3 - "$out/accounts.jsonl" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert [r["id"] for r in rows] == ["acct-checking", "acct-savings"], rows
checking = rows[0]
assert checking == {
    "balance": "100.00",
    "balance_date": "2025-11-18",
    "currency": "USD",
    "id": "acct-checking",
    "name": "Checking",
}, checking
assert rows[1]["balance"] == "-5.50", rows[1]
print("accounts")
PY
    assert_success
    assert_contains "$output" accounts
}

@test "transactions are newest first, windowed, and keep the pending flag" {
    make_replica "$replica"
    run publish
    assert_success

    run python3 - "$out/transactions.jsonl" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
dates = [r["date"] for r in rows]
# 400 days back is outside the 180-day window; everything else is inside.
assert len(rows) == 4, rows
assert "txn-old" not in {r["description"] for r in rows}
assert rows[0]["date"] == "2025-11-16", rows[0]
assert dates[:3] == sorted(dates[:3], reverse=True), dates
# The undated pending row sorts last rather than being dated today.
assert rows[-1] == {
    "account_id": "acct-checking",
    "amount": "-1.00",
    "date": None,
    "description": "Pending thing",
    "pending": True,
}, rows[-1]
assert all(row["pending"] is False for row in rows[:-1]), rows
# The payee's newline is flattened into one line, so a reader gets one record.
assert rows[0]["description"] == "Transfer from checking", rows[0]
print("transactions")
PY
    assert_success
    assert_contains "$output" transactions
}

@test "a narrower window drops dated history and keeps the pending row" {
    make_replica "$replica"
    run publish --window-days 30
    assert_success

    run python3 - "$out/transactions.jsonl" "$out/state.json" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
descriptions = [r["description"] for r in rows]
assert "A month or two back" not in descriptions, descriptions
assert "Pending thing" in descriptions, descriptions
assert len(rows) == 3, rows
state = json.load(open(sys.argv[2], encoding="utf-8"))
assert state["window_days"] == 30, state
assert state["transactions"] == 3, state
print("windowed")
PY
    assert_success
    assert_contains "$output" windowed
}

@test "state.json reports what the run read" {
    make_replica "$replica"
    run publish
    assert_success

    run python3 - "$out/state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state == {
    "accounts": 2,
    "dropped": 0,
    "last_run": "2025-11-19T00:00:00Z",
    "ok": True,
    "source": "finance",
    "transactions": 4,
    "truncated": False,
    "window_days": 180,
}, state
print("state")
PY
    assert_success
    assert_contains "$output" state
}

@test "a run with no --now dates itself, which is how the unit calls it" {
    # An ExecStart cannot compute an epoch, so the unit omits the flag: the
    # module has to date its own run or state.json lies about when it ran.
    make_replica "$replica"
    run python3 -m "$module" --raw "$replica" --out "$out"
    assert_success

    run python3 - "$out/state.json" <<'PY'
import json, sys, time
from datetime import datetime, timezone

state = json.load(open(sys.argv[1], encoding="utf-8"))
stamp = state["last_run"]
assert stamp.endswith("Z"), stamp
ran = datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
assert abs(ran.timestamp() - time.time()) < 3600, (stamp, time.time())
assert state["ok"] is True, state
print("dated")
PY
    assert_success
    assert_contains "$output" dated
}

@test "two runs over one state produce identical bytes" {
    make_replica "$replica"
    run publish
    assert_success
    first=$BATS_TEST_TMPDIR/first
    mkdir "$first"
    cp "$out"/*.json* "$first"/

    run publish
    assert_success
    for name in accounts.jsonl transactions.jsonl state.json; do
        run cmp -s "$first/$name" "$out/$name"
        assert_success
        [[ -s $out/$name ]]
    done
    # The temp files the atomic write leaves behind on failure are not here after
    # a run that finished: three files, nothing else.
    run bash -c 'ls -A "$1"' _ "$out"
    assert_output "accounts.jsonl
state.json
transactions.jsonl"
}

@test "a replica that is not there refuses and writes no accounts file" {
    run publish
    assert_failure
    [[ $status -eq 3 ]]
    [[ ! -e $out/accounts.jsonl ]]
    [[ ! -e $out/state.json ]]
    assert_contains "$output" "no replica state"
}

@test "more transactions than the file may hold keep the newest and say so" {
    run python3 - "$NOW" <<'PY'
import sys

from data_plane.collectors.raw.publish_finance import (
    MAX_TRANSACTIONS,
    build_view,
)

now = int(sys.argv[1])
day = 86400
records = {
    f"finance::txn::acct::t{n}": {
        "amount": "-1.00",
        "description": f"t{n}",
        "posted": now - (n % 100) * day,
    }
    for n in range(MAX_TRANSACTIONS + 5)
}


class FakeReplica:
    """The two methods build_view uses; the ordering is the state's own."""

    def entries(self):
        return tuple(
            {
                "object_id": object_id,
                "metadata": {
                    "kind": "transaction",
                    "account_id": "acct",
                    "pending": False,
                    "posted": record["posted"],
                },
            }
            for object_id, record in records.items()
        )

    def read(self, object_id):
        import json

        return json.dumps(records[object_id]).encode("utf-8")


accounts, transactions, state = build_view(FakeReplica(), now=now)
assert accounts == [], accounts
assert len(transactions) == MAX_TRANSACTIONS, len(transactions)
assert state["truncated"] is True, state
assert state["dropped"] == 5, state
assert state["transactions"] == MAX_TRANSACTIONS, state
# The newest survived: t4 is inside the window and sorts ahead of the dropped tail.
assert {"t0", "t1", "t2", "t3", "t4"} <= {row["description"] for row in transactions}
print("truncated")
PY
    assert_success
    assert_contains "$output" truncated
}
