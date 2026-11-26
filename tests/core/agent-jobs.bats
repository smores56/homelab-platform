#!/usr/bin/env bats
# bats file_tags=core
# Offline checks for the rootless-Podman YOLO shell dispatcher (SDLC #715, T5).
#
# The privileged half -- two runner uids, real podman, a real container -- is in
# docs/manual-steps.md section 46. This proves the half that does not need root:
# the class is fixed by the entry point, the argument vector carries the right
# mounts and network authority for each class, nothing a caller types can become
# a Podman flag, the containment flags are present, the firewall denies the
# addresses the design forbids, and the provisioning script refuses overlapping
# subuid ranges.
#
#   bats tests/core/agent-jobs.bats
# shellcheck disable=SC2016,SC2119,SC2120,SC2154  # literal patterns, sourced builders
load ../helpers

core=scripts/agent-job.sh
personal=scripts/agent-job-personal.sh
general=scripts/agent-job-general.sh
provision=scripts/agent-job-provision.sh
sysusers=bootc/server/rootfs/etc/sysusers.d/smortress-agent-shell.conf
tmpfiles=bootc/server/rootfs/etc/tmpfiles.d/smortress-agent-shell.conf
nft=bootc/server/rootfs/etc/nftables/smortress-agent-jobs.nft
service=units/systemd/smortress-agent-job-provision.service
job_image_file=bootc/server/rootfs/etc/smortress/agent/job-image
doc=docs/agent-jobs.md

file_exists() { [[ -e $1 ]]; }

for f in "$core" "$personal" "$general" "$provision" "$sysusers" "$tmpfiles" \
    "$nft" "$service" "$job_image_file" "$doc"; do
    register "$f exists" file_exists "$f"
done

# --- runner accounts ---------------------------------------------------------

@test "sysusers allocates two login-less shell runners with separate homes" {
    grep -qx 'u agent-shell-personal - "agent personal shell runner" /var/lib/agent-shell/personal /usr/sbin/nologin' "$sysusers"
    grep -qx 'u agent-shell-general - "agent general shell runner" /var/lib/agent-shell/general /usr/sbin/nologin' "$sysusers"
    grep -qx 'g agent-shell-personal -' "$sysusers"
    grep -qx 'g agent-shell-general -' "$sysusers"
}

# The ids are allocated, never demanded: a demand that cannot be met allocates a
# different id silently, and every uid-keyed firewall rule then misses.
@test "the runners demand no fixed uid" {
    fixed=$(grep -E '^[ug] agent-shell-(personal|general) [0-9]' "$sysusers" || true)
    assert_equal "$fixed" ""
}

@test "each runner has a private podman storage home" {
    grep -qx 'd /var/lib/agent-shell/personal 0700 agent-shell-personal agent-shell-personal -' "$tmpfiles"
    grep -qx 'd /var/lib/agent-shell/general 0700 agent-shell-general agent-shell-general -' "$tmpfiles"
}

# --- class is structural, not a request field ---------------------------------

# The entry points are the class. A caller cannot name the class, and the shared
# core is not reachable from a runtime: it takes the class as its first word and
# is installed root-only.
@test "each entry point hard-codes its trust class" {
    grep -q 'exec "\$core" personal "\$@"' "$personal"
    grep -q 'exec "\$core" general "\$@"' "$general"
    grep -q 'core="$(dirname' "$personal"
    grep -q 'core="$(dirname' "$general"
}

@test "no entry point accepts a caller-supplied class" {
    refute grep -qE -- '--class|JOB_CLASS|AGENT_JOB_CLASS' "$core" "$personal" "$general"
}

@test "no entry point forwards a Podman flag from its caller" {
    refute grep -qE -- '--volume|--mount|--network|--env|--device|--security-opt|--cap-add|--privileged' \
        "$personal" "$general"
}

# --- pure argument construction ------------------------------------------------

