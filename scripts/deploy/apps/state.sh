# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # globals are assigned by the entrypoint
# deploy-apps/state.sh: sourced by scripts/deploy-apps.sh; no shebang.
snapshot_previous() {
  local file base pname
  previous_units=()
  previous_secrets_json='{}'
  previous_plan=false
  previous_state=false
  previous_commit=$(deployed_commit homelab-apps 2>/dev/null) || previous_commit=""
  install -d -m 0700 "$work/render.prev" "$work/prev-secrets" || return 1
  # The plan's exact installed bytes: a revert puts them back rather than
  # re-rendering a commit the host no longer has.
  if [[ -f $apps_plan && ! -L $apps_plan ]]; then
    cp -- "$apps_plan" "$work/render.prev/plan.json" || return 1
    previous_plan=true
  fi
  # state.json is part of the revision the revert restores: the record is
  # written before apply.json is cleared, so a failure between the two leaves a
  # host on one revision and a state naming another.
  if [[ -f $deploy_state_file && ! -L $deploy_state_file ]]; then
    cp -- "$deploy_state_file" "$work/render.prev/state.json" || return 1
    previous_state=true
  fi
  # The units: exactly the files this platform rendered (its marker is in the
  # first line). A foreign file in the tenant's unit dir is left alone, never
  # removed and never restored -- it is the tenant's, not this deploy's.
  if [[ -d $apps_unit_dir ]]; then
    for file in "$apps_unit_dir"/*.container "$apps_unit_dir"/*.network; do
      [[ -f $file && ! -L $file ]] || continue
      head -n 1 -- "$file" 2>/dev/null | grep -qF -- "$render_marker" || continue
      base=$(basename -- "$file")
      cp -- "$file" "$work/render.prev/$base" || return 1
      previous_units+=("$base")
    done
  fi
  # The secret values: `create --replace` cannot be undone, so the old value is
  # captured before it is replaced. Every one the installed plan names is taken,
  # because which ones change is only known after the render.
  if [[ -f $apps_plan && ! -L $apps_plan ]]; then
    while IFS= read -r pname; do
      [[ -n $pname ]] || continue
      secret_name_ok "$pname" || {
        warn "$apps_plan names an unusable secret: $pname"
        return 1
      }
      if secret_value "$pname" >"$work/prev-secrets/$pname"; then
        chmod 0600 "$work/prev-secrets/$pname" || return 1
        previous_secrets_json=$(jq -c --arg n "$pname" --arg p "prev-secrets/$pname" \
          '. + {($n): $p}' <<<"$previous_secrets_json")
      else
        # The plan and the store disagree. Recording the absence makes a revert
        # remove what the failed commit created instead of inventing a value.
        rm -f -- "$work/prev-secrets/$pname"
        previous_secrets_json=$(jq -c --arg n "$pname" '. + {($n): null}' <<<"$previous_secrets_json")
      fi
    done < <(jq -r '(.apps // {}) | .[] | (.secretNames // {}) | .[]' "$apps_plan" | sort -u)
  fi
  return 0
}

file_hash() { # <file>
  sha256sum <"$1" | cut -d' ' -f1
}

secret_file() { printf '%s/secrets/%s\n' "$work" "$1"; }

secret_hash() { # <podman name>
  local file
  file=$(secret_file "$1")
  if [[ -f $file ]]; then file_hash "$file"; else printf 'absent\n'; fi
}

unit_hash() { # <app>
  local file
  file=$work/render.next/$(app_unit "$1")
  if [[ -f $file ]]; then file_hash "$file"; else printf 'absent\n'; fi
}

# A hash over the app's secret *names and values*, so a rotation and a rename are
# both a change even when the unit file is identical.
app_secret_hash() { # <app>
  local pname out=''
  while IFS= read -r pname; do
    [[ -n $pname ]] || continue
    out+="$pname $(secret_hash "$pname")"$'\n'
  done < <(jq -r --arg n "$1" '(.apps[$n].secretNames // {}) | .[]' "$work/render.next/plan.json")
  printf '%s' "$out" | sha256sum | cut -d' ' -f1
}

# The table state.json keeps: one entry per app plus the whole-set hashes, which
# is what `status` reports and what the next apply compares against.
build_apps_state() {
  local apps='{}' name units_hash secrets_hash
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    apps=$(jq -c --arg n "$name" --arg u "$(unit_hash "$name")" --arg s "$(app_secret_hash "$name")" \
      '. + {($n): {unit:$u, secrets:$s}}' <<<"$apps")
  done < <(plan_apps "$work/render.next/plan.json")
  units_hash=$(jq -r 'to_entries[] | "\(.key) \(.value.unit)"' <<<"$apps" | sort | sha256sum | cut -d' ' -f1)
  secrets_hash=$(jq -r 'to_entries[] | "\(.key) \(.value.secrets)"' <<<"$apps" | sort | sha256sum | cut -d' ' -f1)
  jq -nc --argjson apps "$apps" --arg u "$units_hash" --arg s "$secrets_hash" \
    '{unitsHash:$u,secretsHash:$s,apps:$apps}'
}

state_apps_write() { # <apps table>
  local current
  current=$(state_read 2>/dev/null) || current='{}'
  # `$s + {...}` and not a fresh object: the unknown top-level keys another
  # writer owns must survive this one, or a downgrade drops a field the readers
  # still expect.
  jq -c --argjson apps "$1" --arg now "$(deploy_now)" '
    . as $s
    | $s + {schema: ($s.schema // 1), apps: $apps, updated: $now}
  ' <<<"$current" | atomic_write "$deploy_state_file"
}

# --- the revision's differences ----------------------------------------------
diff_revision() {
  local name old_unit old_secrets unit
  local -a installed=()
  intended_units=()
  intended_apps=()
  intended_secrets=()
  new_apps=()
  changed_apps=()
  departed_apps=()
  mapfile -t intended_units < <(plan_units "$work/render.next")
  mapfile -t intended_apps < <(plan_apps "$work/render.next/plan.json")
  mapfile -t intended_secrets < <(
    jq -r '(.apps // {}) | .[] | (.secretNames // {}) | .[]' "$work/render.next/plan.json" | sort -u
  )
  # What is installed is the unit set the snapshot found, not the state record:
  # the state may describe a revision whose units were never written.
  for unit in "${previous_units[@]}"; do
    [[ $unit == *.container ]] || continue
    installed+=("${unit%.container}")
  done
  for name in "${intended_apps[@]}"; do
    if ! in_list "$name" "${installed[@]}"; then
      new_apps+=("$name")
      continue
    fi
    # A restart is needed when the unit or any value it mounts moved:
    # `create --replace` leaves a running container on the old value, so a
    # secret-only rotation is a restart too.
    old_unit=$(jq -r --arg n "$name" '.apps.apps[$n].unit // ""' <<<"$state_doc")
    old_secrets=$(jq -r --arg n "$name" '.apps.apps[$n].secrets // ""' <<<"$state_doc")
    if [[ $old_unit != "$(unit_hash "$name")" || $old_secrets != "$(app_secret_hash "$name")" ]]; then
      changed_apps+=("$name")
    fi
  done
  for name in "${installed[@]}"; do
    in_list "$name" "${intended_apps[@]}" || departed_apps+=("$name")
  done
  return 0
}

# The images the revision changes, one `<app>\t<image>` per line: an unchanged
# digest is already in the store, and pulling it again on every apply would make
# a secret rotation wait for the registry.
changed_images() {
  local name image previous
  while IFS=$'\t' read -r name image; do
    [[ -n $name ]] || continue
    previous=''
    if [[ -f $apps_plan ]]; then
      previous=$(jq -r --arg n "$name" '.apps[$n].image // ""' "$apps_plan" 2>/dev/null) || previous=''
    fi
    [[ $previous == "$image" ]] && continue
    printf '%s\t%s\n' "$name" "$image"
  done < <(jq -r '(.apps // {}) | to_entries[] | [.key, .value.image] | @tsv' \
    "$work/render.next/plan.json")
}

pull_ref() { # <image> -> <repo>@sha256:<digest>
  local image=$1 repo digest
  [[ $image == *@* ]] || return 1
  repo=${image%@*}
  digest=${image##*@}
  [[ $repo == */* && $digest =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  printf '%s@%s\n' "$repo" "$digest"
}

# --- mutations ---------------------------------------------------------------
# Each of these changes the host, so the caller reverts on the first failure.

# The record a crash is reverted from: the phase, the two unit sets, whether a
# previous plan exists, and where the previous secret values were saved.
