#!/usr/bin/env bash
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
#   tests/apps/quota.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

script=scripts/apps-quota.sh
[[ -r $script ]] || {
  printf 'FAIL %s is missing\n' "$script" >&2
  exit 1
}

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1"
  [[ -n ${2:-} ]] && printf '     %s\n' "${2//$'\n'/$'\n'     }"
  return 0
}
is() { # got want label
    if [[ $1 == "$2" ]]; then ok "$3"; else bad "$3" "got '$1'"; fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/state/quota" "$work/state/project" "$work/apps"
: >"$work/log"

# State lives in files. `get` answers with a human value unless `-p` asks for
# exact bytes, which is what the real command does; a script that forgets `-p`
# therefore fails the comparisons instead of passing on names.
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

plan=$work/plan.json
apps=$work/apps
dataset=smortress/raw/apps
quota_key=${dataset//\//_}

run() {
    FAKE_LOG=$work/log FAKE_STATE=$work/state FAKE_DATASET=$dataset \
        APPS_PLAN=$plan APPS_ROOT=$apps APPS_OWNER=$(id -u):$(id -g) \
        APPS_SCHEMA=$root/scripts/apps-schema.py ZFS=$work/zfs \
        bash "$script" "$@" >"$work/stdout" 2>"$work/stderr"
}

reset_case() {
    : >"$work/log"
    rm -f "$plan"
    rm -rf "$work/state"
    mkdir -p "$work/state/quota" "$work/state/project"
    rm -rf "$apps"
    mkdir -p "$apps"
}

digest=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
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

quota_of() { cat "$work/state/quota/$quota_key.projectquota@$1" 2>/dev/null; }
project_of() { cat "$work/state/project/$1" 2>/dev/null; }

# --- applying a plan ---------------------------------------------------------

reset_case
plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 5G)" \
  --argjson b "$(app_entry beta 22999 4002 512M)" '{alpha: $a, beta: $b}')" >"$plan"
if run; then ok 'a valid plan applies'; else bad 'a valid plan applies' "$(cat "$work/stderr")"; fi
is "$(project_of alpha)" '4001 P' 'alpha gets its project id and inherit flag'
is "$(project_of beta)" '4002 P' 'beta gets its project id and inherit flag'
is "$(quota_of 4001)" $((5 * 1024 * 1024 * 1024)) 'alpha gets its quota in exact bytes'
is "$(quota_of 4002)" $((512 * 1024 * 1024)) 'beta gets its quota in exact bytes'
if grep -q -- "-r -s $apps/alpha" "$work/log"; then
    ok 'the project id is set recursively'
else
    bad 'the project id is set recursively' "$(cat "$work/log")"
fi
is "$(stat -c %a "$apps/alpha")" 700 'the app directory is created private'
is "$(cat "$work/state/quota/$quota_key.quota")" $((200 * 1024 ** 3)) 'the dataset carries the table quota'

: >"$work/log"
if run; then ok 'a second run converges'; else bad 'a second run converges' "$(cat "$work/stderr")"; fi
if grep -qE -- 'project -p| set ' "$work/log"; then
    bad 'a converged run writes nothing' "$(cat "$work/log")"
else
    ok 'a converged run writes nothing'
fi

# --- check mode --------------------------------------------------------------

if run --check; then ok '--check passes after an apply'; else bad '--check passes after an apply' "$(cat "$work/stderr")"; fi
printf '1\n' >"$work/state/quota/$quota_key.projectquota@4001"
if run --check; then bad '--check reports a changed quota'; else ok '--check reports a changed quota'; fi
if grep -q 'alpha' "$work/stderr"; then ok '--check names the drifted app'; else bad '--check names the drifted app' "$(cat "$work/stderr")"; fi

reset_case
plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 5G)" '{alpha: $a}')" >"$plan"
if run --check; then bad '--check fails when nothing was applied'; else ok '--check fails when nothing was applied'; fi

# `zfs project` prints P for a directory whose id was set explicitly and I for
# an inherited one; a state written by an older run carries I and must not read
# as drift.
run >/dev/null 2>&1
printf '4001 I\n' >"$work/state/project/alpha"
if run --check; then ok '--check accepts an inherited flag'; else bad '--check accepts an inherited flag'; fi

