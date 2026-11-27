#!/usr/bin/env bash
# Turn the Syncthing GUI's host check back on (design #897, T2).
#
# The GUI refuses a Host header it does not expect and Tailscale Serve forwards
# the client's Host unchanged; the loopback proxy in front of the GUI rewrites it
# to 127.0.0.1:8384, the one address config.xml trusts. So the check can stay on,
# and the bypass that used to be the host's answer (`insecureSkipHostcheck`) must
# not come back: that setting is host state, not image state (config.xml lives on
# the syncthing-config dataset), so a restored config, a rebuilt host or an
# operator's experiment would leave the GUI trusting any Host again.
#
# Root only for the key: config.xml is 0700 core:core. The key is never printed.
# Idempotent: PATCHing false when it is already false changes nothing, and the
# read-back is what decides the exit status, so a GUI that ignored the PATCH fails
# this unit instead of leaving the route up on a false assumption.
set -euo pipefail

config=${SYNCTHING_CONFIG:-/var/lib/syncthing/config/config.xml}
gui=${SYNCTHING_GUI:-http://127.0.0.1:8384}
attempts=${SYNCTHING_ATTEMPTS:-60}
pause=${SYNCTHING_PAUSE:-5}

# The GUI is a container that may still be starting, its config -- where the key
# lives -- is written by its own first start, and this unit is ordered after that
# Quadlet but not gated on its health. So the wait comes first: on a fresh host the
# file does not exist yet, and reading it before the GUI answered would fail a unit
# whose whole job is to write one setting. /rest/noauth/health needs no key. A GUI
# that never answers is this unit's failure: the proxy Requires= it, so the route
# goes down with it rather than serving a GUI nobody verified.
ready=
for _ in $(seq 1 "$attempts"); do
  if curl -fsS -o /dev/null "$gui/rest/noauth/health" 2>/dev/null; then
    ready=1
    break
  fi
  sleep "$pause"
done
if [[ -z $ready ]]; then
  echo "syncthing-hostcheck: the GUI at $gui never answered" >&2
  exit 1
fi

# awk, not `sed | head`: under `pipefail` the SIGPIPE from a reader that stops
# early fails the assignment, and the file is root-only so a guessed key is not
# an option.
key=$(awk -F'<apikey>|</apikey>' '/<apikey>/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$config")
if [[ -z $key ]]; then
  echo "syncthing-hostcheck: no <apikey> in $config: the GUI's check cannot be enforced" >&2
  exit 1
fi

if ! curl -fsS -o /dev/null -X PATCH -H "X-API-Key: $key" \
  -H 'Content-Type: application/json' -d '{"insecureSkipHostcheck": false}' \
  "$gui/rest/config/gui"; then
  echo "syncthing-hostcheck: the GUI refused the PATCH" >&2
  exit 1
fi

state=$(curl -fsS -H "X-API-Key: $key" "$gui/rest/config/gui" |
  jq -r '.insecureSkipHostcheck')
if [[ $state != false ]]; then
  echo "syncthing-hostcheck: the GUI still reports insecureSkipHostcheck=${state:-missing}" >&2
  exit 1
fi
echo "syncthing-hostcheck: the GUI's host check is on"