# The dispatcher reads its paths once, from the environment, and its builders are
# globals: bats runs each @test in its own subshell, so every test sources it
# against its own fixture root rather than sharing one another's state.
dispatch() {
    work=$BATS_TEST_TMPDIR/work
    export SMORTRESS_AGENT_JOB_IMAGE_FILE=$repo_root/$job_image_file
    export SMORTRESS_AGENT_JOB_ROOT=$work/run
    export SMORTRESS_AGENT_JOB_STATE_ROOT=$work/state
    export SMORTRESS_AGENT_JOB_WORKSPACE=$work/git
    export SMORTRESS_AGENT_JOB_NFT_FILE=$repo_root/$nft
    mkdir -p "$work/run" "$work/state" "$work/git"
    # shellcheck source=/dev/null
    source "$core"
}

# build_argv: both classes' argument vectors, as the dispatch entry points would
# build them for one probe job each.
build_argv() {
    job_class_config personal
    job_build_podman_argv personal probe-1 'echo hello'
    personal_argv=("${job_podman_argv[@]}")
    job_build_systemd_argv personal probe-1 'echo hello' "$work/run/probe-1.d/job.sh" /run/user/971
    personal_systemd=("${job_systemd_argv[@]}")

    job_class_config general
    job_build_podman_argv general probe-2 'echo hello'
    general_argv=("${job_podman_argv[@]}")
    job_build_systemd_argv general probe-2 'echo hello' "$work/run/probe-2.d/job.sh" /run/user/970
    general_systemd=("${job_systemd_argv[@]}")
}

argv() {
    dispatch
    build_argv
}

has() { local needle=$1; shift; local word; for word in "$@"; do [[ $word == "$needle" ]] && return 0; done; return 1; }
has_prefix() { local needle=$1; shift; local word; for word in "$@"; do [[ $word == "$needle"* ]] && return 0; done; return 1; }

@test "the dispatcher exposes its argument builders for the checks" {
    dispatch
    declare -F job_class_config job_build_podman_argv job_build_systemd_argv
}

# Rootless Podman only accepts a logind runtime directory; a private one fails in
# namespace setup, which is why the dispatcher passes this exact path and why
# provisioning turns linger on. Both halves are asserted here because either one
# alone leaves every job failing closed.
@test "each class points XDG_RUNTIME_DIR at its logind runtime directory" {
    argv
    has --setenv=XDG_RUNTIME_DIR=/run/user/971 "${personal_systemd[@]}"
    has --setenv=XDG_RUNTIME_DIR=/run/user/970 "${general_systemd[@]}"
}

@test "provisioning enables linger and the dispatcher derives /run/user from it" {
    grep -q 'enable-linger "$runner"' "$provision"
    grep -q 'Linger=yes' "$provision"
    grep -q 'job_runtime_dir_for' "$core"
}

# The pinned image is the Hermes runtime, whose ENTRYPOINT is s6-overlay; a job
# must reach a shell instead, or it runs s6's init and never its command.
@test "both classes run the command through a shell, not the image entrypoint" {
    argv
    has --entrypoint=/bin/sh "${general_argv[@]}"
    has --entrypoint=/bin/sh "${personal_argv[@]}"
    assert_equal "${general_argv[${#general_argv[@]} - 2]}" -lc
    assert_equal "${general_argv[${#general_argv[@]} - 1]}" 'echo hello'
}

# PID1 must never be handed our descriptors: `--pipe` is refused for a unit
# created by a service domain on this host, and a job that cannot start is worse
# than a job whose output takes one more file.
@test "no class asks PID1 to carry its stdio" {
    argv
    if has --pipe "${general_systemd[@]}" || has --pipe "${personal_systemd[@]}"; then
        fail "a transient unit asks PID1 to carry its stdio"
    fi
}

@test "each unit runs the per-job script, not the Podman argv" {
    argv
    assert_equal "${general_systemd[${#general_systemd[@]} - 1]}" "$work/run/probe-2.d/job.sh"
    assert_equal "${personal_systemd[${#personal_systemd[@]} - 1]}" "$work/run/probe-1.d/job.sh"
}

