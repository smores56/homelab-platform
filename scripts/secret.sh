#!/usr/bin/env bash
# One operator path for editing, staging, rotating, and verifying a secret.
#
#   scripts/secret.sh list
#   scripts/secret.sh edit <output>
#   scripts/secret.sh stage <output-or-bundle> [--no-restart]
#   scripts/secret.sh rotate <output>
#   scripts/secret.sh rekey [--rotate]
#   scripts/secret.sh verify
#
# `edit` and `rekey` need the operator identity; `stage`, `rotate`, and `rekey`
# write the host; `verify` is keyless and runs anywhere.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$here/lib/log.sh"

root=$(cd -- "$here/.." && pwd)
index=${SMORTRESS_SECRETS_INDEX:-$root/secrets/index.json}
index_bin=$here/secrets-index.py
sops_bin=${SOPS_BIN:-sops}
stage_dst=${SMORTRESS_SECRETS_SRC:-/var/lib/smortress/secrets}
systemctl_bin=${SMORTRESS_SYSTEMCTL:-systemctl}
root_cmd=${SMORTRESS_ROOT_CMD-sudo}
stage_owner=${SMORTRESS_STAGE_OWNER:-root}
stage_group=${SMORTRESS_STAGE_GROUP:-root}

usage() {
  sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit "${1:-2}"
}

as_root() {
  if [[ $(id -u) -eq 0 || -z $root_cmd ]]; then
    "$@"
  else
    # shellcheck disable=SC2086  # the override is a command, spaces intentional
    $root_cmd "$@"
  fi
}

bundle_of() {
  "$index_bin" bundle "$1" --index "$index"
}

path_of() {
  local bundle dir
  bundle=$(bundle_of "$1")
  for dir in "$root/secrets/server" "$root/secrets"; do
    if [[ -f $dir/$bundle ]]; then
      printf '%s\n' "$dir/$bundle"
      return 0
    fi
  done
  die "ciphertext for $bundle is missing"
}

consumers() {
  "$index_bin" list --index "$index" | awk -F '\t' -v b="$1" '$2 == b && $3 != "" { print "  " $1 ": " $3 }'
}

[[ $# -ge 1 ]] || usage 2
command=$1
shift

case $command in
  list)
    "$index_bin" list --index "$index"
    ;;
  edit)
    [[ $# -eq 1 ]] || usage 2
    [[ $(id -u) -ne 0 ]] || die "edit as the operator, not as root (root holds the machine key)"
    "$sops_bin" "$(path_of "$1")"
    ;;
  stage)
    [[ $# -ge 1 ]] || usage 2
    name=$1
    shift
    restart=true
    while (($#)); do
      case $1 in
        --no-restart) restart=false ;;
        *) usage 2 ;;
      esac
      shift
    done
    bundle=$(bundle_of "$name")
    src=$(path_of "$bundle")
    as_root install -d -m 0700 "$stage_dst"
    as_root install -m 0600 -o "$stage_owner" -g "$stage_group" "$src" "$stage_dst/$bundle"
    say "staged $bundle into $stage_dst"
    if $restart; then
      as_root "$systemctl_bin" restart sops-decrypt.service
      say "restarted sops-decrypt.service"
    fi
    say "restart the consumers that read this bundle:"
    consumers "$bundle"
    ;;
  rotate)
    [[ $# -eq 1 ]] || usage 2
    src=$(path_of "$1")
    "$sops_bin" --config "$root/.sops.yaml" rotate --in-place "$src"
    say "generated a new data key for $src"
    "$here/secret.sh" stage "$1"
    ;;
  rekey)
    python3 "$here/sops-policy.py" rekey --repo "$root" "$@"
    ;;
  verify)
    python3 "$here/sops-policy.py" check --repo "$root"
    python3 "$here/secrets-check.py"
    python3 "$here/secrets-check.py" --shadow
    ;;
  *) usage 2 ;;
esac
