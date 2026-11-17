#!/usr/bin/env bash
# Provision the apps tenant user's rootless prerequisites (SDLC #726, T7).
#
# systemd-sysusers creates the login-less `apps` user; rootless Podman still
# needs a subuid/subgid allocation and a user manager that starts without a
# login. Nothing here writes into the tenant's home: that tree belongs to the
# tenant, and root creating or chowning paths inside it would follow a symlink
# the tenant planted. The container policy the tenant runs under is root-owned
# at /usr/share/smortress/apps-policy.json and named by each rendered unit.
set -euo pipefail

user=apps
subuid_file=${SUBUID_FILE:-/etc/subuid}
subgid_file=${SUBGID_FILE:-/etc/subgid}
subid_range=${APPS_SUBID_RANGE:-200000:65536}
required_bins=${APPS_REQUIRE_BINS-pasta newuidmap newgidmap}

fail() {
  echo "apps-user: $*" >&2
  exit 1
}

[[ $subid_range =~ ^[0-9]+:[0-9]+$ ]] || fail "APPS_SUBID_RANGE must be start:count, got '$subid_range'"

id -u "$user" >/dev/null 2>&1 || fail "user $user does not exist"

missing=
for bin in $required_bins; do
  command -v "$bin" >/dev/null 2>&1 || missing="$missing $bin"
done
[[ -z $missing ]] || fail "rootless Podman is missing:$missing"

# Two accounts sharing a subuid range would put their containers in one uid
# space; refuse that rather than map the tenant onto someone else's ids.
overlaps() { # file start count
  local file=$1 start=$2 count=$3 name other_start other_count
  while IFS=: read -r name other_start other_count; do
    [[ -n $name && $name != "$user" ]] || continue
    [[ $other_start =~ ^[0-9]+$ && $other_count =~ ^[0-9]+$ ]] || continue
    ((start < other_start + other_count && other_start < start + count)) && return 0
  done <"$file"
  return 1
}

# The files are `name:start:count` lists. A line this script did not write is
# kept when it is well formed (an operator's own allocation wins), and replaced
# when it is not: a malformed line makes newuidmap find no range at all.
add_range() { # file start:count
  local file=$1 spec=$2 start count line
  start=${spec%%:*}
  count=${spec##*:}
  [[ -e $file ]] || install -m 0644 /dev/null "$file"
  # Appending to a file without a final newline would merge two entries.
  [[ -s $file && $(tail -c 1 "$file" | wc -l) == 0 ]] && printf '\n' >>"$file"
  local existing
  existing=$(grep -cE "^${user}:" "$file" || true)
  ((existing > 1)) && fail "$file holds more than one $user line; refusing to choose"
  line=$(grep -E "^${user}:" "$file" | head -1 || true)
  if [[ -n $line ]]; then
    if [[ $line =~ ^${user}:([0-9]+):([0-9]+)$ ]]; then
      start=${BASH_REMATCH[1]}
      count=${BASH_REMATCH[2]}
      overlaps "$file" "$start" "$count" \
        && fail "the existing $user allocation $start:$count overlaps another account in $file"
      echo "apps-user: keeping the existing allocation $user:$start:$count in $file" >&2
      return 0
    fi
    # Drop the malformed line(s) for this user before writing a valid one.
    sed -i "/^${user}:/d" "$file"
  fi
  overlaps "$file" "$start" "$count" \
    && fail "the allocation $start:$count overlaps another account in $file"
  printf '%s:%s:%s\n' "$user" "$start" "$count" >>"$file"
}
add_range "$subuid_file" "$subid_range"
add_range "$subgid_file" "$subid_range"

echo "apps-user: $user has $subid_range and rootless dependencies"
