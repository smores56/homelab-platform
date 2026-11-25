#!/usr/bin/env bats
# bats file_tags=core
# The hardware-free rows of the T6 adversarial cutover matrix (SDLC #716).
#
# Two agent deployments own two recovery groups. What a tree can prove is that
# each group is one restore unit, that both are in the SSD/HDD/R2 plan with
# retention and readiness, that a snapshot of a group carries only its own
# dataset, that the personal group is the only place personal data lands --
# in the table and in the containers that mount it -- and that a restore never
# targets live state. The rows that need smortress, the disks and the real
# repositories are listed in SDLC #716; none of them is claimed here.
#
# Every finding is shown to bite before the same audit is trusted to pass: each
# @test copies the real tree, breaks one claim, and requires the finding that
# names it. A check that cannot fail is not evidence.
#
#   bats tests/core/agent-recovery.bats
# shellcheck disable=SC2154,SC2016  # the layout table is sourced; its own source text is matched literally
load ../helpers

root=$repo_root

# The audit cannot run without these; the shell suite aborted here. A skip per
# test keeps the closed gate visible in the output instead of hiding it.
setup() {
    local tool
    for tool in jq flock timeout; do
        command -v "$tool" >/dev/null 2>&1 || skip "missing required tool: $tool"
    done
}

# --------------------------------------------------------------- classification
# The two deployments are split by authority, and every agent unit must land in
# exactly one class. A name that says neither is auxiliary (the model server,
# the egress proxy, the config seed) and may mount nothing personal.
unit_class() { # path -> general|personal|aux|ambiguous
    local name=${1##*/} general=0 personal=0
    [[ $name == *general* ]] && general=1
    case $name in
        *local* | *personal* | *collect* | *mail* | *brave*) personal=1 ;;
    esac
    if ((general && personal)); then
        printf 'ambiguous\n'
    elif ((general)); then
        printf 'general\n'
    elif ((personal)); then
        printf 'personal\n'
    else
        printf 'aux\n'
    fi
}

agent_units() {
    printf '%s\n' units/quadlet/agent-*.container units/systemd/smortress-agent-*.service
}

# Datasets on each side of the authority split. Anything else is either app
# state no agent mounts or the model blob, which is in no group at all.
personal_datasets=(state/agent-local raw/files raw/photos raw/music raw/wallpapers
    raw/repo-archive state/syncthing-config state/immich-postgres
    state/immich-dumps state/opdshelf)
general_datasets=(state/agent-general raw/git raw/books)

# ---------------------------------------------------------------- findings
# One line per finding: `<id>|<detail>`. A fixture names the id it must produce.
emit() { printf '%s|%s\n' "$1" "${2:-}"; }

