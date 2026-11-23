# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # globals are assigned by the entrypoint
# deploy-apps/apply.sh: sourced by scripts/deploy-apps.sh; no shebang.
write_apply() { # <phase>
  jq -nc --arg phase "$1" --arg commit "$commit" --arg previous "${previous_commit:-}" \
    --arg work "$work" --argjson previousUnits "$(json_list "${previous_units[@]}")" \
    --argjson intendedUnits "$(json_list "${intended_units[@]}")" \
    --argjson previousPlan "$previous_plan" --argjson previousState "$previous_state" \
    --argjson previousSecrets "$previous_secrets_json" \
    --argjson intendedSecrets "$(json_list "${intended_secrets[@]}")" \
    --arg at "$(deploy_now)" \
    '{schema:1,phase:$phase,commit:$commit,previousCommit:$previous,work:$work,
      previousUnits:$previousUnits,intendedUnits:$intendedUnits,previousPlan:$previousPlan,
      previousState:$previousState,previousSecrets:$previousSecrets,
      intendedSecrets:$intendedSecrets,startedAt:$at}' |
    apply_write
}

install_units() {
  local unit
  tenant mkdir -p -- "$apps_unit_dir" || return 1
  for unit in "${intended_units[@]}"; do
    require_unit_name "$unit" install-unit || return 1
    tenant_install "$work/render.next/$unit" "$apps_unit_dir/$unit" || return 1
  done
  return 0
}

remove_departed_units() {
  local name
  for name in "${departed_apps[@]}"; do
    # The name is a file this apply found in the tenant's own home, and it becomes
    # a path under it: anything but `<app>.container` is refused, journaled, and
    # stops the apply before the file is touched.
    require_app_name "$name" remove-departed-unit || return 1
    tenant_remove "$apps_unit_dir/$(app_unit "$name")" || return 1
  done
  # The internal network unit goes when nothing needs it any more: render emits it
  # only while an app with egress = "none" exists.
  if [[ -f $apps_unit_dir/smortress-apps.network &&
    ! -f $work/render.next/smortress-apps.network ]]; then
    tenant_remove "$apps_unit_dir/smortress-apps.network" || return 1
  fi
  return 0
}

create_changed_secrets() {
  local pname
  for pname in "${intended_secrets[@]}"; do
    if [[ ! -f $(secret_file "$pname") ]]; then
      warn "the render names the secret $pname but no value was resolved"
      return 1
    fi
    # `create --replace` and not `rm` then `create`: a secret a running container
    # still mounts cannot be removed.
    secret_create "$pname" "$(secret_file "$pname")" || return 1
  done
  return 0
}

remove_departed_secrets() {
  local name pname
  for name in "${departed_apps[@]}"; do
    while IFS= read -r pname; do
      [[ -n $pname ]] || continue
      in_list "$pname" "${intended_secrets[@]}" && continue
      secret_remove "$pname"
    done < <(jq -r --arg n "$name" '(.apps[$n].secretNames // {}) | .[]' \
      "$work/render.prev/plan.json" 2>/dev/null || true)
  done
  return 0
}

start_new_apps() {
  local name
  for name in "${new_apps[@]}"; do
    require_app_name "$name" start-app || return 1
    user_ctl start "$(app_service "$name")" || return 1
  done
  return 0
}

restart_changed_apps() {
  local name
  for name in "${changed_apps[@]}"; do
    require_app_name "$name" restart-app || return 1
    user_ctl restart "$(app_service "$name")" || return 1
  done
  return 0
}

stop_departed_apps() {
  local name
  for name in "${departed_apps[@]}"; do
    require_app_name "$name" stop-app || return 1
    user_stop "$(app_service "$name")" || return 1
  done
  return 0
}

# The ingress helper reads the installed plan for the loopback port it binds and
# the container port it forwards to, so it follows its app by name.
apply_ingress() {
  local name
  # Every name here becomes a root `systemctl` instance. The guard is what keeps
  # a forged one -- a departed unit file the tenant planted, a name from an edited
  # plan -- from ever reaching that command line.
  for name in "${new_apps[@]}"; do
    require_app_name "$name" ingress-start || return 1
    system_ctl start "$ingress_template$name" || return 1
  done
  for name in "${changed_apps[@]}"; do
    require_app_name "$name" ingress-restart || return 1
    system_ctl restart "$ingress_template$name" || return 1
  done
  for name in "${departed_apps[@]}"; do
    require_app_name "$name" ingress-stop || return 1
    system_stop "$ingress_template$name" || return 1
  done
  return 0
}

# New and restarted apps only: an unchanged app was committed by an earlier
# apply, and an apply that does not write it cannot repair it. Checking it here
# would let one broken app refuse every later commit, including its own fix.
check_started_apps() {
  local name
  for name in "${new_apps[@]}" "${changed_apps[@]}"; do
    require_app_name "$name" health-check || return 1
    if ! app_health "$name"; then
      failure_reason='app-unhealthy'
      warn "$name: $health_unit is $health_state"
      journal_append apps-unhealthy "$(jq -nc --arg commit "$commit" --arg app "$name" \
        --arg unit "$health_unit" --arg state "$health_state" \
        '{commit:$commit,app:$app,unit:$unit,state:$state}')" ||
        warn "cannot journal the unhealthy app"
      return 1
    fi
  done
  return 0
}

