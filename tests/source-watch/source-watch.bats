#!/usr/bin/env bats
# bats file_tags=source-watch
# The agent plane's live signal (SDLC #995): inotify over the source roots into
# one bounded JSONL feed, and the unit that autostarts it.
#
# Static for everything that only exists on smortress (the datasets, the unit's
# user and paths) and behavioral for the part that runs anywhere: the watcher is
# started against a scratch tree and its records are read back. The ZFS and
# mount-namespace behaviour this design rests on was measured on the host, not
# asserted here.
load ../helpers

watcher=scripts/source-watch.py
unit=units/systemd/smortress-source-watch.service
roots_config=bootc/server/rootfs/etc/smortress/agent/watch-roots.json

# A watcher started by a test must not outlive it: bats waits on a background
# job's stdout, so the process is detached from the harness's fds and killed
# here as well as in the test's own trap.
teardown() {
  if [[ -n ${watcher_pid:-} ]]; then
    kill "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
    watcher_pid=
  fi
}

# roots_json <file> <source>:path ... -- one root per argument, in pairs.
roots_json() {
  local out=$1
  shift
  python3 - "$out" "$@" <<'PY'
import json, sys
args = sys.argv[2:]
roots = [{"source": a.split(":", 1)[0], "path": a.split(":", 1)[1]} for a in args]
json.dump({"roots": roots}, open(sys.argv[1], "w"))
PY
}

# start_watcher <roots-json> <feed-dir> [extra args...]: run the watcher and
# wait for its feed. The file appears only after every watch is installed, so its
# presence is the readiness marker and a create in the test cannot be lost to a
# startup race.
start_watcher() {
  local roots=$1 feed=$2
  shift 2
  python3 "$watcher" --roots "$roots" --feed "$feed/changes.jsonl" "$@" >/dev/null 2>&1 &
  watcher_pid=$!
  for _ in $(seq 1 50); do
    [[ -e $feed/changes.jsonl ]] && return 0
    sleep 0.1
  done
  return 1
}

stop_watcher() {
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  watcher_pid=
}

# wait_records <feed> <count>: the feed holds at least <count> records.
wait_records() {
  local feed=$1 count=$2
  for _ in $(seq 1 50); do
    [[ $(grep -c . "$feed" 2>/dev/null || echo 0) -ge $count ]] && return 0
    sleep 0.1
  done
  return 1
}

@test "the roots file names every root with a source and an absolute path" {
  run python3 - "$roots_config" <<'PY'
import json, sys
config = json.load(open(sys.argv[1]))
roots = config["roots"]
assert roots, "no roots"
seen = set()
for root in roots:
    assert root["source"].strip(), root
    assert root["path"].startswith("/"), root
    assert root["source"] not in seen, root
    seen.add(root["source"])
# One root, the whole Syncthing folder: todo.txt lives at notes/todo.txt and the
# vault beside it, so a second root would watch the same inodes twice.
assert seen == {"files"}, seen
print("ok")
PY
  assert_success
  assert_contains "$output" ok
}

@test "the unit autostarts, waits for its dataset, and can write only its feed" {
  run grep -E '^WantedBy=multi-user.target$' "$unit"
  assert_success
  run grep -E '^Restart=always$' "$unit"
  assert_success
  run grep -E '^User=1000$' "$unit"
  assert_success
  run grep -F 'ConditionPathIsDirectory=/srv/files' "$unit"
  assert_success
  # The feed directory is inside the state dataset, so the unit has to wait for
  # it as well as for the roots; config seeding creates the directory itself.
  run grep -F 'zfs-ready@state-agent-local.service' "$unit"
  assert_success
  run grep -F 'smortress-agent-config.service' "$unit"
  assert_success
  # No `-` prefix: a missing directory must fail the unit, not leave it read-only.
  run grep -E '^ReadWritePaths=/var/lib/agent/local/watch$' "$unit"
  assert_success
  run grep -E '^ReadOnlyPaths=/srv/files$' "$unit"
  assert_success
  # The directory the unit writes into is created by the seeder, with the
  # dataset's uid, because ProtectSystem=strict will not let the watcher create it.
  run grep -F '"$home/watch"' scripts/agent-config-seed.sh
  assert_success
}

@test "the image installs the watcher, marks it executable, and enables the unit" {
  run grep -E '^COPY scripts/source-watch\.py /usr/libexec/source-watch$' bootc/server/Containerfile
  assert_success
  run grep -E '^      /usr/libexec/source-watch \\$' bootc/server/Containerfile
  assert_success
  run grep -E '^      smortress-source-watch\.service \\$' bootc/server/Containerfile
  assert_success
  [[ -x $watcher ]]
}

