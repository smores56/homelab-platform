#!/usr/bin/env bash
# The one storage table for smortress (SDLC #701, T6 of the data plane).
#
# Sourced by init-zpool, zfs-ready and restic-plane-common; never run on its
# own. Data is laid out by kind: `raw/<group>` datasets hold the files the
# system exists to serve, and `state/<app>` datasets hold the service state
# that cannot be rebuilt from them. Everything else under /var/lib is
# rebuildable and has no dataset, no snapshot and no backup.
#
# A unit is the backup and restore unit: one application, and the fixed set of
# datasets restored together. One Restic snapshot names every dataset path in
# the unit, so a restore takes one point in time.
#
# shellcheck disable=SC2034  # sourced library: consumers use a subset

pool=smortress

#: Dataset key -> mountpoint. The key is `raw/<group>` or `state/<app>`, and
#: it is what a readiness unit and a snapshot path are named from. /srv is the
#: ostree symlink to /var/srv, so the mountpoint property is /var/srv/<group>
#: and either path works for a consumer.
declare -A dataset_mount=(
  [raw/files]=/var/srv/files
  [raw/photos]=/var/srv/photos
  [raw/books]=/var/srv/books
  [raw/music]=/var/srv/music
  [raw/wallpapers]=/var/srv/wallpapers
  [raw/git]=/var/srv/git
  [raw/apps]=/var/srv/apps
  [raw/repo-archive]=/var/srv/repo-archive
  [state/immich-postgres]=/var/lib/immich/postgres
  [state/immich-dumps]=/var/lib/immich/dumps
  [state/syncthing-config]=/var/lib/syncthing/config
  [state/opdshelf]=/var/lib/opdshelf
)

#: Tests run this exact table against a scratch tree. Nothing on the host sets
#: it, and an empty value means the real roots.
if [[ -n ${STORAGE_MOUNT_ROOT:-} ]]; then
  for _layout_key in "${!dataset_mount[@]}"; do
    dataset_mount[$_layout_key]=$STORAGE_MOUNT_ROOT${dataset_mount[$_layout_key]}
  done
  unset _layout_key
fi

#: Parent datasets. A ZFS child cannot exist without its parent, and neither
#: parent is mounted: `/` is a plain filesystem, so the `raw` and `state`
#: collections exist only as namespaces in the pool.
dataset_parents=(raw state)

#: Creation order. Associative arrays have no order, and a deterministic
#: init-zpool plan is what --print-plan and its test compare.
dataset_order=(raw/files raw/photos raw/books raw/music raw/wallpapers raw/git
  raw/apps raw/repo-archive state/immich-postgres state/immich-dumps
  state/syncthing-config state/opdshelf)

#: Dataset quotas. Until the core datasets carry a refreservation, the tenant is
#: the only writer that can fill the pool, so the apps dataset is bounded here
#: and each app gets its own project quota inside it (scripts/apps-quota.sh).
declare -A dataset_quota=(
  [raw/apps]=200G
)

#: Restore units, in backup order, and the datasets each one restores together.
declare -A unit_datasets=(
  [files]="raw/files state/syncthing-config"
  [photos]="raw/photos state/immich-postgres state/immich-dumps"
  [books]="raw/books state/opdshelf"
  [music]="raw/music"
  [wallpapers]="raw/wallpapers"
  [git]="raw/git"
  [apps]="raw/apps"
  [repo-archive]="raw/repo-archive"
)
units=(files photos books music wallpapers git apps repo-archive)

#: Directories that must exist for the state datasets to mount. They are not
#: datasets themselves: a cache or a version history is rebuilt, not restored.
state_parents=(/var/lib/immich /var/lib/syncthing)

dataset_name() { printf '%s/%s\n' "$pool" "$1"; }
mountpoint_for() { printf '%s\n' "${dataset_mount[$1]:?unknown dataset key: $1}"; }

#: systemd instance name for a dataset key. `/` cannot appear in an instance,
#: and the leading segment is always raw or state, so the mapping is reversible.
readiness_instance() { printf '%s\n' "${1//\//-}"; }

#: Dataset key from a readiness instance (`raw-files`, `state-immich-postgres`).
readiness_key() {
  local instance=$1 kind=${1%%-*}
  [[ $instance == *-* && ($kind == raw || $kind == state) ]] || return 1
  printf '%s/%s\n' "$kind" "${instance#*-}"
}

#: Every dataset the given unit restores, one key per line.
unit_keys() {
  local key
  for key in ${unit_datasets[$1]:?unknown unit: $1}; do
    printf '%s\n' "$key"
  done
}

#: The unit's snapshot paths as a JSON array, for a state file or a journal.
unit_paths_json() { # unit backend
  local -a paths
  local key
  for key in $(unit_keys "$1"); do
    paths+=("$(mountpoint_for "$key")/.zfs/snapshot/$2")
  done
  if ((${#paths[@]} == 0)); then
    printf '[]\n'
    return 0
  fi
  jq -cn --args '$ARGS.positional' -- "${paths[@]}"
}

#: Every path a consumer may name for a dataset. `/srv` is a symlink to
#: `/var/srv`, so a Quadlet may mount either spelling; a check that compares a
#: volume path to the table must accept both.
mountpoint_aliases() { # key
  local mountpoint
  mountpoint=$(mountpoint_for "$1")
  printf '%s\n' "$mountpoint"
  case $mountpoint in
    */var/srv/*) printf '%s\n' "${mountpoint/\/var\/srv//srv}" ;;
  esac
}
