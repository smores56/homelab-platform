# Public edge (T1 of #725)

The box that serves `photos.sammohr.dev` and `opds.sammohr.dev` to the
internet. It exists so those two names can leave Cloudflare's data path: the
atoms of the design are a tagged tailnet node, Caddy on 443 with a Let's
Encrypt certificate, and a tailnet ACL that admits two ports and nothing else.

Operator commands live in `docs/manual-steps.md#public-edge-vps`; this document is
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

The template's `multipathd`, `ModemManager`, `udisks2`, `upower` and `rsyslog`
are disabled by the bootstrap: this VM has none of that hardware and journald
owns the journal. Everything else is a package, not a container — Caddy and
Tailscale are OS infrastructure on a box whose only application is a TLS proxy.

## What runs

| Piece | Declared in | Purpose |
| --- | --- | --- |
| Caddy | `provision/edge/Caddyfile` | TLS for the two names, proxies to Serve ports 8446 and 8447 |
| nftables | `provision/edge/nftables.conf` | 443 and udp/41641 public, 22 on `tailscale0` only |
| sshd | `provision/edge/05-edge-hardening.conf` + `authorized_keys` | keys only, no password, no root password login; `05-` so it beats cloud-init's `50-cloud-init.conf` |
| tailscale | `provision/edge/bootstrap.sh` | joins once as `tag:vps` with hostname `smoresnet` (the panel name, the OS name and the tailnet name are one word), tags set key expiry off; the bootstrap realigns an existing node's name |

The ctrl panel's network firewall is **not enabled** (decision, 2026-11-22):
the host nftables ruleset is the only layer. What that gives up is written down
as a residual in `docs` and in #725 — a host firewall that fails to load at boot,
or a compromised host, is not bounded by anything in front of it. It saves a
browser-only rule list that no diff or CI can see.

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
appear. Before the cutover there is nothing public to probe: the names resolve
elsewhere and no certificate exists here. The pre-cutover proof is the box's own
`verify.sh` with `EXPECT_UPSTREAM=1`, which proves the firewall, both origins
answering, and that this box cannot reach smortress's 443 at all.

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

Before any of it, prove the host copy is the authoritative library:

```sh
CLUSTER_URL=https://photos.sammohr.dev CLUSTER_API_KEY=… \
HOST_URL=https://smortress.<tailnet>.ts.net HOST_API_KEY=… \
  scripts/legacy/compare-photos-origin.sh
```

It compares `/api/server/statistics` on both copies; a difference means the
cutover would serve a different library. `EDGE_USAGE_DELTA` allows a byte
tolerance, nothing else.

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

The public probe is a post-cutover step, run once Caddy has ordered:

```sh
ssh root@smoresnet EXPECT_UPSTREAM=1 /root/edge/verify.sh   # before the zone moves
scripts/verify-public-edge.sh                               # after it moves
```

Afterwards the same two scripts run daily in
`.github/workflows/verify-public-edge.yml`: `scripts/verify-public-edge.sh` for
the names and `scripts/verify-caa.sh` for the CA the zone's `CAA` records admit
(setup: `docs/manual-steps.md`, "Create the public edge check").

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
   `tag:vps` key has to be minted in the Tailscale console (`docs/manual-steps.md#public-edge-vps`); without
   that login the box never rejoins.
2. In the ctrl panel, reinstall the Ubuntu 24.04 template. Note whether the IPv4
   changed.
3. From the HTML5 console, re-run `provision/edge/bootstrap.sh` with a fresh
   `tag:vps` key (`docs/manual-steps.md#public-edge-vps`). It sets the hostname, appends
   the repository login key, and realigns the tailnet name.
4. Reconnect over the tailnet and run `provision/edge/verify.sh` with
   `EXPECT_UPSTREAM=1`.
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
| SSH host key (ed25519 only) | Kit row plus `EDGE_HOST_KEY`; omitted, the box generates a new one and every `known_hosts` entry goes stale. The template's rsa and ecdsa pairs are deleted, because they are in no kit and would be a second, never-verified identity. |
| Caddy's data directory (ACME account, certificates) | Not restored. A rebuild re-issues, which costs seconds and needs nothing from the kit; the account it replaces is not pinned by CAA, so a new one is valid immediately. |
| Panel network firewall | Not enabled (owner decision). The host nftables ruleset is the only layer; the cost is that a boot-time firewall failure or a compromised host is unbounded, and 443 depends on the host rules being right. |
| The public IPv4 | May change on a replacement (not on a reinstall). DNS takes it in `var.edge_ipv4`; the probes resolve the names, so only the cutover needs the value. |
| Hostname | Closed: the bootstrap sets `smoresnet` on the OS and on the tailnet. |
| Package versions | Distro packages plus unattended upgrades; deliberately unpinned, so a rebuild may pick up newer Caddy. The bootstrap's 2.6 gate is the only floor. |
| Time, sshd policy, firewall, Serve routes on smortress | Closed: bootstrap for the box, the image for smortress, tofu for the tailnet. |

## Validation

Both halves are outside the repository's own checks, and
`.github/workflows/verify-public-edge.yml` runs them daily:

- `provision/edge/verify.sh` on the box: firewall shape, sshd, no port 80,
  Caddy listening, tailnet up with `tag:vps`; and with `EXPECT_UPSTREAM=1`, the
  upstream certificate, both Serve ports and the 443 refusal.
- `scripts/verify-public-edge.sh` from anywhere, after the cutover: all three
  names over valid TLS with life above 14 days, and each path answering as its own
  application — Immich's HTML shell, OPDShelf's 401 challenge, Backrest's own
  page behind its guard — never as the agent gateway, a text/plain 404, or the
  wallpaper listing. A status code alone cannot prove that: Immich answers 200
  and OPDShelf 401 for any path.
