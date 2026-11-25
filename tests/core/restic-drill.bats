#!/usr/bin/env bats
# bats file_tags=core
# Offline checks for the restore-drill guardrails (SDLC #706, T3). Run by bats.
#
# A drill streams a whole unit into one directory. The root filesystem is 100
# GiB and `photos` restores 116 GiB, so a drill there can only end in ENOSPC.
# The drill now picks a data disk by default and refuses a target without room
# before writing anything; these prove both, with a fake restic and a fake df.
load ../helpers

script=scripts/smortress-restic-restore-drill.sh

# The unit's own paths come from the layout the drill reads, not a copy here: a
# restore that omits one has to be caught against the same table the backup used.
setup_file() {
    # shellcheck source=/dev/null
    source scripts/restic-plane-common.sh
    book_paths=$(unit_staging_paths books ssd)
    export book_paths
}

# Every fixture is per test: each @test runs in its own process, so nothing may
# be left in a global a sibling test would race.
setup() {
    tmp=$BATS_TEST_TMPDIR
    mkdir -p "$tmp/bin" "$tmp/secrets" "$tmp/cache" "$tmp/drill_root" "$tmp/tar"
    : >"$tmp/secrets/restic-password.yaml"
    : >"$tmp/log"

    # A one-file tar stands in for the restored tree.
    printf 'known\n' >"$tmp/tar/known.txt"
    tar -cf "$tmp/payload.tar" -C "$tmp/tar" known.txt

    cat >"$tmp/bin/restic" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_LOG"
case $1 in
    -r) shift 2 ;;
esac
case $1 in
    snapshots)
        printf '[{"id":"snap0001","time":"2026-01-01T00:00:00Z","hostname":"smortress","tags":["unit:books","host:smortress","verified"],"paths":[]}]\n' ;;
    stats)
        printf '{"total_size":%s,"total_file_count":1}\n' "${FAKE_RESTORE_SIZE:-1000}" ;;
    dump)
        cat "$FAKE_PAYLOAD" ;;
    restore)
        target=""
        while [ $# -gt 1 ]; do
            case $1 in
                --target) target=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        [ -n "$target" ] || { echo "fake restic: restore without --target" >&2; exit 2; }
        # Real restore writes the snapshot's absolute paths under --target; the
        # suite passes the ones this unit should carry.
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            mkdir -p "$target$p"
        done <<<"${FAKE_STAGING_PATHS:-}"
        printf 'known\n' >"$target/known.txt" ;;
    *) printf 'fake restic: unexpected command: %s\n' "$*" >&2; exit 2 ;;
esac
SH
    chmod +x "$tmp/bin/restic"

    # df reports 1K blocks in field 4 of the second line, like df -Pk.
    cat >"$tmp/bin/df" <<'SH'
#!/usr/bin/env bash
cat <<LINE
Filesystem 1024-blocks Used Available Capacity Mounted on
fake ${FAKE_DF_BLOCKS:-100000000} 0 ${FAKE_DF_BLOCKS:-100000000} 1% /
LINE
SH
    chmod +x "$tmp/bin/df"

    df_blocks=100000000
    restore_size=1000
    staging=$book_paths
    method=
}

# drill [<args>...]: runs the drill against the fakes, leaving its status in `rc`,
# its stdout in `out` and its stderr in $tmp/stderr.
drill() {
    local -a vars=(
        PATH="$tmp/bin:$PATH"
        RESTIC_BIN="$tmp/bin/restic"
        RESTIC_BASE="$tmp/restic"
        RESTIC_STATE_ROOT="$tmp/state"
        RESTIC_CACHE_DIR="$tmp/cache"
        SMORTRESS_SECRETS_DIR="$tmp/secrets"
        RESTIC_DRILL_ROOT="$tmp/drill_root"
        FAKE_LOG="$tmp/log" FAKE_PAYLOAD="$tmp/payload.tar"
        FAKE_DF_BLOCKS="$df_blocks"
        FAKE_RESTORE_SIZE="$restore_size"
        FAKE_STAGING_PATHS="$staging"
    )
    if [[ -n $method ]]; then
        vars+=(RESTIC_DRILL_METHOD="$method")
    fi
    rc=0
    out=$(env "${vars[@]}" bash "$script" "$@" 2>"$tmp/stderr") || rc=$?
}

