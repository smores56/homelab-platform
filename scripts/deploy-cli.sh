#!/usr/bin/env bash
# smortress-deploy: the operator's half of the deploy receiver (SDLC #798).
#
#   smortress-deploy status
#   smortress-deploy release --force
#   smortress-deploy block <commit|digest> <value>
#   smortress-deploy unblock <commit|digest> <value>
#   smortress-deploy bootstrap <repo> <commit>
#
# The image installs this as /usr/libexec/smortress-deploy, so the commands are
# the ones the runbook names. `release --force` is the only way a held platform
# deploy proceeds: it waives the snapshot gate for the digest the operator saw
# held, records who did it and how many restore units were missing, and changes
# nothing else. It never stages an image and never reboots -- the next drain of
# that commit reaches the gate, sees the release and stages.
#
# `status` is read-only and takes no lock: every record it reads is written by
# temp file and rename, so a reader sees a whole document or the previous one,
# and an operator inspecting a wedged host must not queue behind the wedge.
#
# `unblock` is the way off the denylist: a denied tip is refused at the listener
# and stops the hourly poll, so nothing deploys that commit again until the
# operator removes exactly the entry a gate or a rollback added.
#
# `block` is the way on: the drain retries a failed apps apply every 300 s, and a
# revision whose app starts and then exits fails on every attempt. Denying the
# commit turns the next attempt into the verifier's refusal, which pops the entry
# and keeps the poll from offering the tip again. It is one value in one table,
# journaled with who did it, and `unblock` is how it comes back.
#
# `bootstrap` records the commit a restored or rebuilt host is running, once:
# a deployment is only ever verified against a recorded ancestor, and nothing on
# the host may guess one. It refuses to overwrite a record, so a mistaken
# bootstrap cannot silently move the ancestor forward.
#
# Exit codes: 0 done, 1 refused (not root, nothing to release or clear, a record
# already present), 2 usage, 4 the state could not be read or written.
#
# shellcheck disable=SC2154  # deploy-state.sh assigns these at source time
set -euo pipefail

self_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
state_lib=${DEPLOY_STATE_LIB:-}
if [[ -z $state_lib ]]; then
  # Sibling first: in the image both files land in /usr/libexec, and in a
  # checkout both are in scripts/. Preferring the fixed path made a checkout run
  # the installed copy from the running image -- the suites silently tested the
  # old library on the host that had one.
  if [[ -r $self_dir/deploy-state.sh ]]; then
    state_lib=$self_dir/deploy-state.sh
  elif [[ -r $self_dir/deploy-state ]]; then
    state_lib=$self_dir/deploy-state
  else
    state_lib=/usr/libexec/deploy-state
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
usage: smortress-deploy status
       smortress-deploy release --force
       smortress-deploy block <commit|digest> <value>
       smortress-deploy unblock <commit|digest> <value>
       smortress-deploy bootstrap <repo> <commit>

  status           deployed commits, the held and pending records, the denylist
  release --force  waive the snapshot gate for the held platform digest (root)
  block            add one denylist entry, refusing that commit or digest (root)
  unblock          drop one denylist entry (root)
  bootstrap        record the running commit of a restored host, once (root)
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
     apps: ($state.apps // {}),
     updated: ($state.updated // null),
     held: $held,
     pending: $pending,
     denylist: {commits: ($denylist.commits // {}), digests: ($denylist.digests // {})}}'
}

# The value's shape is the table's: a commit is a 40-hex sha and a digest is a
# sha256 reference, so a mistyped table or a truncated value is a usage error
# rather than a silent no-op on a list that keeps the host unable to deploy.
valid_denylist_value() { # <commit|digest> <value>
  case $1 in
    commit) [[ $2 =~ ^[0-9a-f]{40}$ ]] ;;
    digest) [[ $2 =~ ^sha256:[0-9a-f]{64}$ ]] ;;
    *) return 1 ;;
  esac
}

