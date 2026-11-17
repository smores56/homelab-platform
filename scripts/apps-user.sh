#!/usr/bin/env bash
# Provision the apps tenant user's rootless prerequisites (SDLC #726, T7).
#
# systemd-sysusers creates the login-less `apps` user; rootless Podman still
# needs a subuid/subgid allocation, a home for its storage, a user manager that
# starts without a login, and a policy that lets the tenant pull its pinned
# images. The policy is per-user and deliberately looser than the host's
# default-reject one: a tenant definition may name any digest-pinned image (the
# schema refuses tags), and the tenant has no other path into the host.
set -euo pipefail

user=apps
subuid_file=${SUBUID_FILE:-/etc/subuid}
subgid_file=${SUBGID_FILE:-/etc/subgid}
policy_dir=${APPS_POLICY_DIR:-/var/home/apps/.config/containers}
apps_owner=${APPS_OWNER:-apps:apps}
subid_range=${APPS_SUBID_RANGE:-200000-265535}
required_bins=${APPS_REQUIRE_BINS-pasta newuidmap newgidmap}

fail() {
  echo "apps-user: $*" >&2
  exit 1
}

id -u "$user" >/dev/null 2>&1 || fail "user $user does not exist"

missing=
for bin in $required_bins; do
  command -v "$bin" >/dev/null 2>&1 || missing="$missing $bin"
done
[[ -z $missing ]] || fail "rootless Podman is missing:$missing"

# The files are root-owned lists; an entry is a range, and `usermod` is not
# needed for an append. Guarding on the user keeps a reboot idempotent.
add_range() { # file range
  local file=$1 range=$2
  [[ -e $file ]] || install -m 0644 /dev/null "$file"
  grep -qE "^${user}:" "$file" && return 0
  printf '%s:%s\n' "$user" "$range" >>"$file"
}
add_range "$subuid_file" "$subid_range"
add_range "$subgid_file" "$subid_range"

owner_user=${apps_owner%%:*}
owner_group=${apps_owner#*:}
if ((EUID == 0)); then
  install -d -m 0700 -o "$owner_user" -g "$owner_group" "$policy_dir" \
    || fail "could not create $policy_dir"
else
  # Offline tests run unprivileged; the unit always runs as root.
  install -d -m 0700 "$policy_dir" || fail "could not create $policy_dir"
fi
policy=$policy_dir/policy.json
if [[ ! -f $policy ]]; then
  cat >"$policy" <<'JSON'
{
  "default": [
    {
      "type": "insecureAcceptAnything"
    }
  ]
}
JSON
  ((EUID == 0)) && chown "$apps_owner" "$policy"
  chmod 0600 "$policy"
fi

echo "apps-user: $user has $subid_range, a policy, and rootless dependencies"
