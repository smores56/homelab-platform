#!/usr/bin/env bash
# Declare the Tailscale Serve routes that front the loopback-published
# applications. Serve state lives in tailscaled's state file, which is not part
# of a recovery group and not worth backing up: it is re-declared on every boot.
#
# Every route is a root path on its own HTTPS port, because none of these three
# applications supports being served under a subpath. Nothing here is Funnel:
# Serve answers tailnet clients only.
set -euo pipefail

tailscale_bin=${TAILSCALE_BIN:-tailscale}

# https port -> loopback port. 443 Immich, 8443 OPDShelf, 10000 Syncthing GUI.
declare -A routes=(
  [443]=2283
  [8443]=8083
  [10000]=8384
)

for https in "${!routes[@]}"; do
  backend=http://127.0.0.1:${routes[$https]}
  if ! "$tailscale_bin" serve --bg --https="$https" "$backend"; then
    echo "tailscale-serve: could not serve $backend on https/$https" >&2
    exit 1
  fi
done

"$tailscale_bin" serve status
