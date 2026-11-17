#!/usr/bin/env bash
# Dump the Immich database into the photos recovery group, so the physical
# cluster and a logical restore point sit in the same snapshot.
#
# The dump is written to a temporary name and renamed, exactly as the legacy job
# did: a failed dump leaves yesterday's file in place instead of truncating it.
# Retention is Restic's history, not this job's; the file name is stable.
set -euo pipefail

container=${IMMICH_PG_CONTAINER:-smortress-immich-postgres}
out_dir=${IMMICH_DUMP_DIR:-/var/lib/immich/dumps}
podman_bin=${PODMAN_BIN:-podman}

if [[ ! -d /var/lib/immich/postgres ]] || ! mountpoint -q /var/lib/immich/dumps; then
  echo "immich-dump: the postgres or dumps dataset is not mounted" >&2
  exit 1
fi
if ! "$podman_bin" container exists "$container"; then
  echo "immich-dump: container $container does not exist" >&2
  exit 1
fi

install -d -m 0700 "$out_dir"
final=$out_dir/immich.dump
tmp=$out_dir/immich.dump.tmp
trap 'rm -f "$tmp"' EXIT

# Per-attempt deadline; the unit's TimeoutStartSec is the outer bound.
if ! timeout 1740 "$podman_bin" exec "$container" \
    pg_dump -Fc --no-owner -U immich immich >"$tmp"; then
  echo "immich-dump: pg_dump failed; $final is unchanged" >&2
  exit 1
fi
# An empty or non-custom-format file is a failure, not a restore point.
if ! head -c 5 "$tmp" | grep -q PGDMP; then
  echo "immich-dump: pg_dump output is not a custom-format archive" >&2
  exit 1
fi
mv -f "$tmp" "$final"
trap - EXIT
echo "immich-dump: wrote $final ($(stat -c %s "$final") bytes)"
