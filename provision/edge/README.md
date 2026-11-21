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
| `99-edge-hardening.conf` | sshd drop-in; sorts after cloud-init's password-auth file |
| `verify.sh` | on-box proof of the design's shape; run it after any hand change |

## Order

1. Deploy the VPS from the panel's Ubuntu template, in the datacenter recorded
   in the runbook, and note the IPv4 in `docs/core/public-edge.md`.
2. In the panel: enable the network firewall with exactly `tcp/443`,
   `udp/41641` and ICMP echo. Console/VNC bypasses it, so this cannot lock you
   out.
3. From the HTML5 console, run `bootstrap.sh` with a `tag:vps` preauthorized
   key, the host's MagicDNS name and an ACME contact address.
4. Reconnect over the tailnet and run `verify.sh`.

The DNS cutover is not part of this: it waits for #709's retirement gate and is
one apply of `edge_ipv4` (`tofu/dns.tf`). See `docs/core/public-edge.md`.
