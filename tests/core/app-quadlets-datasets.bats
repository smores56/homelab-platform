#!/usr/bin/env bats
# bats file_tags=core
# The Immich dump lands in the photos unit and completes before the R2 job,
# and the storage table is the only list of datasets.
#
# One file of the suite that was tests/core/app-quadlets.bats, split so bats can
# run the sections as parallel files (a file is one job). The tables, the
# file-scope sources and every checker more than one section calls are in
# tests/core/app-quadlets_lib.bash; the checkers only this file uses stay here.
#
#   bats tests/core/app-quadlets-datasets.bats
load ../helpers
load ./app-quadlets_lib

setup_file() { aq_setup_file; }
setup() { aq_setup; }

# 6. The logical Immich dump lands in the photos unit's dump dataset and
#    completes before the daily offsite snapshot.
@test "immich dump writes inside the photos unit" {
  grep -q '/var/lib/immich/dumps' scripts/immich-dump.sh
}

calendar_hour() { # timer
  sed -n 's/^OnCalendar=\*-\*-\* \([0-9][0-9]\):[0-9][0-9]:00$/\1/p' "$1"
}

# The R2 job is at midnight, so "before" means a small positive distance across
# the day boundary: 21:00 -> 00:00 is three hours, 01:00 -> 00:00 is twenty-three.
dump_precedes_the_r2_job() {
  local dump_hour r2_hour gap
  dump_hour=$(calendar_hour units/systemd/smortress-immich-dump.timer)
  r2_hour=$(calendar_hour units/systemd/smortress-restic-backup-r2.timer)
  if [[ -z $dump_hour || -z $r2_hour ]]; then
    printf 'dump=%s r2=%s\n' "$dump_hour" "$r2_hour" >&2
    return 1
  fi
  gap=$(((10#$r2_hour - 10#$dump_hour + 24) % 24))
  if ((gap < 1 || gap > 4)); then
    printf 'gap=%sh dump=%s r2=%s\n' "$gap" "$dump_hour" "$r2_hour" >&2
    return 1
  fi
}

_dump_at=$(calendar_hour units/systemd/smortress-immich-dump.timer)
_r2_at=$(calendar_hour units/systemd/smortress-restic-backup-r2.timer)
if [[ -n $_dump_at && -n $_r2_at ]]; then
  registered "immich dump (${_dump_at}:00) precedes the R2 job (${_r2_at}:00) by $(((10#$_r2_at - 10#$_dump_at + 24) % 24))h" \
    dump_precedes_the_r2_job
else
  registered 'immich dump precedes the R2 job' dump_precedes_the_r2_job
fi
unset _dump_at _r2_at

@test "immich dump requires its dataset" {
  grep -q 'Requires=.*zfs-ready@raw-photos.service' units/systemd/smortress-immich-dump.service
}

# 6b. The dump is the whole database, and OPDShelf must not share Immich's
#    bridge; Syncthing must let its entrypoint do the privilege drop.
@test "immich dump is root-only" {
  grep -q '^UMask=0077' units/systemd/smortress-immich-dump.service
}

@test "opdshelf has its own network" {
  grep -q '^Network=opdshelf.network' units/quadlet/opdshelf.container &&
    grep -q '^Description=Smortress OPDShelf network' units/quadlet/opdshelf.network
}

@test "syncthing lets its entrypoint drop privileges" {
  ! grep -q '^User=' units/quadlet/syncthing.container
}

# 7. The storage table is the only list: the pool and the readiness check read
#    it rather than restating dataset names, and a dataset root belongs to the uid
#    the applications run as, which is what lets a restored tree be written
#    without a manual chown.
# The matched text is the source line, so $layout is deliberately literal.
# shellcheck disable=SC2016
@test "the pool and readiness scripts read the storage table" {
  ! grep -q '^groups=(' scripts/init-zpool.sh &&
    grep -q 'source "$layout"' scripts/init-zpool.sh &&
    grep -q 'source "$layout"' scripts/zfs-ready.sh
}

# The matched text is the source line, so $mountpoint is deliberately literal.
# shellcheck disable=SC2016
@test "the pool unit takes each dataset root owner from the table" {
  grep -q 'chown "$(dataset_owner_for "$key")" "$mountpoint"' scripts/init-zpool.sh
}

# Quadlet drops an empty Exec argument, so valkey's `--save ""` must stay inside
# a shell command or the container refuses to start on the host only.
@test "valkey disables snapshots through a shell wrapper" {
  grep -q "Exec=/bin/sh -c 'exec valkey-server" units/quadlet/immich-valkey.container &&
    grep -qF -- '--save ""' units/quadlet/immich-valkey.container
}

@test "valkey keeps its AOF in the dataset root" {
  grep -q -- '--dir /data --appendonly yes' units/quadlet/immich-valkey.container
}

# The readiness instances the image has to enable and the backup driver has to
# wait for. The shell suite read this list off init-zpool's plan; the plan is
# printed from the storage table, so the table answers the same.
instances=$( (source scripts/storage-layout.sh; printf '%s\n' "${dataset_order[@]}") | tr / -)

image_enables_readiness_instance() { # instance
  grep -q "zfs-ready@$1.service" bootc/server/Containerfile
}

backup_driver_waits_for_readiness_instance() { # instance
  grep -q "zfs-ready@$1.service" units/systemd/smortress-restic-backup@.service
}

for _instance in $instances; do
  registered "image enables zfs-ready@$_instance" image_enables_readiness_instance "$_instance"
  registered "backup driver is ordered after zfs-ready@$_instance" \
    backup_driver_waits_for_readiness_instance "$_instance"
done
unset _instance
