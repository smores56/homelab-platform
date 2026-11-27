#!/usr/bin/env bats
# bats file_tags=core
# The trust policy, the tmpfiles state directories and a SIGTERM stop: the
# conventions a container falls over without.
#
# One file of the suite that was tests/core/app-quadlets.bats, split so bats can
# run the sections as parallel files (a file is one job). The tables, the
# file-scope sources and every checker more than one section calls are in
# tests/core/app-quadlets_lib.bash; the checkers only this file uses stay here.
#
#   bats tests/core/app-quadlets-host.bats
load ../helpers
load ./app-quadlets_lib

setup_file() { aq_setup_file; }
setup() { aq_setup; }

# 8. The trust boundary itself: no upstream application registry may creep into
#    the policy just to make a pull succeed.
policy_does_not_trust_upstream() { # registry
  ! grep -q "\"$1\"" bootc/server/rootfs/etc/containers/policy.json
}

_registries=' '
for _row in "${app_images[@]}"; do
  IFS='|' read -r _name _upstream _digest <<<"$_row"
  if [[ -z $_name ]]; then
    continue
  fi
  _registry=${_upstream%%/*}
  case $_registries in
    *" $_registry "*) continue ;;
  esac
  _registries="$_registries$_registry "
  registered "policy does not trust upstream $_registry" policy_does_not_trust_upstream "$_registry"
done
unset _row _name _upstream _digest _registry _registries

# 9. The state directories the containers mount outside a recovery group are
#    created by tmpfiles, and every container runs as uid 1000. An entry naming
#    a login the image never creates is dropped ("Failed to resolve user
#    'smores': Unknown user") and podman then fails the unit with
#    "statfs <path>: no such file or directory", which is how the second T5 boot
#    lost immich-machine-learning and syncthing.

tmpfiles_creates_for_uid_1000() { # dir
  local line mode owner group
  line=$(grep -E "^d[[:space:]]+$1[[:space:]]" "$tmpfiles" || true)
  read -r _kind _path mode owner group _rest <<<"$line"
  assert_equal "$mode/$owner/$group" "0750/1000/1000"
}

for _dir in /var/lib/immich/ml-cache /var/lib/immich/valkey /var/lib/syncthing/versions; do
  registered "tmpfiles creates $_dir for uid 1000" tmpfiles_creates_for_uid_1000 "$_dir"
done
unset _dir

known_tmpfiles_owners() {
  printf '%s\n' root 0 1000
  local conf
  for conf in bootc/server/rootfs/etc/sysusers.d/*.conf; do
    if [[ ! -f $conf ]]; then
      continue
    fi
    sed -nE 's/^[ug] ([^ ]+).*/\1/p' "$conf"
  done
}

tmpfiles_entry_names_a_real_owner() { # path
  local line owner
  line=$(grep -E "^d[[:space:]]+$1[[:space:]]" "$tmpfiles" || true)
  read -r _kind _path _mode owner _group _rest <<<"$line"
  if [[ " $(known_tmpfiles_owners | paste -sd' ') " != *" $owner "* ]]; then
    printf '%s names uid %q, which no sysusers entry creates\n' "$1" "$owner" >&2
    return 1
  fi
}

while read -r _kind _path _mode _owner _group _rest; do
  if [[ $_kind != d ]]; then
    continue
  fi
  registered "tmpfiles entry $_path names a real owner" tmpfiles_entry_names_a_real_owner "$_path"
done < <(grep -vE '^#|^$' "$tmpfiles")
unset _kind _path _mode _owner _group _rest

# 10. A stopped container leaves a SIGTERM exit behind, and the applications exit
#     143 for it (immich-server did: "Main process exited, code=exited,
#     status=143"). Without declaring that as success, `systemctl stop` marks the
#     unit failed and it sits in `systemctl --failed` next to real failures.
treats_sigterm_stop_as_success() { # quadlet
  grep -q '^SuccessExitStatus=143$' "$1"
}

for _q in "${app_quadlets[@]}"; do
  registered "$_q treats a SIGTERM stop as success" treats_sigterm_stop_as_success "$_q"
done
unset _q
