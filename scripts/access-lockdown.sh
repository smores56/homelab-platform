#!/usr/bin/env bash
# Close the bring-up window: wired interfaces back to the default drop zone.
set -euo pipefail

connections=$(nmcli -t -f UUID,TYPE connection show |
  awk -F: '$2 == "802-3-ethernet" {print $1}')

for uuid in $connections; do
  nmcli connection modify "$uuid" connection.zone drop
done

while IFS=: read -r device type _; do
  [[ $type == ethernet ]] || continue
  nmcli device reapply "$device" || true
done < <(nmcli -t -f DEVICE,TYPE device status)

firewall-cmd --reload
echo "access-lockdown: wired interfaces are back in the drop zone"
