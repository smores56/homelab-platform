#!/usr/bin/env bash
# The trusted rootless-Podman shell dispatcher (SDLC #715, T5 of #702).
#
# This is the only program that turns an agent's shell request into a container.
# It constructs the whole `podman run` argument vector itself: the caller supplies
# one shell command and nothing else. Image, mounts, network authority, limits,
# environment and security options are constants here, so a request cannot name a
# Podman flag, an image, a host path or a proxy.
#
# Two trust classes exist and neither entry point can reach the other:
#
#   personal  the local deployment; no host mount at all, no network, disposable
#             tmpfs scratch. Personal content cannot leave the host through a
#             shell job because the job has nowhere to send it.
#   general   the external deployment; exactly one live read/write mount,
#             /var/srv/git, general egress filtered by the uid-keyed firewall in
#             image/rootfs/etc/nftables/smortress-agent-jobs.nft, and a fixed
#             public resolver. It has no personal dataset, no agent state and no
#             private workspace.
#
# The class is not a request field: scripts/agent-job-personal.sh and
# scripts/agent-job-general.sh are the two entry points, each hard-codes its
# class, and this file is installed root-only. There is no shared submission
# surface to pass a different class through.
#
# Containment, not approval, is the control. Shell commands are fully
# unsupervised YOLO: there is no command approval, source approval, diff review
# or transactional commit here, and this dispatcher must never grow one. The
# single approval contract in the platform is lane B's data_plane/approval.py,
# used by the write broker for dangerous broker effects -- not by a shell job.
#
# Each command runs in a disposable rootless container under its own unprivileged
# runner uid, inside a transient systemd unit that carries the wall clock, CPU,
# memory and PID limits, kills the whole cgroup on timeout, and disappears with
# the job. The gateways never see a Podman socket: they see only the entry point
# a future transport calls, and the dispatcher runs Podman itself.
#
# The privileged half is exercised on smortress (docs/manual-steps.md section 47).
# tests/core/agent-jobs.sh drives the argument builders without root or Podman.
set -uo pipefail

readonly JOB_DEFAULT_IMAGE_FILE=/etc/smortress/agent/job-image
readonly JOB_DEFAULT_NFT_FILE=/etc/nftables/smortress-agent-jobs.nft
# Not under /run/smortress: that directory is 0700 root to keep the bridge's
# socket unreachable from a host uid, and a unit that runs as a runner uid cannot
# traverse it -- systemd then fails the exec with status 203. This path exists
# only for job files and is world-traversable, which is all a runner needs.
readonly JOB_DEFAULT_ROOT=/run/smortress-agent-job
readonly JOB_DEFAULT_STATE_ROOT=/var/lib/agent-shell
readonly JOB_DEFAULT_WORKSPACE=/var/srv/git
readonly JOB_WALL_SECONDS=${SMORTRESS_AGENT_JOB_WALL_SECONDS:-300}
readonly JOB_OUTPUT_CAP=${SMORTRESS_AGENT_JOB_OUTPUT_CAP:-1048576}
readonly JOB_CPU_QUOTA=100%
readonly JOB_MEMORY_MAX=1G
readonly JOB_TASKS_MAX=256
readonly JOB_NAME_PATTERN='^[A-Za-z0-9][A-Za-z0-9_.-]{0,40}$'
readonly JOB_IMAGE_PATTERN='^[a-z0-9][a-z0-9._/-]*@sha256:[0-9a-f]{64}$'

job_die() {
  printf 'agent-job: %s\n' "$*" >&2
  exit 1
}

job_image_file() { printf '%s\n' "${SMORTRESS_AGENT_JOB_IMAGE_FILE:-$JOB_DEFAULT_IMAGE_FILE}"; }
job_nft_file() { printf '%s\n' "${SMORTRESS_AGENT_JOB_NFT_FILE:-$JOB_DEFAULT_NFT_FILE}"; }
job_run_root() { printf '%s\n' "${SMORTRESS_AGENT_JOB_ROOT:-$JOB_DEFAULT_ROOT}"; }
job_state_root() { printf '%s\n' "${SMORTRESS_AGENT_JOB_STATE_ROOT:-$JOB_DEFAULT_STATE_ROOT}"; }
job_workspace() { printf '%s\n' "${SMORTRESS_AGENT_JOB_WORKSPACE:-$JOB_DEFAULT_WORKSPACE}"; }