@test "each start writes one rescan record per live source" {
  mkdir -p "$BATS_TEST_TMPDIR/todos" "$BATS_TEST_TMPDIR/notes"
  roots_json "$BATS_TEST_TMPDIR/roots.json" \
    "todos:$BATS_TEST_TMPDIR/todos" "notes:$BATS_TEST_TMPDIR/notes"
  start_watcher "$BATS_TEST_TMPDIR/roots.json" "$BATS_TEST_TMPDIR/feed"
  run cat "$BATS_TEST_TMPDIR/feed/changes.jsonl"
  assert_success
  [[ $(grep -c '"kind": "rescan"' <<<"$output") -eq 2 ]]
  assert_contains "$output" '"source": "todos"'
  assert_contains "$output" '"source": "notes"'
}

@test "a create, an update and a delete are recorded with their source" {
  mkdir -p "$BATS_TEST_TMPDIR/todos"
  roots_json "$BATS_TEST_TMPDIR/roots.json" "todos:$BATS_TEST_TMPDIR/todos"
  start_watcher "$BATS_TEST_TMPDIR/roots.json" "$BATS_TEST_TMPDIR/feed"
  printf -- '- milk\n' >"$BATS_TEST_TMPDIR/todos/a.md"
  sleep 0.2
  printf -- '- eggs\n' >>"$BATS_TEST_TMPDIR/todos/a.md"
  sleep 0.2
  rm -f "$BATS_TEST_TMPDIR/todos/a.md"
  wait_records "$BATS_TEST_TMPDIR/feed/changes.jsonl" 4

  run cat "$BATS_TEST_TMPDIR/feed/changes.jsonl"
  assert_success
  assert_contains "$output" '"kind": "create"'
  assert_contains "$output" '"kind": "update"'
  assert_contains "$output" '"kind": "delete"'
  assert_contains "$output" '"source": "todos"'
  assert_contains "$output" "\"path\": \"$BATS_TEST_TMPDIR/todos/a.md\""
}

@test "a directory created after the watch goes in is walked and announced" {
  mkdir -p "$BATS_TEST_TMPDIR/todos"
  roots_json "$BATS_TEST_TMPDIR/roots.json" "todos:$BATS_TEST_TMPDIR/todos"
  start_watcher "$BATS_TEST_TMPDIR/roots.json" "$BATS_TEST_TMPDIR/feed"
  mkdir "$BATS_TEST_TMPDIR/todos/later"
  # The watcher installs the watch on the new directory when it sees the create;
  # inotify delivers nothing from inside a directory nobody is watching, so the
  # write waits for that round trip instead of racing it.
  sleep 0.3
  printf 'x\n' >"$BATS_TEST_TMPDIR/todos/later/inside.md"
  wait_records "$BATS_TEST_TMPDIR/feed/changes.jsonl" 4

  run cat "$BATS_TEST_TMPDIR/feed/changes.jsonl"
  assert_success
  assert_contains "$output" "\"path\": \"$BATS_TEST_TMPDIR/todos/later/inside.md\""
  # Content that landed before the walk began is invisible to inotify, so the
  # directory carries a rescan record and a reader sweeps it.
  run python3 - "$BATS_TEST_TMPDIR/feed/changes.jsonl" "$BATS_TEST_TMPDIR/todos/later" <<'PY'
import json, sys
records = [json.loads(line) for line in open(sys.argv[1])]
kinds = [r["kind"] for r in records if r["path"] == sys.argv[2]]
assert "rescan" in kinds, kinds
print("announced")
PY
  assert_success
}

@test "a removed directory is one delete and never an update" {
  mkdir -p "$BATS_TEST_TMPDIR/notes/gone"
  roots_json "$BATS_TEST_TMPDIR/roots.json" "notes:$BATS_TEST_TMPDIR/notes"
  start_watcher "$BATS_TEST_TMPDIR/roots.json" "$BATS_TEST_TMPDIR/feed"
  printf 'x\n' >"$BATS_TEST_TMPDIR/notes/gone/a.md"
  sleep 0.3
  rm -rf "$BATS_TEST_TMPDIR/notes/gone"
  wait_records "$BATS_TEST_TMPDIR/feed/changes.jsonl" 4
  sleep 0.3

  # IN_DELETE_SELF and the parent's IN_DELETE are the same fact; the record a
  # reader gets must be a delete for a path that is gone, never an update that
  # names something it cannot open.
  run python3 - "$BATS_TEST_TMPDIR/feed/changes.jsonl" "$BATS_TEST_TMPDIR/notes/gone" <<'PY'
import json, sys
records = [json.loads(line) for line in open(sys.argv[1])]
mine = [r["kind"] for r in records if r["path"] == sys.argv[2]]
assert mine.count("delete") == 1, mine
assert "update" not in mine, mine
print("clean")
PY
  assert_success
  assert_contains "$output" clean
}

