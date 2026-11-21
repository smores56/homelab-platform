#!/usr/bin/env bash
# smortress-deploy: the operator's half of the deploy receiver (SDLC #798, T3).
#
#   smortress-deploy release --force
#   smortress-deploy status
#
# The image installs this as /usr/libexec/smortress-deploy, so the two commands
# are the ones the runbook names. `release --force` is the only way a held
# platform deploy proceeds: it waives the snapshot gate for the digest the
# operator saw held, records who did it and how many restore units were missing,
# and changes nothing else. It never stages an image and never reboots -- the
# next drain of that commit reaches the gate, sees the release and stages.
#
# `status` is read-only and takes no lock: every record it reads is written by
# temp file and rename, so a reader sees a whole document or the previous one,
# and an operator inspecting a wedged host must not queue behind the wedge.
#
# Exit codes: 0 done, 1 refused (not root, no hold), 2 usage, 4 the state could
# not be read or written.
#
# `unblock` and `bootstrap` are T7 (#805).
#
# shellcheck disable=SC2154  # deploy-state.sh assigns these at source time
set -euo pipefail

self_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
state_lib=${DEPLOY_STATE_LIB:-}
if [[ -z $state_lib ]]; then
  if [[ -r /usr/libexec/deploy-state ]]; then
    state_lib=/usr/libexec/deploy-state
  else
    state_lib=$self_dir/deploy-state.sh
  fi
fi
[[ -r $state_lib ]] || {
  printf 'smortress-deploy: no state library at %s\n' "$state_lib" >&2
  exit 1
}
# shellcheck source=/dev/null
source "$state_lib"

say() { printf 'smortress-deploy: %s\n' "$*"; }
warn() { printf 'smortress-deploy: %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
usage: smortress-deploy release --force
       smortress-deploy status

  release --force  waive the snapshot gate for the held platform digest (root)
  status           deployed commits, the held and pending records, the denylist
EOF
}

cmd_release() {
  local force=0 operator uid digest commit missing held_doc
  while (($#)); do
    case $1 in
      --force) force=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage; exit 2 ;;
    esac
  done
  # Not a confirmation flag: a release is a deliberate waiver of a safety gate,
  # and the door must never open by habit.
  if ((force == 0)); then
    warn "release is the break-glass path: --force is required"
    exit 2
  fi
  uid=$(id -u)
  if [[ $uid != 0 ]]; then
    warn "release must be run as root (uid $uid)"
    exit 1
  fi
  # SUDO_USER is the human; the uid is what is left when this runs from root's
  # own shell, and either is enough to say who waived the gate.
  operator=${SUDO_USER:-$uid}

  if ! deploy_lock_acquire; then
    warn "another drain holds $deploy_lock_file; nothing was released"
    exit 4
  fi
  trap deploy_lock_release EXIT

  if ! record_exists held; then
    warn "no held platform deploy to release"
    exit 1
  fi
  held_doc=$(held_read) || {
    warn "cannot read the hold record"
    exit 4
  }
  digest=$(jq -er '.digest' <<<"$held_doc" 2>/dev/null) || {
    warn "the hold record names no digest"
    exit 4
  }
  commit=$(jq -r '.commit // ""' <<<"$held_doc")
  missing=$(jq -c '.missingUnits // []' <<<"$held_doc")

  journal_append gate-released-by-operator "$(jq -nc --arg digest "$digest" --arg commit "$commit" \
    --arg operator "$operator" --argjson missing "$missing" \
    '{digest:$digest,commit:$commit,operator:$operator,missingUnits:$missing}')" || {
    warn "cannot journal the release; the hold is unchanged"
    exit 4
  }
  jq -c --arg by "$operator" --arg at "$(deploy_now)" \
    '.released = true | .releasedBy = $by | .releasedAt = $at' <<<"$held_doc" | held_write || {
    warn "cannot record the release"
    exit 4
  }
  say "released $digest for $operator; the next drain of ${commit:-the held commit} stages it"
  return 0
}

cmd_status() {
  local state held pending
  state=$(state_read 2>/dev/null) || state='{}'
  held=$(held_read 2>/dev/null) || held='null'
  pending=$(pending_read 2>/dev/null) || pending='null'
  jq -n --argjson state "$state" --argjson held "$held" --argjson pending "$pending" \
    --argjson denylist "$(denylist_read)" '
    {schema: 1,
     repos: ($state.repos // {}),
     updated: ($state.updated // null),
     held: $held,
     pending: $pending,
     denylist: {commits: ($denylist.commits // {}), digests: ($denylist.digests // {})}}'
}

cmd=${1-}
case $cmd in
  release)
    shift
    cmd_release "$@"
    ;;
  status)
    shift
    cmd_status
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac
