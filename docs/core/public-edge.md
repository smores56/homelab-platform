# Public edge (T1 of #725)

The box that serves `photos.sammohr.dev` and `opds.sammohr.dev` to the
internet. It exists so those two names can leave Cloudflare's data path: the
atoms of the design are a tagged tailnet node, Caddy on 443 with a Let's
Encrypt certificate, and a tailnet ACL that admits two ports and nothing else.

Operator commands live in `docs/manual-steps.md` section 50; this document is
the shape, the failure modes and the rebuild.

## Host

| | |
| --- | --- |
| Provider | RackNerd, 4 GB KVM VPS (Black Friday 2026), New York |
| Resources | 4 vCPU, 4 GB RAM, 60 GB SSD, 10 TB transfer/month at 1 Gbps |
| OS | Ubuntu 24.04 (Caddy 2.6.2, which the Caddyfile validates against; jammy's 2.4 cannot parse the TLS options) |
| Address | one IPv4; IPv6 is a support ticket and was not requested |
| Price | $47.98/year, lifetime recurring |
| Control plane | RackNerd `ctrl`: reboot, OS reinstall, HTML5 VNC, optional network firewall |
| Not available | cloud-init, provider API, snapshots, hourly billing |

No snapshots and no API is the load-bearing fact: the box is hand-provisioned
by `provision/edge/bootstrap.sh` and rebuilt by reinstalling the OS and running
it again. Anything stateful that the bootstrap does not recreate must be a
recovery-kit item or must not exist.

## What runs

| Piece | Declared in | Purpose |
| --- | --- | --- |
| Caddy | `provision/edge/Caddyfile` | TLS for the two names, proxies to Serve ports 8446 and 8447 |
| nftables | `provision/edge/nftables.conf` | 443 and udp/41641 public, 22 on `tailscale0` only |
| sshd | `provision/edge/05-edge-hardening.conf` + `authorized_keys` | keys only, no password, no root password login; `05-` so it beats cloud-init's `50-cloud-init.conf` |
| tailscale | `provision/edge/bootstrap.sh` | joins once as `tag:vps` with hostname `smoresnet` (the panel name, the OS name and the tailnet name are one word), tags set key expiry off; the bootstrap realigns an existing node's name |

The ctrl panel's own firewall is the first layer and allows exactly `tcp/443`,
`udp/41641` and ICMP echo. Console/VNC bypasses it, so a wrong panel rule is
recoverable without a support ticket.

`udp/41641` is open so the tailnet keeps a direct WireGuard path to smortress;
without it every proxied byte is relayed through DERP and Immich uploads crawl.

### Why two Serve ports and not 443

Serve's 443 carries Immich's root **and** `/apps/agent-local`,
`/apps/agent-general` and `/wallpapers/` (`scripts/tailscale-serve.sh`). A
tailnet ACL is port-scoped and cannot say "this path only", so proxying the
public names to 443 would publish the agent gateway APIs and the wallpaper
index. `photos` proxies to 8446 and `opds` to 8447, and the ACL
(`tofu/tailscale.tf`) admits `tag:vps -> tag:smortress:8446,8447` with deny
tests for every other port.

### Certificates

Let's Encrypt, TLS-ALPN-01 only: the Caddyfile disables the HTTP challenge and
`auto_https disable_redirects` keeps Caddy off port 80, which is never opened.
No CAA record is written for the edge account — the zone's CAA story stays
pinned to Kanbei's account, and a second pin would make a rebuild's new ACME
account the outage (`docs/cloudflare.md`, "CAA").

**Issuance needs the public name, so it happens after the cutover.** ACME
validates `photos.sammohr.dev` and `opds.sammohr.dev` by resolving them: while
they are proxied CNAMEs to the cluster tunnel, Let's Encrypt reaches Cloudflare
and the challenge fails (`Cannot negotiate ALPN protocol "acme-tls/1"`). Caddy
keeps retrying, and the first successful order is seconds after the `A` records
appear. The pre-cutover probe therefore proves reachability and the path leaks
through `EDGE_IP`, not the certificate.

The ACME account key and the certificates live in Caddy's data directory
(`/var/lib/caddy/.local/share/caddy`). Losing them costs only a re-issue; keep
them in the kit because a re-issue during a rebuild is the step most likely to
fail unattended.

## DNS and the cutover

`tofu/dns.tf` declares two grey-cloud `A` records with an explicit 300 s TTL,
gated on `var.edge_ipv4`. While it is empty the names stay proxied CNAMEs to the
cluster tunnel and nothing about the edge is public.

One plan that both set `edge_ipv4` and dropped the names from the cluster set
would hold a destroy and a create at the same name. OpenTofu cannot order one
before the other and Cloudflare refuses two records at a name, so the cutover is
two commits, each applied by CI (`tofu-apply` on `main`) with no local
credentials:

1. `tofu/terraform.tfvars`: pin `cluster_hosts` to the remaining names, without
   `photos` and `opds`. The apply deletes their proxied CNAMEs.
2. `tofu/terraform.tfvars`: add `edge_ipv4 = "<vps-ipv4>"`. The apply creates
   both grey-cloud `A` records, and Caddy's next order succeeds.

Between the two applies the names fall through to the wildcard, which is the
host tunnel behind the Access deny: refused, not served. That window is one CI
run, and it is the only one either order has.

The cluster tunnel keeps its ingress rules for both names. With no DNS record
they serve nothing; #709 decides when the rules go, not this cutover.

The cutover waits on #709's retirement gate: it changes which Immich is
authoritative, which is a data decision, not a DNS one. Rollback is the same two
commits in reverse — drop `edge_ipv4` (the `A` records go, names fall to the
deny), then restore `cluster_hosts` (the CNAMEs return).

Before the cutover the reachability and path-leak probes run against the box
without touching the zone; the two certificate probes cannot pass until the
names resolve here, and they are the first post-cutover check:

```sh
EDGE_IP=<vps-ipv4> scripts/verify-public-edge.sh   # pre-cutover: cert probes red
scripts/verify-public-edge.sh                      # post-cutover: all ten green
```

## Metering

10 TB/month at 1 Gbps. RackNerd does not degrade over the allowance: it
null-routes or suspends the service, which takes both public names down while
every tailnet route stays up. Record the 30-day `photos` + `opds` transfer from
Cloudflare's analytics before the cutover, and watch the ctrl panel's graph
against it afterwards.

This is also why the box advertises no exit node: exit traffic would spend the
photo allowance, and a null-route would then take both roles down at once.

## Failure modes

| Symptom | Cause | Action |
| --- | --- | --- |
| 502 with a valid certificate | tailnet down, smortress down, or Serve 8446/8447 not declared | `provision/edge/verify.sh`; `tailscale status` on both ends; `systemctl status smortress-tailscale-serve` |
| certificate expired | ctrl firewall blocks 443, clock wrong, or ACME account refused | `journalctl -u caddy`; `timedatectl`; check the panel rule list |
| both names dead, tailnet fine | panel null-route, suspension, or host down | ctrl panel; reboot; console |
| new IP after rebuild | a replacement VPS, not an OS reinstall | update `edge_ipv4`, apply, re-run the probe |
| 404s where an app should answer | ACL, firewalld on smortress, or the Serve route | `tailscale ping`, then the host's `tailscale serve status` |

## Rebuild

A reinstall erases the disk; there is no snapshot to fall back to. The drill is
the rebuild, run once and timed before the cutover:

1. Confirm the kit has the ctrl login with its 2FA recovery codes, the Tailscale
   admin login with its 2FA recovery codes, the SSH host key and Caddy's data
   directory. The reinstall destroys the node identity, so a new preauthorized
   `tag:vps` key has to be minted in the Tailscale console (`§50.2`); without
   that login the box never rejoins.
2. In the ctrl panel, reinstall the Ubuntu 24.04 template. Note whether the IPv4
   changed.
3. From the HTML5 console, re-run `provision/edge/bootstrap.sh` with a fresh
   `tag:vps` key (`docs/manual-steps.md` §50.2). It sets the hostname, appends
   the repository login key, and realigns the tailnet name.
4. Reconnect over the tailnet, run `provision/edge/verify.sh`, then
   `scripts/verify-public-edge.sh` with `EDGE_IP`.
5. If the IPv4 changed, update `edge_ipv4` and apply; otherwise nothing to do.
6. Record the elapsed time. If it is not minutes, T2 does not move Backrest
   here.

Restoring the Caddy data directory before step 3 shortens the wait for
certificates; it is optional, and the ACME account it carries is the same one,
so the re-issued certificates do not depend on a new account registration.

## What a rebuild cannot derive

Everything the box runs is in this repository and `provision/edge/bootstrap.sh`
converges a bare Ubuntu 24.04 template to it. The list below is the whole of
what the repository *cannot* reproduce, with what is done about each item.

| Gap | Closure |
| --- | --- |
| Deploying the VPS itself (template, datacenter, IPv4) | Panel only: ctrl has no API and no cloud-init. Accepted; the bootstrap starts from a stock template. |
| First login on a replacement box | The template installs the order form's key, or the console. `authorized_keys` in the repo is appended by the bootstrap, so *this* login is reproducible after that first contact. |
| ctrl account and its second factor | Recovery-kit row. Without it there is no console and no reinstall. |
| Tailnet identity (the join key) | A preauthorized `tag:vps` key is single-use and minted in the Tailscale console per rebuild; the admin login and 2FA codes are a kit row. Not automated on purpose: the alternative is a long-lived, reusable credential on a public box's rebuild path. |
| SSH host key | Kit row plus `EDGE_HOST_KEY`; omitted, the box generates a new one and every `known_hosts` entry goes stale. |
| Caddy's data directory (ACME account, certificates) | Not restored. A rebuild re-issues, which costs seconds and needs nothing from the kit; the account it replaces is not pinned by CAA, so a new one is valid immediately. |
| Panel network firewall | Manual per rebuild: `tcp/443`, `udp/41641`, ICMP echo. Console/VNC bypasses it, so it cannot lock the box out. |
| The public IPv4 | May change on a replacement (not on a reinstall). Cutover and probes take `EDGE_IP`, and DNS is `var.edge_ipv4` in tofu. |
| Hostname | Closed: the bootstrap sets `smoresnet` on the OS and on the tailnet. |
| Package versions | Distro packages plus unattended upgrades; deliberately unpinned, so a rebuild may pick up newer Caddy. The bootstrap's 2.6 gate is the only floor. |
| Time, sshd policy, firewall, Serve routes on smortress | Closed: bootstrap for the box, the image for smortress, tofu for the tailnet. |

## Validation

Both halves are outside the repository:

- `provision/edge/verify.sh` on the box: firewall shape, sshd, no port 80,
  Caddy listening, tailnet up with `tag:vps`; and with `EXPECT_UPSTREAM=1`, the
  upstream certificate, both Serve ports and the 443 refusal.
- `scripts/verify-public-edge.sh` from anywhere: both names over valid TLS,
  certificate life above 14 days, and the six paths (three per name) that must
  answer 404.
