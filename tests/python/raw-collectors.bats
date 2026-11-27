#!/usr/bin/env bats
# bats file_tags=python
# The raw local-file collectors (SDLC #1000): a Syncthing folder supplies the
# todo list and the Markdown vault, so the guards that keep an empty, half-moved
# or conflicted source from becoming a replica are part of the source contract.
load ../helpers

setup() {
    export PYTHONPATH="$repo_root/libs${PYTHONPATH:+:$PYTHONPATH}"
    export PYTHONDONTWRITEBYTECODE=1
    replica=$BATS_TEST_TMPDIR/replica
    entities=$BATS_TEST_TMPDIR/entities
    mkdir -p "$replica" "$entities"
}

collect() { # source
    run python3 -m data_plane.collectors.raw \
        --root "$replica" --captured-at 2025-11-19T00:00:00+00:00 \
        "$1" --entities "$entities"
}

objects() { # report on stdin
    python3 -c 'import json, sys; print(json.load(sys.stdin)["objects"])'
}

# A done.txt without todo.txt is exactly what a mistyped path, an unmounted
# dataset or a half-finished move leaves behind. Publishing it would mark every
# task in the replica absent and look like a real, empty list.
@test "tasks refuses a directory without todo.txt" {
    printf 'x 2025-11-18 finished\n' >"$entities/done.txt"
    collect tasks
    [ "$status" -eq 3 ]
    [[ $output == *"todo.txt"* ]]
}

@test "tasks publishes todo.txt and done.txt" {
    printf '(A) 2025-11-19 write it\n' >"$entities/todo.txt"
    printf 'x 2025-11-18 finished\n' >"$entities/done.txt"
    collect tasks
    [ "$status" -eq 0 ]
    [ "$(objects <<<"$output")" = 2 ]
}

# Syncthing writes a conflict copy beside the original. It is not a note the
# human wrote, so it must not become a note in the replica.
@test "notes skips Syncthing conflict copies" {
    printf '# real\n' >"$entities/note.md"
    printf '# conflicted\n' >"$entities/note.sync-conflict-20251119-000000-ABCDEFG.md"
    collect notes
    [ "$status" -eq 0 ]
    [ "$(objects <<<"$output")" = 1 ]
}
