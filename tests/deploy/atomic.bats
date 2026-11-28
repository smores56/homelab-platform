#!/usr/bin/env bats
# bats file_tags=deploy
# Offline parity check for the one durability rule behind two atomic writes
# (SDLC #812): the state library's `atomic_write` and the verifier's
# `write_atomic`.
#
# The three are separate code because nothing shared can be installed where the
# listener and the drain both run, so the rule survives only as long as each
# copy keeps it: the target holds one whole payload (never a truncation tail), a
# replace renames a new inode over it instead of rewriting it in place, it is 0600
# whoever wrote it, no temp file outlives the call, and a directory that cannot be
# written fails the call with nothing left behind. Every case below is
# driven against each implementation from the same fixture. No root, no bootc,
# no network.
#
#   tests/deploy/atomic.bats
load ../helpers

lib=scripts/deploy-state.sh
verify=bootc/server/rootfs/usr/libexec/deploy-verify.py

setup() {
    for file in "$lib" "$verify"; do
        [[ -r $file ]] || fail "$file is missing"
    done
    command -v python3 >/dev/null || fail "python3 is required"
}

# One fixture per case: a private 0700 directory, the target the implementation
# writes, and the payloads. `short` is a strict prefix of `long`: an
# implementation that rewrites the file in place without truncating leaves the
# old tail behind and fails both the size and the content check.
fixture() { # <impl>; sets dir, target, long, short
    dir=$BATS_TEST_TMPDIR/$1
    mkdir -p "$dir"
    chmod 0700 "$dir"
    target=$dir/state.json
    long=$BATS_TEST_TMPDIR/payload.long
    short=$BATS_TEST_TMPDIR/payload.short
    head -c 4096 /dev/zero | tr '\0' 'x' >"$long"
    head -c 24 "$long" >"$short"
    if [[ $1 == state ]]; then
        # The library reads its state directory and lock path when it is
        # sourced, so the case owns both.
        export DEPLOY_STATE_DIR=$BATS_TEST_TMPDIR/state
        export DEPLOY_LOCK_FILE=$BATS_TEST_TMPDIR/deploy.lock
        mkdir -p "$DEPLOY_STATE_DIR"
    fi
}

strays_in() { # <dir> <target name>: everything beside the target, whatever it is called
    find "$1" -mindepth 1 -maxdepth 1 ! -name "$2" | wc -l
}

label_for() { # <impl>
    case $1 in
        state) printf 'atomic_write (deploy-state.sh)' ;;
        verify) printf 'write_atomic (deploy-verify.py)' ;;
    esac
}

# Each implementation's own entry point, unchanged: the library reads its
# content from stdin, the verifier takes (path, bytes). The loader is the one
# tests/deploy/verify.bats uses.
write_with() { # <impl> <path> <payload-file>
    case $1 in
        state)
            # shellcheck source=/dev/null
            source "$lib"
            atomic_write "$2" <"$3"
            ;;
        verify)
            python3 - "$2" "$3" "$verify" <<'PY'
import importlib.util
import sys

path, payload, verify = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("deploy_verify", verify)
module = importlib.util.module_from_spec(spec)
sys.modules["deploy_verify"] = module
spec.loader.exec_module(module)
with open(payload, "rb") as handle:
    data = handle.read()
module.write_atomic(path, data)
PY
            ;;
    esac
}

# --- a fresh write ---------------------------------------------------------
check_writes_the_record() { # <impl>
    fixture "$1"
    run write_with "$1" "$target" "$long"
    assert_success
}

check_writes_exactly_the_payload() {
    fixture "$1"
    write_with "$1" "$target" "$long"
    run cmp -s "$target" "$long"
    assert_success
}

check_writes_the_whole_payload() {
    fixture "$1"
    write_with "$1" "$target" "$long"
    assert_equal "$(stat -c %s "$target")" 4096
}

check_writes_the_record_0600() {
    fixture "$1"
    write_with "$1" "$target" "$long"
    assert_equal "$(stat -c %a "$target")" 600
}

check_leaves_no_temp_file() {
    fixture "$1"
    write_with "$1" "$target" "$long"
    assert_equal "$(strays_in "$dir" state.json)" 0
}

