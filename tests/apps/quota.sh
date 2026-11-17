#!/usr/bin/env bash
# Offline checks for the apps-tenant quota applier (SDLC #726, T7 of #701).
#
# The tenant is the only writer that can fill the pool, so two quotas bound it:
# one on the `raw/apps` dataset, and a ZFS project quota per app directory. This
# proves the applier without a pool: the project id and quota it sets, the
# dataset ceiling from the storage table, a `--check` that reports drift, and a
# refusal to apply a plan that names a quota above the platform ceiling.
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

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# State lives in files so the fake zfs can answer `get` and `project -c`.
mkdir -p "$work/state/quota" "$work/state/project" "$work/apps"
: >"$work/log"

cat >"$work/zfs" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_LOG"
state=$FAKE_STATE
key() { printf '%s' "${1//\//_}"; }
case $1 in
    project)
        shift
        id= dir= check=false
        for arg in "$@"; do
            case $arg in
                -p) id=next ;;
                -r | -s) ;;
                *) if [[ ${id:-} == next ]]; then id=$arg; else dir=$arg; fi ;;
            esac
        done
        # `-c` is the check mode; the flag is positional before -p.
        case " $* " in *" -c "*) check=true ;; esac
        if $check; then
            want=$(cat "$state/project/$(basename "$dir")" 2>/dev/null || echo 0)
            [[ $want == "$id" ]] || printf '%s\n' "$dir"
        else
            printf '%s\n' "$id" >"$state/project/$(basename "$dir")"
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
        target=${args[${#args[@]}-1]}
        prop=${args[${#args[@]}-2]}
        case $prop in
            projectquota@*) f=$state/quota/$(key "$target").projectquota@${prop#projectquota@} ;;
            quota) f=$state/quota/$(key "$target").quota ;;
            *) echo "fake zfs: unsupported get $prop" >&2; exit 2 ;;
        esac
        if [[ -f $f ]]; then cat "$f"; else printf -- '-\n'; fi ;;
    list) printf '%s\n' "$FAKE_DATASET" ;;
    *) echo "fake zfs: unsupported command: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$work/zfs"

plan=$work/plan.json
apps=$work/apps
dataset=smortress/raw/apps

run() {
    FAKE_LOG=$work/log FAKE_STATE=$work/state FAKE_DATASET=$dataset \
        APPS_PLAN=$plan APPS_ROOT=$apps APPS_OWNER=$(id -u):$(id -g) ZFS=$work/zfs \
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

is() { # got want label
    if [[ $1 == "$2" ]]; then ok "$3"; else bad "$3" "got '$1'"; fi
}
quota_of() { cat "$work/state/quota/${dataset//\//_}.projectquota@$1" 2>/dev/null; }
project_of() { cat "$work/state/project/$1" 2>/dev/null; }

# --- applying a plan ---------------------------------------------------------

reset_case
cat >"$plan" <<'EOF'
{"version": 1, "apps": {
  "alpha": {"basePath": "/apps/alpha", "loopbackPort": 21234, "projectId": 4001, "quota": "5G", "reachable": true},
  "beta": {"basePath": "/apps/beta", "loopbackPort": 22999, "projectId": 4002, "quota": "512M", "reachable": true}
}}
EOF
if run; then ok 'a valid plan applies'; else bad 'a valid plan applies' "$(cat "$work/stderr")"; fi
is "$(project_of alpha)" 4001 'alpha gets its project id'
is "$(project_of beta)" 4002 'beta gets its project id'
is "$(quota_of 4001)" $((5 * 1024 * 1024 * 1024)) 'alpha gets its quota in bytes'
is "$(quota_of 4002)" $((512 * 1024 * 1024)) 'beta gets its quota in bytes'
if grep -q -- "-r -s $apps/alpha" "$work/log"; then
    ok 'the project id is inherited by new files'
else
    bad 'the project id is inherited by new files' "$(cat "$work/log")"
fi
is "$(stat -c %a "$apps/alpha")" 700 'the app directory is created private'
is "$(cat "$work/state/quota/${dataset//\//_}.quota")" $((200 * 1024 ** 3)) 'the dataset carries the table quota'

# --- check mode --------------------------------------------------------------

if run --check; then ok '--check passes after an apply'; else bad '--check passes after an apply' "$(cat "$work/stderr")"; fi
printf '1\n' >"$work/state/quota/${dataset//\//_}.projectquota@4001"
if run --check; then bad '--check reports a changed quota'; else ok '--check reports a changed quota'; fi
if grep -q 'alpha' "$work/stderr"; then ok '--check names the drifted app'; else bad '--check names the drifted app' "$(cat "$work/stderr")"; fi

reset_case
cat >"$plan" <<'EOF'
{"version": 1, "apps": {
  "alpha": {"basePath": "/apps/alpha", "loopbackPort": 21234, "projectId": 4001, "quota": "5G", "reachable": true}
}}
EOF
if run --check; then bad '--check fails when nothing was applied'; else ok '--check fails when nothing was applied'; fi

# --- the plan is not trusted -------------------------------------------------

rejected() { # description, plan body
    reset_case
    printf '%s\n' "$2" >"$plan"
    if run; then bad "$1" "$(cat "$work/stderr")"; else ok "$1"; fi
    [[ -s $work/log ]] && bad "$1 changes nothing" "$(cat "$work/log")"
}

rejected 'a quota above the platform ceiling is rejected' \
    '{"apps": {"alpha": {"basePath": "/apps/alpha", "projectId": 4001, "quota": "60G", "reachable": true}}}'
rejected 'a malformed quota is rejected' \
    '{"apps": {"alpha": {"basePath": "/apps/alpha", "projectId": 4001, "quota": "5 gigabytes", "reachable": true}}}'
rejected 'a non-numeric project id is rejected' \
    '{"apps": {"alpha": {"basePath": "/apps/alpha", "projectId": "4001", "quota": "5G", "reachable": true}}}'
rejected 'a zero project id is rejected' \
    '{"apps": {"alpha": {"basePath": "/apps/alpha", "projectId": 0, "quota": "5G", "reachable": true}}}'
rejected 'a duplicated project id is rejected' \
    '{"apps": {"alpha": {"basePath": "/apps/alpha", "projectId": 4001, "quota": "5G", "reachable": true},
               "beta": {"basePath": "/apps/beta", "projectId": 4001, "quota": "5G", "reachable": true}}}'
rejected 'a base path that disagrees with the name is rejected' \
    '{"apps": {"alpha": {"basePath": "/apps/beta", "projectId": 4001, "quota": "5G", "reachable": true}}}'
rejected 'an app name that is not a slug is rejected' \
    '{"apps": {"../etc": {"basePath": "/apps/../etc", "projectId": 4001, "quota": "5G", "reachable": true}}}'
rejected 'invalid JSON is rejected' 'not json'

# --- an empty tenant still bounds the dataset --------------------------------

reset_case
if run; then ok 'no plan is not an error'; else bad 'no plan is not an error' "$(cat "$work/stderr")"; fi
is "$(cat "$work/state/quota/${dataset//\//_}.quota")" $((200 * 1024 ** 3)) 'no plan still applies the dataset quota'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
