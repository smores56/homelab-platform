#!/usr/bin/env bash
# What "this deployment works" means on the edge, for greenboot.
#
# greenboot runs every executable in check/required.d after boot and rolls the
# deployment back if one exits non-zero. That is the automatic rollback for a
# host that boots into a sick image -- the boot counter covers the other case, a
# deployment whose PID 1 never reaches userspace, and neither covers the other's
# failure. Both together replace the gate this repository used to hand-roll.
#
# The check is deliberately about the edge's own job and nothing else: Caddy
# serving the three names and the tailnet joined. Everything else on this box is
# the image's business, and a check that fails for a reason the image cannot fix
# only buys a rollback loop.
#
# A boot is not a steady state. Caddy reloads certificates and tailscaled joins
# after the network is up, so every probe is retried inside one budget rather
# than failed on first look: greenboot's unit is a oneshot with systemd's 90 s
# default, and a probe that gave up after five seconds would roll back a healthy
# deployment on a slow boot.
set -uo pipefail

budget=${GREENBOOT_EDGE_BUDGET:-60}
deadline=$((SECONDS + budget))
failures=0

report() { printf '10-edge-health: %s: %s\n' "$1" "$2" >&2; }

# One local request per name, resolved to the loopback so the probe exercises the
# listener, the certificate and the route without needing DNS or hairpin NAT. The
# Host/SNI name is the real one, so a certificate that does not cover it fails
# here rather than in a browser.
probe_name() {
  local name=$1 expect=$2 status
  while :; do
    status=$(curl --silent --show-error --max-time 10 --output /dev/null \
      --write-out '%{http_code}' --resolve "$name:443:127.0.0.1" "https://$name/" 2>/dev/null) || status=000
    [[ $status == "$expect" ]] && return 0
    if ((SECONDS >= deadline)); then
      report "$name" "answered ${status:-nothing}, expected $expect"
      return 1
    fi
    sleep 3
  done
}

# The public names the edge exists to serve. A 200 is the served page; opds
# answers 401 without credentials, which is the auth working rather than failing.
probe_name photos.sammohr.dev 200 || failures=1
probe_name opds.sammohr.dev 401 || failures=1

if ! systemctl is-active --quiet caddy; then
  report caddy "not active"
  failures=1
fi

# The tailnet is how the operator reaches this box at all: sshd listens there and
# the deploy plane used to. A host that booted without it is a console trip even
# though Caddy answers, so it is a required check rather than a wanted one.
while :; do
  if tailscale status --peers=false >/dev/null 2>&1; then
    break
  fi
  if ((SECONDS >= deadline)); then
    report tailscale "not joined within ${budget}s"
    failures=1
    break
  fi
  sleep 3
done

if ((failures)); then
  printf '10-edge-health: this deployment is not serving; greenboot will roll it back\n' >&2
fi
exit "$failures"