# A tree that lost the inherit flag would let new files escape the quota.
run >/dev/null 2>&1
printf '4001 -\n' >"$work/state/project/alpha"
if run --check; then bad '--check reports a lost inherit flag'; else ok '--check reports a lost inherit flag'; fi

# A retained id must not be handed to a new app.
reset_case
mkdir -p "$apps/orphan"
printf '4001 P\n' >"$work/state/project/orphan"
plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 5G)" '{alpha: $a}')" >"$plan"
if run; then bad 'a project id collision is refused'; else ok 'a project id collision is refused'; fi
if grep -q 'already stamped' "$work/stderr"; then ok 'the collision names the other tree'; else bad 'the collision names the other tree' "$(cat "$work/stderr")"; fi

# The tenant can replace its data directory with a symlink; a root applier must
# not stamp or trust it.
reset_case
mkdir -p "$apps/elsewhere"
ln -s "$apps/elsewhere" "$apps/alpha"
plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 5G)" '{alpha: $a}')" >"$plan"
if run; then bad 'a symlinked app directory is refused'; else ok 'a symlinked app directory is refused'; fi
if grep -q 'symlink' "$work/stderr"; then ok 'the symlink refusal is explicit'; else bad 'the symlink refusal is explicit' "$(cat "$work/stderr")"; fi

# A missing directory is drift, not something a check may pass over.
reset_case
plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 5G)" '{alpha: $a}')" >"$plan"
if run --check; then bad '--check reports a missing app directory'; else ok '--check reports a missing app directory'; fi
if grep -q 'is missing' "$work/stderr"; then ok 'the missing directory is named'; else bad 'the missing directory is named' "$(cat "$work/stderr")"; fi

# --- retained quotas are reported, not silently forgotten ---------------------

reset_case
plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 5G)" '{alpha: $a}')" >"$plan"
run >/dev/null 2>&1
printf '123\n' >"$work/state/quota/$quota_key.projectquota@9999"
run --check >/dev/null 2>&1 || true
if grep -q 'retained project quota for id 9999' "$work/stdout"; then
    ok 'a retained quota is listed'
else
    bad 'a retained quota is listed' "$(cat "$work/stdout" "$work/stderr")"
fi

# --- the plan is not trusted -------------------------------------------------

rejected() { # description, jq patch applied to a complete alpha entry
    reset_case
    plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 5G | jq "$2")" '{alpha: $a}')" >"$plan"
    if run; then bad "$1" "$(cat "$work/stderr")"; else ok "$1"; fi
    if grep -qE -- '( set |project -p)' "$work/log"; then
        bad "$1 changes nothing" "$(cat "$work/log")"
    fi
}

rejected 'a quota above the platform ceiling is rejected' '.quota = "60G"'
rejected 'an overflow-sized quota is rejected' '.quota = "18014398509481984K"'
rejected 'a malformed quota is rejected' '.quota = "5 gigabytes"'
rejected 'a non-numeric project id is rejected' '.projectId = "4001"'
rejected 'a zero project id is rejected' '.projectId = 0'
rejected 'a base path that disagrees with the name is rejected' '.basePath = "/apps/beta"'
rejected 'a zero quota is rejected' '.quota = "0G"'

# A duplicate id between two apps is a plan error, not a quota merge.
reset_case
plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 5G)" \
  --argjson b "$(app_entry beta 22999 4001 5G)" '{alpha: $a, beta: $b}')" >"$plan"
if run; then bad 'a duplicated project id is rejected'; else ok 'a duplicated project id is rejected'; fi

# An entry that is not an object must not be skipped by either consumer.
reset_case
printf '{"apps": {"alpha": "x"}}\n' >"$plan"
if run; then bad 'an app entry that is not an object is rejected'; else ok 'an app entry that is not an object is rejected'; fi
if grep -qE -- '( set |project -p)' "$work/log"; then
    bad 'a non-object entry changes nothing' "$(cat "$work/log")"
fi

# Invalid JSON is rejected before any pool write.
reset_case
printf 'not json\n' >"$plan"
if run; then bad 'invalid JSON is rejected'; else ok 'invalid JSON is rejected'; fi

# --- an empty tenant still bounds the dataset --------------------------------

reset_case
if run; then ok 'no plan is not an error'; else bad 'no plan is not an error' "$(cat "$work/stderr")"; fi
is "$(cat "$work/state/quota/$quota_key.quota")" $((200 * 1024 ** 3)) 'no plan still applies the dataset quota'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
