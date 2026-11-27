#!/usr/bin/env bash
# Journal every pending Mirage ask once (SDLC #979, T7).
#
# The daemon holds a decision until a human answers it, and nothing pushes: the
# ask is visible only to someone who asks for the list. This run, on a timer,
# turns each new pending ask into one journal line, so a delete that is waiting
# for sign-off shows up in the same place as every other unit's failures instead
# of sitting silently inside a container.
#
# One line per ask, not per pass: the ids already journaled are kept in the
# dataset, so a pending ask pages once and stays quiet until it is answered or
# denied. An ask that disappears from the list (answered) is forgotten, which is
# what keeps the file from growing without bound.
#
# This is a notice, not an approver. It prints the ask id and the command; the
# answer is `scripts/mirage-ask.sh allow|deny`, run by the operator.
set -euo pipefail

podman_bin=${PODMAN:-podman}
container=${SMORTRESS_MIRAGE_CONTAINER:-smortress-mirage-personal}
workspace=${SMORTRESS_MIRAGE_WORKSPACE:-personal}
state_dir=${SMORTRESS_MIRAGE_STATE:-/var/lib/agent/local/mirage}
seen=$state_dir/asks.seen
tag=${SMORTRESS_MIRAGE_TAG:-smortress-mirage}

if ! "$podman_bin" container exists "$container" >/dev/null 2>&1; then
  # No container, no asks. This is the state before the first boot and after a
  # deliberate stop, and neither is a failure to notify about.
  exit 0
fi

if ! asks=$("$podman_bin" exec "$container" mirage workspace list-asks -w "$workspace" 2>/dev/null); then
  echo "mirage-ask-notify: could not read the ask list from $container" >&2
  exit 1
fi

install -d -m 0750 "$state_dir"
touch "$seen"
chmod 0600 "$seen"

# pending IDS, one per line: the daemon's JSON is an array of records and every
# record here is unanswered by construction.
pending=$(printf '%s' "$asks" | jq -r '.[] | select(.outcome == null) | .id' 2>/dev/null || true)

new=''
while IFS= read -r id; do
  [[ -n $id ]] || continue
  if ! grep -qxF -- "$id" "$seen"; then
    new="$new $id"
  fi
done <<<"$pending"

for id in $new; do
  printf '%s' "$asks" | jq -r --arg id "$id" '
    .[] | select(.id == $id) |
    "ask \(.id): \(.command) \(.argv | join(" ")) in \(.cwd) -- \(.reason)"' |
    while IFS= read -r line; do
      logger -t "$tag" -p user.warning -- "$line"
    done
done

# The file tracks what is still pending, so an answered ask is dropped here and
# cannot suppress a later one with the same id.
{
  printf '%s\n' "$pending" | sed '/^$/d'
} >"$seen.new"
mv -f "$seen.new" "$seen"
