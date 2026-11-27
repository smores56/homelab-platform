#!/usr/bin/env bash
# What "this host works" means, for greenboot.
#
# greenboot rolls a deployment back when a required check exits non-zero, which
# is the automatic rollback for a host that boots into a sick image. The boot
# counter covers the deployment that never reaches userspace; neither covers the
# other's failure, and together they replace the post-boot gate this repository
# used to hand-roll.
#
# "Serving" is the list that gate read: /usr/share/smortress/deploy-units.txt
# names the units a healthy host keeps active. Reusing it is deliberate -- it is
# the one definition of this host's job, and a second list would drift from it.
#
# The check waits rather than failing on first look: a boot is not a steady
# state, and units that depend on the ZFS pool come up over a minute. The 300 s
# budget is the one the post-boot gate used for the same wait, and the
# greenboot-healthcheck drop-in raises the unit's timeout to cover it -- a
# probe that gave up early would roll back a healthy deployment on a slow boot.
set -uo pipefail

budget=${GREENBOOT_SMORTRESS_BUDGET:-300}
deadline=$((SECONDS + budget))
units_file=${GREENBOOT_DEPLOY_UNITS:-/usr/share/smortress/deploy-units.txt}
failures=0

report() { printf '10-smortress-health: %s: %s\n' "$1" "$2" >&2; }

# The pool is the data plane: when it is not ONLINE, every app, every backup and
# every restore is failing at once, whatever the units report.
while :; do
  health=$(zpool list -H -o health smortress 2>/dev/null) || health=
  [[ $health == ONLINE ]] && break
  if ((SECONDS >= deadline)); then
    report zpool "${health:-unreadable}"
    failures=1
    break
  fi
  sleep 3
done

if [[ ! -r $units_file ]]; then
  report units "$units_file is missing or unreadable"
  exit 1
fi

mapfile -t pending < <(grep -vE '^[[:space:]]*(#|$)' "$units_file")
# The first pass always runs: a budget of zero means "do not wait", not "do not
# look", and a loop that skipped the check would pass a host that is not serving.
while :; do
  still=()
  for unit in "${pending[@]}"; do
    systemctl is-active --quiet "$unit" || still+=("$unit")
  done
  pending=(${still[@]+"${still[@]}"})
  ((${#pending[@]})) || break
  ((SECONDS >= deadline)) && break
  sleep 3
done

if ((${#pending[@]})); then
  for unit in "${pending[@]}"; do
    report "$unit" "not active"
  done
  failures=1
fi

if ((failures)); then
  printf '10-smortress-health: this deployment is not serving; greenboot will roll it back\n' >&2
fi
exit "$failures"