# job_runtime_dir_for USER -> the logind runtime directory for that account.
#
# Rootless Podman's namespace setup only accepts a real /run/user/<uid>: handed a
# private directory it fails with "error opening namespace handles: Permission
# denied", even when the runner owns it. systemd-logind creates the path for a
# lingering account, so provisioning turns linger on and this never creates it.
job_runtime_dir_for() {
  printf '%s/%s\n' "${SMORTRESS_AGENT_JOB_RUNTIME_BASE:-/run/user}" "$(id -u "$1")"
}

# job_read_image -> the one image this dispatcher may run, on stdout.
#
# The reference is a root-owned file with a digest, never a tag and never a
# caller argument: a tag would let the registry change what a shell request
# executes, and an image name from the model would be an arbitrary-code request.
job_read_image() {
  local file ref
  file=$(job_image_file)
  [[ -r $file ]] || job_die "the job image pin $file is missing or unreadable"
  ref=$(head -n1 "$file" | tr -d '[:space:]')
  [[ -n $ref ]] || job_die "the job image pin $file is empty"
  [[ $ref =~ $JOB_IMAGE_PATTERN ]] ||
    job_die "the job image pin $file is not a digest-pinned reference: $ref"
  printf '%s\n' "$ref"
}

# job_class_config CLASS -> the constants that differ by trust class.
#
# Kept in one place so a class cannot be assembled from a request: the entry
# point picks a case arm, and every mount and network decision follows from it.
job_class_config() {
  local class=$1
  job_class=$class
  job_work_tmpfs=()
  case $class in
    personal)
      job_user=agent-shell-personal
      job_group=agent-shell-personal
      job_home=$(job_state_root)/personal
      job_network=none
      job_resolvers=()
      job_binds=()
      # The personal class has no host mount, so /work is disposable scratch.
      # shellcheck disable=SC2054  # one --tmpfs value; the commas are not array separators
      job_work_tmpfs=(--tmpfs=/work:rw,size=512m,nosuid,nodev)
      ;;
    general)
      job_user=agent-shell-general
      job_group=agent-shell-general
      job_home=$(job_state_root)/general
      job_network=pasta
      # A fixed public resolver: the host stub usually lives on loopback, which
      # the general class is forbidden to reach. Naming the resolver keeps DNS
      # working without permitting the host or the LAN.
      job_resolvers=(--dns=1.1.1.1 --dns=9.9.9.9)
      # The only live host mount, and the only one either class gets. No :z/:Z:
      # a runtime-selected relabel of a shared root is forbidden, so the tree
      # keeps its stable label and the operator grants the runner an ACL.
      job_binds=(--volume="$(job_workspace):/work")
      ;;
    *)
      job_die "unknown job trust class: $class"
      ;;
  esac
}

# job_build_podman_argv CLASS NAME COMMAND -> job_podman_argv.
#
# Everything before the image is fixed here. The command is the final element,
# so a word like `--privileged` is an argument to /bin/sh and never a Podman
# flag. The image is a constant digest and `--pull=never` refuses to resolve
# anything at run time: an image that was not prepulled fails closed.
job_build_podman_argv() {
  local class=$1 name=$2 command=$3
  job_class_config "$class"
  [[ $name =~ $JOB_NAME_PATTERN ]] || job_die "invalid job name: $name"
  job_image=$(job_read_image)
  job_podman_argv=(
    podman run
    --rm
    --replace
    --name "$name"
    --pull=never
    --read-only
    --cap-drop=all
    --security-opt=no-new-privileges
    # No seccomp= flag: podman 6 reads `seccomp=default` as a profile *path* and
    # refuses the run ("open default: no such file or directory", rc 125). The
    # built-in default profile applies without a flag, so the confinement stays.
    --ipc=private
    --pid=private
    --uts=private
    --cgroupns=private
    --hostname=agent-job
    --network="$job_network"
    "${job_resolvers[@]}"
    "${job_binds[@]}"
    --workdir=/work
    "--tmpfs=/tmp:rw,size=64m,nosuid,nodev,noexec"
    "${job_work_tmpfs[@]}"
    --ulimit=nofile=1024:1024
    --umask=0077
    --env=HOME=/tmp
    --env=TZ=UTC
    --env=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    # The pinned image is the Hermes runtime, whose ENTRYPOINT is s6-overlay: the
    # command would be s6's argv, and s6 needs a full container (group setup,
    # /opt/data) that a job must not have. Override it with the shell.
    --entrypoint=/bin/sh
    "$job_image"
    -lc "$command"
  )
}

