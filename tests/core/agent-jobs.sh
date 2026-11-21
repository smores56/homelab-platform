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
job_build_systemd_argv personal probe-1 'echo hello'
personal_systemd=("${job_systemd_argv[@]}")

job_class_config general
job_build_podman_argv general probe-2 'echo hello'
general_argv=("${job_podman_argv[@]}")
job_build_systemd_argv general probe-2 'echo hello'
general_systemd=("${job_systemd_argv[@]}")

# The containment every command gets, on both classes.
for flag in --read-only --cap-drop=all --security-opt=no-new-privileges \
  --security-opt=seccomp=default --ipc=private --pid=private --uts=private \
  --cgroupns=private --pull=never; do
  if has "$flag" "${general_argv[@]}" && has "$flag" "${personal_argv[@]}"; then
    ok "both classes carry $flag"
  else
    bad "both classes carry $flag"
  fi
done
if has_prefix --tmpfs=/tmp: "${general_argv[@]}" && has_prefix --tmpfs=/tmp: "${personal_argv[@]}" &&
  has_prefix --tmpfs=/work: "${general_argv[@]}" && has_prefix --tmpfs=/work: "${personal_argv[@]}"; then
  ok 'both classes get bounded tmpfs scratch'
else
  bad 'both classes get bounded tmpfs scratch'
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
for stub in id nft setfacl getfacl newuidmap newgidmap pasta podman; do
  printf '#!/bin/sh\nexit 0\n' >"$work/bin/$stub"
  chmod 0755 "$work/bin/$stub"
done

run_provision() {
  PATH=$work/bin:$PATH \
    AGENT_JOB_SUBUID_FILE=$work/subids/subuid \
    AGENT_JOB_SUBGID_FILE=$work/subids/subgid \
    AGENT_JOB_WORKSPACE=$work/git \
    AGENT_JOB_NFT_FILE=$root/$nft \
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
  AGENT_JOB_NFT_FILE=$root/$nft "$provision" --check >/dev/null 2>&1; then
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
