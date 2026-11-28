# Public edge (T1 of #725)

The box that serves `photos.sammohr.dev`, `opds.sammohr.dev` and
`recovery.sammohr.dev` to the internet, and the only public surface the zone has
(SDLC #833 retired every Access application and tunnel). It exists so the media
names can leave Cloudflare's data path: the atoms of the design are a tagged
tailnet node, Caddy on 443 with a Let's Encrypt certificate, and a tailnet ACL
that admits three Services and nothing else.

Operator commands live in `docs/manual-steps.md#public-edge-vps`; this document is
the shape, the failure modes and the rebuild.

## Host

| | |
| --- | --- |
| Provider | RackNerd, 4 GB KVM VPS (Black Friday 2026), New York |
| Resources | 4 vCPU, 4 GB RAM, 60 GB SSD, 10 TB transfer/month at 1 Gbps |
| OS | `ghcr.io/smores56/homelab-platform/edge`, a signed bootc image built from `bootc/edge/`; its Caddy is 2.11, and the Caddyfile's `tls` block needs 2.6 (2.4 cannot parse it) |
| Booted reference | `ostree-image-signed:docker://ghcr.io/smores56/homelab-platform/edge:latest`, active digest `sha256:3657b35e128e40f6b31e7cdb77da61701803207788c71626591a95110afb657c`, version `45.20261030.3.1 (2026-11-27T03:03:35Z)` — measured with `rpm-ostree status` on 2026-11-27. The box follows the tag, so `bootc upgrade` is what moves it, at the 04:00 America/New_York window the image's `bootc-fetch-apply-updates.timer.d/10-schedule.conf` alone sets; a deploy stage installs a digest instead and leaves it pinned |
| Address | one IPv4; IPv6 is a support ticket and was not requested |
| Price | $47.98/year, lifetime recurring |
| Control plane | RackNerd `ctrl`: reboot, OS reinstall, HTML5 VNC, optional network firewall |
| Not available | cloud-init, provider API, snapshots, hourly billing |

No snapshots and no API is the load-bearing fact: the box is installed from this
repository's own artifact — `coreos-installer` on the FCOS live ISO with the
committed `ignition/edge.json` and the sha512 of that same file — and a rebuild is
that install again, never a hand-installed OS plus a bootstrap. There is no
configuration-management layer beside the image: after the install, the only
things a person writes are the `/etc/smoresnet` values and secrets no public
repository may carry, which `scripts/edge-bootstrap.sh` writes from stdin, and
everything else this document describes arrives in the image. Anything stateful
those two do not recreate must be a recovery-kit item or must not exist.

Caddy, Tailscale, firewalld and sshd are packages inside the image, not
containers: the box's only application is a TLS proxy, and no Quadlet runs here.

## What runs

| Piece | Declared in | Purpose |
| --- | --- | --- |
| Caddy | `bootc/edge/rootfs/usr/share/smoresnet/Caddyfile`, run by `caddy.service.d/10-smoresnet.conf` | TLS for the three names: `photos`, `opds` and `recovery` each proxy to a Tailscale Service on smortress (`svc:immich`, `svc:opds`, `svc:recovery`). No application process runs on this box |
| firewalld | `bootc/edge/rootfs/usr/share/smoresnet/firewalld/zones/public.xml` and `tailscale.xml`, installed by `smoresnet-firewall-zones` and bound by `-public`/`-tailscale` | 443 and udp/41641 public, 22 on `tailscale0` only, default zone drop |
| sshd | `bootc/edge/rootfs/etc/ssh/sshd_config.d/05-edge-hardening.conf` | keys only, no password, no root password login; the operator's key arrives through the Ignition document's `authorized_keys`, which the base's afterburn drop-ins point `AuthorizedKeysFile` at |
| tailscale | `smoresnet-tailscale-up.service`, with the key `scripts/edge-bootstrap.sh` writes | joins once as `tag:vps` with hostname `smoresnet` (`/etc/hostname` is in the Ignition document, so the panel name, the install's name and the tailnet name are one word), and tags set key expiry off |

The ctrl panel's network firewall is **not enabled** (decision, 2026-11-22):
the image's firewalld zones are the only layer. What that gives up is written down
as a residual in `docs` and in #725 — a host firewall that fails to load at boot,
or a compromised host, is not bounded by anything in front of it. It saves a
browser-only rule list that no diff or CI can see.

`udp/41641` is open so the tailnet keeps a direct WireGuard path to smortress;
without it every proxied byte is relayed through DERP and Immich uploads crawl.

The state directories the units write are image content, not something an
operator's hand step leaves behind. `systemd-tmpfiles` makes `/var/lib/caddy`
(Caddy's ACME account key and certificates), the deploy tree at
`/var/lib/homelab/deploy` with its queue, and `/var/lib/smoresnet` (the node
identity, 0700) from `bootc/edge/rootfs/etc/tmpfiles.d/smoresnet-edge.conf` and
`bootc/edge/rootfs/usr/lib/tmpfiles.d/smoresnet-deploy.conf` at every boot,
because each of them is a `ReadWritePaths` target: a unit whose target is missing
fails in namespace setup with `226/NAMESPACE` before its own program runs, which
is how the boot gate was lost on the boot after the first install.
`bootc/edge/unit-paths.tsv` is the list of record: one row per path a unit names,
with which of those makes it, and `scripts/check-edge-unit-paths.sh` fails a pull
request where a unit names a path nothing creates. A from-scratch install that
never reaches `edge-bootstrap` therefore has a Caddy storage directory, a deploy
queue and a boot gate that can start, rather than the four missing paths the
2026-11 reinstall found on the console.

### Why a Service per application and not the host's 443

Serve's 443 on the host's own name carries Immich's root **and**
`/apps/agent-local`, `/apps/agent-general` and `/wallpapers/`
(`scripts/tailscale-serve.sh`). A tailnet ACL is port-scoped and cannot say "this
path only", so proxying the public names there would publish the agent gateway
APIs and the wallpaper index.

Each application is advertised on a Service of its own instead — `svc:immich`
and `svc:opds`, `serve --service=... --https=443` — so Tailscale terminates TLS
for `<service>.<tailnet>.ts.net` and a Service publishes exactly one application
with no path prefix. `photos` proxies to `https://immich.<tailnet>.ts.net` and
`opds` to `https://opds.<tailnet>.ts.net`, the ACL (`tofu/tailscale.tf`) admits
`tag:vps -> svc:immich:443, svc:opds:443` with deny tests for everything else,
and the host's own 443 stays out of reach of this box.

Neither name is hardcoded: `scripts/edge-bootstrap.sh` strips the first label
off `SMORTRESS_FQDN` to get the tailnet domain, refuses a value with no dot, and
writes `IMMICH_UPSTREAM` and `OPDS_UPSTREAM` to `/etc/caddy/edge.env`, which is
what the image's Caddyfile substitutes and what the packaged unit validates before
Caddy starts.

`recovery` is a Service like the other two since SDLC #953. Backrest ran on this
box from #725 T2, which put the corpus-read credential on a box anybody can
reach; it now runs on smortress behind its guard, Caddy proxies
`https://recovery.<tailnet>.ts.net` (`$RECOVERY_UPSTREAM`), and the ACL admits
`tag:vps -> svc:recovery:443`. A popped edge yields no corpus access at all.

### Certificates

Let's Encrypt, TLS-ALPN-01 only: the Caddyfile disables the HTTP challenge and
`auto_https disable_redirects` keeps Caddy off port 80, which is never opened.
The zone's `CAA` records name the CA, not the edge's ACME account
(`docs/cloudflare.md`, "CAA"), so a rebuild's freshly registered account is
authorized as soon as it orders.

**Issuance needs the public name.** ACME validates each name by resolving it,
so the order only succeeds once the grey `A` record points here: while a name was
a proxied CNAME to the cluster tunnel, Let's Encrypt reached Cloudflare and the
challenge failed (`Cannot negotiate ALPN protocol "acme-tls/1"`). Caddy keeps
retrying, and the first successful order is seconds after the record appears —
which is why a new box, or a `edge_ipv4` change, is followed by a wait rather
than a config edit. The on-box proof that does not need public DNS is the boot
gate's own infrastructure input: it requires each of the three names to resolve
and Caddy to complete a TLS handshake on loopback before it blesses a boot
(`## The boot gate`), and a 502 there is an upstream's answer rather than a failed
handshake.

The ACME account key and the certificates live in Caddy's data directory
(`/var/lib/caddy/.local/share/caddy`). Losing them costs only a re-issue; keep
them in the kit because a re-issue during a rebuild is the step most likely to
fail unattended.

## DNS and the cutover

`tofu/dns.tf` declares the grey-cloud `A` records for `photos`, `opds` and
`recovery` with an explicit 300 s TTL, gated on `var.edge_ipv4`. The cutover is
done: `edge_ipv4 = "192.236.188.99"` is committed, so the three names resolve to
this box and nothing in the zone is proxied. Rollback is dropping that one value
— the records go and the names stop resolving, because the wildcard CNAME they
used to fall through is retired with the tunnels (SDLC #833). There is no
`cluster_hosts` to restore and no second record at either name any more.

The cutover that created them was two commits while the cluster tunnel still
owned the names: pin `cluster_hosts` without `photos` and `opds`, apply, then set
`edge_ipv4` and apply again. Cloudflare refuses two records at one name and
OpenTofu cannot order a destroy before a create, which is why it could not be one
plan. Both of those inputs are gone — the tunnel, its CNAMEs and `cluster_hosts`
are retired (SDLC #833) — so one field carries the records: setting `edge_ipv4`
creates them, dropping it removes them, and the only window left is the seconds
between the apply and Caddy's next order.

Before the first cutover, `scripts/legacy/compare-photos-origin.sh` compared
`/api/server/statistics` on the cluster copy against the host's; the cluster copy
is gone, so there is one library now and no comparison to run.

The cutover waited on #709's retirement gate because it changed which Immich is
authoritative, a data decision rather than a DNS one.

The public probe is a post-cutover step, run once Caddy has ordered:

```sh
scripts/verify-public-edge.sh   # thirteen checks: three names, certificates, three applications
```

There is no separate pre-cutover on-box run to make: while a name still resolves
into Cloudflare no ACME order can succeed anywhere, and the boot gate's
infrastructure inputs are what a box proves about itself in the meantime.

Afterwards both probes run daily in
`.github/workflows/verify-public-edge.yml`: `scripts/verify-public-edge.sh` for
the names and `scripts/verify-caa.sh` for the CA the zone's `CAA` records admit
(setup: `docs/manual-steps.md`, "Create the public edge check").

## Metering

10 TB/month at 1 Gbps. RackNerd does not degrade over the allowance: it
null-routes or suspends the service, which takes both public names down while
every tailnet route stays up. The pre-cutover baseline was 30 days of `photos` + `opds` transfer from
Cloudflare's analytics; the running number is the ctrl panel's graph, since no
Cloudflare phase sees this traffic any more.

This is also why the box advertises no exit node: exit traffic would spend the
photo allowance, and a null-route would then take both roles down at once.

## Failure modes

| Symptom | Cause | Action |
| --- | --- | --- |
| 502 with a valid certificate | tailnet down, smortress down, or `svc:immich`/`svc:opds` not advertised | `scripts/verify-public-edge.sh`; `tailscale status` on both ends; `systemctl status smortress-tailscale-serve` |
| certificate expired | ctrl firewall blocks 443, clock wrong, or ACME account refused | `journalctl -u caddy`; `timedatectl`; check the panel rule list |
| every name dead, tailnet fine | panel null-route, suspension, or host down | ctrl panel; reboot; console |
| new IP after rebuild | a replacement VPS, not an OS reinstall | update `edge_ipv4`, apply, re-run the probe |
| 404s where an app should answer | ACL, firewalld on smortress, or the Serve route | `tailscale ping`, then the host's `tailscale serve status` |
| `recovery` answers 502 while `photos` works | smortress's reader, its guard or `svc:recovery` — never this box | `systemctl status smortress-backrest.service` and `journalctl -u smortress-backrest-watchdog.service` on smortress; `tests/backrest/check.bats` owns the shape |
| the box does not reach userspace after a deployment | the new image's PID1 never got far enough for `edge-boot-gate.service` to judge it, so nothing was denylisted and nothing rolled back | the RackNerd console: pick the previous boot entry — the deployment `bootc switch` replaced — and reboot. There is no unattended rollback for this class; see `## The boot gate` |

## The boot gate

The bootc edge (design #939) runs `bootc/edge/rootfs/usr/libexec/edge-boot-gate`
from `edge-boot-gate.service` on every boot, `Before=boot-complete.target` and
`After=multi-user.target`, the way the server's
`scripts/smortress-boot-gate.sh` does. What it can do about a bad deployment is
much less, so its inputs fall into two classes and the class is the contract.

**Verdict inputs** are facts about the deployment, and the deployment may be
denylisted and rolled back for them: the booted digest `bootc status --booted`
reports is the one the staged request recorded (either digest form), the boot's
own startup finished (`systemctl is-system-running` reached `running` or
`degraded`), no unit in `bootc/edge/rootfs/usr/share/smoresnet/deploy-units.txt`
— caddy, firewalld, sshd — is inactive or failed, and `state.json` records this
commit and these digests, read back after the write. A failure journals
`boot-gate-failed`, denylists both digest forms, pages the `deploy` check and runs
`bootc rollback --apply`. A boot whose digest is not the staged one is the
bootloader's own fallback: it is journaled `rolled-back-by-bootloader`, denylisted
and consumed, and nothing is rolled back, because there is nothing to roll back
to.

**Infrastructure inputs** are facts about the host's surroundings, and the commit
is never the reason they are down: the tailscale backend is `Running`, each of the
three public names resolves, Caddy completes a TLS handshake on loopback (any
status — a 502 is an upstream's answer, not a failed handshake), and this host's
public address is the address the names resolve to. The name list is a knob
(`EDGE_PUBLIC_NAMES`) because the zone is the other half of it: a name the gate
checks and `local.edge_hosts` in `tofu/cluster.tf` does not publish is a boot that
holds on `dns` and pages until one of the two changes. They are retried inside a
300 s budget, because the tailnet and DNS come up seconds after multi-user. A
failure never denylists and never rolls back: it journals `deploy-held` with
reason `infra-<input>`, pages `/fail`, and stamps `retry_at` (epoch seconds, the
queue's own field) on the pending record. The record stays, so the next boot
decides again, and `state.json` still names the old commit, so the poll re-requests
the deployment the host could not prove.

**A first boot** — an install or a reinstall, `/var` without
`/var/lib/smoresnet/boot-gate-landed.json` — alerts, holds and writes the marker,
and touches nothing else. `/var` is the only tree it can keep a record in, the
marker is the record, and without it nothing could say the running deployment is
worse than the one it replaced: the previous deployment on a fresh box is the
install medium's. So the marker costs one page per host life and buys a gate that
never rolls back on a history it does not have. The boot after it decides
normally.

There is no boot counting on this box, and that is a decision rather than a gap
(#941, canceled): the edge is a BIOS-only VPS, so sd-boot's `LoaderEntryOneShot`
— the clean way to count a boot — has no ESP to live on and is unusable here, and
bootupd 0.3.2, the package this base ships, has no force flag and scopes its
regeneration to UEFI, so it cannot own a GRUB entry either. The unproven GRUB
`custom.cfg` workaround lives on `smores/t13-loader` and ships nowhere.
`edge-boot-gate.service` therefore journals `boot-counting-absent` on every boot,
which is the journal saying the verdict above is the only rollback this host has,
and a deployment whose PID1 never reaches userspace is a console recovery: the
RackNerd HTML5 console, the previous boot entry, and no expectation of an
automatic rollback that will never come. #994 is the drill that proves that
recovery, timed, on the real box.

The page is the operator's URL in `/etc/smoresnet/deploy-ping-url`, written the
way the tailnet auth key is written and by the same kind of step: it is not image
content, and until it exists every page journals `notify-skipped` instead of
failing the boot.

A hold exits 1 on purpose: the deployment was neither blessed nor refused, and a
clean `boot-complete.target` would be the host claiming otherwise. The tests are
`tests/deploy/edge-boot.bats`, and the outside-in assertions — 443 answering, 22
and every port but 443 closed to the internet — are the scheduled probe's
(`scripts/verify-public-edge.sh`), not this gate's.

## The deploy plane

Four units, and none of them is a sops unit: the edge has no SOPS plane and no age
identity. `smoresnet-deploy-poll.timer` asks GitHub for the tip every fifteen
minutes and enqueues a request when it moved; it is the only trigger (design
#1010, #1018), and nothing reaches in — no listener, no Serve forward, and no
tailnet grant but the owner's ssh. The drain (`smoresnet-deploy.service`,
`deploy-drain-edge`) runs the shared `bootc/lib/deploy/drain.sh` loop with a no-op
where the server's snapshot gate sits, records `pending.json` and reboots into the
digest the verifier's `bootc switch` already staged. The poll is the dead-man
too (#1019): every run pings the deploy check's `/start` and one verdict, green
only while no queue entry has waited a poll interval with no drain applying it
and no hold is unreleased, and `/fail` with the reason otherwise. Publishing
never triggers a deploy: `publish-edge-image.yml` builds and signs, and the poll
is what lands the release. Enqueuing is the poll's alone; `smoresnet-deploy.path` starts
the drain on the first file in the queue, so a hand-run (`systemctl start
smoresnet-deploy.service`) is the same path an operator can take.

`smoresnet-firewall-prejoin.service` is the one door that is not on the list
above: the public zone admits no ssh, and that is right for a host with a
tailnet. A host that has not joined has no other way in, so the unit opens 22 on
the public zone as a *runtime* rule while
`/var/lib/smoresnet/tailscale-enrolled` is absent, and the first boot after the
join removes it. The shipped zone stays the single reviewed answer to "what does
this box accept"; the window is visible in `firewall-cmd --zone=public
--list-all` and in the journal, and it is what makes `edge-bootstrap` reachable
on a box whose join has not happened yet.

The secrets are the operator's, never image content, plaintext and 0600 under
`/etc/smoresnet` (a `tmpfiles.d` line creates the 0700 directory): the dead-man URL
above and the transport credential the join unit reads (`tailscale-authkey`).
There is no webhook secret: the box answers no inbound deploy any more (#1018).
`scripts/edge-bootstrap.sh` writes both from stdin — never argv — and a re-run
rotates one only with `--force`;
`docs/manual-steps.md#bootstrap-the-fresh-edge` is the order.

## Rebuild

A rebuild is the artifact install the running box came from, and nothing else:
the box runs a signed bootc image, so there is no base OS to assemble and no
bootstrap script to replay. The install is `coreos-installer` from the FCOS live
ISO on the VPS, with the committed `ignition/edge.json` pinned by the sha512 of
that same file, onto the BIOS disk (`/dev/vda`), with the five kernel arguments
the box's static network needs — `ip=`, `nameserver=` and `net.ifnames=0`,
because dracut has no profile to read and brings the address up before anything
else exists. Nothing on the box is hand-configured afterwards except the
`/etc/smoresnet` values and secrets only an operator holds, which
`scripts/edge-bootstrap.sh` writes from stdin.

**The commands are `docs/manual-steps.md`**: "Render and commit the edge
Ignition" is the `coreos-installer` invocation, and "Bootstrap the fresh edge" is
the one operator step after it. They live there, once, so an install typed on a
console cannot disagree with an install typed from this document. What follows is
what a rebuild costs and in what order it is paid; the drill that times it is
#994 (T16).

1. Confirm the kit has the ctrl login with its 2FA recovery codes and the
   Tailscale admin login with its 2FA recovery codes. The reinstall destroys the
   node identity, so a new preauthorized `tag:vps` key has to be minted in the
   Tailscale console (`docs/manual-steps.md#public-edge-vps`); without that login
   the box never rejoins.
2. In the ctrl panel, boot the FCOS live ISO and run the install from
   `docs/manual-steps.md`, "Render and commit the edge Ignition". Note whether the
   IPv4 changed: it is a kernel argument in that install, and a different address
   is also a different `edge_ipv4`.
3. From the HTML5 console — the first session is on the public side, since the
   tailnet join needs the key this step writes — run `scripts/edge-bootstrap.sh`
   with the fresh `tag:vps` key and the rest of the secret document
   (`docs/manual-steps.md#bootstrap-the-fresh-edge`).
4. Run `scripts/verify-public-edge.sh` from a checkout: thirteen checks, the three
   names over valid TLS and each answering as its own application.
5. If the IPv4 changed, update `edge_ipv4` and apply; otherwise nothing to do.
6. Record the elapsed time. The reader no longer runs here (SDLC #953), so a
   rebuild costs `recovery.sammohr.dev` only for the seconds Caddy spends ordering
   its certificate: the reader itself and its credential stay on smortress.

Restoring the recovery kit's copy of Caddy's data directory before step 3 shortens
the wait for certificates; it is optional, and the ACME account it carries is the
same one, so the re-issued certificates do not depend on a new account
registration.

## What a rebuild cannot derive

Everything the box runs is in this repository: the image is the whole host and
`scripts/edge-bootstrap.sh` writes the rest. The list below is the whole of what
the repository *cannot* reproduce, with what is done about each item.

| Gap | Closure |
| --- | --- |
| Deploying the VPS itself (datacenter, IPv4, the live ISO) | Panel only: ctrl has no API and no cloud-init. Accepted; the install is typed on the console from `docs/manual-steps.md`. |
| First login after the install | Closed by the artifact: the Ignition document carries the operator's public key, and firewalld publishes 22 on the public interface only until the tailnet join, so the first contact needs nothing from the panel and nothing from the repository. |
| ctrl account and its second factor | Recovery-kit row. Without it there is no console and no reinstall. |
| Tailnet identity (the join key) | A preauthorized `tag:vps` key is single-use and minted in the Tailscale console per rebuild; the admin login and 2FA codes are a kit row. Not automated on purpose: the alternative is a long-lived, reusable credential on a public box's rebuild path. |
| SSH host key | Not carried. sshd generates an ed25519 identity at first boot and this build keeps it (#185): logins arrive over the tailnet, where the node key is what authenticates the machine, so a pinned sshd key buys a stable `known_hosts` line and costs a credential to fetch, trust and rotate. The cost is real: after a reinstall the first `ssh` over the tailnet reports a changed host key. |
| Caddy's data directory (ACME account, certificates) | Not restored. A rebuild re-issues, which costs seconds and needs nothing from the kit; the account it replaces is not pinned by CAA, so a new one is valid immediately. |
| Panel network firewall | Not enabled (owner decision). The image's firewalld zones are the only layer; the cost is that a boot-time firewall failure or a compromised host is unbounded, and 443 depends on the host rules being right. |
| The public IPv4 | May change on a replacement. It is a kernel argument in the install and `var.edge_ipv4` in DNS; an update to that one value plus an apply repoints all three names. |
| Hostname | Closed: `/etc/hostname` is in the Ignition document, and `smoresnet-tailscale-up.service` joins as `smoresnet`. |
| Package versions | Closed: they are the image's, resolved at build, recorded in the digest the repository pins, and changed by a deploy rather than by an unattended upgrade on the box. A rebuild installs the digest the Ignition document names, so it cannot pick up a different Caddy. |
| Time, sshd policy, firewall, Serve routes on smortress | Closed: the image for the box, the image for smortress, tofu for the tailnet. |

## Validation

Nothing here is proved by a human reading the console. The image's static half
runs in CI, the boot gate judges every boot on the box, and the outside-in probe
runs daily (`.github/workflows/verify-public-edge.yml`).

- `bootc/edge/tests/check.sh` in CI's `image` area
  (`.github/workflows/server-image-static.yml`, on any `bootc/**` pull request):
  the image's half of the design, carried onto `bootc/edge/rootfs` (design #939,
  T5) — the Caddyfile's shape and its path outside `/etc`, the emptied public
  zone and the tailnet-only sshd, the units, no secret in the image, and the base
  being a stream tag. `bootc container lint` is part of it but runs inside the
  built image; outside one the checker reports it as a skip.
- `edge-boot-gate.service` on the box, every boot: the tailnet backend running,
  each of the three names resolving, Caddy completing a loopback handshake and
  this host's public address being the one the names resolve to — the half of the
  design that no repository check can see, judged before the boot is blessed.
- `scripts/verify-public-edge.sh` from anywhere, after the cutover: all three
  names over valid TLS with life above 14 days, and each path answering as its own
  application — Immich's HTML shell, OPDShelf's 401 challenge, Backrest's own
  page behind its guard — never as the agent gateway, a text/plain 404, or the
  wallpaper listing. A status code alone cannot prove that: Immich answers 200
  and OPDShelf 401 for any path.
- `scripts/verify-caa.sh`: reads the zone's `CAA` records and the issuer of the
  certificate `photos.sammohr.dev` serves, and requires the issuer's CA domain in
  an `issue` value — Google Trust Services to `pki.goog`, Let's
  Encrypt to `letsencrypt.org`, DigiCert to `digicert.com`, Sectigo to
  `sectigo.com`, ZeroSSL to `zerossl.com`. `issuewild` governs wildcard orders
  only and admits no ordinary order, so it never satisfies this probe
  (`CAA_WILDCARD=1` checks it for a wildcard name instead). The served issuer is
  admitted by the union of the two `letsencrypt.org` records this repository
  declares and the CA set Cloudflare appends for the proxied names (#833 retired
  the last of those); an empty set is a notice, not a failure, which keeps the
  check meaningful for a zone that has none.

## The operator order

The edge is a RackNerd 4 GB KVM VPS with one IPv4 and no IPv6. It runs the
repository's own signed image, joins the tailnet as `tag:vps`, and proxies
`photos`, `opds` and `recovery` to the `svc:immich`, `svc:opds` and `svc:recovery`
Services. The order and the decisions are here; the commands are
`docs/manual-steps.md#public-edge-vps`, typed once there so an install cannot
disagree with itself.

1. **Apply the tailnet policy first** — a key can only carry a tag its owner may
   apply, and the tag must exist in `tagOwners`: `tofu -chdir=tofu apply -no-color`
   from the checkout on `main`.
2. **Mint a preauthorized `tag:vps` key** — admin console → Settings → Keys, tag
   `tag:vps`, preauthorized, 1-day expiry, reusable off. Do not store it; a
   reinstall mints a new one, which is why the admin login and its 2FA recovery
   codes are recovery-kit rows.
3. **Panel firewall.** Decision 2026-11-22: the ctrl network firewall stays off.
   The image's firewalld zones are the only layer; the accepted residual is that a
   host firewall failing at boot leaves the kernel default-allow. If that changes,
   the rule set is `tcp/443`, `udp/41641` and ICMP (all types — PMTU needs
   destination-unreachable), added **before** enabling it.
4. **Install the image from the console.** Boot the FCOS live ISO in the ctrl
   panel and run the `coreos-installer` line in `docs/manual-steps.md`, "Render and
   commit the edge Ignition": the committed `ignition/edge.json`, its sha512,
   `/dev/vda`, and the five `ip=`/`nameserver=`/`net.ifnames=` kernel arguments the
   static address needs. The Ignition document carries the only key sshd accepts,
   and firewalld publishes 22 on the public interface only until the tailnet join,
   so the first `ssh root@<ipv4>` is that window and nothing else is open in it.
5. **Bootstrap the box.** `scripts/edge-bootstrap.sh` on the box as root, with
   both secrets on stdin — `docs/manual-steps.md#bootstrap-the-fresh-edge`. It
   writes `/etc/caddy/edge.env`, the tailnet key, the dead-man URL and the first
   deploy record, and it ends by saying what remains.
6. **Declare the Serve routes on smortress**, then prove it from a checkout:

   ```sh
   sudo firewall-cmd --reload
   sudo systemctl restart smortress-tailscale-serve.service
   scripts/verify-public-edge.sh   # thirteen ok lines
   ```

   Expect the previous routes unchanged plus `svc:immich` → `http://127.0.0.1:2283`,
   `svc:opds` → `http://127.0.0.1:8083` and `svc:recovery` → `http://127.0.0.1:9898`,
   and then three names over valid TLS, each answering as its own application. The
   box's own half — firewall, sshd, no port 80, Caddy listening, tailnet up with
   `tag:vps` — is the image's, asserted by `bootc/edge/tests/check.sh` before it is
   ever installed.
7. **The names.** The cutover is done, so this step is the address only: record
   30 days of `photos` + `opds` transfer from before the cutover against the ctrl
   panel's graph now, and stop to size the plan if the traffic is a meaningful
   fraction of 10 TB. The library comparison that gated the first cutover compared
   a cluster copy that no longer exists (`scripts/legacy/compare-photos-origin.sh`).

   The records exist: `edge_ipv4` is committed, so `photos`, `opds` and `recovery`
   already point here. A replacement box with a new address is one value and one
   apply — the two-commit dance the first cutover needed existed only while the
   cluster tunnel still owned those names, and that tunnel is retired (SDLC #833):

   ```sh
   $EDITOR tofu/terraform.tfvars   # edge_ipv4 = "<vps-ipv4>"
   git commit -qm 'feat(tofu): point the edge names at the VPS'
   git push
   scripts/verify-public-edge.sh   # all thirteen green, certificates included
   ```

   The probe checks each name answers *as its application*: Immich's own HTML shell
   for any path, OPDShelf's 401 challenge for any path. Rollback is dropping
   `edge_ipv4`, which removes the records.
8. **The rebuild drill, timed** (#994, T16). Reinstall from the live ISO on the
   real box following `## Rebuild`, then repeat steps 2 through 6 (the install
   destroyed the node identity, so the key is new too). The kit rows must already
   hold the ctrl login with its 2FA recovery codes. Record the elapsed time and the
   panel bandwidth graph; if the rebuild is not minutes, the outage is longer than
   it should be.