apply_mutations() {
  # The plan first: the quota applier and Serve both re-read it, and neither may
  # act on the previous revision once a container of the new one exists.
  install_plan "$work/render.next/plan.json" || return 1
  journal_append apps-plan-installed "$(jq -nc --arg commit "$commit" \
    --argjson apps "$(json_list "${intended_apps[@]}")" '{commit:$commit,apps:$apps}')" ||
    warn "cannot journal the installed plan"
  # A RemainAfterExit unit: `start` is a no-op and only a restart makes it read
  # the new plan. It creates the new apps' directories and project quotas before
  # anything starts, so a new app is never unquoted.
  system_ctl restart "$quota_unit" || return 1
  journal_append apps-quota-applied "$(jq -nc --arg commit "$commit" '{commit:$commit}')" ||
    warn "cannot journal the quota restart"

  install_units || return 1
  remove_departed_units || return 1
  create_changed_secrets || return 1
  user_ctl daemon-reload || return 1
  start_new_apps || return 1
  restart_changed_apps || return 1
  # A departed app is stopped before its secrets are removed: a value a running
  # container still mounts cannot be removed.
  stop_departed_apps || return 1
  remove_departed_secrets || return 1
  apply_ingress || return 1
  # The apps this apply started are what the next boot's gate judges, and a gate
  # that finds one down rolls back a healthy platform image. So a revision whose
  # apps do not stay up is reverted here, before it is committed.
  check_started_apps || return 1
  return 0
}

restart_serve() { # <reason>
  local rc=0
  bounded "$serve_timeout" "$systemctl_bin" restart "$serve_unit" || rc=$?
  if ((rc != 0)); then
    journal_append apps-serve-failed "$(jq -nc --arg commit "$commit" --argjson exit "$rc" \
      --arg reason "$1" '{commit:$commit,exit:$exit,reason:$reason}')" ||
      warn "cannot journal the failed Serve restart"
    warn "Serve did not regenerate (exit $rc); the routes stay as they were"
  fi
  return "$rc"
}

