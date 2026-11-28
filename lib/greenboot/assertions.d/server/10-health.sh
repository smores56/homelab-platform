# What "this host works" means on smortress, for greenboot (SDLC #939).
#
# The check that runs this file is lib/greenboot/required.d/10-health.sh; the
# image installs it as /etc/greenboot/assertions.d/10-health.sh. Everything that
# differs between hosts is here — the name the verdict carries, the budget, and
# what is probed — so the shared check has no host in it.
#
# "Serving" is the list the post-boot gate read: /usr/share/smortress/deploy-units.txt
# names the units a healthy host keeps active. Reusing it is deliberate -- it is
# the one definition of this host's job, and a second list would drift from it.
check_name=10-smortress-health
# The 300 s budget is the one the post-boot gate used for the same wait, and the
# greenboot-healthcheck drop-in raises the unit's timeout to cover it
# (units/systemd/greenboot-healthcheck.service.d/10-timeout.conf).
budget=${GREENBOOT_SMORTRESS_BUDGET:-300}
units_file=${GREENBOOT_DEPLOY_UNITS:-/usr/share/smortress/deploy-units.txt}

assertions() {
  # The pool is the data plane: when it is not ONLINE, every app, every backup
  # and every restore is failing at once, whatever the units report.
  while :; do
    health=$(zpool list -H -o health smortress 2>/dev/null) || health=
    [[ $health == ONLINE ]] && break
    if expired; then
      report zpool "${health:-unreadable}"
      break
    fi
    wait_step
  done

  if [[ ! -r $units_file ]]; then
    report units "$units_file is missing or unreadable"
    return
  fi

  mapfile -t pending < <(grep -vE '^[[:space:]]*(#|$)' "$units_file")
  # The first pass always runs: a budget of zero means "do not wait", not "do
  # not look", and a loop that skipped the check would pass a host that is not
  # serving.
  while :; do
    still=()
    for unit in "${pending[@]}"; do
      systemctl is-active --quiet "$unit" || still+=("$unit")
    done
    pending=(${still[@]+"${still[@]}"})
    ((${#pending[@]})) || return
    expired && break
    wait_step
  done

  for unit in "${pending[@]}"; do
    report "$unit" "not active"
  done
}
