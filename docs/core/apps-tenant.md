# The apps tenant (T7 of #701)

`homelab-apps` is the one repository an agent may merge without a human. Its
definitions are not units: `scripts/apps-schema.py` validates them and renders
rootless Quadlets plus a plan, and the pieces below turn that plan into a
running, bounded tenant. This document describes what exists on smortress and
what the deploy still has to do when it applies a revision.

## Accounts and datasets

- One unprivileged, login-less user `apps`, uid/gid 1001, home
  `/var/home/apps`. `smortress-apps-user.service` gives it a subuid/subgid
  range, a user manager at boot (linger), and a per-user container policy.
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
| `basePath`, `loopbackPort`, `reachable` | Serve route generator |
| `projectId`, `quota` | quota applier |
| `image`, `network`, `mcs`, `secretNames` | the deploy's own apply step |

The plan is root-owned and validated again by each consumer: a foreign path, a
port outside 20000-29999, a quota above the platform ceiling, a non-numeric
project id or invalid JSON changes nothing.

## Bounds

- **Quota.** Nothing on the host can grow past the table: `raw/apps`
  carries a 200G dataset quota, and `apps-quota` gives each app a ZFS project id
  with the inherit flag and a project quota no larger than 50G. `--check`
  reports drift for a deploy gate.
- **Egress.** `egress = "internet"` renders pasta, and a tenant-wide nftables
  rule (`smortress-apps-egress.service`) drops the tenant uid's traffic to LAN,
  link-local, loopback, CGNAT/Tailscale, the tailnet ULA and the metadata
  address. `egress = "none"` joins the internal Podman network, which has no
  route out; Serve still reaches the loopback publish.
- **Ingress.** Only Serve: core apps own the root paths on 443, 8443 and 10000,
  so `tailscale-serve` puts each reachable app on `/apps/<name>` at 443 and
  removes a path the plan no longer names. Nothing is published off loopback.

## Boot order

    sysusers -> smortress-apps-user -> smortress-apps-egress
             -> zfs-ready@raw-apps -> smortress-apps-quota
             -> tenant units (once the deploy installs them)

## What the deploy still adds

The receiver task owns the remaining half: fetch the pushed commit, require it
to be the tip of `homelab-apps` `main`, descend from the deployed commit, and
carry a valid signature; re-run the validator from the image; install the
rendered units into `~apps/.config/containers/systemd`, create the tenant's
Podman secrets from its SOPS section, reload and restart only the changed apps,
and leave the last good revision running when any step fails. The immediate
reboot snapshot and post-boot health gate belong to that same gate.
