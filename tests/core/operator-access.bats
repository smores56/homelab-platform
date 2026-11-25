#!/usr/bin/env bats
# bats file_tags=core
# Offline checks for scripts/operator-access.sh.
#
# The host half — a real dataset owned 1000:1000 and the real operator account —
# is section 40.6 of docs/manual-steps.md. This proves the half that does not
# need root or a real dataset: the account is resolved instead of assumed, the
# ACL specification carries the operator's name and numeric 1000 in both the
# access and the default entries, --check writes nothing, a path that is not a
# mountpoint is refused, and an account that does not exist is louder than a
# grant to the wrong uid.
load ../helpers

script=scripts/operator-access.sh

# Both stubs and the scratch tree are per test: each @test runs in its own
# process, so nothing may be left in a global a sibling test would race.
setup() {
    tmp=$BATS_TEST_TMPDIR
    mkdir -p "$tmp/bin" "$tmp/mnt/sub"
    : >"$tmp/mnt/notes.md"
    : >"$tmp/mnt/sub/a.txt"
    mnt=$(realpath "$tmp/mnt")

    # A mountinfo the script can be pointed at: field 5 is the mount point,
    # exactly the comparison zfs-ready and restic-plane-common make. The scratch
    # tree is not a mount, and the script must not need one to prove its own
    # behaviour.
    printf '%s\n' '36 25 0:32 / / rw,relatime - ext4 /dev/sda1 rw' \
        "77 25 0:50 / $mnt rw,relatime shared:9 - zfs smortress/raw/files rw,xattr,posixacl" \
        >"$tmp/mountinfo"
    printf '%s\n' '36 25 0:32 / / rw,relatime - ext4 /dev/sda1 rw' >"$tmp/mountinfo-root"

    # The account exists in no fixture: getent is stubbed so the checks do not
    # depend on the host's NSS, and a uid that is nobody's on the host proves the
    # number is resolved rather than written into the script.
    cat >"$tmp/bin/getent" <<'SH'
#!/bin/sh
printf 'getent %s\n' "$*" >>"$STUB_LOG"
if [ "$1" != passwd ] || [ "${GETENT_UID:-}" = none ]; then exit 2; fi
printf '%s:x:%s:%s::/home/%s:/usr/bin/bash\n' "$2" "$GETENT_UID" "$GETENT_UID" "$2"
SH
    cat >"$tmp/bin/setfacl" <<'SH'
#!/bin/sh
printf 'setfacl %s\n' "$*" >>"$STUB_LOG"
exit 0
SH
    cat >"$tmp/bin/getfacl" <<'SH'
#!/bin/sh
printf 'getfacl %s\n' "$*" >>"$STUB_LOG"
cat "${GETFACL_OUT:-/dev/null}"
SH
    chmod 0755 "$tmp/bin"/*

    # What getfacl prints for a tree that already carries the grant, one block
    # per path, directories with their default entries. The uid is the one the
    # getent stub resolves, so a drift check that ignored the resolved account
    # would call this tree granted.
    granted_access='user::rwx
user:4242:rwx
user:1000:rwx
group::---
group:1000:rwx
mask::rwx
other::---'
    granted_default='default:user::rwx
default:user:4242:rwx
default:user:1000:rwx
default:group::---
default:group:1000:rwx
default:mask::rwx
default:other::---'
    : >"$tmp/granted"
    for p in "$mnt" "$mnt/sub"; do
        printf '# file: %s\n%s\n%s\n' "$p" "$granted_access" "$granted_default" >>"$tmp/granted"
    done
    for p in "$mnt/notes.md" "$mnt/sub/a.txt"; do
        printf '# file: %s\n%s\n' "$p" "$granted_access" >>"$tmp/granted"
    done

    getent_uid=4242
    operator_account=smores
    getfacl_out=/dev/null
}

# drive <log> <mountinfo> [<script args>...]: runs the script with the stubs on
# PATH, leaving its output in `out` and its status in `rc`.
drive() {
    local log=$1 info=$2
    shift 2
    : >"$log"
    rc=0
    out=$(env PATH="$tmp/bin:$PATH" STUB_LOG="$log" GETENT_UID="$getent_uid" \
        OPERATOR_ACCOUNT="$operator_account" OPERATOR_ACCESS_MOUNTINFO="$info" \
        GETFACL_OUT="$getfacl_out" \
        "$script" "$@" 2>&1) || rc=$?
}

@test "operator-access is executable" {
    [[ -x $script ]]
}

@test "operator-access parses" {
    bash -n "$script"
}

# An ungranted tree is what a restore leaves: restic does not carry POSIX ACLs.
@test "--check exits 1 on a tree with no grant" {
    drive "$BATS_TEST_TMPDIR/log-check" "$tmp/mountinfo" --check "$mnt"
    assert_equal "$rc" 1
}

@test "--check calls no setfacl" {
    drive "$BATS_TEST_TMPDIR/log-check" "$tmp/mountinfo" --check "$mnt"
    assert_equal "$(grep -c '^setfacl' "$BATS_TEST_TMPDIR/log-check" || true)" 0
}

@test "--check names the paths that lack the grant" {
    drive "$BATS_TEST_TMPDIR/log-check" "$tmp/mountinfo" --check "$mnt"
    assert_contains "$out" 'lack the grant'
}

@test "apply exits 0 against stubs" {
    drive "$BATS_TEST_TMPDIR/log-apply" "$tmp/mountinfo" "$mnt"
    assert_equal "$rc" 0
}

@test "the access ACL names the operator and numeric 1000, and closes the rest" {
    drive "$BATS_TEST_TMPDIR/log-apply" "$tmp/mountinfo" "$mnt"
    assert_equal \
        "$(sed -n 's/^setfacl -R -m \(u:.*\) -- .*/\1/p' "$BATS_TEST_TMPDIR/log-apply")" \
        'u:smores:rwX,u:1000:rwX,g:1000:rwX,g::---,m::rwx,o::---'
}