# The script is the whole capture contract: cap where the bytes are written, and
# Podman's status rather than head's. The helper groups the script for the
# runner; a test has no runner account, so any real group the current user
# belongs to proves the same code path.
write_probe_script() {
    job_build_podman_argv general probe-3 'echo hello; exit 3'
    install -d "$work/run/probe-3.d"
    job_group=$(id -gn)
    job_write_runner_script "$work/run/probe-3.d" "$work/run/probe-3.d/out"
}

@test "the runner script caps its own output and keeps the command one argument" {
    dispatch
    write_probe_script
    script=$(cat "$work/run/probe-3.d/job.sh")
    grep -qx 'set -o pipefail' <<<"$script"
    grep -qF "| head -c $((JOB_OUTPUT_CAP + 1)) > $work/run/probe-3.d/out" <<<"$script"
    grep -qF -- "--entrypoint=/bin/sh" <<<"$script"
    grep -qF -- '-lc echo\ hello\;\ exit\ 3' <<<"$script"
}

@test "the runner script is readable and executable by the runner group only" {
    dispatch
    write_probe_script
    assert_equal "$(stat -c %a "$work/run/probe-3.d/job.sh")" 550
    assert_equal "$(stat -c %G "$work/run/probe-3.d/job.sh")" "$job_group"
}

# The job root must be reachable by a runner uid. /run/smortress is not: it is
# 0700 root to keep the bridge socket unreachable, and a script under it fails
# the exec with status 203.
@test "the job root is outside /run/smortress and traverse-only" {
    grep -q '^readonly JOB_DEFAULT_ROOT=/run/smortress-agent-job$' "$core"
    grep -qx 'd /run/smortress-agent-job 0711 root root -' "$tmpfiles"
}

# A file at the cap is reported as-is; one byte past it is truncated and named.
@test "short output is printed unchanged and unannotated" {
    dispatch
    printf 'ok' >"$BATS_TEST_TMPDIR/short.out"
    assert_equal "$(job_report_output "$BATS_TEST_TMPDIR/short.out" 2>&1)" ok
}

@test "output past the cap is truncated and reported" {
    dispatch
    head -c "$((JOB_OUTPUT_CAP + 1))" /dev/zero | tr '\0' 'x' >"$BATS_TEST_TMPDIR/long.out"
    reported=$(job_report_output "$BATS_TEST_TMPDIR/long.out" 2>"$BATS_TEST_TMPDIR/long.err")
    assert_equal "${#reported}" "$JOB_OUTPUT_CAP"
    assert_contains "$(cat "$BATS_TEST_TMPDIR/long.err")" 'output truncated'
}

# The containment every command gets, on both classes. No seccomp= flag: podman 6
# treats `seccomp=default` as a path and refuses the run, and the built-in profile
# applies without one.
both_carry() {
    argv
    has "$1" "${general_argv[@]}" || fail "the general argv lacks $1"
    has "$1" "${personal_argv[@]}" || fail "the personal argv lacks $1"
}

for flag in --read-only --cap-drop=all --security-opt=no-new-privileges \
    --ipc=private --pid=private --uts=private \
    --cgroupns=private --pull=never; do
    register "both classes carry $flag" both_carry "$flag"
done

@test "no class passes seccomp=default, which podman 6 reads as a profile path" {
    argv
    if has --security-opt=seccomp=default "${general_argv[@]}" ||
        has --security-opt=seccomp=default "${personal_argv[@]}"; then
        fail 'an argv passes --security-opt=seccomp=default'
    fi
}

@test "both classes get a bounded /tmp" {
    argv
    has_prefix --tmpfs=/tmp: "${general_argv[@]}"
    has_prefix --tmpfs=/tmp: "${personal_argv[@]}"
}

