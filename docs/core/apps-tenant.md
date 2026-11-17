# The apps tenant (T7 of #701)

`homelab-apps` is the one repository an agent may merge without a human. Its
definitions are not units: `scripts/apps-schema.py` validates them and renders
rootless Quadlets plus a plan, and the pieces below turn that plan into a
running, bounded tenant. This document describes what exists on smortress and
what the deploy still has to do when it applies a revision.

## Accounts and datasets

- One unprivileged, login-less user `apps`, uid/gid 1001, home
  `/var/home/apps`, with linger in tmpfiles so its user manager starts at boot.
  `smortress-apps-user.service` gives it a subuid/subgid range (`start:count`)
  and refuses one that overlaps another account. Root never writes inside the
  tenant's home: the tenant owns that tree, and a root `install`/`chown` there
  would follow a symlink the tenant planted.
- `raw/apps` (`/var/srv/apps`) is one recovery group and belongs to the tenant
  account, mode 0700. Every core dataset is 0750 and owned by uid 1000, so the
  tenant cannot read application data, SOPS identities, or the agent workspace.
- Each app writes exactly one directory, `/srv/apps/<name>`, mounted at `/data`
  with `:Z` so Podman relabels it into that container's MCS pair.

## The plan

`render --root <checkout> --out <dir>` writes one `<name>.container` per app,
`smortress-apps.network` when any app has `egress = "none"`, and `plan.json`.
The deploy installs `plan.json` as `/var/lib/homelab/apps/plan.json`; every
consumer re-reads it rather than trusting an environment variable:

| Field | Used by |
| --- | --- |
| `basePath`, `loopbackPort` | Serve route generator |
| `projectId`, `quota` | quota applier |
| `image`, `dataPath`, `network`, `mcs`, `secretNames`, `unitName` | the deploy's own apply step |

The plan is root-owned and every consumer runs the renderer's own
`apps-schema verify-plan` against it: a foreign path, a port outside
20000-29999, a quota outside 1 byte-50G, a duplicate or non-numeric project id,
a bad image reference, a non-object entry or invalid JSON changes nothing.

## Bounds

- **Quota.** Nothing on the host can grow past the table: `raw/apps`
  carries a 200G dataset quota, and `apps-quota` gives each app a ZFS project id
  with the inherit flag and a project quota no larger than 50G. `--check`
  reports drift for a deploy gate.
- **Egress.** `egress = "internet"` renders pasta, and a tenant-wide nftables
  rule (`smortress-apps-egress.service`) drops the tenant uid's traffic to
  IPv4 LAN, link-local, loopback, CGNAT/Tailscale and the metadata address.
  Any local address is matched with `fib daddr type local`, so a host address
  outside the private ranges is covered too. IPv6 is dropped for the tenant
  entirely. DNS (port 53) is the one exception, to any destination: pasta
  forwards the tenant's DNS as the tenant uid and the resolver may be the host
  stub, MagicDNS or a LAN router, so no static set can name it. An app can
  therefore still reach a resolver on the tailnet or LAN, but nothing else. `egress = "none"` joins the internal Podman network, which has no
  route out; Serve still reaches the loopback publish.
- **Ingress.** Only Serve: core apps own the root paths on 443, 8443 and 10000,
  so `tailscale-serve` puts each app on `/apps/<name>` at 443 and
  removes a path the plan no longer names. Nothing is published off loopback.

## Boot order

    sysusers -> smortress-apps-user -> smortress-apps-egress
             -> zfs-ready@raw-apps -> smortress-apps-quota
             -> systemd-logind -> user@1001 (lingering) -> tenant units

`user@1001.service.d/50-smortress-apps.conf` makes the user manager `Requires=`
the three prerequisites, so a failed provisioning, egress rule or quota stops
the tenant instead of starting it unbounded. That propagation also means
restarting any of the three stops the tenant until it is started again; a deploy
that changes a quota must restart the tenant's units afterwards.

## What the deploy still adds

The tenant's image policy is root-owned at
`/usr/share/smortress/apps-policy.json` and named by every rendered unit with
`PodmanArgs=--signature-policy=…`; it admits any digest-pinned image, which is
the documented risk of an unsupervised repository. The plan's per-app memory,
CPU and task limits are Podman's own; the tenant user's `/var` home (image
layers, container storage) is not on a dataset and has no quota yet — the
accepted gap until a dataset or quota is designed for it.

The receiver task owns the remaining half: fetch the pushed commit, require it
to be the tip of `homelab-apps` `main`, descend from the deployed commit, and
carry a valid signature; re-run the validator from the image; pull each app image by digest as the
tenant user with `--signature-policy=/usr/share/smortress/apps-policy.json`
(the host policy still rejects it for root); install the rendered units into
`~apps/.config/containers/systemd`, create the tenant's Podman secrets from its
SOPS section, reload and restart only the changed apps,
and leave the last good revision running when any step fails. The immediate
reboot snapshot and post-boot health gate belong to that same gate.
