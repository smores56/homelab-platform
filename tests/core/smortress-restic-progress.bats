#!/usr/bin/env bats
# bats file_tags=core
# Offline checks for the backup progress command (SDLC #706, T3 follow-up).
#
# The host half — a real restic uploading to a real repository — needs smortress.
# This drives the renderer against the tree the backup driver publishes, with a
# stubbed systemctl for the timer half, so the parsing, the liveness rules, the
# idle state and the no-root promise are exercised without a repository.
#
#   bats tests/core/smortress-restic-progress.bats
load ../helpers

script=scripts/smortress-restic-progress.sh

# progress_fixture: the tree the driver publishes and the stub that answers the
# timer half. Every @test builds its own: the markers change between cases, each
# @test runs in its own process, and the file may run under --jobs.
progress_fixture() {
    local b u
    work=$BATS_TEST_TMPDIR/work
    bin=$work/bin
    progress=$work/progress
    install -d -m 0755 "$bin" "$progress/last"

    # The timer half is the only systemctl call the command makes, so the stub is
    # also the proof it asks per backend rather than hardcoding a schedule.
    cat >"$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
# show -p <prop> --value <unit>, or is-active <unit>
if [[ $1 == show ]]; then
  prop=$3 unit=$5
  case $prop in
    ActiveState) case $unit in *-hdd.timer) printf 'inactive\n' ;; *) printf 'active\n' ;; esac ;;
    NextElapseUSecRealtime) case $unit in *-ssd.timer) printf '%s\n' "$STUB_NEXT" ;; *) printf '\n' ;; esac ;;
  esac
fi
EOF
    chmod 0755 "$bin/systemctl"

    now=$(date +%s)
    stamp() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

    # A live attempt: current names the unit, and the status stream is restic's
    # own --json record shape.
    cat >"$progress/current-ssd.json" <<JSON
{"backend":"ssd","unit":"agent-local","start":"$(stamp $((now - 90)))","epoch":$((now - 90)),"deadline":14400,"expiry":40000}
JSON
    printf '%s\n' \
        '{"message_type":"status","percent_done":0.25,"total_bytes":4000,"bytes_done":1000,"total_files":10,"files_done":2,"seconds_remaining":120}' \
        '{"message_type":"status","percent_done":0.5,"total_bytes":4000,"bytes_done":2000,"total_files":10,"files_done":5,"seconds_remaining":60}' \
        >"$progress/ssd-agent-local.jsonl"

    # Durable results as the driver publishes them: one failure, the rest ok.
    pub() { printf '%s\n' "$2" >"$progress/last/$1.json"; }
    for b in ssd hdd; do
        for u in files books music wallpapers git apps repo-archive agent-general; do
            pub "$b-$u" "{\"schema\":2,\"attempt\":1,\"result\":\"success\",\"exit\":0,\"reason\":\"\",\"snapshot\":\"abc\",\"start\":\"$(stamp $((now - 3600)))\",\"end\":\"$(stamp $((now - 3500)))\",\"backend\":\"$b\",\"unit\":\"$u\"}"
        done
    done
    pub hdd-photos "{\"schema\":2,\"attempt\":2,\"result\":\"failure\",\"exit\":124,\"reason\":\"timeout\",\"snapshot\":null,\"start\":\"$(stamp $((now - 3600)))\",\"end\":\"$(stamp $((now - 3000)))\",\"backend\":\"hdd\",\"unit\":\"photos\"}"
    pub ssd-photos "{\"schema\":2,\"attempt\":2,\"result\":\"failure\",\"exit\":124,\"reason\":\"timeout\",\"snapshot\":null,\"start\":\"$(stamp $((now - 3600)))\",\"end\":\"$(stamp $((now - 3000)))\",\"backend\":\"ssd\",\"unit\":\"photos\"}"

    export PATH="$bin:$PATH" RESTIC_PROGRESS_ROOT=$progress
    # 1 h 30 s, not a round 10 min: the renderer truncates to whole minutes, and a
    # delta that lands on a minute boundary is 9m59s by the time it is parsed.
    STUB_NEXT="$(date -u -d @$((now + 3630)) '+%a %Y-%m-%d %H:%M:%S UTC')"
    export STUB_NEXT
}

# frame [args...]: one render, its output in `out` and its status in `rc`.
frame() {
    rc=0
    out=$("$script" "$@" 2>&1) || rc=$?
}

@test "the progress command is executable" {
    [[ -x $script ]]
}

@test "the progress command parses" {
    bash -n "$script"
}

@test "the progress command has --help" {
    "$script" --help >/dev/null 2>&1
}