cmd_block() {
  local kind=${1-} value=${2-} operator uid
  (($# == 2)) || {
    usage
    exit 2
  }
  if ! valid_denylist_value "$kind" "$value"; then
    warn "block takes {commit <40-hex sha>|digest sha256:<64-hex>}, not $kind $value"
    exit 2
  fi
  uid=$(id -u)
  if [[ $uid != 0 ]]; then
    warn "block must be run as root (uid $uid)"
    exit 1
  fi
  operator=${SUDO_USER:-$uid}

  if ! deploy_lock_acquire; then
    warn "another drain holds $deploy_lock_file; nothing was denied"
    exit 1
  fi
  trap deploy_lock_release EXIT

  if denylist_has "$kind" "$value"; then
    # Not an error in the state: saying so is what stops the operator believing
    # the entry was just placed by this run.
    warn "$value is already on the denylist"
    exit 1
  fi
  journal_append denylist-added "$(jq -nc --arg kind "$kind" --arg value "$value" \
    --arg by "$operator" '{kind:$kind,value:$value,operator:$by}')" || {
    warn "cannot journal the denial; nothing was written"
    exit 4
  }
  # The reason is the table's own wording: a reader of denylist.json must be able
  # to tell a gate's refusal from an operator's, and the journal has who.
  denylist_add "$kind" "$value" operator || {
    warn "cannot rewrite $deploy_denylist_file"
    exit 4
  }
  say "denylisted the $kind $value for $operator"
  return 0
}

cmd_unblock() {
  local kind=${1-} value=${2-} operator uid
  (($# == 2)) || {
    usage
    exit 2
  }
  if ! valid_denylist_value "$kind" "$value"; then
    warn "unblock takes {commit <40-hex sha>|digest sha256:<64-hex>}, not $kind $value"
    exit 2
  fi
  uid=$(id -u)
  if [[ $uid != 0 ]]; then
    warn "unblock must be run as root (uid $uid)"
    exit 1
  fi
  operator=${SUDO_USER:-$uid}

  if ! deploy_lock_acquire; then
    warn "another drain holds $deploy_lock_file; nothing was cleared"
    exit 1
  fi
  trap deploy_lock_release EXIT

  if ! denylist_has "$kind" "$value"; then
    # Not an error in the state: the operator asked for the wrong entry, and
    # saying so is what stops them believing the host will deploy again.
    warn "$value is not on the denylist; nothing was cleared"
    exit 1
  fi
  journal_append denylist-cleared "$(jq -nc --arg kind "$kind" --arg value "$value" \
    --arg by "$operator" '{kind:$kind,value:$value,operator:$by}')" || {
    warn "cannot journal the clear; the entry is unchanged"
    exit 4
  }
  denylist_remove "$kind" "$value" || {
    warn "cannot rewrite $deploy_denylist_file"
    exit 4
  }
  say "cleared the denylisted $kind $value for $operator"
  return 0
}

cmd_bootstrap() {
  local repo=${1-} commit=${2-} operator uid existing
  (($# == 2)) || {
    usage
    exit 2
  }
  case $repo in
    homelab-platform | homelab-apps) ;;
    *)
      warn "bootstrap takes homelab-platform or homelab-apps, not $repo"
      exit 2
      ;;
  esac
  if [[ ! $commit =~ ^[0-9a-f]{40}$ ]]; then
    warn "bootstrap takes the 40-character commit the host is running, not $commit"
    exit 2
  fi
  uid=$(id -u)
  if [[ $uid != 0 ]]; then
    warn "bootstrap must be run as root (uid $uid)"
    exit 1
  fi
  operator=${SUDO_USER:-$uid}

  if ! deploy_lock_acquire; then
    warn "another drain holds $deploy_lock_file; nothing was recorded"
    exit 1
  fi
  trap deploy_lock_release EXIT

  existing=$(deployed_commit "$repo" 2>/dev/null) || existing=""
  if [[ -n $existing ]]; then
    # The recorded ancestor is what every later deploy is checked against, so a
    # second bootstrap is a request to move it by hand -- exactly the history
    # rewrite the descendancy check exists to prevent.
    warn "$repo already records $existing; bootstrap never overwrites a record"
    exit 1
  fi
  journal_append bootstrap-recorded "$(jq -nc --arg repo "$repo" --arg commit "$commit" \
    --arg by "$operator" '{repo:$repo,commit:$commit,operator:$by}')" || {
    warn "cannot journal the bootstrap; the state is unchanged"
    exit 4
  }
  # Commit only: the digest forms belong to the image the registry serves today,
  # which is the verifier's answer to give on the next real deploy.
  state_record_verified "$repo" "$commit" || {
    warn "cannot record $repo at $commit"
    exit 4
  }
  say "recorded $repo at $commit for $operator; the next deploy must be a descendant of it"
  return 0
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
  block)
    shift
    cmd_block "$@"
    ;;
  unblock)
    shift
    cmd_unblock "$@"
    ;;
  bootstrap)
    shift
    cmd_bootstrap "$@"
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