- `scripts/verify-caa.sh`: reads the zone's `CAA` records and the issuer of the
  certificate `kanbei.sammohr.dev` serves, and requires the issuer's CA domain in
  an `issue`/`issuewild` value — Google Trust Services to `pki.goog`, Let's
  Encrypt to `letsencrypt.org`, DigiCert to `digicert.com`, Sectigo to
  `sectigo.com`, ZeroSSL to `zerossl.com`. An empty CAA set is a notice and
  passes: there is nothing to assert until the records land.

## The operator order

The edge is a RackNerd 4 GB KVM VPS with one IPv4 and no IPv6. It runs Caddy for
`photos.sammohr.dev` and `opds.sammohr.dev`, joins the tailnet as `tag:vps`, and
proxies to Serve ports 8446 and 8447. Shape and failure modes:
`docs/core/public-edge.md`. Nothing here can be done by repo code, and the cutover
waits for the retirement gate and the origin-parity comparison, not for the box.

1. **Apply the tailnet policy first** — a key can only carry a tag its owner may
   apply, and the tag must exist in `tagOwners`: `tofu -chdir=tofu apply -no-color`
   from the checkout on `main`.
2. **Mint a preauthorized `tag:vps` key** — admin console → Settings → Keys, tag
   `tag:vps`, preauthorized, 1-day expiry, reusable off. Do not store it; a
   reinstall mints a new one, which is why the admin login and its 2FA recovery
   codes are recovery-kit rows.
3. **Panel firewall.** Decision 2026-11-22: the ctrl network firewall stays off.
   `provision/edge/nftables.conf`, applied by the bootstrap, is the only layer; the
   accepted residual is that a host firewall failing at boot leaves the kernel
   default-allow. If that changes, the rule set is `tcp/443`, `udp/41641` and ICMP
   (all types — PMTU needs destination-unreachable), added **before** enabling it.
4. **Deploy and join from the console.** Use the Ubuntu 24.04 template (jammy's
   Caddy cannot parse `provision/edge/Caddyfile`) and install Tailscale from its
   signed repository, not `curl | sh`:

   ```sh
   . /etc/os-release
   curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$VERSION_CODENAME.noarmor.gpg" \
     -o /usr/share/keyrings/tailscale-archive-keyring.gpg
   curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$VERSION_CODENAME.tailscale-keyring.list" \
     -o /etc/apt/sources.list.d/tailscale.list
   apt-get update -qq && apt-get install -y tailscale
   tailscale up --auth-key 'tskey-auth-…' --advertise-tags=tag:vps \
     --hostname=smoresnet --accept-routes=false
   ```

   Port 22 is closed at the panel, so this console session is the only way in until
   the tailnet link is up, and a root key must exist in `/root/.ssh/authorized_keys`
   before the bootstrap closes password auth.
5. **Copy the bootstrap over the tailnet and run it:**

   ```sh
   tar -C provision -cf - edge | ssh root@smoresnet 'tar -C /root -xf -'
   ssh root@smoresnet
   SMORTRESS_FQDN=smortress.stonecat-jazz.ts.net EDGE_ACME_EMAIL=… \
   EDGE_HOST_KEY=/root/edge-host-key   /root/edge/bootstrap.sh
   ```

   `EDGE_HOST_KEY` is the key from the recovery kit; omit it to let the box
   generate one. `verify.sh` runs at the end and every line must read `ok`.
6. **Declare the Serve routes on smortress**, then prove the pair:

   ```sh
   sudo firewall-cmd --reload
   sudo systemctl restart smortress-tailscale-serve.service
   ssh root@smoresnet EXPECT_UPSTREAM=1 /root/edge/verify.sh
   ```

   Expect the previous routes unchanged plus 8446 → `http://127.0.0.1:2283` and 8447
   → `http://127.0.0.1:8083`, and a green upstream run: the firewall shape, both
   Serve ports answering, the upstream certificate verifying, and this box unable to
   reach smortress on 443.
7. **The cutover.** Prove the host copy is the authoritative library first, with
   `CLUSTER_URL=… CLUSTER_API_KEY=… HOST_URL=… HOST_API_KEY=…
   scripts/legacy/compare-photos-origin.sh`: both counts must match, and usage within
   `EDGE_USAGE_DELTA` if you allow one. Then record 30 days of `photos` + `opds`
   transfer from Cloudflare's analytics; if it is a meaningful fraction of 10 TB,
   stop and size the plan instead.

   Cloudflare refuses two records at one name and OpenTofu cannot order a destroy
   before a create, so the cutover is two commits, each applied by CI:

   ```sh
   $EDITOR tofu/terraform.tfvars   # cluster_hosts = [<every host but photos and opds>]
   git commit -qm 'chore(tofu): take photos and opds off the cluster tunnel'
   git push
   $EDITOR tofu/terraform.tfvars   # edge_ipv4 = "<vps-ipv4>"
   git commit -qm 'feat(tofu): point the edge names at the VPS'
   git push
   scripts/verify-public-edge.sh   # all thirteen green, certificates included
   ```

   The probe checks each name answers *as its application*: Immich's own HTML shell
   for any path, OPDShelf's 401 challenge for any path. Rollback is the same two
   commits in reverse.
8. **The rebuild drill, timed.** Reinstall the template from the panel on the real
   box, then repeat steps 2 through 6 (the reinstall destroyed the node identity, so
   the key is new too). The kit rows must already hold the ctrl login with its 2FA
   recovery codes, the edge SSH host key and Caddy's data directory. Record the
   elapsed time and the panel bandwidth graph; if the rebuild is not minutes,
   Backrest does not move here.
