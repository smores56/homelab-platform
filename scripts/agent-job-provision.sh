#!/usr/bin/env bash
# Provision the two agent shell runners for rootless Podman (SDLC #715, T5).
#
# systemd-sysusers creates the login-less accounts; this gives each one what
# rootless Podman needs and makes the boundaries real before a job can start:
#
#   * a non-overlapping subuid/subgid range. Two accounts sharing a range put
#     their containers in one uid space, so an overlap is refused rather than
#     mapped onto somebody else's ids.
#   * the general runner's ACL on /var/srv/git, the one live host mount. The tree
#     stays owned by the operator and keeps its stable label; the runner gets
#     read/write through an ACL, and the default ACL gives new files the same.
#   * the uid-keyed egress table, loaded from the image so a boot that cannot
#     parse it leaves the runners dropped rather than open.
#   * a logind session (linger) per runner. Rootless Podman refuses a runtime
#     directory it did not get from logind -- "error opening namespace handles"
#     -- so /run/user/<uid> must exist before a job can start.
#
# `--check` reports drift and writes nothing; the boot unit runs the apply mode.
# The uid ranges are allocated here, not demanded from sysusers: a demanded id
# that is taken moves silently and every uid-keyed rule then matches nobody.
#
#   scripts/agent-job-provision.sh
#   scripts/agent-job-provision.sh --check
set -euo pipefail

mode=apply
case ${1:-} in
  '') ;;
  --check) mode=check ;;
  -h | --help)
    sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "agent-job-provision: unknown argument: $1" >&2
    exit 2
    ;;
esac

subuid_file=${AGENT_JOB_SUBUID_FILE:-/etc/subuid}
subgid_file=${AGENT_JOB_SUBGID_FILE:-/etc/subgid}
workspace=${AGENT_JOB_WORKSPACE:-/var/srv/git}
nft_file=${AGENT_JOB_NFT_FILE:-/etc/nftables/smortress-agent-jobs.nft}
loginctl_bin=${AGENT_JOB_LOGINCTL:-loginctl}
runtime_base=${AGENT_JOB_RUNTIME_BASE:-/run/user}

# 200000:65536 belongs to the apps tenant. The shell domains sit above it and do
# not touch it; the overlap check below refuses any future collision regardless.
declare -A range_for=(
  [agent-shell-personal]=${AGENT_JOB_SUBID_PERSONAL:-300000:65536}
  [agent-shell-general]=${AGENT_JOB_SUBID_GENERAL:-400000:65536}
)
runners=(agent-shell-personal agent-shell-general)
required_bins=${AGENT_JOB_REQUIRE_BINS-newuidmap newgidmap pasta nft setfacl loginctl}

fail() {
  echo "agent-job-provision: $*" >&2
  exit 1
}

for spec in "${range_for[@]}"; do
  [[ $spec =~ ^[0-9]+:[0-9]+$ ]] || fail "a subid range must be start:count, got '$spec'"
done

for runner in "${runners[@]}"; do
  id -u "$runner" >/dev/null 2>&1 || fail "user $runner does not exist"
done

missing=
for bin in $required_bins; do
  command -v "$bin" >/dev/null 2>&1 || missing="$missing $bin"
done
[[ -z $missing ]] || fail "rootless Podman is missing:$missing"

overlaps() { # file user start count
  local file=$1 user=$2 start=$3 count=$4 name other_start other_count
  while IFS=: read -r name other_start other_count; do
    [[ -n $name && $name != "$user" ]] || continue
    [[ $other_start =~ ^[0-9]+$ && $other_count =~ ^[0-9]+$ ]] || continue
    ((start < other_start + other_count && other_start < start + count)) && return 0
  done <"$file"
  return 1
}

add_range() { # file user start:count
  local file=$1 user=$2 spec=$3 start count line existing
  start=${spec%%:*}
  count=${spec##*:}
  [[ -e $file ]] || install -m 0644 /dev/null "$file"
  [[ -s $file && $(tail -c 1 "$file" | wc -l) == 0 ]] && printf '\n' >>"$file"
  existing=$(grep -cE "^${user}:" "$file" || true)
  ((existing > 1)) && fail "$file holds more than one $user line; refusing to choose"
  line=$(grep -E "^${user}:" "$file" | head -1 || true)
  if [[ -n $line ]]; then
    if [[ $line =~ ^${user}:([0-9]+):([0-9]+)$ ]]; then
      start=${BASH_REMATCH[1]}
      count=${BASH_REMATCH[2]}
      overlaps "$file" "$user" "$start" "$count" &&
        fail "the existing $user allocation $start:$count overlaps another account in $file"
      return 0
    fi
    sed -i "/^${user}:/d" "$file"
  fi
  overlaps "$file" "$user" "$start" "$count" &&
    fail "the allocation $start:$count overlaps another account in $file"
  printf '%s:%s:%s\n' "$user" "$start" "$count" >>"$file"
}

# check_range FILE USER START:COUNT -> nonzero when the exact line is missing.
check_range() {
  local file=$1 user=$2 spec=$3
  [[ -r $file ]] && grep -qx "${user}:${spec}" "$file"
}

if [[ $mode == check ]]; then
  rc=0
  for runner in "${runners[@]}"; do
    spec=${range_for[$runner]}
    check_range "$subuid_file" "$runner" "$spec" ||
      { echo "agent-job-provision: $subuid_file has no $runner:$spec" >&2; rc=1; }
    check_range "$subgid_file" "$runner" "$spec" ||
      { echo "agent-job-provision: $subgid_file has no $runner:$spec" >&2; rc=1; }
  done
  for runner in "${runners[@]}"; do
    if ! "$loginctl_bin" show-user "$runner" -p Linger 2>/dev/null | grep -qx 'Linger=yes'; then
      echo "agent-job-provision: $runner does not linger; run without --check" >&2
      rc=1
    fi
    if [[ ! -d $runtime_base/$(id -u "$runner") ]]; then
      echo "agent-job-provision: $runtime_base/$(id -u "$runner") is missing for $runner" >&2
      rc=1
    fi
  done
  [[ -r $nft_file ]] || { echo "agent-job-provision: $nft_file is missing" >&2; rc=1; }
  if [[ -r $nft_file ]] && command -v nft >/dev/null 2>&1; then
    nft -c -f "$nft_file" || rc=1
  fi
  exit "$rc"
fi

for runner in "${runners[@]}"; do
  add_range "$subuid_file" "$runner" "${range_for[$runner]}"
  add_range "$subgid_file" "$runner" "${range_for[$runner]}"
  # linger is what makes logind create and keep /run/user/<uid>; without it the
  # runner has no runtime directory and rootless Podman cannot start a namespace.
  "$loginctl_bin" enable-linger "$runner"
done

[[ -r $nft_file ]] || fail "the egress ruleset $nft_file is missing"
nft -f "$nft_file"

# A missing tree means the git dataset is not mounted yet; the dispatcher fails
# closed on a non-writable workspace, so this is reported rather than guessed.
if [[ -d $workspace ]]; then
  setfacl -m "u:agent-shell-general:rwx" "$workspace"
  setfacl -m "d:u:agent-shell-general:rwx" "$workspace"
else
  echo "agent-job-provision: $workspace is absent; zfs-ready@raw-git has not run" >&2
fi

echo "agent-job-provision: runners have distinct subids, the general ACL and the egress table"
