#!/usr/bin/env bats
# bats file_tags=deploy
# The golden fixtures for the deploy decision (design #939, T2).
#
# The server and the edge ask the same question with different policy, and they
# will be two verifiers, two drains and two gates. What keeps them honest is this
# directory: every document under bootc/lib/deploy/fixtures/ names a request, the
# world behind it (GitHub, the registry, the host's state and denylist) and the
# outcome today produces -- byte for byte. Both verifiers are meant to replay the
# same documents, so a fixture this suite accepts is the contract the edge has to
# meet, not a description of the server's code.
#
# This suite replays each one through the server's own programs, which is what
# makes it a drift test: a changed reason, a reordered key, a dropped check or a
# gate code the drain stops honouring fails here.
#
#   bats tests/deploy/fixtures.bats
#
# Two kinds of fixture, because "accept, hold, refuse" happens at two layers:
# `verify` documents end in the verifier's exit code and its one-line verdict,
# and `gate` documents end in what the drain did with a verified entry -- staged,
# held (the snapshot gate said hold), refused (the staged image was not the
# verified one) or deferred (no verdict at all).
#
# The only substitution the comparison makes is `$BASE`: a fixture's detail text
# can name the API it asked, and the fake server's port is minted per run. Every
# other byte is compared as it stands.
load ../helpers

fixtures=bootc/lib/deploy/fixtures
verify=bootc/server/rootfs/usr/libexec/deploy-verify.py
drain=scripts/deploy-drain.sh
state_lib=scripts/deploy-state.sh
decisions=bootc/lib/deploy/decisions.py
# The GitHub API and the ghcr registry: one loopback server, shared with
# tests/deploy/edge-verify.bats, answering out of the fixture document it is
# pointed at. The fixture *is* the world, so a new case needs no new server code,
# and both roles replay the same answers rather than two renderings of them.
world_server=tests/deploy/fixture-server.py

commit=0123456789abcdef0123456789abcdef01234567
id_e=55555555-5555-4555-8555-555555555555

setup_file() {
    local dir=$BATS_FILE_TMPDIR

    # The role hooks the drain calls. The platform stub answers per sub-command,
    # because "held" and "refused" are two different exit codes of one program.
    cat >"$dir/fake-platform" <<'STUB'
#!/usr/bin/env bash
case $1 in
    prepare) exit "${FAKE_PREPARE_EXIT:-0}" ;;
    stage) exit "${FAKE_STAGE_EXIT:-0}" ;;
    *) exit 0 ;;
esac
STUB
    cat >"$dir/fake-apps" <<'STUB'
#!/usr/bin/env bash
exit "${FAKE_APPS_EXIT:-0}"
STUB
    chmod 0755 "$dir/fake-platform" "$dir/fake-apps"
}

setup() {
    local file

    work=$BATS_TEST_TMPDIR
    state_dir=$work/state

    for file in "$verify" "$drain" "$state_lib" "$decisions" "$world_server"; do
        [[ -r $file ]] || fail "$file is missing"
    done
    for file in jq python3 timeout cmp; do
        command -v "$file" >/dev/null || fail "$file is required"
    done

    mkdir -p "$state_dir/queue" "$state_dir/work"
    chmod 0700 "$state_dir" "$state_dir/queue"

    export DEPLOY_STATE_DIR=$state_dir
    export DEPLOY_LOCK_FILE=$work/deploy.lock
    export DEPLOY_VERIFY_BIN=$repo_root/$verify
    export DEPLOY_PLATFORM_BIN=$BATS_FILE_TMPDIR/fake-platform
    export DEPLOY_APPS_BIN=$BATS_FILE_TMPDIR/fake-apps
    export DEPLOY_DRAIN_RESCAN_PAUSE=0
    # shellcheck source=/dev/null
    source "$state_lib"
    # The loop file defines the queue-shape rule this suite compares with the
    # decisions; `drain_main` is not called, so sourcing it is inert. The role's
    # repo list is the server script's, read from it rather than restated here.
    # shellcheck source=/dev/null
    source "$repo_root/bootc/lib/deploy/drain.sh"
    drain_repos=$(sed -nE 's/^drain_repos="([^"]*)"$/\1/p' "$repo_root/scripts/deploy-drain.sh")
    [[ -n $drain_repos ]] || fail "scripts/deploy-drain.sh names no drain_repos"
}