# job_build_systemd_argv CLASS NAME COMMAND SCRIPT -> job_systemd_argv.
#
# The transient unit, not Podman, enforces the resource and wall-clock limits.
# That keeps the limits enforceable without relying on delegated cgroup
# controllers inside a rootless user manager, and it kills every process in the
# job's cgroup on timeout. `Delegate=yes` lets Podman manage any nested cgroup
# it wants; the limits above it still apply.
#
# No `--pipe`: that asks PID1 to hand the unit the dispatcher's own pipes, and on
# this host every such start from a service domain is refused with "Failed to
# start transient service unit: Connection reset by peer" while the identical
# call from a login shell succeeds. The unit runs a per-job script that redirects
# its own output to a file instead, so no descriptor of ours crosses into PID1.
job_build_systemd_argv() {
  local class=$1 name=$2 command=$3 script=$4 runtime_dir=${5:-}
  job_build_podman_argv "$class" "$name" "$command"
  job_unit="smortress-agent-job-${class}-${name}"
  [[ -n $runtime_dir ]] || runtime_dir=$(job_runtime_dir_for "$job_user")
  job_runtime_dir=$runtime_dir
  job_systemd_argv=(
    systemd-run
    --quiet
    --wait
    --collect
    --unit="$job_unit"
    --uid="$job_user"
    --gid="$job_group"
    --property=RuntimeMaxSec="$JOB_WALL_SECONDS"
    --property=TimeoutStopSec=10
    --property=CPUQuota="$JOB_CPU_QUOTA"
    --property=MemoryMax="$JOB_MEMORY_MAX"
    --property=MemorySwapMax=0
    --property=TasksMax="$JOB_TASKS_MAX"
    --property=Delegate=yes
    --setenv=HOME="$job_home"
    --setenv=XDG_RUNTIME_DIR="$job_runtime_dir"
    --setenv=PATH=/usr/bin:/bin
    --setenv=TZ=UTC
    "$script"
  )
}

job_as_runner() {
  # Never inherit the caller's directory: an operator running this from a 0700
  # home makes the privilege drop fail before Podman starts, and the job then
  # blames an image that is present and prepulled.
  (
    cd / || exit 1
    runuser -u "$job_user" -- env -i \
      HOME="$job_home" \
      XDG_RUNTIME_DIR="$job_runtime_dir" \
      PATH=/usr/bin:/bin \
      "$@"
  )
}

# The caller must never be able to reach this program without root: it switches
# to a runner uid and creates units, so an unprivileged invocation is a bug or an
# attempt, never a request to serve.
job_require_root() {
  ((EUID == 0)) || job_die "must run as root; the gateway calls its class entry point"
}

job_prepare_runtime() {
  # Rootless Podman needs a logind runtime directory, not a path we invent: given
  # anything else it fails in namespace setup with "error opening namespace
  # handles". systemd-logind creates /run/user/<uid> for a lingering account, so
  # the check is the provisioning contract and never a directory we create.
  local runtime_dir
  runtime_dir=$(job_runtime_dir_for "$job_user")
  [[ -d $runtime_dir ]] ||
    job_die "$runtime_dir is missing; run scripts/agent-job-provision.sh (loginctl enable-linger $job_user)"
  [[ $(stat -c %u "$runtime_dir") == "$(id -u "$job_user")" ]] ||
    job_die "$runtime_dir is not owned by $job_user; run scripts/agent-job-provision.sh"
  # 0711: the runner traverses to its own job directory and cannot list the tree.
  install -d -m 0711 "$(job_run_root)"
}

# Fail closed on the uid firewall before a job exists. The table is keyed by the
# runner accounts, so it is a default-deny owner independent of Podman's pasta
# or bridge behaviour; a ruleset that cannot load means the job does not run.
job_ensure_egress() {
  local nft_file
  nft_file=$(job_nft_file)
  [[ -r $nft_file ]] || job_die "the job egress ruleset $nft_file is missing"
  nft -f "$nft_file"
}