layout_findings() { # tree
    (
        unset STORAGE_MOUNT_ROOT
        # shellcheck source=/dev/null
        source "$1/scripts/storage-layout.sh"

        for spec in agent-local:state/agent-local agent-general:state/agent-general; do
            unit=${spec%%:*}
            want=${spec#*:}
            if [[ -z ${unit_datasets[$unit]:-} ]] ||
                ! printf '%s\n' "${units[@]}" | grep -qx -- "$unit"; then
                emit agent-unit-missing "$unit"
                continue
            fi
            got=$(unit_keys "$unit" | paste -sd' ')
            if [[ $got != "$want" ]]; then
                emit agent-unit-not-united "$unit restores: $got"
                [[ $unit == agent-general ]] && emit agent-general-personal "$got"
            fi
        done

        for key in state/agent-local state/agent-general; do
            owners=()
            for unit in "${units[@]}"; do
                unit_keys "$unit" | grep -qx -- "$key" && owners+=("$unit")
            done
            ((${#owners[@]} <= 1)) || emit agent-dataset-shared "$key in ${owners[*]}"
        done

        for unit in "${units[@]}"; do
            while IFS= read -r key; do
                [[ -n ${dataset_mount[$key]:-} ]] || emit agent-unit-unknown-dataset "$unit: $key"
                [[ $key == state/agent-model ]] && emit agent-model-in-unit "$unit"
            done < <(unit_keys "$unit")
        done

        # A unit that snapshots a dataset which contains another unit's dataset
        # would capture both in one snapshot and break the boundary.
        declared=()
        for unit in "${units[@]}"; do
            while IFS= read -r key; do declared+=("$key"); done < <(unit_keys "$unit")
        done
        for a in "${declared[@]}"; do
            for b in "${declared[@]}"; do
                [[ $a == "$b" ]] && continue
                [[ $b == "$a"/* ]] && emit agent-dataset-nested "$a contains $b"
            done
        done
    )
}

plan_findings() { # tree
    local tree=$1
    (
        unset STORAGE_MOUNT_ROOT
        # shellcheck source=/dev/null
        source "$tree/scripts/restic-plane-common.sh"
        got=${backends[*]}
        [[ $got == 'ssd hdd r2' ]] || emit plane-backend-missing "backends: $got"
    )
    for backend in ssd hdd r2; do
        timer=$tree/units/systemd/smortress-restic-backup-$backend.timer
        if [[ ! -r $timer ]] || ! grep -qE "^Unit=smortress-restic-backup@$backend\.service$" "$timer"; then
            emit plane-backend-missing "$backend has no timer for its driver"
        fi
    done
    grep -qE '^ExecStart=/usr/libexec/smortress-restic-backup %i$' \
        "$tree/units/systemd/smortress-restic-backup@.service" ||
        emit plane-backend-missing 'the driver template does not take the backend as %i'

    # A job that starts before its dataset is mounted records readiness, but the
    # ordering is what keeps a healthy dataset from racing a fresh mount. Both
    # keys span continuation lines, so the value is joined before matching.
    unit_value() { # file key
        awk -v key="$2" '
      $0 ~ "^" key "=" { on = 1; sub("^" key "=", "") }
      on { printf "%s ", $0; if ($0 !~ /\\[[:space:]]*$/) exit }' "$1"
    }
    for key in state-agent-local state-agent-general; do
        for prefix in After Wants; do
            [[ $(unit_value "$tree/units/systemd/smortress-restic-backup@.service" "$prefix") == *"zfs-ready@$key.service"* ]] ||
                emit plane-readiness-missing "$prefix lacks zfs-ready@$key"
        done
    done

    # Retention is per unit and iterates the table. A skip list is how an agent
    # group silently stops being forgettable.
    local forget
    forget=$(awk '
    $0 ~ /for g in/ && $0 ~ /units\[@\]/ { on = 1 }
    on { print }
    on && /^[[:space:]]*done$/ { exit }' "$tree/scripts/smortress-restic-backup.sh")
    if [[ $forget != *'unit:$g,verified'* ]] || [[ $forget == *continue* ]]; then
        emit plane-retention-skipped
    fi

    # The verifier must join every destination with every unit from the same
    # table. A stale copy of the unit list is how a group loses its freshness
    # alarm without any unit changing.
    local verify=$tree/scripts/smortress-restic-verify.sh
    grep -q 'restic-plane-common' "$verify" || emit plane-verify-skipped 'the verifier does not source the plane vocabulary'
    grep -q 'for backend in "${backends\[@\]}"' "$verify" || emit plane-verify-skipped 'the verifier does not iterate backends'
    grep -q 'for unit in "${units\[@\]}"' "$verify" || emit plane-verify-skipped 'the verifier does not iterate units'

    grep -qE 'agent-local|agent-general' "$tree"/scripts/smortress-restic-*.sh &&
        emit plane-hardcoded-units 'a plane script names a unit instead of reading the table'
}

mount_findings() { # tree
    (
        cd "$1" || exit 1
        unset STORAGE_MOUNT_ROOT
        # shellcheck source=/dev/null
        source "$1/scripts/storage-layout.sh"

        # `<src>\t<opts>` for every bind the file names, Quadlet or podman.
        mount_sources() {
            local file=$1 spec src opts
            while IFS= read -r spec; do
                src=${spec%%:*}
                opts=${spec#*:}
                opts=${opts#*:}
                [[ $src == /* ]] || continue
                printf '%s\t%s\n' "$src" "$opts"
            done < <(
                sed -n 's|^Volume=\([^ ]*\)$|\1|p' "$file"
                grep -oE -- '--volume [^ ]+' "$file" 2>/dev/null | sed 's/^--volume //' || true
            )
        }

        readonly_of() { # opts -> 0 when ro is one of the comma-separated flags
            local flag
            local IFS=,
            for flag in $1; do [[ $flag == ro ]] && return 0; done
            return 1
        }

        # The dataset that owns a mount source, longest match, or nothing.
        dataset_owner() {
            local src=$1 key alias best='' owner_key
            for key in "${dataset_order[@]}"; do
                for alias in $(mountpoint_aliases "$key"); do
                    if [[ $src == "$alias" || $src == "$alias"/* ]] &&
                        ((${#alias} > ${#best})); then
                        best=$alias
                        owner_key=$key
                    fi
                done
            done
            [[ -n $best ]] && printf '%s\n' "$owner_key"
        }

        in_set() { # key set...
            local key=$1
            shift
            local member
            for member in "$@"; do [[ $key == "$member" ]] && return 0; done
            return 1
        }

        while IFS= read -r file; do
            class=$(unit_class "$file")
            if [[ $class == ambiguous ]]; then
                emit agent-mount-unclassified "$file"
                continue
            fi
            while IFS=$'\t' read -r src opts; do
                [[ -n $src ]] || continue
                key=$(dataset_owner "$src") || continue
                case $class in
                    personal)
                        in_set "$key" "${general_datasets[@]}" && emit agent-mount-cross "$file mounts the general dataset $key"
                        ;;
                    general)
                        in_set "$key" "${personal_datasets[@]}" && emit agent-mount-cross "$file mounts the personal dataset $key"
                        ;;
                    aux)
                        in_set "$key" "${personal_datasets[@]}" && emit agent-mount-cross "$file mounts the personal dataset $key"
                        ;;
                esac
                if [[ $key == state/agent-model ]] && ! readonly_of "$opts"; then
                    emit agent-model-writable "$file mounts the model blob writable"
                fi
                # An auxiliary unit has no side, so nothing under the agent state
                # tree can be attributed to it. A unit that mounts one of the two
                # deployments and does not say which it serves could be either,
                # which is how a collector ends up writing personal data into the
                # general group.
                if [[ $class == aux && $key == state/agent-* && $key != state/agent-model ]]; then
                    emit agent-mount-unclassified "$file mounts $key but names no side"
                fi
            done < <(mount_sources "$file")
        done < <(agent_units)
    )
}

restore_findings() { # tree
    local tree=$1 drill=$1/scripts/smortress-restic-restore-drill.sh
    [[ -r $drill ]] || {
        emit agent-restore-in-place 'no restore drill'
        return
    }
    ( # shellcheck disable=SC2317 # the subshell exists to scope the sourced table
        unset STORAGE_MOUNT_ROOT
        # shellcheck source=/dev/null
        source "$tree/scripts/storage-layout.sh"
        # A drill root inside a dataset would write a restore into live state.
        candidates=$(sed -n 's/^[[:space:]]*for candidate in \(.*\); do$/\1/p' "$drill")
        candidates+=" $(sed -n 's/.*drill_root=${drill_root:-\([^}]*\)}.*/\1/p' "$drill")"
        for path in $candidates; do
            [[ $path == /* ]] || continue
            for key in "${dataset_order[@]}"; do
                if [[ $path == "$(mountpoint_for "$key")" || $path == "$(mountpoint_for "$key")"/* ]]; then
                    emit agent-restore-in-place "$path is inside the live dataset $key"
                fi
            done
        done
    )
    grep -q 'refusing to mix a drill into old data' "$drill" ||
        emit agent-restore-in-place 'the drill accepts a non-empty target'
    grep -q 'unit:$unit,verified' "$drill" ||
        emit agent-restore-incomplete 'the drill does not require the verified tag'
}

# ------------------------------------------------------------------- plane run
# The real driver against stubs: the table is what decides which groups a
# backend run touches, so removing a group from it must remove its snapshot
# here. Nothing else in the repository proves that ordering.
install_stubs() { # workdir
    local bin=$1/bin
    install -d -m 0755 "$bin"
    cat >"$bin/restic" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$STUB_LOG/restic"
cmd=""
while (($#)); do
  case $1 in
    -r | --retry-lock) shift 2 ;;
    -*) shift ;;
    *) cmd=$1; shift; break ;;
  esac
done
case $cmd in
  backup) printf '{"message_type":"summary","snapshot_id":"up-%s"}\n' "$STUB_UNIT" ;;
  cat) printf '{"tree":"tree-%s"}\n' "$STUB_UNIT" ;;
  tag | forget | prune | check | unlock) ;;
  snapshots)
    printf '[{"id":"tagged-%s","tree":"tree-%s","time":"2026-01-01T00:00:00Z","hostname":"smortress","paths":[],"tags":["unit:%s","host:smortress","verified"]}]\n' \
      "$STUB_UNIT" "$STUB_UNIT" "$STUB_UNIT"
    ;;
  *) printf 'unexpected restic command: %s\n' "$cmd" >&2; exit 2 ;;
esac
STUB
    cat >"$bin/zfs" <<'STUB'
#!/usr/bin/env bash
case $1 in
  list) exit 1 ;;
  snapshot)
    key=${2#smortress/}
    key=${key%@*}
    # shellcheck source=/dev/null
    source "$STORAGE_LAYOUT"
    install -d -m 0755 "$(mountpoint_for "$key")/.zfs/snapshot/${2##*@}"
    ;;
esac
STUB
    cat >"$bin/zfs-ready" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod 0755 "$bin"/*
}

plane_findings() { # tree work
    local tree=$1 work=$2 backend unit state expected got rc
    local mnt=$work/mnt
    install -d -m 0700 "$work/repos/ssd" "$work/repos/hdd" "$work/secrets" \
        "$work/log" "$work/cache"
    printf 'hunter2\n' >"$work/secrets/restic-password.yaml"
    chmod 0600 "$work/secrets/restic-password.yaml"
    printf 'r2_access_key_id: stub-id\nr2_secret_access_key: stub-secret\n' \
        >"$work/secrets/r2-credentials.yaml"
    chmod 0600 "$work/secrets/r2-credentials.yaml"
    printf '36 25 8:1 / %s rw - ext4 /dev/sdb1 rw\n37 25 8:2 / %s rw - ext4 /dev/sda1 rw\n' \
        "$work/repos/ssd" "$work/repos/hdd" >"$work/mountinfo"
    install_stubs "$work"

    # Every dataset mount and its `.zfs/snapshot` directory, from the tree's own
    # table: the driver refuses a group whose snapshot directory is absent, and a
    # fixture that removes or renames a dataset must change this tree too.
    rm -rf "$mnt"
    install -d -m 0755 "$mnt"
    (
        export STORAGE_MOUNT_ROOT=$mnt
        # shellcheck source=/dev/null
        source "$tree/scripts/storage-layout.sh"
        for key in "${dataset_order[@]}"; do
            install -d -m 0755 "$(mountpoint_for "$key")/.zfs/snapshot"
        done
    )

    for backend in ssd hdd r2; do
        for unit in agent-local agent-general; do
            rm -rf "$work/state-$backend"
            rc=0
            env \
                PATH="$work/bin:$PATH" \
                STUB_LOG="$work/log" STUB_UNIT="$unit" \
                STORAGE_LAYOUT="$tree/scripts/storage-layout.sh" STORAGE_MOUNT_ROOT="$mnt" \
                RESTIC_BIN="$work/bin/restic" ZFS_BIN="$work/bin/zfs" \
                ZFS_READY_BIN="$work/bin/zfs-ready" CURL_BIN="$work/bin/zfs-ready" \
                RESTIC_BASE="$work/repos" RESTIC_STATE_ROOT="$work/state-$backend" \
                RESTIC_CACHE_DIR="$work/cache" SMORTRESS_SECRETS_DIR="$work/secrets" \
                RESTIC_MOUNTINFO="$work/mountinfo" \
                RESTIC_ATTEMPTS=1 RESTIC_RETRY_SLEEP_LOCAL=0 RESTIC_RETRY_SLEEP_R2=0 \
                RESTIC_LOCK_WAIT=5 RESTIC_DEADLINE_LOCAL=20 RESTIC_DEADLINE_R2=20 \
                bash "$tree/scripts/smortress-restic-backup.sh" "$backend" \
                --unit "$unit" --no-maintenance >"$work/last" 2>&1 || rc=$?
            state=$work/state-$backend/state/$backend-$unit.json
            if [[ ! -r $state ]]; then
                emit plane-unit-missing "$backend/$unit (exit $rc: $(tail -n1 "$work/last"))"
                continue
            fi
            got=$(jq -r '.last_attempt.result' "$state")
            [[ $got == success ]] || emit plane-unit-failed "$backend/$unit: $got"
            expected=$mnt/var/lib/agent/${unit#agent-}/.zfs/snapshot/$backend
            got=$(jq -r '.paths | join(",")' "$state")
            [[ $got == "$expected" ]] || emit plane-paths-not-exact "$backend/$unit: $got"
        done
    done
}

deep=1
audit() { # tree work
    layout_findings "$1"
    plan_findings "$1"
    mount_findings "$1"
    restore_findings "$1"
    ((deep)) && plane_findings "$1" "$2"
    return 0
}

# ------------------------------------------------------- broken fixtures
fixture_tree() { # name
    local target=$BATS_TEST_TMPDIR/fixtures/$1
    install -d -m 0755 "$target"
    # Only what the audit reads: a fixture that needs a file this list does not
    # carry fails loudly instead of silently passing on a stale copy.
    (
        cd "$root" || exit 1
        cp --parents \
            scripts/storage-layout.sh scripts/restic-plane-common.sh \
            scripts/smortress-restic-backup.sh scripts/smortress-restic-verify.sh \
            scripts/smortress-restic-restore-drill.sh \
            units/systemd/smortress-restic-* units/systemd/smortress-agent-*.service \
            units/quadlet/agent-*.container "$target/"
    )
    printf '%s\n' "$target"
}

# expect_finding <name> <deep> <id> <fixture-command...>: the fixture is caught
# as the finding that names it. The broken rows stay deep where the shell suite
# ran them deep, so a table edit is exercised through the real driver too.
expect_finding() {
    local name=$1 want_deep=$2 id=$3 target got
    shift 3
    target=$(fixture_tree "$name")
    (cd "$target" && "$@")
    deep=$want_deep
    got=$(audit "$target" "$BATS_TEST_TMPDIR/plane-$name")
    if ! grep -q "^$id|" <<<"$got"; then
        fail "$name was not caught as $id; findings were:
$got"
    fi
}

mutate() { # file perl-expression
    perl -0pi -e "$2" "$1"
}

# Each fixture copies the real tree, breaks one claim, and must produce the
# finding that names it.
@test "drop-general-unit is caught as agent-unit-missing" {
    expect_finding drop-general-unit 1 agent-unit-missing \
        mutate scripts/storage-layout.sh 's/ agent-general\)/)/'
}

@test "general-gains-a-personal-dataset is caught as agent-general-personal" {
    expect_finding general-gains-a-personal-dataset 1 agent-general-personal \
        mutate scripts/storage-layout.sh 's/\[agent-general\]="state\/agent-general"/[agent-general]="state\/agent-general raw\/files"/'
}

@test "personal-takes-the-general-dataset is caught as agent-dataset-shared" {
    expect_finding personal-takes-the-general-dataset 1 agent-dataset-shared \
        mutate scripts/storage-layout.sh 's/\[agent-local\]="state\/agent-local"/[agent-local]="state\/agent-local state\/agent-general"/'
}

@test "general-mounts-personal-state is caught as agent-mount-cross" {
    expect_finding general-mounts-personal-state 0 agent-mount-cross \
        sh -c 'printf "Volume=/var/lib/agent/local:/personal:ro\n" >> units/quadlet/agent-general.container'
}

@test "collector-writes-to-the-general-group is caught as agent-mount-cross" {
    expect_finding collector-writes-to-the-general-group 0 agent-mount-cross \
        mutate units/systemd/smortress-agent-collect-finance.service \
        's|/var/lib/agent/local/replica:/replica:z|/var/lib/agent/general/replica:/replica:z|'
}

@test "nameless-unit-mounts-agent-state is caught as agent-mount-unclassified" {
    expect_finding nameless-unit-mounts-agent-state 0 agent-mount-unclassified \
        sh -c 'mv units/systemd/smortress-agent-collect-finance.service units/systemd/smortress-agent-sync.service'
}

@test "model-mounted-writable is caught as agent-model-writable" {
    expect_finding model-mounted-writable 0 agent-model-writable \
        mutate units/quadlet/agent-model.container 's|/var/lib/agent/model:/models:ro,z|/var/lib/agent/model:/models:z|'
}

@test "r2-timer-dropped is caught as plane-backend-missing" {
    expect_finding r2-timer-dropped 0 plane-backend-missing \
        rm units/systemd/smortress-restic-backup-r2.timer
}

@test "readiness-order-dropped is caught as plane-readiness-missing" {
    expect_finding readiness-order-dropped 0 plane-readiness-missing \
        mutate units/systemd/smortress-restic-backup@.service 's/ zfs-ready\@state-agent-general\.service//g'
}

@test "retention-skips-an-agent-group is caught as plane-retention-skipped" {
    expect_finding retention-skips-an-agent-group 0 plane-retention-skipped \
        mutate scripts/smortress-restic-backup.sh \
        's/(for g in "\$\{units\[@\]\}"; do\n)/$1    [[ $g == agent-general ]] \&\& continue\n/'
}

@test "drill-restores-over-live-state is caught as agent-restore-in-place" {
    expect_finding drill-restores-over-live-state 0 agent-restore-in-place \
        mutate scripts/smortress-restic-restore-drill.sh \
        's|for candidate in /var/lib/restic/hdd /var/lib/restic/ssd; do|for candidate in /var/lib/agent/local /var/lib/restic/ssd; do|'
}

# ------------------------------------------------------------ the good tree
@test "the tree has no agent recovery findings" {
    deep=0
    findings=$(audit "$root" "$BATS_TEST_TMPDIR/good")
    assert_equal "$findings" ""
}
