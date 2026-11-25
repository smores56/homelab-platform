#!/usr/bin/env bash
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
#   tests/core/agent-jobs.sh
# shellcheck disable=SC2016,SC2119,SC2120,SC2154  # literal patterns, sourced builders
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

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
eq() {
  if [[ $1 == "$2" ]]; then ok "$3"; else bad "$3" "got '$1' want '$2'"; fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

core=scripts/agent-job.sh
personal=scripts/agent-job-personal.sh
general=scripts/agent-job-general.sh
provision=scripts/agent-job-provision.sh
sysusers=image/rootfs/etc/sysusers.d/smortress-agent-shell.conf
tmpfiles=image/rootfs/etc/tmpfiles.d/smortress-agent-shell.conf
nft=image/rootfs/etc/nftables/smortress-agent-jobs.nft
service=units/systemd/smortress-agent-job-provision.service
job_image_file=image/rootfs/etc/smortress/agent/job-image
doc=docs/agent-jobs.md

for f in "$core" "$personal" "$general" "$provision" "$sysusers" "$tmpfiles" \
  "$nft" "$service" "$job_image_file" "$doc"; do
  if [[ -e $f ]]; then ok "$f exists"; else bad "$f exists"; fi
done

# --- runner accounts ---------------------------------------------------------

if grep -qx 'u agent-shell-personal - "agent personal shell runner" /var/lib/agent-shell/personal /usr/sbin/nologin' "$sysusers" &&
  grep -qx 'u agent-shell-general - "agent general shell runner" /var/lib/agent-shell/general /usr/sbin/nologin' "$sysusers" &&
  grep -qx 'g agent-shell-personal -' "$sysusers" &&
  grep -qx 'g agent-shell-general -' "$sysusers"; then
  ok 'sysusers allocates two login-less shell runners with separate homes'
else
  bad 'sysusers allocates two login-less shell runners with separate homes' "$(cat "$sysusers" 2>/dev/null)"
fi
# The ids are allocated, never demanded: a demand that cannot be met allocates a
# different id silently, and every uid-keyed firewall rule then misses.
if grep -qE '^[ug] agent-shell-(personal|general) [0-9]' "$sysusers"; then
  bad 'the runners demand no fixed uid' "$(grep -E '^[ug] agent-shell' "$sysusers")"
else
  ok 'the runners demand no fixed uid'
fi
if grep -qx 'd /var/lib/agent-shell/personal 0700 agent-shell-personal agent-shell-personal -' "$tmpfiles" &&
  grep -qx 'd /var/lib/agent-shell/general 0700 agent-shell-general agent-shell-general -' "$tmpfiles"; then
  ok 'each runner has a private podman storage home'
else
  bad 'each runner has a private podman storage home' "$(cat "$tmpfiles" 2>/dev/null)"
fi

# --- class is structural, not a request field ---------------------------------

# The entry points are the class. A caller cannot name the class, and the shared
# core is not reachable from a runtime: it takes the class as its first word and
# is installed root-only.
if grep -q 'exec "\$core" personal "\$@"' "$personal" &&
  grep -q 'exec "\$core" general "\$@"' "$general" &&
  grep -q 'core="$(dirname' "$personal" && grep -q 'core="$(dirname' "$general"; then
  ok 'each entry point hard-codes its trust class'
else
  bad 'each entry point hard-codes its trust class'
fi
if grep -qE -- '--class|JOB_CLASS|AGENT_JOB_CLASS' "$core" "$personal" "$general"; then
  bad 'no entry point accepts a caller-supplied class'
else
  ok 'no entry point accepts a caller-supplied class'
fi
if grep -qE -- '--volume|--mount|--network|--env|--device|--security-opt|--cap-add|--privileged' \
  "$personal" "$general"; then
  bad 'no entry point forwards a Podman flag from its caller'
else
  ok 'no entry point forwards a Podman flag from its caller'
fi

# --- pure argument construction ------------------------------------------------

export SMORTRESS_AGENT_JOB_IMAGE_FILE=$root/$job_image_file
export SMORTRESS_AGENT_JOB_ROOT=$work/run
export SMORTRESS_AGENT_JOB_STATE_ROOT=$work/state
export SMORTRESS_AGENT_JOB_WORKSPACE=$work/git
export SMORTRESS_AGENT_JOB_NFT_FILE=$root/$nft

# shellcheck source=/dev/null
source "$core"

has() { local needle=$1; shift; local word; for word in "$@"; do [[ $word == "$needle" ]] && return 0; done; return 1; }
has_prefix() { local needle=$1; shift; local word; for word in "$@"; do [[ $word == "$needle"* ]] && return 0; done; return 1; }

if declare -F job_class_config job_build_podman_argv job_build_systemd_argv >/dev/null; then
  ok 'the dispatcher exposes its argument builders for the checks'
else
  bad 'the dispatcher exposes its argument builders for the checks'
fi

job_class_config personal
job_build_podman_argv personal probe-1 'echo hello'
personal_argv=("${job_podman_argv[@]}")
personal_systemd=()
job_build_systemd_argv personal probe-1 'echo hello' "$work/run/probe-1.d/job.sh" /run/user/971
personal_systemd=("${job_systemd_argv[@]}")

job_class_config general
job_build_podman_argv general probe-2 'echo hello'
general_argv=("${job_podman_argv[@]}")
job_build_systemd_argv general probe-2 'echo hello' "$work/run/probe-2.d/job.sh" /run/user/970
general_systemd=("${job_systemd_argv[@]}")

# Rootless Podman only accepts a logind runtime directory; a private one fails in
# namespace setup, which is why the dispatcher passes this exact path and why
# provisioning turns linger on. Both halves are asserted here because either one
# alone leaves every job failing closed.
if has --setenv=XDG_RUNTIME_DIR=/run/user/971 "${personal_systemd[@]}" &&
  has --setenv=XDG_RUNTIME_DIR=/run/user/970 "${general_systemd[@]}"; then
  ok 'each class points XDG_RUNTIME_DIR at its logind runtime directory'
else
  bad 'each class points XDG_RUNTIME_DIR at its logind runtime directory'
fi
if grep -q 'enable-linger "$runner"' "$provision" &&
  grep -q 'Linger=yes' "$provision" &&
  grep -q 'job_runtime_dir_for' "$core"; then
  ok 'provisioning enables linger and the dispatcher derives /run/user from it'
else
  bad 'provisioning enables linger and the dispatcher derives /run/user from it'
fi

# The pinned image is the Hermes runtime, whose ENTRYPOINT is s6-overlay; a job
# must reach a shell instead, or it runs s6's init and never its command.
if has --entrypoint=/bin/sh "${general_argv[@]}" &&
  has --entrypoint=/bin/sh "${personal_argv[@]}" &&
  [[ ${general_argv[${#general_argv[@]} - 2]} == -lc &&
    ${general_argv[${#general_argv[@]} - 1]} == 'echo hello' ]]; then
  ok 'both classes run the command through a shell, not the image entrypoint'
else
  bad 'both classes run the command through a shell, not the image entrypoint'
fi

# PID1 must never be handed our descriptors: `--pipe` is refused for a unit
# created by a service domain on this host, and a job that cannot start is worse
# than a job whose output takes one more file.
if has --pipe "${general_systemd[@]}" || has --pipe "${personal_systemd[@]}"; then
  bad 'no class asks PID1 to carry its stdio' "${general_systemd[*]}"
else
  ok 'no class asks PID1 to carry its stdio'
fi
if [[ ${general_systemd[${#general_systemd[@]} - 1]} == "$work/run/probe-2.d/job.sh" &&
  ${personal_systemd[${#personal_systemd[@]} - 1]} == "$work/run/probe-1.d/job.sh" ]]; then
  ok 'each unit runs the per-job script, not the Podman argv'
else
  bad 'each unit runs the per-job script, not the Podman argv' "${general_systemd[*]: -1}"
fi

# The script is the whole capture contract: cap where the bytes are written, and
# Podman's status rather than head's.
job_build_podman_argv general probe-3 'echo hello; exit 3'
install -d "$work/run/probe-3.d"
job_write_runner_script "$work/run/probe-3.d" "$work/run/probe-3.d/out"
script=$(cat "$work/run/probe-3.d/job.sh")
if grep -qx 'set -o pipefail' <<<"$script" &&
  grep -qF "| head -c $((JOB_OUTPUT_CAP + 1)) > $work/run/probe-3.d/out" <<<"$script" &&
  grep -qF -- "--entrypoint=/bin/sh" <<<"$script" &&
  grep -qF -- '-lc echo\ hello\;\ exit\ 3' <<<"$script"; then
  ok 'the runner script caps its own output and keeps the command one argument'
else
  bad 'the runner script caps its own output and keeps the command one argument' "$script"
fi
if [[ $(stat -c %a "$work/run/probe-3.d/job.sh") == 555 ]]; then
  ok 'the runner script is executable and not writable by the runner'
else
  bad 'the runner script is executable and not writable by the runner'
fi

# A file at the cap is reported as-is; one byte past it is truncated and named.
printf 'ok' >"$work/short.out"
if [[ $(job_report_output "$work/short.out" 2>&1) == ok ]]; then
  ok 'short output is printed unchanged and unannotated'
else
  bad 'short output is printed unchanged and unannotated'
fi
head -c "$((JOB_OUTPUT_CAP + 1))" /dev/zero | tr '\0' 'x' >"$work/long.out"
reported=$(job_report_output "$work/long.out" 2>"$work/long.err")
if [[ ${#reported} -eq $JOB_OUTPUT_CAP ]] &&
  grep -q 'output truncated' "$work/long.err"; then
  ok 'output past the cap is truncated and reported'
else
  bad 'output past the cap is truncated and reported' "$(cat "$work/long.err")"
fi

# The containment every command gets, on both classes. No seccomp= flag: podman 6
# treats `seccomp=default` as a path and refuses the run, and the built-in profile
# applies without one.
for flag in --read-only --cap-drop=all --security-opt=no-new-privileges \
  --ipc=private --pid=private --uts=private \
  --cgroupns=private --pull=never; do
  if has "$flag" "${general_argv[@]}" && has "$flag" "${personal_argv[@]}"; then
    ok "both classes carry $flag"
  else
    bad "both classes carry $flag"
  fi
done
if has --security-opt=seccomp=default "${general_argv[@]}" ||
  has --security-opt=seccomp=default "${personal_argv[@]}"; then
  bad 'no class passes seccomp=default, which podman 6 reads as a profile path'
else
  ok 'no class passes seccomp=default, which podman 6 reads as a profile path'
fi
if has_prefix --tmpfs=/tmp: "${general_argv[@]}" && has_prefix --tmpfs=/tmp: "${personal_argv[@]}"; then
  ok 'both classes get a bounded /tmp'
else
  bad 'both classes get a bounded /tmp'
fi
if has_prefix --tmpfs=/work: "${personal_argv[@]}"; then
  ok 'personal jobs get a bounded /work scratch'
else
  bad 'personal jobs get a bounded /work scratch'
fi
# A tmpfs on /work is applied after the bind, so it would shadow the general
# tree and leave every general job with an empty directory.
if has_prefix --tmpfs=/work: "${general_argv[@]}"; then
  bad 'general jobs do not shadow the /work bind with a tmpfs' "${general_argv[*]}"
else
  ok 'general jobs do not shadow the /work bind with a tmpfs'
fi
# Nothing may hand a job a host namespace, a device, extra capability, a
# relabel of the shared root, or a Podman socket.
for forbidden in --privileged --device --network=host --userns=host --pid=host \
  --ipc=host --uts=host --cap-add label=disable --remote; do
  if has "$forbidden" "${general_argv[@]}" || has "$forbidden" "${personal_argv[@]}"; then
    bad "no class carries $forbidden"
  else
    ok "no class carries $forbidden"
  fi
done
if printf '%s\n' "${personal_argv[@]}" "${general_argv[@]}" | grep -qE ':(z|Z)(,|$)|podman\.sock'; then
  bad 'no class relabels a shared root or names a Podman socket'
else
  ok 'no class relabels a shared root or names a Podman socket'
fi

# Personal: no host mount at all, no route out.
if ! has_prefix --volume= "${personal_argv[@]}" && ! has --volume "${personal_argv[@]}" &&
  has --network=none "${personal_argv[@]}"; then
  ok 'personal jobs get no host mount and no network'
else
  bad 'personal jobs get no host mount and no network' "${personal_argv[*]}"
fi
for path in /var/srv/git /var/lib/agent /var/lib/agent-shell /var/home "$work/git"; do
  if printf '%s\n' "${personal_argv[@]}" | grep -qF "$path"; then
    bad "personal jobs never name $path"
  else
    ok "personal jobs never name $path"
  fi
done
if has --dns=1.1.1.1 "${personal_argv[@]}"; then
  bad 'personal jobs get no DNS resolver'
else
  ok 'personal jobs get no DNS resolver'
fi

# General: exactly one live read/write mount, the general tree, and general
# egress with a fixed public resolver.
general_binds=()
for word in "${general_argv[@]}"; do
  [[ $word == --volume=* ]] && general_binds+=("$word")
done
eq "${#general_binds[@]}" 1 'general jobs get exactly one host mount'
eq "${general_binds[0]:-}" "--volume=$work/git:/work" 'general jobs mount only the general tree'
if has --network=pasta "${general_argv[@]}" && has --dns=1.1.1.1 "${general_argv[@]}"; then
  ok 'general jobs get general egress and a fixed public resolver'
else
  bad 'general jobs get general egress and a fixed public resolver'
fi
for path in /var/lib/agent /var/lib/agent-shell /var/home; do
  if printf '%s\n' "${general_argv[@]}" | grep -qF "$path"; then
    bad "general jobs never name $path"
  else
    ok "general jobs never name $path"
  fi
done

# The command is one opaque element after the image: a caller cannot turn a
# word into a Podman flag because everything after the image is the command.
job_class_config general
job_build_podman_argv general probe-3 'echo --privileged --volume /:/host --network=host'
last=${job_podman_argv[${#job_podman_argv[@]} - 1]}
eq "$last" 'echo --privileged --volume /:/host --network=host' 'the command stays one argument'
if has --privileged "${job_podman_argv[@]}" || has --volume "${job_podman_argv[@]}"; then
  bad 'command words never become Podman flags'
else
  ok 'command words never become Podman flags'
fi

# Resource and wall-clock limits are enforced by the transient unit, so the
# dispatcher never depends on rootless cgroup delegation for them.
for property in RuntimeMaxSec=300 CPUQuota=100% MemoryMax=1G TasksMax=256 Delegate=yes; do
  if has_prefix "--property=$property" "${personal_systemd[@]}" &&
    has_prefix "--property=$property" "${general_systemd[@]}"; then
    ok "both classes carry $property"
  else
    bad "both classes carry $property"
  fi
done
if has --uid=agent-shell-personal "${personal_systemd[@]}" &&
  has --uid=agent-shell-general "${general_systemd[@]}"; then
  ok 'each class runs under its own unprivileged runner uid'
else
  bad 'each class runs under its own unprivileged runner uid'
fi
if has_prefix --unit=smortress-agent-job-personal- "${personal_systemd[@]}" &&
  has_prefix --unit=smortress-agent-job-general- "${general_systemd[@]}"; then
  ok 'the transient unit is class-scoped'
else
  bad 'the transient unit is class-scoped'
fi

# The image is a root-owned digest pin: a tag would let the registry move what
# the shell runs, and a caller may never name one.
printf 'ghcr.io/smores56/homelab-platform/agent-shell:latest\n' >"$work/tag"
if ( SMORTRESS_AGENT_JOB_IMAGE_FILE=$work/tag; job_read_image >/dev/null 2>&1 ); then
  bad 'the dispatcher refuses a tag as the job image'
else
  ok 'the dispatcher refuses a tag as the job image'
fi
printf 'ghcr.io/smores56/homelab-platform/agent-shell@sha256:%064d\n' 0 >"$work/digest"
if ( SMORTRESS_AGENT_JOB_IMAGE_FILE=$work/digest; job_read_image >/dev/null 2>&1 ); then
  ok 'the dispatcher accepts a digest-pinned image'
else
  bad 'the dispatcher accepts a digest-pinned image'
fi

# The shipped pin is the runtime image the deployment already carries, so it is
# prepulled by construction rather than by a second registry pull.
# shellcheck source=/dev/null
source scripts/app-images.sh
eq "$(cat "$job_image_file")" "$(app_image_ref agent-runtime)" 'the job image is the pinned agent runtime'

# --- firewall boundary ---------------------------------------------------------

if grep -qE 'meta skuid agent-shell-personal drop' "$nft"; then
  ok 'personal runner egress is dropped outright'
else
  bad 'personal runner egress is dropped outright'
fi
for range in 127.0.0.0/8 169.254.0.0/16 100.64.0.0/10 10.0.0.0/8 \
  172.16.0.0/12 192.168.0.0/16 fc00::/7 fe80::/10; do
  if grep -qF "$range" "$nft"; then
    ok "general runner cannot reach $range"
  else
    bad "general runner cannot reach $range"
  fi
done
if grep -qE 'meta skuid agent-shell-general fib daddr type local drop' "$nft"; then
  ok 'general runner cannot reach a local host address outside the private ranges'
else
  bad 'general runner cannot reach a local host address outside the private ranges'
fi

# --- provisioning --------------------------------------------------------------

mkdir -p "$work/bin" "$work/subids" "$work/git"
for stub in nft setfacl getfacl newuidmap newgidmap pasta podman; do
  printf '#!/bin/sh\nexit 0\n' >"$work/bin/$stub"
  chmod 0755 "$work/bin/$stub"
done
# id maps the two runners to fixed uids so the runtime-directory check is real.
printf '#!/bin/sh\ncase "$*" in\n  "-u agent-shell-personal") echo 971 ;;\n  "-u agent-shell-general") echo 970 ;;\n  *) exit 0 ;;\nesac\n' >"$work/bin/id"
printf '#!/bin/sh\ncase "$1" in\n  show-user) printf "Linger=yes\\n" ;;\n  *) exit 0 ;;\nesac\n' >"$work/bin/loginctl"
chmod 0755 "$work/bin/id" "$work/bin/loginctl"
mkdir -p "$work/run/970" "$work/run/971"

run_provision() {
  PATH=$work/bin:$PATH \
    AGENT_JOB_SUBUID_FILE=$work/subids/subuid \
    AGENT_JOB_SUBGID_FILE=$work/subids/subgid \
    AGENT_JOB_WORKSPACE=$work/git \
    AGENT_JOB_NFT_FILE=$root/$nft \
    AGENT_JOB_RUNTIME_BASE=$work/run \
    "$provision" "$@"
}

if run_provision >/dev/null 2>&1; then
  ok 'provisioning succeeds with a fake host'
else
  bad 'provisioning succeeds with a fake host'
fi
if grep -qx 'agent-shell-personal:300000:65536' "$work/subids/subuid" &&
  grep -qx 'agent-shell-general:400000:65536' "$work/subids/subuid" &&
  grep -qx 'agent-shell-general:400000:65536' "$work/subids/subgid"; then
  ok 'each runner gets a distinct subuid/subgid range'
else
  bad 'each runner gets a distinct subuid/subgid range' "$(cat "$work/subids/subuid" 2>/dev/null)"
fi
if run_provision >/dev/null 2>&1 &&
  [[ $(grep -c '^agent-shell-personal:' "$work/subids/subuid") == 1 ]]; then
  ok 'a second run adds no duplicate range'
else
  bad 'a second run adds no duplicate range'
fi
printf 'other:400000:65536\n' >"$work/subids/subuid"
if run_provision >/dev/null 2>&1; then
  bad 'provisioning refuses an overlapping subuid range'
else
  ok 'provisioning refuses an overlapping subuid range'
fi
printf 'agent-shell-personal:300000:65536\n' >"$work/subids/check"
if PATH=$work/bin:$PATH AGENT_JOB_SUBUID_FILE=$work/subids/check \
  AGENT_JOB_SUBGID_FILE=$work/subids/check AGENT_JOB_WORKSPACE=$work/git \
  AGENT_JOB_NFT_FILE=$root/$nft AGENT_JOB_RUNTIME_BASE=$work/run \
  "$provision" --check >/dev/null 2>&1; then
  bad '--check succeeds on a host that has no allocation yet'
else
  ok '--check reports a missing allocation without writing one'
fi
if ! grep -q "agent-shell-general" "$work/subids/check"; then
  ok '--check writes nothing'
else
  bad '--check writes nothing'
fi

# --- the approval seam ---------------------------------------------------------

# Shell jobs are YOLO: no command approval, no approval token, no in-dispatcher
# completion. The one approval contract in the platform belongs to the broker.
if grep -qE 'approval|approved|approve' "$core"; then
  if grep -q 'data_plane/approval.py' "$core"; then
    ok 'the dispatcher names the broker approval contract as the only seam'
  else
    bad 'the dispatcher handles approval itself'
  fi
else
  bad 'the dispatcher documents where approval lives'
fi
if ! grep -qiE 'token|hmac|nonce|verify_approval' "$core"; then
  ok 'the dispatcher reads or issues no approval credential'
else
  bad 'the dispatcher reads or issues no approval credential'
fi

# --- the runner never inherits the caller's directory ---------------------------

# Dropping privileges from a directory the runner cannot read -- an operator's
# 0700 home, say -- fails inside the privilege drop, before Podman starts, and
# the dispatcher then blames a missing image that is present. The shim records
# the directory the runner would have been started in.
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
eq "$(cat "$SMORTRESS_TEST_RUNUSER_CWD")" '/' \
  "the runner starts in /, not the caller's directory"

# --- image wiring --------------------------------------------------------------

if grep -q 'scripts/agent-job.sh' image/Containerfile; then
  ok 'the image installs the dispatcher'
else
  bad 'the image installs the dispatcher'
fi
if grep -q 'smortress-agent-job-provision.service' image/Containerfile; then
  ok 'the image enables the provisioning unit'
else
  bad 'the image enables the provisioning unit'
fi
if grep -rqE -- '--volume .*podman\.sock|CONTAINER_HOST|/run/podman' units/quadlet units/systemd; then
  bad 'no gateway or job unit receives a Podman socket'
else
  ok 'no gateway or job unit receives a Podman socket'
fi

printf '\n%d checks, %d failed\n' "$pass" "$fail"
((fail == 0))
