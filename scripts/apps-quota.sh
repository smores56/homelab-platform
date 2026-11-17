#!/usr/bin/env bash
# Apply the apps tenant's quotas (SDLC #726, T7 of #701).
#
# Two bounds keep the tenant from filling the pool: the `raw/apps` dataset
# carries the quota from the storage table, and each app directory carries a
# ZFS project quota with the inherit flag set, so files created later are
# accounted too. The plan is written by the deploy, but this script does not
# trust it: it runs the shipped plan verifier first, then checks the pool.
#
#   apps-quota            apply what differs, verify the rest
#   apps-quota --check    report drift without writing anything
#
# An app that left the plan keeps its directory and its quota: removing data is
# a human decision, and the dataset quota still bounds the total. Its project
# id is still listed, so the operator can see what the tenant holds.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
layout=${STORAGE_LAYOUT:-$here/storage-layout}
[[ -r $layout ]] || layout=$layout.sh
# shellcheck source=/dev/null
source "$layout"

zfs_bin=${ZFS:-zfs}
schema=${APPS_SCHEMA:-/usr/libexec/apps-schema}
plan=${APPS_PLAN:-/var/lib/homelab/apps/plan.json}
dataset=$(dataset_name raw/apps)
apps_root=${APPS_ROOT:-$(mountpoint_for raw/apps)}
apps_owner=${APPS_OWNER:-$(dataset_owner_for raw/apps)}

ceiling=50G
quota_re='^([0-9]+)([KMGT])$'

check=false
case ${1:-} in
  --check) check=true ;;
  '') ;;
  *)
    echo "usage: apps-quota [--check]" >&2
    exit 2
    ;;
esac

fail() {
  echo "apps-quota: $*" >&2
  exit 1
}

quota_bytes() {
  local value=$1 number unit
  [[ $value =~ $quota_re ]] || return 1
  number=${BASH_REMATCH[1]}
  unit=${BASH_REMATCH[2]}
  # Bound before multiplying: an oversized count would wrap in 64-bit
  # arithmetic and turn a quota into zero, i.e. no quota at all.
  ((number > 0 && number <= 1024 * 1024)) || return 1
  case $unit in
    K) number=$((number * 1024)) ;;
    M) number=$((number * 1024 ** 2)) ;;
    G) number=$((number * 1024 ** 3)) ;;
    T) number=$((number * 1024 ** 4)) ;;
  esac
  printf '%s\n' "$number"
}

ceiling_bytes=$(quota_bytes "$ceiling") || fail "invalid ceiling: $ceiling"

dataset_quota=${dataset_quota[raw/apps]:-}
dataset_quota_bytes=
if [[ -n $dataset_quota ]]; then
  dataset_quota_bytes=$(quota_bytes "$dataset_quota") \
    || fail "the storage table names an invalid apps dataset quota: $dataset_quota"
  ((dataset_quota_bytes >= ceiling_bytes)) \
    || fail "the apps dataset quota $dataset_quota is below the per-app ceiling $ceiling"
fi