default_target() {
    find "$tmp/drill_root" -mindepth 1 -maxdepth 1 -type d -name 'ssd-books-*' -print -quit
}

# --- the default target is a data disk, not /var/tmp ------------------------

@test "a drill with room succeeds" {
    drill ssd books
    assert_equal "$rc" 0
}

@test "the default target lives under the drill root" {
    drill ssd books
    target=$(default_target)
    if [[ $target != "$tmp/drill_root"/ssd-books-* ]]; then
        printf 'got %q\n' "$target" >&2
        return 1
    fi
}

@test "the restored content lands in the target" {
    drill ssd books
    target=$(default_target)
    if [[ ! -f $target/known.txt ]]; then
        ls -A "$target" >&2 || true
        return 1
    fi
}

# --- the default method is restore; dump stays behind an override -------------

@test "a drill restores through restic restore" {
    drill ssd books
    if ! grep -qE ' restore .*--target' "$tmp/log"; then
        cat "$tmp/log" >&2
        return 1
    fi
}

@test "RESTIC_DRILL_METHOD=dump still drills through dump and tar" {
    method=dump
    drill ssd books
    assert_equal "$rc" 0
}

@test "the override reaches restic" {
    method=dump
    drill ssd books
    if ! grep -q ' dump ' "$tmp/log"; then
        cat "$tmp/log" >&2
        return 1
    fi
}

# --- the default restore's flags are part of the contract --------------------

@test "the default restore keeps holes and drops the SELinux label" {
    drill ssd books
    if ! grep -qF -- '--sparse --exclude-xattr security.selinux' "$tmp/log"; then
        cat "$tmp/log" >&2
        return 1
    fi
}

# --- a snapshot that lacks one of the unit's paths is not a drill -----------

@test "a snapshot missing one of the unit paths is refused" {
    staging=${book_paths%%$'\n'*}
    drill ssd books
    [[ $rc -ne 0 ]]
}

@test "the missing path is named" {
    staging=${book_paths%%$'\n'*}
    drill ssd books
    if ! grep -q 'restored an incomplete unit' "$tmp/stderr"; then
        cat "$tmp/stderr" >&2
        return 1
    fi
}

# --- an unknown method is a usage error, not a silent default ---------------

@test "an unknown method is a usage error" {
    method=bogus
    drill ssd books
    assert_equal "$rc" 2
}

# --- a target without room is refused before writing ------------------------

# 1 GiB of free blocks and a 2 GiB restore (plus the 2 GiB margin).
@test "a target without room is refused" {
    df_blocks=1048576
    restore_size=$((2 * 1024 ** 3))
    drill ssd books
    [[ $rc -ne 0 ]]
}

@test "the refusal names the way out" {
    df_blocks=1048576
    restore_size=$((2 * 1024 ** 3))
    drill ssd books
    if ! grep -q 'choose --target' "$tmp/stderr"; then
        cat "$tmp/stderr" >&2
        return 1
    fi
}

@test "nothing is restored when the size does not fit" {
    df_blocks=1048576
    restore_size=$((2 * 1024 ** 3))
    drill ssd books
    if grep -qE ' (dump|restore) ' "$tmp/log"; then
        cat "$tmp/log" >&2
        return 1
    fi
}

# --- a non-empty target is still refused ------------------------------------

@test "a non-empty target is refused" {
    mkdir -p "$tmp/drill_root/busy"
    printf 'x\n' >"$tmp/drill_root/busy/keep"
    drill ssd books --target "$tmp/drill_root/busy"
    [[ $rc -ne 0 ]]
}

# --- an unsizable snapshot is refused ---------------------------------------

@test "an unsizable snapshot is refused" {
    restore_size=not-a-number
    drill ssd books
    [[ $rc -ne 0 ]]
}