teardown() {
    kill "${server_pid:-}" 2>/dev/null || true
    wait 2>/dev/null || true
}

free_port() {
    python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

# start_world <fixture>: one server answering out of the fixture's world. The
# port is per test, so the verifier's API base is too, which is why a fixture's
# detail text may say $BASE instead of a URL.
start_world() { # <fixture>
    port=$(free_port)
    base=http://127.0.0.1:$port
    python3 "$world_server" "$1" "$port" >"$work/server.log" 2>&1 &
    server_pid=$!
    local _
    for _ in $(seq 1 100); do
        if python3 -c 'import socket, sys
s = socket.socket()
s.settimeout(0.2)
sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)' "$port"; then
            return 0
        fi
        sleep 0.1
    done
    fail "the fixture server never answered on $base: $(cat "$work/server.log")"
}

# seed <fixture>: the host's own records, exactly as the fixture states them. A
# null state is a host with no record at all, which is the bootstrap case.
seed() { # <fixture>
    local state denylist
    state=$(jq -c '.state' "$1")
    denylist=$(jq -c '.denylist' "$1")
    if [[ $state != null ]]; then
        jq -c . <<<"$state" >"$state_dir/state.json"
    fi
    if [[ $denylist != null ]]; then
        jq -c . <<<"$denylist" >"$state_dir/denylist.json"
    fi
    return 0
}

# expect_bytes <fixture> <jq-path>: the fixture's expected bytes, with the one
# substitution the run needs.
expect_bytes() { # <fixture> <jq-path>
    local want
    # The sentinel is what keeps a trailing newline: a command substitution
    # strips them, and the verifier's verdict is one line *with* its newline.
    want=$(jq -j "$2" "$1"; printf 'x')
    want=${want//\$BASE/$base}
    printf '%s' "${want%x}"
}

# compare_bytes <expected> <actual> <label>
compare_bytes() { # <expected-file> <actual-file> <label>
    if cmp -s "$1" "$2"; then
        return 0
    fi
    fail "$3" "$(diff -u "$1" "$2" | tail -n +3)"
}

replay_verify() { # <fixture>
    local fixture=$1 rc=0 repo sha
    repo=$(jq -r '.request.repo' "$fixture")
    sha=$(jq -r '.request.commit' "$fixture")
    start_world "$fixture"
    seed "$fixture"
    DEPLOY_GITHUB_API=$base DEPLOY_REGISTRY=$base python3 "$verify" --repo "$repo" --commit "$sha" \
        >"$work/out" 2>"$work/err" || rc=$?
    assert_equal "$rc" "$(jq -r '.expect.exit' "$fixture")" "the exit code"
    expect_bytes "$fixture" '.expect.stdout' >"$work/want"
    compare_bytes "$work/want" "$work/out" "the verdict bytes"
}

replay_gate() { # <fixture>
    local fixture=$1 rc=0 repo sha prepare stage queued action
    repo=$(jq -r '.request.repo' "$fixture")
    sha=$(jq -r '.request.commit' "$fixture")
    prepare=$(jq -r '.gate.prepare' "$fixture")
    stage=$(jq -r '.gate.stage' "$fixture")
    start_world "$fixture"
    seed "$fixture"
    jq -nc --arg id "$id_e" --arg repo "$repo" --arg commit "$sha" \
        --argjson at "$(date +%s)" \
        '{schema:1,id:$id,repo:$repo,commit:$commit,queued_at:$at,source:"event"}' |
        atomic_write "$state_dir/queue/$id_e.json"

    env FAKE_PREPARE_EXIT="$prepare" FAKE_STAGE_EXIT="$stage" \
        DEPLOY_GITHUB_API=$base DEPLOY_REGISTRY=$base \
        timeout 60 bash "$drain" >"$work/out" 2>&1 || rc=$?

    assert_equal "$rc" "$(jq -r '.expect.exit' "$fixture")" "the drain's exit code"
    # The last line is the drain's own summary: the counters a held or refused
    # deploy moved, in the spelling `smortress-deploy status` and the journal use.
    expect_bytes "$fixture" '.expect.summary' >"$work/want"
    tail -n 1 "$work/out" >"$work/summary"
    compare_bytes "$work/want" "$work/summary" "the drain's summary"

    queued=$(queue_count)
    assert_equal "$queued" "$(jq -r '.expect.queued' "$fixture")" "the queue after the drain"
    if [[ $(jq -r '.expect.finish' "$fixture") != null ]]; then
        for action in drained rejected held refused notDeployable noop invalid superseded; do
            assert_equal "$(jq -r "select(.event==\"drain-finish\") | .$action" "$state_dir/journal.jsonl")" \
                "$(jq -r ".expect.finish.$action" "$fixture")" "the drain counted $action"
        done
    else
        # A deferred entry is popped by nothing: the run ends at the stamp, and
        # the next attempt is the step after it.
        assert_equal "$(grep -c 'drain-finish' "$state_dir/journal.jsonl" || true)" 0 \
            "a deferred drain finishes nothing"
    fi
    local deferred
    deferred=$(jq -r '.expect.deferred' "$fixture")
    if [[ $deferred != null ]]; then
        assert_equal "$(jq -r 'select(.event=="deferred") | .reason' "$state_dir/journal.jsonl")" \
            "$deferred" "the deferral reason"
    fi
    # The role hook's exit codes are data in the shared decisions, and the drain
    # is what has to keep honouring them: this compares the table to the fixture
    # (what the drain just did), so neither can drift alone.
    python3 - "$repo_root" "$fixture" "$prepare" "$stage" <<'PY'
import json
import sys

root, fixture, prepare, stage = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
sys.path.insert(0, f"{root}/bootc/lib/deploy")
import decisions  # noqa: E402

document = json.load(open(fixture))
action, reason = decisions.step(decisions.GATE_STEPS, prepare, "snapshot-gate")
if action == decisions.STAGE_NEXT:
    action, reason = decisions.step(decisions.STAGE_STEPS, stage, "staging")
expected = document["expect"]
if (action or "deferred") != expected["action"] or (reason or None) != expected["deferred"]:
    raise SystemExit(
        f"the shared gate table says {action or 'deferred'!r}/{reason!r}, the fixture says "
        f"{expected['action']!r}/{expected['deferred']!r}"
    )
PY
}

replays() { # <fixture>
    case $(jq -r '.kind' "$1") in
        verify) replay_verify "$1" ;;
        gate) replay_gate "$1" ;;
        *) fail "unknown fixture kind $(jq -r '.kind' "$1") in $1" ;;
    esac
}

