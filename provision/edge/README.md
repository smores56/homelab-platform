# The public edge

The RackNerd KVM VPS that serves `photos.sammohr.dev` and
`opds.sammohr.dev` (design #725). It is a tailnet node carrying `tag:vps`,
and its only public listener is Caddy on 443. Nothing here is in the smortress
image: the box is a separate host with a hand-run bootstrap, because RackNerd's
ctrl panel offers no cloud-init and no API to declare one.

| File | Purpose |
| --- | --- |
| `bootstrap.sh` | the whole provisioning step: packages, tailnet join, firewall, Caddy, unattended upgrades, then `verify.sh` |
| `Caddyfile` | the two names, TLS-ALPN-01 only, proxying to Serve ports 8446/8447 |
| `nftables.conf` | second firewall layer: 443 and 41641 public, 22 on the tailnet only |
| `05-edge-hardening.conf` | sshd drop-in; sshd keeps the first value, so `05-` beats cloud-init's `50-` |
| `verify.sh` | on-box proof of the design's shape; run it after any hand change |
| `authorized_keys` | the login key the bootstrap appends, so a replacement box trusts it without a console step |

## Order

1. Deploy the VPS from the panel's **Ubuntu 24.04** template, in the datacenter
   recorded in the runbook, and note the IPv4 in `docs/core/public-edge.md`.
   The Caddyfile is validated against noble's Caddy 2.6.2; jammy's 2.4 is
   refused by the bootstrap.
2. Leave the ctrl network firewall off (decision 2026-11-22). The host
   nftables ruleset is the only layer; the accepted residual is that a broken
   host firewall or a compromised host is unbounded.
3. From the HTML5 console, run `bootstrap.sh` with a `tag:vps` preauthorized
   key, the host's MagicDNS name and an ACME contact address. It names the box
   `smoresnet` on the OS and the tailnet, and appends `authorized_keys`. A root
   SSH key must already be in `/root/.ssh/authorized_keys`; the template takes
   it from the order form, and the bootstrap leaves key auth as the only way in.
4. Reconnect over the tailnet (`ssh root@smoresnet`) and run `verify.sh`. Its upstream half (the two
   Serve ports and the 443 refusal) is gated on `EXPECT_UPSTREAM=1`: run that
   once the image that declares 8446/8447 is on smortress, and before cutover.

The DNS cutover is not part of this: it waits for #709's retirement gate and is
two commits applied by CI (pin `cluster_hosts`, then set `edge_ipv4`), cluster
records first. See `docs/core/public-edge.md`.

`verify.sh`'s direct-path check can fail in the first seconds after the join,
before the WireGuard path is established; re-run it rather than changing
anything.