@test "personal jobs get a bounded /work scratch" {
    argv
    has_prefix --tmpfs=/work: "${personal_argv[@]}"
}

# A tmpfs on /work is applied after the bind, so it would shadow the general
# tree and leave every general job with an empty directory.
@test "general jobs do not shadow the /work bind with a tmpfs" {
    argv
    if has_prefix --tmpfs=/work: "${general_argv[@]}"; then
        fail "the general argv shadows /work with a tmpfs"
    fi
}

# Nothing may hand a job a host namespace, a device, extra capability, a
# relabel of the shared root, or a Podman socket.
no_class_carries() {
    argv
    if has "$1" "${general_argv[@]}" || has "$1" "${personal_argv[@]}"; then
        fail "an argv carries $1"
    fi
}

for forbidden in --privileged --device --network=host --userns=host --pid=host \
    --ipc=host --uts=host --cap-add label=disable --remote; do
    register "no class carries $forbidden" no_class_carries "$forbidden"
done

@test "no class relabels a shared root or names a Podman socket" {
    argv
    if printf '%s\n' "${personal_argv[@]}" "${general_argv[@]}" | grep -qE ':(z|Z)(,|$)|podman\.sock'; then
        fail "an argv relabels a root or names a Podman socket"
    fi
}

# Personal: no host mount at all, no route out.
@test "personal jobs get no host mount and no network" {
    argv
    if has_prefix --volume= "${personal_argv[@]}" ||
        has --volume "${personal_argv[@]}" ||
        ! has --network=none "${personal_argv[@]}"; then
        fail "the personal argv has a mount or a route out: ${personal_argv[*]}"
    fi
}

personal_never_names() {
    argv
    if printf '%s\n' "${personal_argv[@]}" | grep -qF "$1"; then
        fail "the personal argv names $1"
    fi
}

for path in /var/srv/git /var/lib/agent /var/lib/agent-shell /var/home; do
    register "personal jobs never name $path" personal_never_names "$path"
done

# The general tree is the one live host mount, so a personal job must not name
# the workspace either. The old suite printed its own mktemp path here, which a
# per-test fixture cannot reproduce, so the name says what it checks instead.
@test "personal jobs never name the workspace tree" {
    argv
    if printf '%s\n' "${personal_argv[@]}" | grep -qF "$work/git"; then
        fail "the personal argv names the workspace $work/git"
    fi
}

@test "personal jobs get no DNS resolver" {
    argv
    if has --dns=1.1.1.1 "${personal_argv[@]}"; then
        fail "the personal argv carries a DNS resolver"
    fi
}

# General: exactly one live read/write mount, the general tree, and general
# egress with a fixed public resolver.
general_binds() {
    local word
    for word in "${general_argv[@]}"; do
        [[ $word == --volume=* ]] && printf '%s\n' "$word"
    done
}

@test "general jobs get exactly one host mount" {
    argv
    assert_equal "$(general_binds | wc -l)" 1
}

@test "general jobs mount only the general tree" {
    argv
    assert_equal "$(general_binds)" "--volume=$work/git:/work"
}

@test "general jobs get general egress and a fixed public resolver" {
    argv
    has --network=pasta "${general_argv[@]}"
    has --dns=1.1.1.1 "${general_argv[@]}"
}

general_never_names() {
    argv
    if printf '%s\n' "${general_argv[@]}" | grep -qF "$1"; then
        fail "the general argv names $1"
    fi
}

for path in /var/lib/agent /var/lib/agent-shell /var/home; do
    register "general jobs never name $path" general_never_names "$path"
done

# The command is one opaque element after the image: a caller cannot turn a
# word into a Podman flag because everything after the image is the command.
@test "the command stays one argument" {
    dispatch
    job_class_config general
    job_build_podman_argv general probe-3 'echo --privileged --volume /:/host --network=host'
    assert_equal "${job_podman_argv[${#job_podman_argv[@]} - 1]}" \
        'echo --privileged --volume /:/host --network=host'
}

