# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # globals are assigned by the entrypoint
# deploy-apps/commands.sh: sourced by scripts/deploy-apps.sh; no shebang.
resolve_secret_values() { # <plan> <secrets json|"">
  local secrets=$2 app key pname
  mkdir -p "$work/secrets" || return 1
  chmod 0700 "$work/secrets" || return 1
  [[ -n $secrets ]] || return 0
  while IFS=$'\t' read -r app key pname; do
    [[ -n $app && -n $key && -n $pname ]] || continue
    secret_name_ok "$pname" || {
      warn "the render names an unusable secret: $pname"
      return 1
    }
    # The tenant file's shape is `apps.<app>.<key>`, and the renderer refuses a
    # definition that names a key its own section does not declare; a missing
    # value here is a ciphertext that decrypted to nothing, which must not become
    # an empty secret.
    # `-j` writes the string's own bytes and adds nothing: a value that ends in a
    # newline keeps it, so a snapshot taken from the store restores it exactly.
    jq -j --arg a "$app" --arg k "$key" '.apps[$a][$k] // empty' "$secrets" \
      >"$(secret_file "$pname").tmp" 2>/dev/null || true
    if [[ ! -s $(secret_file "$pname").tmp ]]; then
      warn "the tenant SOPS file has no value for $app/$key"
      rm -f -- "$(secret_file "$pname").tmp"
      return 1
    fi
    chmod 0600 "$(secret_file "$pname").tmp" || return 1
    mv -f -- "$(secret_file "$pname").tmp" "$(secret_file "$pname")" || return 1
  done < <(jq -r '(.apps // {}) | to_entries[] | .key as $a
    | (.value.secretNames // {}) | to_entries[] | [$a, .key, .value] | @tsv' "$1")
  return 0
}

# The trees an interrupted apply leaves behind hold the decrypted tenant secrets,
# and the process that would have removed them is gone. Only the tree apply.json
# still names is a crash state a revert restores from; every other one older than
# the grace period is removed here, under the drain's lock.
cmd_sweep() {
  local keep='' dir removed=0
  deploy_state_init || {
    warn "cannot create $deploy_state_dir"
    return 4
  }
  if record_exists apply; then
    keep=$(record_field apply work 2>/dev/null) || keep=""
  fi
  for dir in "$deploy_work_dir"/apps-*; do
    [[ -d $dir ]] || continue
    if [[ -n $keep && $dir == "$keep" ]]; then
      continue
    fi
    # An unreadable mtime is not a reason to keep plaintext, but it is a reason
    # not to remove blind: the tree is left for the next run.
    [[ -n $(find "$dir" -maxdepth 0 -mmin "+$sweep_grace" 2>/dev/null) ]] || continue
    if cleanup_work "$dir"; then
      removed=$((removed + 1))
    else
      # A path this sweep refuses is one a human has to look at, but it is not a
      # reason to fail the sweep the drain runs before every deploy -- that would
      # leave a plaintext tree holding the whole queue hostage, not a cleanup.
      journal_append apps-work-kept "$(jq -nc --arg dir "$dir" '{dir:$dir}')" ||
        warn "cannot journal the kept work tree"
    fi
  done
  journal_append apps-work-swept "$(jq -nc --argjson removed "$removed" \
    --arg kept "$keep" '{removed:$removed,kept:$kept}')" || warn "cannot journal the sweep"
  say "swept $removed stale work tree(s)"
  return 0
}

cmd_apply() {
  local commit_arg='' secrets='' rc=0 name ref image_ref reason='' pull_rc=0 apps_state=''
  local -a validate_args=()
  while (($#)); do
    case $1 in
      --commit)
        commit_arg=${2-}
        shift 2
        ;;
      *) usage; return 2 ;;
    esac
  done
  if [[ ! $commit_arg =~ ^[0-9a-f]{40}$ ]]; then
    warn "--commit must be a 40-character lowercase hex sha"
    usage
    return 2
  fi
  commit=$commit_arg
  deploy_state_init || {
    warn "cannot create $deploy_state_dir"
    return 4
  }
  require_tenant || return 4
  deadline=$(($(date -u +%s) + apps_budget))

  # An interrupted apply is reconciled first: the "previous" revision this apply
  # snapshots would otherwise be half of two revisions.
  if record_exists apply; then
    say "an apps apply was interrupted; reverting it first"
    revert_apply || {
      warn "cannot revert the interrupted apply; not starting another"
      return 4
    }
  fi

  # The listener and the drain already refuse a commit the state records, but a
  # hand-run apply must not restart a healthy tenant for a commit it has.
  if [[ $(deployed_commit homelab-apps 2>/dev/null || true) == "$commit" ]]; then
    journal_append already-deployed "$(jq -nc --arg repo homelab-apps --arg commit "$commit" \
      '{repo:$repo,commit:$commit}')" || warn "cannot journal the already-deployed commit"
    say "$commit is already deployed"
    return 0
  fi

  work=$(work_dir_for "$commit")
  # Every normal exit below removes the tree itself, except the one that keeps
  # apply.json for a revert -- that revert restores from render.prev, so the tree
  # has to stay. This covers the exits nobody wrote a branch for: the tree holds
  # the decrypted tenant secrets, and leaving it behind is a plaintext leak that
  # grows with every failed deploy.
  # shellcheck disable=SC2329  # invoked through the trap below, not by name
  apply_exit_cleanup() {
    local status=$?
    if ((status != 0)) && [[ -n ${work:-} ]] && ! record_exists apply; then
      cleanup_work "$work" || warn "cannot remove $work"
    fi
    return 0
  }
  trap apply_exit_cleanup EXIT
  journal_append apps-start "$(jq -nc --arg commit "$commit" '{commit:$commit}')" || {
    warn "cannot journal the apply start"
    return 4
  }
  cleanup_work "$work" || return 4
  install -d -m 0700 "$work/tree" "$work/secrets" || return 4

  # 1. Fetch, then work from the extracted tree only. The tarball is only kept
  # until the tree is there.
  if ! fetch_commit "$commit" "$work/commit.tar.gz"; then
    warn "cannot fetch $apps_fetch_base/$commit"
    cleanup_work "$work" || true
    return 4
  fi
  # The tarball is untrusted bytes from a repository this host only validates
  # after extraction, and the tree is a root-only directory: without these three
  # flags tar takes ownership, permissions and the directory's own mode from it.
  # --no-overwrite-dir keeps the 0700 tree this apply created.
  if ! bounded "$tar_timeout" "$tar_bin" -xzf "$work/commit.tar.gz" -C "$work/tree" \
    --strip-components=1 --no-same-owner --no-same-permissions --no-overwrite-dir; then
    warn "cannot extract the commit tarball"
    cleanup_work "$work" || true
    return 4
  fi
  rm -f -- "$work/commit.tar.gz" || true

  # 2. Decrypt the tenant SOPS file once: the validator needs its key names and
  # the apply needs its values, and neither may read the ciphertext twice.
  rc=0
  decrypt_tenant_secrets "$work/tree" "$work/secrets.json" || rc=$?
  case $rc in
    0) secrets=$work/secrets.json ;;
    # No tenant SOPS file: a definition that references a secret is then refused
    # by the validator, which is the right outcome rather than an empty value.
    10) secrets='' ;;
    *)
      cleanup_work "$work" || true
      return 4
      ;;
  esac

  # 3. Validate, then render. A rejected definition never reaches the installed
  # plan, and the commit is denylisted so the poll stops re-enqueueing it.
  validate_args=(validate --root "$work/tree")
  if [[ -n $secrets ]]; then validate_args+=(--secrets "$secrets"); fi
  if ! bounded "$schema_timeout" "$schema_bin" "${validate_args[@]}" >"$work/validate.log" 2>&1; then
    sed -e 's/^/deploy-apps: /' "$work/validate.log" >&2 || true
    journal_append apps-rejected "$(jq -nc --arg commit "$commit" --arg reason definition-rejected \
      '{commit:$commit,reason:$reason}')" || warn "cannot journal the rejection"
    denylist_add commit "$commit" apps:definition-rejected || warn "cannot denylist $commit"
    deploy_notify fail apps-definition-rejected || warn "could not report the rejection"
    warn "$commit is rejected by the schema; the installed plan is untouched"
    cleanup_work "$work" || true
    return 3
  fi
  if ! render_commit "$work/tree" "$secrets" "$work/render.next" >"$work/render.log" 2>&1; then
    sed -e 's/^/deploy-apps: /' "$work/render.log" >&2 || true
    # Rendering failed after validation passed: that is this environment (a full
    # disk, an unwritable work tree), not the commit, so nothing is denylisted and
    # the entry is retried.
    warn "cannot render $commit"
    cleanup_work "$work" || true
    return 4
  fi

  # 4. Resolve the values the rendered units mount.
  if ! resolve_secret_values "$work/render.next/plan.json" "$secrets"; then
    cleanup_work "$work" || true
    return 4
  fi

  # 5. Free space, then the record, then the pull: a host that cannot hold the
  # images must not be half-applied.
  if ! check_space; then
    cleanup_work "$work" || true
    return 4
  fi
  state_doc=$(state_read 2>/dev/null) || state_doc='{}'
  snapshot_previous || {
    warn "cannot snapshot the installed revision"
    cleanup_work "$work" || true
    return 4
  }
  diff_revision
  if ! write_apply pulling; then
    warn "cannot write $deploy_state_dir/apply.json"
    cleanup_work "$work" || true
    return 4
  fi
  journal_append apps-apply-recorded "$(jq -nc --arg commit "$commit" --arg phase pulling \
    --argjson new "$(json_list "${new_apps[@]}")" --argjson changed "$(json_list "${changed_apps[@]}")" \
    --argjson departed "$(json_list "${departed_apps[@]}")" \
    '{commit:$commit,phase:$phase,new:$new,changed:$changed,departed:$departed}')" ||
    warn "cannot journal the apply record"

  while IFS=$'\t' read -r name ref; do
    [[ -n $name ]] || continue
    if ! image_ref=$(pull_ref "$ref"); then
      warn "$name: $ref is not a digest-pinned reference"
      reason="image-not-pinned"
      pull_rc=1
      break
    fi
    say "$name: pulling $image_ref"
    pull_rc=0
    tenant_bounded "$(cap_of "$pull_timeout")" "$podman_bin" pull \
      --signature-policy="$apps_policy" "$image_ref" >/dev/null || pull_rc=$?
    if ((pull_rc != 0)); then
      reason="pull-failed"
      journal_append apps-pull-failed "$(jq -nc --arg commit "$commit" --arg app "$name" \
        --arg image "$image_ref" --argjson exit "$pull_rc" \
        '{commit:$commit,app:$app,image:$image,exit:$exit}')" || warn "cannot journal the failed pull"
      break
    fi
    journal_append apps-pulled "$(jq -nc --arg commit "$commit" --arg app "$name" \
      --arg image "$image_ref" '{commit:$commit,app:$app,image:$image}')" ||
      warn "cannot journal the pull"
  done < <(changed_images)
  if ((pull_rc != 0)); then
    # A pull changes nothing the host runs, so the record goes with it: a failed
    # pull leaves no crash state behind. A pinned digest the registry will not
    # serve is treated as retryable -- an outage and a withdrawn image are
    # indistinguishable here -- and the deploy check names it.
    warn "${reason:-pull-failed}: the installed revision is untouched"
    deploy_notify fail "apps-${reason:-pull-failed}" || warn "could not report the failed pull"
    cleanup_work "$work" || true
    record_clear apply || warn "cannot clear the apply record"
    return 4
  fi

  # 6. Mutate. From here on every failure is reverted.
  if ! write_apply installing; then
    warn "cannot update $deploy_state_dir/apply.json"
    cleanup_work "$work" || true
    record_clear apply || true
    return 4
  fi
  journal_append apps-apply-recorded "$(jq -nc --arg commit "$commit" --arg phase installing \
    --argjson apps "$(json_list "${intended_apps[@]}")" \
    --argjson new "$(json_list "${new_apps[@]}")" --argjson changed "$(json_list "${changed_apps[@]}")" \
    --argjson departed "$(json_list "${departed_apps[@]}")" \
    '{commit:$commit,phase:$phase,apps:$apps,new:$new,changed:$changed,departed:$departed}')" ||
    warn "cannot journal the apply record"

  if ! apply_mutations; then
    warn "the apply failed after it started changing the host; reverting"
    journal_append apps-failed "$(jq -nc --arg commit "$commit" --arg phase restoring \
      --arg reason "${failure_reason:-mutation-failed}" \
      '{commit:$commit,phase:$phase,reason:$reason}')" || warn "cannot journal the failure"
    revert_apply || warn "the revert did not finish; the record is kept for the next gate"
    deploy_notify fail apps-apply-reverted || warn "could not report the failed apply"
    say "$commit was rolled back to the previous revision"
    return 5
  fi

  # 7. Commit: the content hashes first, then the commit itself, then the tree a
  # revert would have used. Only after that does Serve regenerate.
  if ! apps_state=$(build_apps_state) || ! state_apps_write "$apps_state" ||
    ! state_record_verified homelab-apps "$commit"; then
    warn "cannot record the applied revision"
    revert_apply || warn "the revert did not finish; the record is kept for the next gate"
    deploy_notify fail apps-state-failed || warn "could not report the failed record"
    return 5
  fi
  # The record goes before the saved tree: a crash in between leaves garbage the
  # next apply of this commit removes, while the reverse leaves a boot reverting
  # a revision that already committed. A record that will not clear is a rollback
  # instead -- the state restore is what makes that safe after the commit write.
  if ! record_clear apply; then
    warn "cannot clear the apply record; rolling back so no boot reverts a committed revision"
    revert_apply || warn "the revert did not finish; the record is kept for the next gate"
    deploy_notify fail apps-state-failed || warn "could not report the failed record"
    return 5
  fi
  cleanup_work "$work" || warn "cannot remove $work"
  journal_append apps-applied "$(jq -nc --arg commit "$commit" \
    --argjson apps "$(json_list "${intended_apps[@]}")" \
    --argjson new "$(json_list "${new_apps[@]}")" --argjson changed "$(json_list "${changed_apps[@]}")" \
    --argjson departed "$(json_list "${departed_apps[@]}")" \
    '{commit:$commit,apps:$apps,new:$new,changed:$changed,departed:$departed}')" ||
    warn "cannot journal the applied commit"

  # Serve is a RemainAfterExit oneshot: without this restart a new app has no
  # route and a removed one keeps one. A failure here is a route to fix, not a
  # reason to roll a running revision back -- Serve also fails on unrelated
  # dataset absenteeism -- so the apply stands and the deploy check is paged.
  if ! restart_serve commit; then
    deploy_notify fail apps-serve-failed || warn "could not report the failed Serve restart"
  elif ! deploy_notify success; then
    warn "could not report the deployment to the deploy check"
  fi
  say "$commit is running"
  return 0
}
