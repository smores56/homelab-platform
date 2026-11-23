# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # globals are assigned by the entrypoint
# deploy-apps/secrets.sh: sourced by scripts/deploy-apps.sh; no shebang.
secret_value() { # <podman name>  -> the value bytes on stdout
  # `--showsecret` is the only way to read a value back, and it prints the value
  # plus one newline: dropping exactly that byte keeps a restore byte-exact (a
  # value that really ends in a newline keeps it).
  tenant_bounded "$(cap_of "$ctl_timeout")" "$podman_bin" secret inspect --showsecret \
    --format '{{.SecretData}}' "$1" 2>/dev/null | head -c -1
}

secret_create() { # <podman name> <file holding the value>
  tenant_bounded "$(cap_of "$ctl_timeout")" "$podman_bin" secret create --replace \
    "$1" - >/dev/null <"$2"
}

# Removal is best effort: a secret that is already gone is the state the caller
# asked for, and a value a running container still mounts cannot be removed.
secret_remove() { # <podman name>
  tenant_bounded "$(cap_of "$ctl_timeout")" "$podman_bin" secret rm "$1" >/dev/null 2>&1 || true
}

# A secret name becomes a path under work/, so only what the renderer can emit is
# accepted; anything else is a plan this script refuses to act on.
secret_name_ok() {
  [[ $1 =~ ^[a-z0-9][a-z0-9._-]*$ ]]
}

# --- work tree ---------------------------------------------------------------
work_dir_for() { printf '%s/apps-%s\n' "$deploy_work_dir" "$1"; }

# A work tree is a day old before it is garbage: a host that is still catching up
# after a restore may be reverting one of them, and the cost of keeping a stale
# tree one more day is nothing next to reverting a revision the operator needed.
sweep_grace=${APPS_SWEEP_GRACE_MINUTES:-1440}

# Only a path this script minted is ever removed: apply.json is a file an operator
# can edit, and `rm -rf "$(jq -r .work apply.json)"` on a wrong path is how a
# state directory becomes a catastrophe. The shape is therefore checked on the
# canonical path, not on the string: `realpath -e` resolves `..` and symlinks
# first, so `<work>/apps-<sha>` cannot name anything but itself, and only a
# 40-hex commit's own tree -- never `apps-*` -- is one of ours.
cleanup_work() { # <dir>
  local dir=${1:-} real parent work_real base
  [[ -n $dir ]] || return 0
  # A tree that is not there is the state the caller asked for: the apply calls
  # this before it creates one, and a committed apply has already removed it.
  if [[ -L $dir && ! -e $dir ]]; then
    warn "refusing to remove $dir: it is a symlink to nothing"
    return 1
  fi
  [[ -e $dir ]] || return 0
  if ! real=$(realpath -e -- "$dir" 2>/dev/null); then
    warn "refusing to remove $dir: it does not resolve to a directory"
    return 1
  fi
  work_real=$(realpath -e -- "$deploy_work_dir" 2>/dev/null) || work_real=""
  parent=$(dirname -- "$real")
  base=$(basename -- "$real")
  if [[ -z $work_real || $parent != "$work_real" || ! $base =~ ^apps-[0-9a-f]{40}$ ]]; then
    warn "refusing to remove $dir: not a work tree of this deploy"
    return 1
  fi
  rm -rf -- "$real" || return 1
  sync -- "$deploy_work_dir" 2>/dev/null || true
  return 0
}

# --- fetch, decrypt, render --------------------------------------------------
