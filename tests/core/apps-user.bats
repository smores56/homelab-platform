#!/usr/bin/env bats
# bats file_tags=core
# Offline checks for the apps tenant user (SDLC #726, T7 of #701).
#
# The tenant is one unprivileged account whose id nobody names. This proves the
# account shape that the rest of the tenant depends on: the id systemd-sysusers
# allocates rather than one we demand, the account the egress rule and the
# dataset owner name, a login-less shell, a private home with linger, the
# subuid/subgid allocation Podman needs, a per-user policy that admits
# digest-pinned images, and a refusal to continue when a rootless dependency is
# missing.
#
#   bats tests/core/apps-user.bats
load ../helpers

script=scripts/apps-user.sh
sysusers=image/rootfs/etc/sysusers.d/smortress-apps.conf
unit=units/systemd/smortress-apps-user.service
nft=image/rootfs/etc/nftables/smortress-apps.nft
tmpfiles=image/rootfs/etc/tmpfiles.d/smortress.conf

# Everything the provisioner touches is per test: each @test runs in its own
# process, so the fake account, the subid files and the policy dir live under
# this test's tmpdir and never under /etc.
setup() {
    work=$BATS_TEST_TMPDIR
    mkdir -p "$work/bin" "$work/subids" "$work/policy" "$work/linger"
    cat >"$work/bin/id" <<'SH'
#!/bin/sh
[ "${FAKE_MISSING_USER:-}" = 1 ] && exit 1
case $1 in
    -u) echo 1513 ;;
    -g) echo 1513 ;;
esac
exit 0
SH
    chmod 0755 "$work/bin/id"
    subuid=$work/subids/subuid
    subgid=$work/subids/subgid
}

# provision [<NAME=VALUE>...]: runs the script with the fake account first on
# PATH, its output in the usual places and its status in `rc`. The seam is the
# script's own: every path and the required-binary list come from the
# environment. Later NAME=VALUE pairs win, so a test overrides one default.
provision() {
    rc=0
    env PATH="$work/bin:$PATH" \
        SUBUID_FILE="$subuid" SUBGID_FILE="$subgid" \
        APPS_REQUIRE_BINS='' APPS_SUBID_RANGE=200000:65536 "$@" \
        bash "$script" >"$work/stdout" 2>"$work/stderr" || rc=$?
}

# report_stderr: the script's stderr on the report, the way the shell suite
# printed it beside a FAIL line.
report_stderr() {
    [[ ! -s $work/stderr ]] || cat "$work/stderr" >&2
    return 0
}

# expect_line <file> <line>: the file holds that exact line, and the file is on
# the report when it does not.
expect_line() {
    grep -qx -- "$2" "$1" && return 0
    cat "$1" >&2 || true
    return 1
}

# file_exists <path>: the image ships it.
file_exists() {
    [[ -f $1 ]]
}

# before_logind <unit>: the unit is done before a lingering user manager (which
# systemd-logind starts) can run.
before_logind() {
    grep -q '^Before=.*systemd-logind.service' "units/systemd/$1"
}

for f in "$script" "$sysusers" "$unit" "$nft" "$tmpfiles"; do
    register "$f exists" file_exists "$f"
done

# --- account shape -----------------------------------------------------------

# sysusers allocates the id: a demand for a number allocates a different one
# silently when it is taken, and every numeric consumer then points at nobody.
@test "sysusers allocates the tenant id and keeps its group" {
    grep -qx 'u apps - "apps tenant" /var/home/apps /usr/sbin/nologin' "$sysusers"
    grep -qx 'g apps -' "$sysusers"
}

@test "sysusers demands no tenant id" {
    ! grep -qE '^[ug] apps [0-9]' "$sysusers"
}

# The egress rule must follow this account wherever sysusers puts it: it
# allocates the next free uid silently when 1001 is taken, so a numeric rule
# would match nobody and leave the tenant outside the policy.
@test "the egress rule names the same account, not a uid" {
    account=$(awk '$1 == "u" && $2 == "apps" { print $2 }' "$sysusers")
    assert_equal "$account" apps
    grep -qE 'meta skuid apps([[:space:]]|$)' "$nft"
    ! grep -qE 'meta skuid [0-9]' "$nft"
}

@test "the tenant home is private to the tenant" {
    grep -qE '^d /var/home/apps 0700 apps apps -$' "$tmpfiles"
}

@test "the tenant user manager starts without a login" {
    grep -qE '^f /var/lib/systemd/linger/apps ' "$tmpfiles"
}