@test "seq continues across a restart so a reader sees no rewind" {
  mkdir -p "$BATS_TEST_TMPDIR/todos"
  roots_json "$BATS_TEST_TMPDIR/roots.json" "todos:$BATS_TEST_TMPDIR/todos"
  start_watcher "$BATS_TEST_TMPDIR/roots.json" "$BATS_TEST_TMPDIR/feed"
  printf 'a\n' >"$BATS_TEST_TMPDIR/todos/a.md"
  wait_records "$BATS_TEST_TMPDIR/feed/changes.jsonl" 2
  stop_watcher
  start_watcher "$BATS_TEST_TMPDIR/roots.json" "$BATS_TEST_TMPDIR/feed"
  printf 'b\n' >"$BATS_TEST_TMPDIR/todos/b.md"
  wait_records "$BATS_TEST_TMPDIR/feed/changes.jsonl" 4

  run python3 - "$BATS_TEST_TMPDIR/feed/changes.jsonl" <<'PY'
import json, sys
records = [json.loads(line) for line in open(sys.argv[1])]
seqs = [r["seq"] for r in records]
assert seqs == sorted(seqs), seqs
assert len(set(seqs)) == len(seqs), seqs
# The restart is visible only as a second rescan for the same source.
rescans = [r for r in records if r["kind"] == "rescan"]
assert len(rescans) == 2, rescans
print("resumed")
PY
  assert_success
  assert_contains "$output" resumed
}

@test "syncthing, git and office noise is neither watched nor recorded" {
  mkdir -p "$BATS_TEST_TMPDIR/vault/sub/.stversions" "$BATS_TEST_TMPDIR/vault/tmp"
  roots_json "$BATS_TEST_TMPDIR/roots.json" "vault:$BATS_TEST_TMPDIR/vault"
  start_watcher "$BATS_TEST_TMPDIR/roots.json" "$BATS_TEST_TMPDIR/feed"
  mkdir "$BATS_TEST_TMPDIR/vault/later"
  mkdir -p "$BATS_TEST_TMPDIR/vault/later/.git/objects"
  sleep 0.3
  printf 'x\n' >"$BATS_TEST_TMPDIR/vault/sub/.stversions/old.md"
  printf 'x\n' >"$BATS_TEST_TMPDIR/vault/tmp/scratch.md"
  printf 'x\n' >"$BATS_TEST_TMPDIR/vault/.syncthing.keep.tmp"
  printf 'x\n' >"$BATS_TEST_TMPDIR/vault/later/.git/objects/obj"
  printf 'x\n' >"$BATS_TEST_TMPDIR/vault/~\$lock.docx"
  printf 'y\n' >"$BATS_TEST_TMPDIR/vault/later/kept.md"
  wait_records "$BATS_TEST_TMPDIR/feed/changes.jsonl" 3
  sleep 0.3

  # Asserted on the path relative to the root: the test's own directory is under
  # /tmp, so a substring match on the absolute path would prove nothing, and the
  # nested exclusions are the ones a synced vault actually has -- a top-level-only
  # rule would pass this test while watching every per-directory .stversions.
  run python3 - "$BATS_TEST_TMPDIR/feed/changes.jsonl" "$BATS_TEST_TMPDIR/vault" <<'PY'
import json, os, sys
root = sys.argv[2]
paths = [os.path.relpath(r["path"], root) for r in map(json.loads, open(sys.argv[1]))]
assert "later/kept.md" in paths, paths
for noise in ("sub/.stversions/old.md", "tmp/scratch.md", ".syncthing.keep.tmp",
              "later/.git/objects/obj", "~$lock.docx"):
    assert noise not in paths, (noise, paths)
print("quiet")
PY
  assert_success
  assert_contains "$output" quiet
}

@test "the feed is a ring buffer, not a ledger" {
  mkdir -p "$BATS_TEST_TMPDIR/ring/todos"
  roots_json "$BATS_TEST_TMPDIR/ring/roots.json" "todos:$BATS_TEST_TMPDIR/ring/todos"
  start_watcher "$BATS_TEST_TMPDIR/ring/roots.json" "$BATS_TEST_TMPDIR/ring/feed" \
    --keep 4 --trim-at 5
  # Distinct names, because the debounce merges a repeat of the same (path, kind).
  for n in $(seq 1 12); do
    printf 'x\n' >"$BATS_TEST_TMPDIR/ring/todos/f$n.md"
    sleep 0.05
  done
  for _ in $(seq 1 100); do
    [[ $(grep -c . "$BATS_TEST_TMPDIR/ring/feed/changes.jsonl" 2>/dev/null || echo 0) -le 5 ]] && break
    sleep 0.1
  done
  run bash -c 'grep -c . "$1"' _ "$BATS_TEST_TMPDIR/ring/feed/changes.jsonl"
  assert_success
  [[ $output -le 5 ]]
}
