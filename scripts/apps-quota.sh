#!/usr/bin/env bash
# Apply the apps tenant's quotas (SDLC #726, T7 of #701).
#
# Two bounds keep the tenant from filling the pool: the `raw/apps` dataset
# carries the quota from the storage table, and each app directory carries a
# ZFS project quota with the inherit flag set, so files created later are
# accounted too. The plan is written by the deploy, but this script does not
# trust it: every name, project id and quota is checked again here.
#
#   apps-quota            apply the plan's quotas and the dataset quota
#   apps-quota --check    report drift without writing anything
#
# An app that left the plan keeps its directory and its quota: removing data is
# a human decision, and the dataset quota still bounds the total.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
layout=${STORAGE_LAYOUT:-$here/storage-layout}
[[ -r $layout ]] || layout=$layout.sh
# shellcheck source=/dev/null
source "$layout"

zfs_bin=${ZFS:-zfs}
plan=${APPS_PLAN:-/var/lib/homelab/apps/plan.json}
dataset=$(dataset_name raw/apps)
apps_root=${APPS_ROOT:-$(mountpoint_for raw/apps)}
apps_owner=${APPS_OWNER:-apps:apps}

# Mirrors QUOTA_CEILING in apps-schema.py. A plan is root-owned, but a ceiling
# that exists only in the writer is not a boundary.
ceiling=50G
app_name_re='^[a-z]([a-z0-9-]{0,29}[a-z0-9])?$'
quota_re='^([0-9]+)([KMGT])$'
project_max=4294967295

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
  case $unit in
    K) number=$((number * 1024)) ;;
    M) number=$((number * 1024 ** 2)) ;;
    G) number=$((number * 1024 ** 3)) ;;
    T) number=$((number * 1024 ** 4)) ;;
  esac
  printf '%s\n' "$number"
}

ceiling_bytes=$(quota_bytes "$ceiling")
dataset_quota=${dataset_quota[raw/apps]:-}
dataset_quota_bytes=
if [[ -n $dataset_quota ]]; then
  dataset_quota_bytes=$(quota_bytes "$dataset_quota") \
    || fail "the storage table names an invalid apps dataset quota: $dataset_quota"
  ((dataset_quota_bytes >= ceiling_bytes)) \
    || fail "the apps dataset quota $dataset_quota is below the per-app ceiling $ceiling"
  ((dataset_quota_bytes <= ceiling_bytes * 8)) \
    || fail "the apps dataset quota $dataset_quota is too large for this pool"
fi

# Validate every definition before touching the pool. A rejected plan changes
# nothing rather than applying half of itself.
declare -a names=() projects=() quotas=()
declare -A seen_project=()
if [[ -e $plan ]]; then
  [[ -f $plan ]] || fail "$plan is not a regular file"
  jq -e 'type == "object" and ((.apps // {}) | type) == "object"' "$plan" >/dev/null 2>&1 \
    || fail "$plan is not a tenant plan"
  while IFS=$'\t' read -r name path project project_kind quota quota_kind; do
    [[ $name =~ $app_name_re ]] || fail "invalid app name in $plan: $name"
    [[ $path == "/apps/$name" ]] || fail "app $name: base path is $path, not /apps/$name"
    [[ $project_kind == number && $project =~ ^[0-9]+$ ]] \
      || fail "app $name: project id is not a number: $project"
    ((project >= 1 && project <= project_max)) \
      || fail "app $name: project id $project is out of range"
    [[ -z ${seen_project[$project]:-} ]] \
      || fail "app $name: project id $project is also used by ${seen_project[$project]}"
    seen_project[$project]=$name
    [[ $quota_kind == string ]] || fail "app $name: quota is not a string: $quota"
    bytes=$(quota_bytes "$quota") || fail "app $name: invalid quota: $quota"
    ((bytes <= ceiling_bytes)) || fail "app $name: quota $quota exceeds the platform ceiling $ceiling"
    names+=("$name")
    projects+=("$project")
    quotas+=("$bytes")
  done < <(
    jq -r '(.apps // {}) | to_entries[]
      | [.key, (.value.basePath // ""), (.value.projectId // "" | tostring),
         (.value.projectId | type), (.value.quota // "" | tostring),
         (.value.quota // "" | type)]
      | @tsv' "$plan"
  )
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

if [[ -n $dataset_quota_bytes ]]; then
  got=$("$zfs_bin" get -H -o value quota "$dataset")
  if [[ $got != "$dataset_quota_bytes" ]]; then
    if $check; then
      report "$dataset quota is $got, want $dataset_quota_bytes"
    else
      "$zfs_bin" set "quota=$dataset_quota_bytes" "$dataset" \
        || fail "could not set the quota on $dataset"
    fi
  fi
fi

owner_user=${apps_owner%%:*}
owner_group=${apps_owner#*:}
for index in "${!names[@]}"; do
  name=${names[$index]}
  project=${projects[$index]}
  bytes=${quotas[$index]}
  dir=$apps_root/$name

  if ! $check; then
    install -d -m 0700 -o "$owner_user" -g "$owner_group" "$dir" \
      || fail "could not create $dir"
    "$zfs_bin" project -p "$project" -r -s "$dir" \
      || fail "could not assign project $project to $dir"
    "$zfs_bin" set "projectquota@$project=$bytes" "$dataset" \
      || fail "could not set the project quota for $name"
  fi

  got_project=$("$zfs_bin" project -c -p "$project" "$dir" 2>/dev/null || true)
  [[ -z $got_project ]] || report "$name: project id is wrong on $got_project"
  got_quota=$("$zfs_bin" get -H -o value "projectquota@$project" "$dataset")
  [[ $got_quota == "$bytes" ]] || report "$name: project quota is $got_quota, want $bytes"
done

if $check; then
  ((problems == 0)) || exit 1
  echo "apps-quota: all ${#names[@]} apps match the plan"
else
  ((problems == 0)) || exit 1
  echo "apps-quota: applied ${#names[@]} apps under $dataset"
fi