@test "the progress command rejects an unknown flag" {
    refute "$script" --nonsense
}

@test "one frame exits 0" {
    progress_fixture
    frame --once
    assert_equal "$rc" 0
}

@test "the frame names every backend" {
    progress_fixture
    frame --once
    assert_contains "$out" 'ssd'
}

@test "the live unit is named" {
    progress_fixture
    frame --once
    assert_contains "$out" 'agent-local'
}

@test "restic's own percentage is rendered" {
    progress_fixture
    frame --once
    assert_contains "$out" '50%'
}

@test "the transferred byte count is rendered" {
    progress_fixture
    frame --once
    assert_contains "$out" '2.0KiB'
}

@test "the file count is rendered" {
    progress_fixture
    frame --once
    assert_contains "$out" '5/10 files'
}

@test "an estimate is rendered" {
    progress_fixture
    frame --once
    assert_contains "$out" 'eta'
}

@test "a timer that is not scheduled is not hidden" {
    progress_fixture
    frame --once
    assert_contains "$out" 'inactive'
}

@test "the next run is rendered as a countdown" {
    progress_fixture
    frame --once
    assert_contains "$out" '1h00m'
}

@test "a failed unit from the last run is reported" {
    progress_fixture
    frame --once
    assert_contains "$out" 'timeout'
}

@test "a progress bar is drawn" {
    progress_fixture
    frame --once
    assert_contains "$out" '[#'
}

@test "--all lists a unit that failed" {
    progress_fixture
    frame --once --all
    assert_contains "$out" 'photos'
}

@test "--all lists the units that succeeded" {
    progress_fixture
    frame --once --all
    assert_contains "$out" 'files'
}

# A frame for a backend with no current marker must say it is idle instead of
# rendering a unit that is not running.
@test "a backend with no running unit reads idle" {
    progress_fixture
    frame --once --backend hdd
    assert_contains "$out" 'idle'
}

@test "a backend filter does not borrow another backend's live unit" {
    progress_fixture
    frame --once --backend hdd
    if [[ $out == *'agent-local'* ]]; then
        fail "the hdd frame rendered the ssd unit: $out"
    fi
}

# A marker left behind by a killed driver must not look live forever.
@test "an abandoned marker is called stale" {
    progress_fixture
    old=$((now - 86400))
    cat >"$progress/current-ssd.json" <<JSON
{"backend":"ssd","unit":"agent-local","start":"$(stamp $old)","epoch":$old,"deadline":1800,"expiry":60}
JSON
    frame --once --backend ssd
    assert_contains "$out" 'stale'
}

# A long unit is legal for its lock wait, its bounded attempts and the
# post-upload calls; the deadline alone is not the window.
@test "a healthy long run is not called stale" {
    progress_fixture
    legal=$((now - 2160))
    cat >"$progress/current-ssd.json" <<JSON
{"backend":"ssd","unit":"agent-local","start":"$(stamp "$legal")","epoch":$legal,"deadline":1800}
JSON
    frame --once --backend ssd
    if [[ $out == *'stale'* ]]; then
        fail "a run inside its window was called stale: $out"
    fi
}

# Nothing published yet is an answer, not an error.
@test "an empty progress tree exits 0" {
    progress_fixture
    rc=0
    out=$(RESTIC_PROGRESS_ROOT=$work/empty "$script" --once 2>&1) || rc=$?
    assert_equal "$rc" 0
}

@test "an empty progress tree says so" {
    progress_fixture
    rc=0
    out=$(RESTIC_PROGRESS_ROOT=$work/empty "$script" --once 2>&1) || rc=$?
    assert_contains "$out" 'no runs recorded'
}

# The installed command is /usr/bin/<name> -> /usr/libexec/<name>, and bash
# reports the symlink, not the target. Resolving the library from the sibling
# libexec directory is what makes the documented alias work at all.
@test "the installed symlink resolves its library" {
    progress_fixture
    install -d -m 0755 "$work/sbin" "$work/libexec"
    ln -s "$repo_root/scripts/smortress-restic-progress.sh" "$work/sbin/restic-progress"
    # The installed names drop the .sh; the layout keeps its suffix because the
    # common library falls back to it.
    ln -s "$repo_root/scripts/restic-plane-common.sh" "$work/libexec/restic-plane-common"
    ln -s "$repo_root/scripts/storage-layout.sh" "$work/libexec/storage-layout.sh"
    rc=0
    out=$("$work/sbin/restic-progress" --once 2>&1) || rc=$?
    assert_contains "$out" 'no runs recorded'
}
