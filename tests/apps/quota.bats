#!/usr/bin/env bats
# bats file_tags=apps
# Offline checks for the apps-tenant quota applier (SDLC #726, T7 of #701).
#
# The tenant is the only writer that can fill the pool, so two quotas bound it:
# one on the `raw/apps` dataset, and a ZFS project quota per app directory with
# the inherit flag set. This proves the applier without a pool: exact-byte
# reads, the id and flag it stamps, the dataset ceiling from the storage table,
# a `--check` that reports drift (missing directory, lost inherit flag, wrong
# quota), id collisions with retained data, an informational orphan listing,
# and idempotency — a second run must not rewrite what already matches.
#
#   bats tests/apps/quota.bats
#
# Every test gets its own fake pool, plan and app root under
# $BATS_TEST_TMPDIR, so no state outlives the check that wrote it.
load ../helpers

script=scripts/apps-quota.sh
digest=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

setup() {
    [ -r "$script" ]
    work=$BATS_TEST_TMPDIR
    log=$work/log
    plan=$work/plan.json
    apps=$work/apps
    dataset=smortress/raw/apps
    quota_key=${dataset//\//_}
    mkdir -p "$work/state/quota" "$work/state/project" "$apps"
    : >"$log"
    install_zfs
}

# State lives in files. `get` answers with a human value unless `-p` asks for
# exact bytes, which is what the real command does; a script that forgets `-p`
# therefore fails the comparisons instead of passing on names.
install_zfs() {
    cat >"$work/zfs" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_LOG"
state=$FAKE_STATE
key() { printf '%s' "${1//\//_}"; }
exact=false
for arg in "$@"; do [[ $arg == -p ]] && exact=true; done
case $1 in
    project)
        shift
        id= dir= check=false list=false
        for arg in "$@"; do
            case $arg in
                -p) id=next ;;
                -r | -s) ;;
                -c) check=true ;;
                -d) list=true ;;
                *) if [[ ${id:-} == next ]]; then id=$arg; else dir=$arg; fi ;;
            esac
        done
        current=$(cat "$state/project/$(basename "$dir")" 2>/dev/null || echo "0 -")
        if $list; then
            printf '%s %s\n' ${current} "$dir"
        elif $check; then
            [[ ${current%% *} == "$id" ]] || printf '%s\n' "$dir"
        else
            printf '%s P\n' "$id" >"$state/project/$(basename "$dir")"
        fi ;;
    set)
        prop=$2 target=$3
        case $prop in
            projectquota@*) pid=${prop#projectquota@}; pid=${pid%%=*}
                printf '%s\n' "${prop#*=}" >"$state/quota/$(key "$target").projectquota@$pid" ;;
            quota=*) printf '%s\n' "${prop#*=}" >"$state/quota/$(key "$target").quota" ;;
            *) echo "fake zfs: unsupported property $prop" >&2; exit 2 ;;
        esac ;;
    get)
        args=("$@")
        prop=${args[${#args[@]}-2]}
        target=${args[${#args[@]}-1]}
        case $prop in
            all)
                for f in "$state"/quota/*.projectquota@*; do
                    [[ -f $f ]] || continue
                    base=$(basename "$f")
                    printf '%s\t%s\n' "${base##*.}" "$(cat "$f")"
                done ;;
            projectquota@*) f=$state/quota/$(key "$target").projectquota@${prop#projectquota@} ;;
            quota) f=$state/quota/$(key "$target").quota ;;
            *) echo "fake zfs: unsupported get $prop" >&2; exit 2 ;;
        esac
        if [[ $prop != all ]]; then
            if [[ ! -f $f ]]; then
                if $exact; then printf '0\n'; else printf -- '-\n'; fi
            elif $exact; then
                cat "$f"
            else
                printf '1G\n'
            fi
        fi ;;
    list) printf '%s\n' "$FAKE_DATASET" ;;
    *) echo "fake zfs: unsupported command: $*" >&2; exit 2 ;;
esac
EOF
    chmod +x "$work/zfs"
}

# quota_run [args...]: the applier against the fake pool. stdout and stderr are
# kept per test, and the caller reads its own.
quota_run() {
    FAKE_LOG=$log FAKE_STATE=$work/state FAKE_DATASET=$dataset \
        APPS_PLAN=$plan APPS_ROOT=$apps APPS_OWNER=$(id -u):$(id -g) \
        APPS_SCHEMA=$repo_root/scripts/apps-schema.py ZFS=$work/zfs \
        bash "$script" "$@" >"$work/stdout" 2>"$work/stderr"
}

app_entry() { # name port project quota
    jq -cn --arg n "$1" --argjson port "$2" --argjson project "$3" \
        --arg quota "$4" --arg digest "$digest" '{
            image: "ghcr.io/example/\($n)@sha256:\($digest)",
            basePath: "/apps/\($n)",
            dataPath: "/srv/apps/\($n)",
            loopbackPort: $port,
            projectId: $project,
            quota: $quota,
            network: "pasta",
            mcs: "s0:c1,c2",
            secretNames: {},
            unitName: "\($n).container"
        }'
}

plan_with() { jq -cn --argjson apps "$1" '{version: 1, apps: $apps}'; }

# alpha_plan [jq patch]: one complete alpha entry, optionally patched.
alpha_plan() {
    local entry
    entry=$(app_entry alpha 21234 4001 5G)
    if [[ -n ${1:-} ]]; then entry=$(jq -c "$1" <<<"$entry"); fi
    plan_with "$(jq -cn --argjson a "$entry" '{alpha: $a}')" >"$plan"
}

two_apps_plan() {
    plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 5G)" \
        --argjson b "$(app_entry beta 22999 4002 512M)" '{alpha: $a, beta: $b}')" >"$plan"
}

quota_of() { cat "$work/state/quota/$quota_key.projectquota@$1" 2>/dev/null; }
project_of() { cat "$work/state/project/$1" 2>/dev/null; }

# --- applying a plan ---------------------------------------------------------

@test "a valid plan applies" {
    two_apps_plan
    local rc=0
    quota_run || rc=$?
    assert_equal "$rc" 0
}

@test "alpha gets its project id and inherit flag" {
    two_apps_plan
    quota_run || true
    assert_equal "$(project_of alpha)" '4001 P'
}

@test "beta gets its project id and inherit flag" {
    two_apps_plan
    quota_run || true
    assert_equal "$(project_of beta)" '4002 P'
}

@test "alpha gets its quota in exact bytes" {
    two_apps_plan
    quota_run || true
    assert_equal "$(quota_of 4001)" $((5 * 1024 * 1024 * 1024))
}

@test "beta gets its quota in exact bytes" {
    two_apps_plan
    quota_run || true
    assert_equal "$(quota_of 4002)" $((512 * 1024 * 1024))
}

@test "the project id is set recursively" {
    two_apps_plan
    quota_run || true
    grep -q -- "-r -s $apps/alpha" "$log"
}

@test "the app directory is created private" {
    two_apps_plan
    quota_run || true
    assert_equal "$(stat -c %a "$apps/alpha")" 700
}

@test "the dataset carries the table quota" {
    two_apps_plan
    quota_run || true
    assert_equal "$(cat "$work/state/quota/$quota_key.quota")" $((200 * 1024 ** 3))
}

@test "a second run converges" {
    two_apps_plan
    quota_run || true
    local rc=0
    quota_run || rc=$?
    assert_equal "$rc" 0
}

@test "a converged run writes nothing" {
    two_apps_plan
    quota_run || true
    : >"$log"
    quota_run || true
    if grep -qE -- 'project -p| set ' "$log"; then
        printf 'a converged run wrote:\n%s\n' "$(cat "$log")" >&2
        return 1
    fi
}

# --- check mode --------------------------------------------------------------

@test "--check passes after an apply" {
    alpha_plan
    quota_run || true
    local rc=0
    quota_run --check || rc=$?
    assert_equal "$rc" 0
}

@test "--check reports a changed quota" {
    alpha_plan
    quota_run || true
    printf '1\n' >"$work/state/quota/$quota_key.projectquota@4001"
    local rc=0
    quota_run --check || rc=$?
    assert_not_equal "$rc" 0
}

@test "--check names the drifted app" {
    alpha_plan
    quota_run || true
    printf '1\n' >"$work/state/quota/$quota_key.projectquota@4001"
    quota_run --check || true
    grep -q 'alpha' "$work/stderr"
}

@test "--check fails when nothing was applied" {
    alpha_plan
    local rc=0
    quota_run --check || rc=$?
    assert_not_equal "$rc" 0
}

# `zfs project` prints P for a directory whose id was set explicitly and I for
# an inherited one; a state written by an older run carries I and must not read
# as drift.
@test "--check accepts an inherited flag" {
    alpha_plan
    quota_run || true
    printf '4001 I\n' >"$work/state/project/alpha"
    local rc=0
    quota_run --check || rc=$?
    assert_equal "$rc" 0
}

# A tree that lost the inherit flag would let new files escape the quota.
@test "--check reports a lost inherit flag" {
    alpha_plan
    quota_run || true
    printf '4001 -\n' >"$work/state/project/alpha"
    local rc=0
    quota_run --check || rc=$?
    assert_not_equal "$rc" 0
}

# A retained id must not be handed to a new app.
@test "a project id collision is refused" {
    mkdir -p "$apps/orphan"
    printf '4001 P\n' >"$work/state/project/orphan"
    alpha_plan
    local rc=0
    quota_run || rc=$?
    assert_not_equal "$rc" 0
}

@test "the collision names the other tree" {
    mkdir -p "$apps/orphan"
    printf '4001 P\n' >"$work/state/project/orphan"
    alpha_plan
    quota_run || true
    grep -q 'already stamped' "$work/stderr"
}

# The tenant can replace its data directory with a symlink; a root applier must
# not stamp or trust it.
@test "a symlinked app directory is refused" {
    mkdir -p "$apps/elsewhere"
    ln -s "$apps/elsewhere" "$apps/alpha"
    alpha_plan
    local rc=0
    quota_run || rc=$?
    assert_not_equal "$rc" 0
}

@test "the symlink refusal is explicit" {
    mkdir -p "$apps/elsewhere"
    ln -s "$apps/elsewhere" "$apps/alpha"
    alpha_plan
    quota_run || true
    grep -q 'symlink' "$work/stderr"
}

# A missing directory is drift, not something a check may pass over.
@test "--check reports a missing app directory" {
    alpha_plan
    local rc=0
    quota_run --check || rc=$?
    assert_not_equal "$rc" 0
}

@test "the missing directory is named" {
    alpha_plan
    quota_run --check || true
    grep -q 'is missing' "$work/stderr"
}

# --- retained quotas are reported, not silently forgotten ---------------------

@test "a retained quota is listed" {
    alpha_plan
    quota_run || true
    printf '123\n' >"$work/state/quota/$quota_key.projectquota@9999"
    quota_run --check || true
    grep -q 'retained project quota for id 9999' "$work/stdout"
}

# --- the plan is not trusted -------------------------------------------------

rejected_case() { # jq patch applied to a complete alpha entry
    local rc=0
    alpha_plan "$1"
    quota_run || rc=$?
    assert_not_equal "$rc" 0
    if grep -qE -- '( set |project -p)' "$log"; then
        printf 'a rejected plan changed the pool:\n%s\n' "$(cat "$log")" >&2
        return 1
    fi
}

while IFS='|' read -r label patch; do
    register "$label" rejected_case "$patch"
done <<'CASES'
a quota above the platform ceiling is rejected|.quota = "60G"
an overflow-sized quota is rejected|.quota = "18014398509481984K"
a malformed quota is rejected|.quota = "5 gigabytes"
a non-numeric project id is rejected|.projectId = "4001"
a zero project id is rejected|.projectId = 0
a base path that disagrees with the name is rejected|.basePath = "/apps/beta"
a zero quota is rejected|.quota = "0G"
CASES

# A duplicate id between two apps is a plan error, not a quota merge.
@test "a duplicated project id is rejected" {
    plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 5G)" \
        --argjson b "$(app_entry beta 22999 4001 5G)" '{alpha: $a, beta: $b}')" >"$plan"
    local rc=0
    quota_run || rc=$?
    assert_not_equal "$rc" 0
}

# An entry that is not an object must not be skipped by either consumer.
@test "an app entry that is not an object is rejected" {
    printf '{"apps": {"alpha": "x"}}\n' >"$plan"
    local rc=0
    quota_run || rc=$?
    assert_not_equal "$rc" 0
    if grep -qE -- '( set |project -p)' "$log"; then
        printf 'a non-object entry changed the pool:\n%s\n' "$(cat "$log")" >&2
        return 1
    fi
}

# Invalid JSON is rejected before any pool write.
@test "invalid JSON is rejected" {
    printf 'not json\n' >"$plan"
    local rc=0
    quota_run || rc=$?
    assert_not_equal "$rc" 0
}

# --- an empty tenant still bounds the dataset --------------------------------

@test "no plan is not an error" {
    local rc=0
    quota_run || rc=$?
    assert_equal "$rc" 0
}

@test "no plan still applies the dataset quota" {
    quota_run || true
    assert_equal "$(cat "$work/state/quota/$quota_key.quota")" $((200 * 1024 ** 3))
}