@test "command words never become Podman flags" {
    dispatch
    job_build_podman_argv general probe-3 'echo --privileged --volume /:/host --network=host'
    if has --privileged "${job_podman_argv[@]}" || has --volume "${job_podman_argv[@]}"; then
        fail "a command word became a Podman flag: ${job_podman_argv[*]}"
    fi
}

# Resource and wall-clock limits are enforced by the transient unit, so the
# dispatcher never depends on rootless cgroup delegation for them.
both_carry_property() {
    argv
    has_prefix "--property=$1" "${personal_systemd[@]}" || fail "the personal unit lacks $1"
    has_prefix "--property=$1" "${general_systemd[@]}" || fail "the general unit lacks $1"
}

for property in RuntimeMaxSec=300 CPUQuota=100% MemoryMax=1G TasksMax=256 Delegate=yes; do
    register "both classes carry $property" both_carry_property "$property"
done

@test "each class runs under its own unprivileged runner uid" {
    argv
    has --uid=agent-shell-personal "${personal_systemd[@]}"
    has --uid=agent-shell-general "${general_systemd[@]}"
}

@test "the transient unit is class-scoped" {
    argv
    has_prefix --unit=smortress-agent-job-personal- "${personal_systemd[@]}"
    has_prefix --unit=smortress-agent-job-general- "${general_systemd[@]}"
}

# The image is a root-owned digest pin: a tag would let the registry move what
# the shell runs, and a caller may never name one.
@test "the dispatcher refuses a tag as the job image" {
    dispatch
    printf 'ghcr.io/smores56/homelab-platform/agent-shell:latest\n' >"$BATS_TEST_TMPDIR/tag"
    rc=0
    (SMORTRESS_AGENT_JOB_IMAGE_FILE=$BATS_TEST_TMPDIR/tag; job_read_image) >/dev/null 2>&1 || rc=$?
    assert_not_equal "$rc" 0
}

@test "the dispatcher accepts a digest-pinned image" {
    dispatch
    printf 'ghcr.io/smores56/homelab-platform/agent-shell@sha256:%064d\n' 0 >"$BATS_TEST_TMPDIR/digest"
    (SMORTRESS_AGENT_JOB_IMAGE_FILE=$BATS_TEST_TMPDIR/digest; job_read_image) >/dev/null 2>&1
}

# The shipped pin is the runtime image the deployment already carries, so it is
# prepulled by construction rather than by a second registry pull.
@test "the job image is the pinned agent runtime" {
    # shellcheck source=/dev/null
    source scripts/app-images.sh
    assert_equal "$(cat "$job_image_file")" "$(app_image_ref agent-runtime)"
}

# --- firewall boundary ---------------------------------------------------------

@test "personal runner egress is dropped outright" {
    grep -qE 'meta skuid agent-shell-personal drop' "$nft"
}

nft_names() { grep -qF "$1" "$nft"; }

for range in 127.0.0.0/8 169.254.0.0/16 100.64.0.0/10 10.0.0.0/8 \
    172.16.0.0/12 192.168.0.0/16 fc00::/7 fe80::/10; do
    register "general runner cannot reach $range" nft_names "$range"
done

@test "general runner cannot reach a local host address outside the private ranges" {
    grep -qE 'meta skuid agent-shell-general fib daddr type local drop' "$nft"
}

# --- provisioning --------------------------------------------------------------