@test "the default ACL carries the same grant for content created later" {
    drive "$BATS_TEST_TMPDIR/log-apply" "$tmp/mountinfo" "$mnt"
    assert_equal \
        "$(sed -n 's/^setfacl -R -m \(d:.*\) -- .*/\1/p' "$BATS_TEST_TMPDIR/log-apply")" \
        'd:u:smores:rwX,d:u:1000:rwX,d:g:1000:rwX,d:g::---,d:m::rwx,d:o::---'
}

@test "the uid in the report is the one NSS resolved" {
    drive "$BATS_TEST_TMPDIR/log-apply" "$tmp/mountinfo" "$mnt"
    assert_contains "$out" 'uid 4242'
}

# A different account must reach the grant by its own name: a hardcoded smores
# would grant the wrong person after a rebuild.
@test "the grant follows the resolved account, not a hardcoded name" {
    operator_account=backup
    getent_uid=4243
    drive "$BATS_TEST_TMPDIR/log-other" "$tmp/mountinfo" "$mnt"
    assert_equal \
        "$(sed -n 's/^setfacl -R -m \(u:.*\) -- .*/\1/p' "$BATS_TEST_TMPDIR/log-other")" \
        'u:backup:rwX,u:1000:rwX,g:1000:rwX,g::---,m::rwx,o::---'
}

# --check on a granted tree reports and writes nothing.
@test "--check exits 0 on a granted tree" {
    getfacl_out=$tmp/granted
    drive "$BATS_TEST_TMPDIR/log-clean" "$tmp/mountinfo" --check "$mnt"
    assert_equal "$rc" 0
}

@test "--check on a granted tree calls no setfacl" {
    getfacl_out=$tmp/granted
    drive "$BATS_TEST_TMPDIR/log-clean" "$tmp/mountinfo" --check "$mnt"
    assert_equal "$(grep -c '^setfacl' "$BATS_TEST_TMPDIR/log-clean" || true)" 0
}

# A directory on the root filesystem is a bug, not a target: a restore lands
# under a mountpoint.
@test "a path that is not a mountpoint is refused" {
    drive "$BATS_TEST_TMPDIR/log-nomount" "$tmp/mountinfo-root" "$mnt"
    assert_equal "$rc" 1
}

@test "the refusal happens before any write" {
    drive "$BATS_TEST_TMPDIR/log-nomount" "$tmp/mountinfo-root" "$mnt"
    assert_equal "$(grep -c '^setfacl' "$BATS_TEST_TMPDIR/log-nomount" || true)" 0
}

@test "the refusal says why" {
    drive "$BATS_TEST_TMPDIR/log-nomount" "$tmp/mountinfo-root" "$mnt"
    assert_contains "$out" 'not a mountpoint'
}

# An account that does not exist must fail, never fall back to a uid.
@test "a missing operator account is fatal" {
    getent_uid=none
    drive "$BATS_TEST_TMPDIR/log-noaccount" "$tmp/mountinfo" "$mnt"
    assert_equal "$rc" 1
}

@test "a missing account grants nothing" {
    getent_uid=none
    drive "$BATS_TEST_TMPDIR/log-noaccount" "$tmp/mountinfo" "$mnt"
    assert_equal "$(grep -c '^setfacl' "$BATS_TEST_TMPDIR/log-noaccount" || true)" 0
}

@test "the missing account is named" {
    getent_uid=none
    drive "$BATS_TEST_TMPDIR/log-noaccount" "$tmp/mountinfo" "$mnt"
    assert_contains "$out" 'no such account: smores'
}

# Argument handling, the way the other core suites check it.
@test "an unknown flag is refused" {
    drive "$BATS_TEST_TMPDIR/log-flag" "$tmp/mountinfo" --nonsense
    assert_equal "$rc" 2
}

@test "a missing path is refused" {
    drive "$BATS_TEST_TMPDIR/log-bare" "$tmp/mountinfo"
    assert_equal "$rc" 2
}

@test "--help succeeds" {
    drive "$BATS_TEST_TMPDIR/log-help" "$tmp/mountinfo" --help
    assert_equal "$rc" 0
}