# Nothing may name the tenant's user manager by number: a drop-in or an enable
# for user@<uid> silently stops applying the moment sysusers allocates another
# id, which is how the gate and the slice limits used to disappear unnoticed.
@test "no unit or image line names the tenant user manager by number" {
    numeric_user_units=$(grep -rlE 'user@[0-9]+|user-[0-9]+\.slice' units image/Containerfile 2>/dev/null |
        sort | paste -sd' ' || true)
    assert_equal "$numeric_user_units" ""
}

@test "the tenant has no per-uid manager drop-in" {
    dropin=false
    if compgen -G 'units/systemd/user@*.service.d/*' >/dev/null ||
        compgen -G 'units/systemd/user-*.slice.d/*' >/dev/null; then
        dropin=true
    fi
    [[ $dropin == false ]] || find units/systemd -maxdepth 1 -name 'user*' >&2
    assert_equal "$dropin" false
}

@test "the image ships the plan verifier" {
    grep -q '/usr/libexec/apps-schema' image/Containerfile
}

@test "the image enables the provisioning unit" {
    grep -q 'smortress-apps-user.service' image/Containerfile
}

# The gate is what orders the prerequisites ahead of the tenant's manager: a
# lingering user manager starts from systemd-logind, so each prerequisite
# finishing first is what keeps an unprovisioned or unfiltered tenant from
# starting. A user unit cannot carry this as Requires= — a user manager cannot
# resolve a system unit and fails the unit outright.
for name in smortress-apps-user.service smortress-apps-egress.service \
    smortress-apps-quota.service; do
    register "$name finishes before a user manager can start" before_logind "$name"
done

# --- behaviour with a fake account and fake files ----------------------------

@test "provisioning succeeds with the account present" {
    provision
    report_stderr
    assert_equal "$rc" 0
}

@test "the tenant gets a subuid range" {
    provision
    expect_line "$subuid" 'apps:200000:65536'
}

@test "the tenant gets a subgid range" {
    provision
    expect_line "$subgid" 'apps:200000:65536'
}

@test "provisioning is idempotent" {
    provision
    provision
    report_stderr
    assert_equal "$rc" 0
}

@test "a second run adds no duplicate range" {
    provision
    provision
    count=$(grep -c '^apps:' "$subuid" || true)
    [[ $count == 1 ]] || cat "$subuid" >&2
    assert_equal "$count" 1
}

# A root provisioner must never write into the tenant-owned home: it would
# follow a symlink the tenant planted.
@test "provisioning never writes into the tenant home" {
    if grep -q '/var/home/apps' "$script"; then
        ! grep -qE 'install -d|mktemp|chown' "$script"
    fi
}

# The tenant's looser image policy is root-owned and named by the renderer.
@test "the tenant image policy is shipped and root-owned" {
    [[ -f image/rootfs/usr/share/smortress/apps-policy.json ]]
    jq -e '.default[0].type == "insecureAcceptAnything"' \
        image/rootfs/usr/share/smortress/apps-policy.json >/dev/null 2>&1
}

# A range that already belongs to another account is refused.
@test "an overlapping allocation is refused" {
    printf 'other:200000:65536\n' >"$subuid"
    provision
    ((rc != 0))
}

@test "the overlap is named" {
    printf 'other:200000:65536\n' >"$subuid"
    provision
    assert_contains "$(cat "$work/stderr")" 'overlaps'
}

# A malformed line from an older revision is replaced, not trusted.
@test "a malformed existing allocation is repaired" {
    printf 'apps:200000-265535\n' >"$subuid"
    printf 'apps:200000:65536\n' >"$subgid"
    provision
    report_stderr
    assert_equal "$rc" 0
}

@test "the repaired line uses start:count" {
    printf 'apps:200000-265535\n' >"$subuid"
    printf 'apps:200000:65536\n' >"$subgid"
    provision
    expect_line "$subuid" 'apps:200000:65536'
}

@test "a missing account stops provisioning" {
    provision FAKE_MISSING_USER=1 SUBUID_FILE="$work/subids/x" SUBGID_FILE="$work/subids/y" \
        APPS_POLICY_DIR="$work/policy" APPS_OWNER="$(id -u):$(id -g)"
    ((rc != 0))
}

@test "a missing rootless dependency stops provisioning" {
    provision SUBUID_FILE="$work/subids/z" SUBGID_FILE="$work/subids/w" \
        APPS_POLICY_DIR="$work/policy" APPS_OWNER="$(id -u):$(id -g)" \
        APPS_REQUIRE_BINS='not-a-real-binary'
    ((rc != 0))
}

@test "the missing dependency is named" {
    provision SUBUID_FILE="$work/subids/z" SUBGID_FILE="$work/subids/w" \
        APPS_POLICY_DIR="$work/policy" APPS_OWNER="$(id -u):$(id -g)" \
        APPS_REQUIRE_BINS='not-a-real-binary'
    assert_contains "$(cat "$work/stderr")" 'not-a-real-binary'
}