# provision_host: the fake host agent-job-provision.sh is pointed at — stubs that
# record what they were asked, a uid map for the two runners, and the runtime
# directories logind would have created.
provision_host() {
    work=$BATS_TEST_TMPDIR/work
    mkdir -p "$work/bin" "$work/subids" "$work/git" "$work/state" "$work/run/970" "$work/run/971"
    for stub in setfacl getfacl newuidmap newgidmap pasta; do
        printf '#!/bin/sh\nexit 0\n' >"$work/bin/$stub"
        chmod 0755 "$work/bin/$stub"
    done
    # podman and nft record what they were asked, so the order the boot takes is
    # visible: the image a pin names must be in each runner's store before the
    # egress table that makes the personal runner unreachable exists.
    # The log path is baked in: the pull runs under `env -i`, so an environment
    # variable would be missing where the record is written.
    printf '#!/bin/sh\nprintf "podman %%s\\n" "$*" >>"%s"\nexit 0\n' "$work/provision.log" >"$work/bin/podman"
    printf '#!/bin/sh\nprintf "nft %%s\\n" "$*" >>"%s"\nexit 0\n' "$work/provision.log" >"$work/bin/nft"
    # runuser really drops to the runner; here it only strips the wrapper so the
    # stubbed podman runs as the caller.
    printf '#!/bin/sh\nshift 2\n[ "$1" = "--" ] && shift\nexec "$@"\n' >"$work/bin/runuser"
    chmod 0755 "$work/bin/podman" "$work/bin/nft" "$work/bin/runuser"
    # id maps the two runners to fixed uids so the runtime-directory check is real.
    printf '#!/bin/sh\ncase "$*" in\n  "-u agent-shell-personal") echo 971 ;;\n  "-u agent-shell-general") echo 970 ;;\n  *) exit 0 ;;\nesac\n' >"$work/bin/id"
    printf '#!/bin/sh\ncase "$1" in\n  show-user) printf "Linger=yes\\n" ;;\n  *) exit 0 ;;\nesac\n' >"$work/bin/loginctl"
    chmod 0755 "$work/bin/id" "$work/bin/loginctl"
    : >"$work/provision.log"
}

# run_provision [args...]: apply (or --check) against that host. The id files are
# this fixture's unless the test names its own.
run_provision() {
    PATH=$work/bin:$PATH \
        AGENT_JOB_SUBUID_FILE=${subuid_file:-$work/subids/subuid} \
        AGENT_JOB_SUBGID_FILE=${subgid_file:-$work/subids/subgid} \
        AGENT_JOB_WORKSPACE=$work/git \
        AGENT_JOB_NFT_FILE=$repo_root/$nft \
        AGENT_JOB_RUNTIME_BASE=$work/run \
        AGENT_JOB_STATE_ROOT=$work/state \
        AGENT_JOB_IMAGE_FILE=$repo_root/$job_image_file \
        AGENT_JOB_RUNUSER=$work/bin/runuser \
        AGENT_JOB_PODMAN=$work/bin/podman \
        "$provision" "$@"
}

@test "provisioning succeeds with a fake host" {
    provision_host
    run_provision
}

# The personal runner has zero egress by rule, so a digest a pin bump names can
# only be fetched before that rule exists -- and both classes' jobs fail closed
# until their own store has it. The order is the whole point.
@test "provisioning pulls the pinned image for both runners before the egress table" {
    provision_host
    run_provision
    assert_equal "$(grep -c '^podman pull ' "$work/provision.log")" 2
    last_pull=$(grep -n '^podman pull ' "$work/provision.log" | tail -1 | cut -d: -f1)
    first_nft=$(grep -n '^nft -f ' "$work/provision.log" | head -1 | cut -d: -f1)
    if [[ -z $last_pull || -z $first_nft ]] || ((last_pull >= first_nft)); then
        fail "the pull is not before the table (pull=$last_pull nft=$first_nft)"
    fi
    grep -q '@sha256:' "$work/provision.log"
}

@test "each runner gets a distinct subuid/subgid range" {
    provision_host
    run_provision
    grep -qx 'agent-shell-personal:300000:65536' "$work/subids/subuid"
    grep -qx 'agent-shell-general:400000:65536' "$work/subids/subuid"
    grep -qx 'agent-shell-general:400000:65536' "$work/subids/subgid"
}

@test "a second run adds no duplicate range" {
    provision_host
    run_provision
    run_provision
    assert_equal "$(grep -c '^agent-shell-personal:' "$work/subids/subuid")" 1
}