# --- revert ------------------------------------------------------------------
# Restores the revision apply.json recorded and clears the record. Idempotent:
# the units and the plan are written from the saved tree, so a second run after a
# crash in the middle of a revert finishes the same work.
revert_apply() {
  local doc phase dir render_prev rc=0 pname path name current saved_schema
  local -a previous=() intended=() saved=()
  doc=$(apply_read) || {
    warn "cannot read $deploy_state_dir/apply.json"
    return 1
  }
  phase=$(jq -r '.phase // "installing"' <<<"$doc") || phase=installing
  dir=$(jq -r '.work // ""' <<<"$doc") || dir=""
  render_prev=$dir/render.prev
  mapfile -t previous < <(jq -r '.previousUnits[]?' <<<"$doc" 2>/dev/null || true)
  mapfile -t intended < <(jq -r '.intendedUnits[]?' <<<"$doc" 2>/dev/null || true)
  current=$(jq -r '.commit // ""' <<<"$doc") || current=""

  if [[ $phase == pulling ]]; then
    # Nothing outside the image store was touched yet, and the store is not a
    # revision: there is nothing to put back.
    journal_append apps-reverted "$(jq -nc --arg commit "$current" --arg phase "$phase" \
      '{commit:$commit,phase:$phase,mutated:false}')" || warn "cannot journal the revert"
    cleanup_work "$dir" || warn "cannot remove $dir"
    record_clear apply || warn "cannot clear the apply record"
    say "cleared an interrupted pull; the installed revision was untouched"
    return 0
  fi

  if [[ -z $dir || ! -d $render_prev ]]; then
    # Without the saved tree there is nothing to restore, and deleting the record
    # would make the next boot believe the host is consistent.
    journal_append apps-revert-failed "$(jq -nc --arg work "$dir" --arg commit "$current" \
      '{reason:"no-saved-tree",work:$work,commit:$commit}')" ||
      warn "cannot journal the failed revert"
    warn "cannot revert: $render_prev is missing"
    return 1
  fi

  # 1. The previous units back, and away with the ones the failed apply added.
  # apply.json names these files and an operator can edit it, so each one is
  # checked against the shape this deploy writes before it becomes a path.
  for name in "${previous[@]}"; do
    [[ -f $render_prev/$name ]] || continue
    require_unit_name "$name" revert-restore-unit || {
      rc=1
      continue
    }
    tenant_install "$render_prev/$name" "$apps_unit_dir/$name" || rc=1
  done
  for name in "${intended[@]}"; do
    in_list "$name" "${previous[@]}" && continue
    require_unit_name "$name" revert-remove-unit || {
      rc=1
      continue
    }
    tenant_remove "$apps_unit_dir/$name" || rc=1
  done

  # 2. The previous plan, then the quota applier for it, before any container of
  # the restored revision is started.
  if [[ $(jq -r '.previousPlan // false' <<<"$doc") == true && -f $render_prev/plan.json ]]; then
    install_plan "$render_prev/plan.json" || rc=1
  else
    rm -f -- "$apps_plan" || rc=1
  fi
  system_ctl restart "$quota_unit" || rc=1

  # 2b. The state document, so a revert leaves nothing claiming the new commit
  # or the new content hashes. A saved document of another schema is not this
  # library's truth: restoring it would move the host's record past whatever
  # migrated it, so a mismatch is refused, journaled and paged -- the record stays
  # and a human decides, rather than a revert silently rewriting the state.
  if [[ $(jq -r '.previousState // false' <<<"$doc") == true && -f $render_prev/state.json ]]; then
    saved_schema=$(jq -r '.schema // "missing"' "$render_prev/state.json" 2>/dev/null) ||
      saved_schema=unreadable
    if [[ $saved_schema == "$deploy_state_schema" ]]; then
      atomic_write "$deploy_state_file" <"$render_prev/state.json" || rc=1
    else
      journal_append apps-revert-failed "$(jq -nc --arg commit "$current" --arg saved "$saved_schema" \
        --argjson want "$deploy_state_schema" \
        '{reason:"state-schema-mismatch",commit:$commit,savedSchema:$saved,wantSchema:$want}')" ||
        warn "cannot journal the refused state restore"
      deploy_notify fail apps-revert-state-schema || warn "could not report the refused state restore"
      warn "not restoring $render_prev/state.json: schema '$saved_schema', this library writes $deploy_state_schema"
      rc=1
    fi
  else
    rm -f -- "$deploy_state_file" || rc=1
  fi

  # 3. The previous secret values. A saved value that is a null path names a
  # secret the previous plan wanted and the store did not hold, so it is left out.
  while IFS=$'\t' read -r pname path; do
    [[ -n $pname ]] || continue
    if [[ -n $path && -f $dir/$path ]]; then
      secret_create "$pname" "$dir/$path" || rc=1
    else
      secret_remove "$pname"
    fi
  done < <(jq -r '(.previousSecrets // {}) | to_entries[] | [.key, (.value // "")] | @tsv' <<<"$doc")

  # 4. The apps themselves.
  user_ctl daemon-reload || rc=1
  for name in "${intended[@]}"; do
    in_list "$name" "${previous[@]}" && continue
    [[ $name == *.container ]] || continue
    name=${name%.container}
    require_app_name "$name" revert-stop-app || {
      rc=1
      continue
    }
    user_stop "$(app_service "$name")" || rc=1
    system_stop "$ingress_template$name" || rc=1
  done
  # Only after their containers are gone: a secret a running container mounts
  # cannot be removed.
  mapfile -t saved < <(jq -r '(.previousSecrets // {}) | keys[]' <<<"$doc")
  while IFS= read -r pname; do
    [[ -n $pname ]] || continue
    in_list "$pname" "${saved[@]}" && continue
    secret_remove "$pname"
  done < <(jq -r '.intendedSecrets[]?' <<<"$doc" 2>/dev/null || true)
  for name in "${previous[@]}"; do
    [[ $name == *.container ]] || continue
    name=${name%.container}
    require_app_name "$name" revert-start-app || {
      rc=1
      continue
    }
    if in_list "${name}.container" "${intended[@]}"; then
      user_ctl restart "$(app_service "$name")" || rc=1
      system_ctl restart "$ingress_template$name" || rc=1
    else
      user_ctl start "$(app_service "$name")" || rc=1
      system_ctl start "$ingress_template$name" || rc=1
    fi
  done

  # 5. Serve, so the routes match the plan that is installed again.
  bounded "$serve_timeout" "$systemctl_bin" restart "$serve_unit" || rc=1

  if ((rc != 0)); then
    journal_append apps-revert-failed "$(jq -nc --arg commit "$current" --arg phase "$phase" \
      '{commit:$commit,phase:$phase,reason:"restore-incomplete"}')" ||
      warn "cannot journal the failed revert"
    warn "the previous revision was not fully restored; the record is kept"
    return 1
  fi
  journal_append apps-reverted "$(jq -nc --arg commit "$current" --arg phase "$phase" \
    --argjson units "$(json_list "${previous[@]}")" \
    '{commit:$commit,phase:$phase,mutated:true,units:$units}')" || warn "cannot journal the revert"
  # The record goes last: a crash before this leaves it, and the next gate or
  # drain repeats an idempotent revert instead of forgetting it.
  cleanup_work "$dir" || warn "cannot remove $dir"
  record_clear apply || {
    warn "cannot clear the apply record"
    return 1
  }
  say "restored the previous revision"
  return 0
}

# --- commands ----------------------------------------------------------------
# Resolve the tenant SOPS values into root-only files under work/secrets: the
# rendered units mount them by name, and a hash, a `create --replace` and a
# restore then read the same bytes.
