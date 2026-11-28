# What "this deployment works" means on the edge, for greenboot (SDLC #939).
#
# The check that runs this file is lib/greenboot/required.d/10-health.sh; the
# image installs it as /etc/greenboot/assertions.d/10-health.sh. Everything that
# differs between hosts is here — the name the verdict carries, the budget, and
# what is probed — so the shared check has no host in it.
#
# The assertions are deliberately about the edge's own job and nothing else:
# Caddy serving the public names and the tailnet joined. Everything else on this
# box is the image's business, and a check that fails for a reason the image
# cannot fix only buys a rollback loop.
check_name=10-edge-health
# greenboot's unit is a oneshot with systemd's 90 s default, so a budget past
# that would be killed mid-wait and read as a failure — a rollback loop on a
# slow boot. The edge installs no timeout drop-in; the number is the contract.
budget=${GREENBOOT_EDGE_BUDGET:-60}

assertions() {
  # Caddy reloads certificates and tailscaled joins after the network is up, so
  # every probe is retried inside the one budget rather than failed on first look.
  #
  # One local request per name, resolved to the loopback so the probe exercises
  # the listener, the certificate and the route without needing DNS or hairpin
  # NAT. The Host/SNI name is the real one, so a certificate that does not cover
  # it fails here rather than in a browser.
  probe_name() {
    local name=$1 expect=$2 status
    while :; do
      status=$(curl --silent --show-error --max-time 10 --output /dev/null \
        --write-out '%{http_code}' --resolve "$name:443:127.0.0.1" "https://$name/" 2>/dev/null) || status=000
      [[ $status == "$expect" ]] && return 0
      if expired; then
        report "$name" "answered ${status:-nothing}, expected $expect"
        return 1
      fi
      wait_step
    done
  }

  # The public names the edge exists to serve. A 200 is the served page; opds
  # answers 401 without credentials, which is the auth working rather than
  # failing.
  probe_name photos.sammohr.dev 200
  probe_name opds.sammohr.dev 401

  if ! systemctl is-active --quiet caddy; then
    report caddy "not active"
  fi

  # The tailnet is how the operator reaches this box at all: sshd listens there
  # and the deploy plane used to. A host that booted without it is a console trip
  # even though Caddy answers, so it is a required check rather than a wanted one.
  while :; do
    if tailscale status --peers=false >/dev/null 2>&1; then
      break
    fi
    if expired; then
      report tailscale "not joined within ${budget}s"
      break
    fi
    wait_step
  done
}