@test "provisioning refuses an overlapping subuid range" {
    provision_host
    printf 'other:400000:65536\n' >"$work/subids/subuid"
    rc=0
    run_provision >/dev/null 2>&1 || rc=$?
    assert_not_equal "$rc" 0
}

# The check mode against a host that has one allocation and needs another.
check_a_missing_allocation() {
    provision_host
    printf 'agent-shell-personal:300000:65536\n' >"$work/subids/check"
    subuid_file=$work/subids/check subgid_file=$work/subids/check
    rc=0
    run_provision --check >/dev/null 2>&1 || rc=$?
}

@test "--check reports a missing allocation without writing one" {
    check_a_missing_allocation
    assert_not_equal "$rc" 0
}

@test "--check writes nothing" {
    check_a_missing_allocation
    if grep -q 'agent-shell-general' "$work/subids/check"; then
        fail "--check wrote an allocation: $(cat "$work/subids/check")"
    fi
}

# The general facade reads the same tree as the repos source (SDLC #851) and runs
# as uid 1000, which the mode keeps out. The read is an ACL, never a relabel.
@test "provisioning grants the facade read on the general tree by ACL" {
    grep -qF 'setfacl -m "u:core:r-x" "$workspace"' "$provision"
    grep -qF 'setfacl -m "d:u:core:r-x" "$workspace"' "$provision"
}

@test "--check does not pull the job image" {
    check_a_missing_allocation
    if grep -q '^podman pull ' "$work/provision.log"; then
        fail "--check pulled the job image: $(cat "$work/provision.log")"
    fi
}

# --- the approval seam ---------------------------------------------------------

# Shell jobs are YOLO: no command approval, no approval token, no in-dispatcher
# completion. The one approval contract in the platform belongs to the broker.
@test "the dispatcher names the broker approval contract as the only seam" {
    grep -qE 'approval|approved|approve' "$core"
    grep -q 'data_plane/approval.py' "$core"
}

@test "the dispatcher reads or issues no approval credential" {
    refute grep -qiE 'token|hmac|nonce|verify_approval' "$core"
}

# --- the runner never inherits the caller's directory ---------------------------

# Dropping privileges from a directory the runner cannot read -- an operator's
# 0700 home, say -- fails inside the privilege drop, before Podman starts, and
# the dispatcher then blames a missing image that is present. The shim records
# the directory the runner would have been started in.
@test "the runner starts in /, not the caller's directory" {
    dispatch
    job_class_config general
    # shellcheck disable=SC2034  # read by job_as_runner
    job_runtime_dir=$work/runtime
    mkdir -p "$work/shim" "$work/private"
    chmod 0700 "$work/private"
    cat >"$work/shim/runuser" <<'SHIM'
#!/usr/bin/env bash
while [[ ${1:-} != -- ]]; do shift; done
shift
printf '%s\n' "$PWD" >>"$SMORTRESS_TEST_RUNUSER_CWD"
exec "$@"
SHIM
    chmod +x "$work/shim/runuser"
    export SMORTRESS_TEST_RUNUSER_CWD=$work/runuser-cwd
    : >"$SMORTRESS_TEST_RUNUSER_CWD"
    (cd "$work/private" && PATH=$work/shim:$PATH job_as_runner true) >/dev/null 2>&1
    assert_equal "$(cat "$SMORTRESS_TEST_RUNUSER_CWD")" '/'
}

# --- image wiring --------------------------------------------------------------

@test "the image installs the dispatcher" {
    grep -q 'scripts/agent-job.sh' bootc/server/Containerfile
}

@test "the image enables the provisioning unit" {
    grep -q 'smortress-agent-job-provision.service' bootc/server/Containerfile
}

@test "no gateway or job unit receives a Podman socket" {
    refute grep -rqE -- '--volume .*podman\.sock|CONTAINER_HOST|/run/podman' units/quadlet units/systemd
}