# --- replacing a longer payload over a wider-mode file ---------------------
# The previous record is both longer and more readable than the new one, so
# this is the case where a rename would keep the old tail or the old mode.
replaced() { # <impl>: the target holds the long payload at 0664
    fixture "$1"
    write_with "$1" "$target" "$long"
    chmod 0664 "$target"
}

check_replaces_an_existing_record() {
    replaced "$1"
    run write_with "$1" "$target" "$short"
    assert_success
}

check_keeps_exactly_the_new_payload() {
    replaced "$1"
    write_with "$1" "$target" "$short"
    run cmp -s "$target" "$short"
    assert_success
}

check_leaves_no_tail_from_the_longer_payload() {
    replaced "$1"
    write_with "$1" "$target" "$short"
    assert_equal "$(stat -c %s "$target")" 24
}

check_replaces_the_mode_with_0600() {
    replaced "$1"
    write_with "$1" "$target" "$short"
    assert_equal "$(stat -c %a "$target")" 600
}

# The inode is the only thing an outside reader can see. It proves the target was
# not truncated in place: an unlink-and-create lands a fresh inode just as a
# rename does, so this assertion cannot tell a rename from a delete-then-create,
# and it does not claim to -- the rename itself is the implementation's business.
check_does_not_truncate_the_record_in_place() {
    replaced "$1"
    ino_before=$(stat -c %i -- "$target")
    write_with "$1" "$target" "$short"
    [[ -e $target ]] || fail "$target is gone"
    assert_not_equal "$(stat -c %i -- "$target")" "$ino_before"
}

check_leaves_no_temp_file_after_a_replace() {
    replaced "$1"
    write_with "$1" "$target" "$short"
    assert_equal "$(strays_in "$dir" state.json)" 0
}

# --- a directory that cannot be written ------------------------------------
# The mktemp/open of the temp file is the first write, so this fails before
# the rename: no partial target, and nothing to clean up afterwards.
unwritable() { # <impl>: sets locked, a 0500 directory beside the target
    fixture "$1"
    locked=$dir/locked
    mkdir -p "$locked"
    chmod 0500 "$locked"
    # The probe, not `EUID -eq 0`: root, a uid holding CAP_DAC_OVERRIDE and some
    # overlay/9p mounts all keep writing through 0500, and failing such a host
    # would report a hole in the implementation that is really in the filesystem.
    if [[ -w $locked ]]; then
        skip "this filesystem does not enforce the mode"
    fi
}

check_fails_on_an_unwritable_directory() {
    unwritable "$1"
    rc=0
    write_with "$1" "$locked/state.json" "$short" 2>/dev/null || rc=$?
    assert_not_equal "$rc" 0
    chmod 0700 "$locked"
}

check_leaves_no_temp_file_and_no_partial_record() {
    unwritable "$1"
    write_with "$1" "$locked/state.json" "$short" 2>/dev/null || true
    assert_equal "$(strays_in "$locked" state.json)" 0
    chmod 0700 "$locked"
}

# The old suite's `for impl in state verify receiver`, now without the receiver
# (#1018): thirteen cases against each copy, from one fixture, so a case that
# lands in only one of the two copies shows up as a name missing from this file.
for impl in state verify; do
    who=$(label_for "$impl")
    register "$who writes the record" check_writes_the_record "$impl"
    register "$who writes exactly the payload" check_writes_exactly_the_payload "$impl"
    register "$who writes the whole payload" check_writes_the_whole_payload "$impl"
    register "$who writes the record 0600" check_writes_the_record_0600 "$impl"
    register "$who leaves no temp file" check_leaves_no_temp_file "$impl"
    register "$who replaces an existing record" check_replaces_an_existing_record "$impl"
    register "$who keeps exactly the new payload" check_keeps_exactly_the_new_payload "$impl"
    register "$who leaves no tail from the longer payload" check_leaves_no_tail_from_the_longer_payload "$impl"
    register "$who replaces the mode with 0600" check_replaces_the_mode_with_0600 "$impl"
    register "$who does not truncate the record in place" check_does_not_truncate_the_record_in_place "$impl"
    register "$who leaves no temp file after a replace" check_leaves_no_temp_file_after_a_replace "$impl"
    register "$who fails on an unwritable directory" check_fails_on_an_unwritable_directory "$impl"
    register "$who leaves no temp file and no partial record behind" check_leaves_no_temp_file_and_no_partial_record "$impl"
done
