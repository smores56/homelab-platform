#!/usr/bin/env bash
# Boot reconcile of the root ingress instances (#150).
#
#   apps-ingress-reconcile
#
# `smortress-app-ingress@<name>` is a static template: `systemctl enable` has
# nothing to hook, and the only code that starts an instance is the apps apply.
# A reboot brings the tenant's containers back -- they are user units under a
# lingering manager -- and leaves every `/apps/<name>` route answering nothing
# until the next apps revision. Measured on 2026-11-25: the route stayed dead
# across six boots, and the health probe named the closed loopback port each
# time. This walks the installed plan and makes the instance set match it: one
# instance per app the plan names, none for a name it has dropped.
#
# The plan is verified before anything is started, for the same reason the
# helper verifies it before it binds: a foreign path or a port outside the
# platform range must stop the run, not reach a listener. An unreadable plan
# fails too -- a host whose tenant nobody can describe is a fault, not a host
# with no tenant. No plan at all is the host before its first apps apply, and
# is not a failure.
#
# Every knob is environment-overridable so tests/apps/ingress-reconcile.bats can
# drive this exact code against stubs. Production sets none of them.
set -euo pipefail

plan=${APPS_PLAN:-/var/lib/homelab/apps/plan.json}
systemctl_bin=${SYSTEMCTL:-systemctl}
template=${APPS_INGRESS_TEMPLATE:-smortress-app-ingress@}
schema=${APPS_SCHEMA:-/usr/libexec/apps-schema}
jq_bin=${JQ:-jq}

[[ -e $plan ]] || exit 0

if ! problems=$("$schema" verify-plan --plan "$plan" 2>&1); then
  printf 'apps-ingress-reconcile: %s is not accepted:\n%s\n' "$plan" "$problems" >&2
  exit 1
fi

declare -A planned=()
while IFS= read -r name; do
  [[ -n $name ]] || continue
  planned[$name]=1
done < <("$jq_bin" -r '.apps | keys[]' "$plan")

# Every instance the manager knows about, including a failed one: a unit that
# failed still owns the name, and restarting it is how it comes back.
declare -A present=()
while IFS= read -r unit; do
  [[ -n $unit ]] || continue
  name=${unit#"$template"}
  name=${name%.service}
  [[ -n $name && $name != "$unit" ]] || continue
  present[$name]=1
done < <("$systemctl_bin" list-units --all --plain --no-legend --full \
  "${template}*.service" 2>/dev/null | awk 'NF { print $1 }')

rc=0
# Queued, not awaited: the helper waits for its container itself, so holding the
# boot transaction for that would turn one dead app into a slow boot. A start
# that cannot even be queued still fails this run.
for name in "${!planned[@]}"; do
  "$systemctl_bin" start --no-block "${template}${name}.service" || rc=1
done
# A dropped app's instance would keep answering its loopback port with a socket
# into a namespace the plan no longer describes; Serve has pruned the route, so
# nothing reaches it, but the port stays open until this stops it.
for name in "${!present[@]}"; do
  [[ -n ${planned[$name]+x} ]] && continue
  "$systemctl_bin" stop "${template}${name}.service" || rc=1
done
exit "$rc"