# The verifier is the renderer's own; it fails closed on a non-object entry, a
# foreign path, a duplicate project id or a quota above the ceiling.
declare -a names=() projects=() quotas=()
if [[ -e $plan ]]; then
  [[ -f $plan ]] || fail "$plan is not a regular file"
  if ! "$schema" verify-plan --plan "$plan"; then
    fail "$plan is not a valid tenant plan"
  fi
  if ! rows=$(jq -r '(.apps // {}) | to_entries[]
      | [.key, (.value.projectId | tostring), (.value.quota)] | @tsv' "$plan"); then
    fail "could not read $plan"
  fi
  while IFS=$'\t' read -r name project quota; do
    [[ -n $name ]] || continue
    names+=("$name")
    projects+=("$project")
    quotas+=("$(quota_bytes "$quota")") || fail "app $name: invalid quota: $quota"
  done <<<"$rows"
fi

"$zfs_bin" list -H -o name "$dataset" >/dev/null 2>&1 \
  || fail "dataset $dataset does not exist"

if [[ -z ${APPS_ROOT:-} ]] && ! mountpoint -q "$apps_root"; then
  fail "$apps_root is not a mountpoint; refusing to write into an empty tree"
fi

problems=0
report() {
  problems=$((problems + 1))
  echo "apps-quota: $*" >&2
}

exact_prop() { # property dataset -> exact bytes (0 when unset)
  "$zfs_bin" get -H -p -o value "$1" "$2"
}

dir_project() { # dir -> "<id> <flag>"
  "$zfs_bin" project -d "$1" | awk 'NR == 1 { print $1, $2 }'
}

if [[ -n $dataset_quota_bytes ]]; then
  got=$(exact_prop quota "$dataset")
  if [[ $got != "$dataset_quota_bytes" ]]; then
    if $check; then
      report "$dataset quota is $got, want $dataset_quota_bytes"
    else
      "$zfs_bin" set "quota=$dataset_quota_bytes" "$dataset" \
        || fail "could not set the quota on $dataset"
    fi
  fi
fi

# A project id already stamped on some other app directory belongs to data that
# stayed behind; reusing it would make two apps share one quota.
collision() { # wanted-id own-dir
  local wanted=$1 own=$2 dir id
  for dir in "$apps_root"/*/; do
    [[ -d $dir ]] || continue
    [[ $(cd "$dir" && pwd) == "$(cd "$own" 2>/dev/null && pwd)" ]] && continue
    read -r id _ < <(dir_project "$dir") || continue
    [[ $id == "$wanted" ]] && { printf '%s\n' "$dir"; return 0; }
  done
  return 1
}

owner_user=${apps_owner%%:*}
owner_group=${apps_owner#*:}
for index in "${!names[@]}"; do
  name=${names[$index]}
  project=${projects[$index]}
  bytes=${quotas[$index]}
  dir=$apps_root/$name

  if [[ ! -d $dir ]]; then
    if $check; then
      report "$name: $dir is missing"
      continue
    fi
    if ((EUID == 0)); then
      install -d -m 0700 -o "$owner_user" -g "$owner_group" "$dir" \
        || fail "could not create $dir"
    else
      install -d -m 0700 "$dir" || fail "could not create $dir"
    fi
  fi

  # The tenant owns /srv/apps and can replace an entry with a symlink; a root
  # applier must never stamp, chown or create through one.
  if [[ -L $dir ]] || [[ $(readlink -f -- "$dir") != "$apps_root/$name" ]]; then
    if $check; then
      report "$name: $dir is a symlink or resolves outside the tenant"
    else
      fail "$name: $dir is a symlink or resolves outside the tenant"
    fi
    continue
  fi

  read -r current_id current_flag < <(dir_project "$dir") || true
  if [[ $current_id != "$project" || $current_flag != I ]]; then
    if other=$(collision "$project" "$dir"); then
      report "$name: project id $project is already stamped on $other"
      continue
    fi
    if $check; then
      report "$name: project id is $current_id/${current_flag:--}, want $project/I"
    else
      "$zfs_bin" project -p "$project" -r -s "$dir" \
        || fail "could not assign project $project to $dir"
    fi
  fi

  got=$(exact_prop "projectquota@$project" "$dataset")
  if [[ $got != "$bytes" ]]; then
    if $check; then
      report "$name: project quota is $got, want $bytes"
    else
      "$zfs_bin" set "projectquota@$project=$bytes" "$dataset" \
        || fail "could not set the project quota for $name"
    fi
  fi

  if $check; then
    # New files inherit the id; a tree that lost the flag or carries a foreign
    # id would silently escape the quota, so walk it.
    if ! drift=$("$zfs_bin" project -c -p "$project" -r "$dir"); then
      report "$name: could not check the project tree"
    elif [[ -n $drift ]]; then
      report "$name: project drift under $(printf '%s\n' "$drift" | head -1)"
    fi
  fi
done

# Orphans are informational: the data is retained on purpose, so a deploy that
# removes an app must not fail, but the operator should see the usage.
while IFS=',' read -r property _; do
  id=${property#projectquota@}
  [[ $id =~ ^[0-9]+$ ]] || continue
  if ! printf '%s\n' "${projects[@]}" | grep -qx "$id"; then
    echo "apps-quota: note: retained project quota for id $id ($property)"
  fi
done < <("$zfs_bin" get -H -p -o property,value all "$dataset" | grep '^projectquota@' || true)

if $check; then
  ((problems == 0)) || exit 1
  echo "apps-quota: all ${#names[@]} apps match the plan"
else
  ((problems == 0)) || exit 1
  echo "apps-quota: applied ${#names[@]} apps under $dataset"
fi