for fixture in "$fixtures"/*.json; do
    register "the fixture ${fixture##*/} reproduces its outcome" replays "$fixture"
done

@test "the allowlist is per role: the edge runs the platform plane only" {
    run python3 - "$repo_root" <<'PY'
import pathlib
import re
import sys

sys.path.insert(0, f"{sys.argv[1]}/bootc/lib/deploy")
import decisions  # noqa: E402

problems = []
if sorted(decisions.ROLES[decisions.SERVER].repos) != [decisions.APPS, decisions.PLATFORM]:
    problems.append(f"server allows {sorted(decisions.ROLES[decisions.SERVER].repos)}")
if sorted(decisions.ROLES[decisions.EDGE].repos) != [decisions.PLATFORM]:
    problems.append(f"edge allows {sorted(decisions.ROLES[decisions.EDGE].repos)}")
if decisions.allows(decisions.EDGE, decisions.APPS):
    problems.append("the edge accepts an apps request at the door")
if not decisions.allows(decisions.SERVER, decisions.APPS):
    problems.append("the server refuses its own apps tenant")
shell = re.search(
    r'^drain_repos="([^"]*)"$',
    (pathlib.Path(sys.argv[1]) / "scripts/deploy-drain.sh").read_text(),
    re.MULTILINE,
)
if shell is None:
    problems.append("scripts/deploy-drain.sh names no drain_repos")
elif sorted(shell.group(1).split()) != sorted(decisions.ROLES[decisions.SERVER].repos):
    problems.append(f"the drain allows {sorted(shell.group(1).split())}")
if problems:
    raise SystemExit("; ".join(problems))
PY
    assert_success
}