# The general runner writes the live tree directly. Root cannot make that true
# by fiat: the operator grants an ACL (the provisioning unit does it at boot), and
# a tree that is not writable is a job that would fail halfway through an edit.
job_check_workspace() {
  [[ $job_class == general ]] || return 0
  job_as_runner test -w "$(job_workspace)" ||
    job_die "the general tree $(job_workspace) is not writable by $job_user; run scripts/agent-job-provision.sh"
}

# A pinned image that was not prepulled for this runner cannot be run with
# --pull=never, and a dispatcher that silently pulled would defeat the pin.
job_check_image() {
  job_as_runner podman image exists "$job_image" ||
    job_die "$job_user has not prepulled $job_image (docs/manual-steps.md section 47)"
}

# Best effort: a killed Podman may leave a container behind even with --rm.
job_cleanup() {
  local name=$1
  job_as_runner podman rm --force --ignore "$name" >/dev/null 2>&1 || true
}

job_new_name() {
  printf '%s-%s-%s-%s\n' "$1" "$(date +%s)" "$$" "$RANDOM"
}

# job_job_dir NAME -> the one directory a job owns.
#
# Traversable but not listable or writable by the runner (0711, root): the runner
# must reach its script and its output file, and must not be able to replace
# either. Root removes the whole directory when the job exits.
job_job_dir() {
  printf '%s/%s.d\n' "$(job_run_root)" "$1"
}

# job_write_runner_script DIR OUT -> DIR/job.sh, the unit's whole ExecStart.
#
# The same `head -c` cap the dispatcher used to apply from outside, moved inside
# the unit so the file it writes cannot outgrow the cap while nobody is looking,
# and `pipefail` keeps Podman's status rather than head's. Each argv word is
# quoted by the shell, so a word the caller typed stays one argument to Podman
# and never becomes syntax.
job_write_runner_script() {
  local dir=$1 out=$2 argv
  argv=$(printf '%q ' "${job_podman_argv[@]}")
  {
    printf '#!/bin/bash\n'
    printf '# One job: its container, and its output capped where it is written.\n'
    printf 'set -o pipefail\n'
    printf '%s 2>&1 | head -c %s > %q\n' "$argv" "$((JOB_OUTPUT_CAP + 1))" "$out"
  } >"$dir/job.sh"
  # Readable only by the runner's group: the command is the caller's text, and
  # another local account has no business reading which command ran.
  chgrp "$job_group" "$dir/job.sh"
  chmod 0550 "$dir/job.sh"
}

# job_report_output FILE -> the job's output on stdout, capped and annotated.
job_report_output() {
  local out=$1 size
  [[ -f $out ]] || return 0
  size=$(wc -c <"$out")
  if ((size > JOB_OUTPUT_CAP)); then
    truncate -s "$JOB_OUTPUT_CAP" "$out"
    printf 'agent-job: output truncated at %s bytes\n' "$JOB_OUTPUT_CAP" >&2
  fi
  cat "$out"
}

job_main() {
  local class=${1:-}
  shift || true
  [[ $class == personal || $class == general ]] ||
    job_die "usage: agent-job-<personal|general> <shell command>"
  ((EUID == 0)) || job_die "must run as root; the gateway calls its class entry point"
  (( $# == 1 )) || job_die "expected exactly one shell command argument"
  job_class_config "$class"
  local status
  # The EXIT trap runs after this function returns, when its locals are gone, so
  # the names it uses are globals (and `set -u` would otherwise kill the exit).
  job_name=$(job_new_name "$class")
  job_dir=$(job_job_dir "$job_name")
  job_out=$job_dir/out
  command=$1
  job_build_systemd_argv "$class" "$job_name" "$command" "$job_dir/job.sh"
  job_prepare_runtime
  job_ensure_egress
  job_check_workspace
  job_check_image

  install -d -m 0750 -g "$job_group" "$job_dir"
  # The runner writes the output file itself; creating it here is what makes the
  # redirect possible in a directory it cannot write.
  install -m 0600 -o "$job_user" -g "$job_group" /dev/null "$job_out"
  job_write_runner_script "$job_dir" "$job_out"
  trap 'job_cleanup "$job_name"; rm -rf "$job_dir"' EXIT

  set +e
  "${job_systemd_argv[@]}"
  status=$?
  set -e
  job_report_output "$job_out"
  return "$status"
}

# Sourced by tests/core/agent-jobs.sh to drive the builders without root.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  set -euo pipefail
  job_main "$@"
fi
