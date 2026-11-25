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
  # Navidrome's database: playlists, play counts, users and shares, none of
  # which the library files regenerate.
  [state/navidrome]=/var/lib/navidrome
  # Agent deployments (SDLC #711): one state dataset per gateway, and one for the
  # 4.7 GiB model file the personal gateway's server loads.
  [state/agent-local]=/var/lib/agent/local
  [state/agent-general]=/var/lib/agent/general
  [state/agent-model]=/var/lib/agent/model
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
  state/syncthing-config state/opdshelf state/navidrome
  state/agent-local state/agent-general state/agent-model)

#: Dataset quotas. Until the core datasets carry a refreservation, the tenant is
#: the only writer that can fill the pool, so the apps dataset is bounded here
#: and each app gets its own project quota inside it (scripts/apps-quota.sh).
declare -A dataset_quota=(
  [raw/apps]=200G
)

#: Dataset root ownership and mode. Every core dataset belongs to uid 1000 and
#: is 0750, so the unprivileged tenant user cannot read application data; the
#: tenant's own dataset belongs to the tenant and is private to it.
declare -A dataset_root_owner=(
  # No container writes these, so the operator owns them outright. Without an
  # entry they take the numeric default, which is uid 1000 -- `core` on this
  # host, not the operator -- and init-zpool chowns every dataset root at each
  # boot, so the operator's access has to be re-applied by hand every time.
  [raw/git]=smores:smores
  [raw/repo-archive]=smores:smores
  [raw/wallpapers]=smores:smores
  # The tenant account by name, never by id: systemd-sysusers allocates the id,
  # so a number here would hand /srv/apps to whoever holds it after the account
  # is recreated. init-zpool resolves the name when it chowns, and the pool unit
  # is ordered After=systemd-sysusers.service for exactly that reason — it sets
  # DefaultDependencies=no, so nothing would otherwise order it there.
  [raw/apps]=apps:apps
)
declare -A dataset_root_mode=(
  [raw/apps]=0700
)
: "${dataset_root_owner_default:=1000:1000}"
: "${dataset_root_mode_default:=0750}"

#: POSIX ACLs must survive the chmod below. ZFS deletes every non-trivial ACE on
#: chmod by default (aclmode=discard), and init-zpool re-runs that chmod on each
#: dataset root at every boot, so an ACL granting the operator access to a
#: container-owned tree would silently vanish on the next reboot.
dataset_acl_mode=passthrough

dataset_owner_for() { printf '%s\n' "${dataset_root_owner[$1]:-$dataset_root_owner_default}"; }
dataset_mode_for() { printf '%s\n' "${dataset_root_mode[$1]:-$dataset_root_mode_default}"; }

#: Restore units, in backup order, and the datasets each one restores together.
declare -A unit_datasets=(
  [files]="raw/files state/syncthing-config"
  [photos]="raw/photos state/immich-postgres state/immich-dumps"
  [books]="raw/books state/opdshelf"
  [music]="raw/music state/navidrome"
  [wallpapers]="raw/wallpapers"
  [git]="raw/git"
  [apps]="raw/apps"
  [repo-archive]="raw/repo-archive"
  # A gateway's state is its sessions, its memory and its skills: not derivable
  # from anything else on the host, so it is a recovery point. The model file is
  # not (see dataset_unrestored).
  [agent-local]="state/agent-local"
  [agent-general]="state/agent-general"
)
units=(files photos books music wallpapers git apps repo-archive agent-local agent-general)

#: Datasets deliberately in no unit. state/agent-model holds one 4.7 GiB GGUF
#: blob that docs/manual-steps.md section 40.8 re-downloads and verifies by
#: checksum: backing it up would put a reconstructable artefact in every Restic
#: snapshot and in R2, for no restore value at all. A restore that needs it runs
#: the fetch; the gateway cannot start without it, which is loud and correct.
dataset_unrestored=(state/agent-model)

#: Directories that must exist for the state datasets to mount. They are not
#: datasets themselves: a cache or a version history is rebuilt, not restored.
state_parents=(/var/lib/immich /var/lib/syncthing /var/lib/agent)

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