@test "the queue shape is the same rule in the drain and in the decisions" {
    # `drain_entry_valid` is the shell spelling of decisions.entry_valid: an entry
    # one reader accepts and the other drops is a request nothing deploys.
    local entry shell want mismatched=''
    local -a entries=(
        '{"schema":1,"id":"a","repo":"homelab-platform","commit":"0123456789abcdef0123456789abcdef01234567","queued_at":1,"source":"event"}'
        '{"schema":1,"id":"a","repo":"homelab-apps","commit":"0123456789abcdef0123456789abcdef01234567","queued_at":1,"source":"event"}'
        '{"schema":1,"id":"a","repo":"other-repo","commit":"0123456789abcdef0123456789abcdef01234567","queued_at":1,"source":"event"}'
        '{"schema":1,"id":"a","repo":"homelab-platform","commit":"short","queued_at":1,"source":"event"}'
        '{"schema":1,"repo":"homelab-platform","commit":"0123456789abcdef0123456789abcdef01234567","queued_at":1,"source":"event"}'
        '{"schema":1,"id":"a","repo":null,"commit":"0123456789abcdef0123456789abcdef01234567","queued_at":1,"source":"event"}'
    )
    for entry in "${entries[@]}"; do
        printf '%s\n' "$entry" >"$state_dir/queue/$id_e.json"
        run drain_entry_valid "$id_e"
        shell=$([[ $status == 0 ]] && echo accept || echo drop)
        want=$(python3 -c "import json, sys; sys.path.insert(0, '$repo_root/bootc/lib/deploy'); import decisions; print('accept' if decisions.entry_valid(json.loads(sys.argv[1]), 'server') else 'drop')" "$entry")
        if [[ $shell != "$want" ]]; then
            mismatched+="$entry: shell=$shell decisions=$want"$'\n'
        fi
    done
    assert_equal "$mismatched" ""
}

@test "the tag name and the coalesce key are the rules both roles share" {
    # The publish workflow pushes `sha-<12>` and nothing else, so the poll and the
    # gate have to recognise that exact shape and refuse a near-miss rather than
    # slice whatever arrived; the coalesce key is what makes two pending requests
    # for one repository one deploy.
    run python3 - "$repo_root" <<'PY'
import sys

sys.path.insert(0, f"{sys.argv[1]}/bootc/lib/deploy")
import decisions  # noqa: E402

commit = "0123456789abcdef0123456789abcdef01234567"
tag = "sha-" + commit[:12]
problems = []
if decisions.tag_for(commit) != tag:
    problems.append(f"tag_for({commit}) = {decisions.tag_for(commit)!r}")
if decisions.parse_tag(tag) != commit[:12]:
    problems.append(f"parse_tag({tag}) = {decisions.parse_tag(tag)!r}")
for refused in ("sha-0123456789", "sha-0123456789abc", "latest", "sha-0123456789zz", ""):
    if decisions.parse_tag(refused) is not None:
        problems.append(f"parse_tag({refused!r}) accepted it")
if decisions.coalesce_key(None, "an-id") != "unreadable/an-id":
    problems.append(f"an unreadable entry keys as {decisions.coalesce_key(None, 'an-id')!r}")
if decisions.coalesce_key(decisions.APPS, "an-id") != decisions.APPS:
    problems.append("a readable entry does not key on its repository")
if problems:
    raise SystemExit("; ".join(problems))
PY
    assert_success
}

@test "the journal vocabulary is the set the writers use" {
    # One list, two languages: a reader of the journal is written against these
    # names, so a rename on either side has to be a change here too.
    run python3 - "$repo_root" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / "bootc/lib/deploy"))
import decisions  # noqa: E402

used = set()
for name in (
    "scripts/deploy-state.sh",
    "bootc/lib/deploy/drain.sh",
    "scripts/deploy-drain.sh",
):
    for line in (root / name).read_text().splitlines():
        if line.lstrip().startswith("#"):
            continue
        used.update(re.findall(r"journal_append\s+([a-z][a-z-]*)", line))

problems = []
if used - decisions.JOURNAL_EVENTS:
    problems.append(f"written but not in the vocabulary: {sorted(used - decisions.JOURNAL_EVENTS)}")
if decisions.JOURNAL_EVENTS - used:
    problems.append(f"in the vocabulary but written nowhere: {sorted(decisions.JOURNAL_EVENTS - used)}")
if problems:
    raise SystemExit("; ".join(problems))
PY
    assert_success
}
