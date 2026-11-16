#!/usr/bin/env bash
# Open SSH on the wired interfaces until the tailnet is enrolled.
#
# The zone is set on the NetworkManager connection, not on the interface:
# NM re-asserts its own zone on every activation, so a firewalld-only binding
# is reset and the box becomes unreachable — which is exactly how the first
# bring-up of this host lost SSH. access-lockdown.sh reverses this after
# enrollment; the bootstrap zone permits ssh and nothing else.
set -euo pipefail

connections=$(nmcli -t -f UUID,TYPE connection show |
  awk -F: '$2 == "802-3-ethernet" {print $1}')

for uuid in $connections; do
  nmcli connection modify "$uuid" connection.zone bootstrap
done

while IFS=: read -r device type _; do
  [[ $type == ethernet ]] || continue
  nmcli device reapply "$device" || true
done < <(nmcli -t -f DEVICE,TYPE device status)

firewall-cmd --reload
echo "access-bootstrap: wired interfaces in the bootstrap zone until enrollment"
