# The apps tenant (T7 of #701)

`homelab-apps` is the one repository an agent may merge without a human. Its
definitions are not units: `scripts/apps-schema.py` validates them and renders
rootless Quadlets plus a plan, and the pieces below turn that plan into a
running, bounded tenant. This document describes what exists on smortress and
what the deploy still has to do when it applies a revision.

## Accounts and datasets

- One unprivileged, login-less user `apps` whose id `systemd-sysusers`
  allocates, home `/var/home/apps`, with linger in tmpfiles so its user manager
  starts at boot. Nothing names the id: the egress ruleset, the tmpfiles
  entries, the rendered Quadlets and `/srv/apps` all name the account. A fixed
  id was the older model and it failed silently — sysusers allocates the next
  free uid when the demand cannot be met, and every numeric reference (a dataset
  owner, a `user@<uid>` drop-in) then points at somebody else or at nothing.
  `smortress-apps-user.service` gives the account a subuid/subgid range
  (`start:count`) and refuses one that overlaps another account. Root never
  writes inside the tenant's home: the tenant owns that tree, and a root
  `install`/`chown` there would follow a symlink the tenant planted.
- `raw/apps` (`/var/srv/apps`) is one recovery group and belongs to the tenant
  account by name (`apps:apps`), mode 0700; `init-zpool` resolves the name when
  it chowns, which is why the pool unit is ordered after `systemd-sysusers`.
  Every core dataset is 0750 and owned by uid 1000, so the tenant cannot read
  application data, SOPS identities, or the agent workspace.
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

## Repository and check

`homelab-apps` holds definitions only: `apps/<name>/app.toml` and, when an app
needs secrets, `secrets.sops.json` — a SOPS file over the platform recipients
(operator key, machine identity, three YubiKeys), committed still encrypted.
The design originally named a tenant-only age recipient whose identity decrypts
nothing else; it is not used, because the apply step runs as root and already
holds the machine identity, so a second key would add a secret to protect
without narrowing that path. A definition may reference only keys under its own
`apps.<name>` section.

The required check named `apps-schema` runs this repository's validator from
`homelab-platform` at a SHA pinned in the tenant workflow — never a vendored
copy — and renders rather than only validating, because the host renders before
it applies. Both repositories are public, so the checkout needs no credential
and the tenant workflow carries no secret a pull request could read. The
validator reads the secrets file still encrypted: SOPS encrypts values only, so
key names are visible and no identity is needed.

`CODEOWNERS` names the operator for `.github/**`, `CODEOWNERS` itself and
`.sops.yaml`: an app-only PR needs no human approval, while a PR that changes
the check or the recipient list cannot merge without one. Required signed
commits are not enforced yet — no unattended signing key exists — and the
broker holds no `pull_requests: write` on the tenant repository, so the agent
cannot yet open the PR it is meant to auto-merge.

## Bounds

- **Quota.** Nothing on the host can grow past the table: `raw/apps`
  carries a 200G dataset quota, and `apps-quota` gives each app a ZFS project id
  with the inherit flag and a project quota no larger than 50G. `--check`
  reports drift for a deploy gate.
- **Egress.** `egress = "internet"` renders pasta, and a tenant-wide nftables
  rule (`smortress-apps-egress.service`) drops the `apps` account's traffic to
  IPv4 LAN, link-local, loopback, CGNAT/Tailscale and the metadata address.
  The rule names the account, not its number: nft resolves the name at load
  time, so the policy follows whatever uid systemd-sysusers allocated instead
  of matching nobody after the id moved. Any local address is matched with
  `fib daddr type local`, so a host address outside the private ranges is
  covered too. IPv6 is dropped for the tenant entirely. DNS (port 53) is the
  one exception, to any destination: pasta
  forwards the tenant's DNS as the tenant uid and the resolver may be the host
  stub, MagicDNS or a LAN router, so no static set can name it. An app can
  therefore still reach a resolver on the tailnet or LAN, but nothing else.
  The tenant's own network is excepted: the bridge sits inside
  `10.0.0.0/8`, and the rule that keeps the tenant off the LAN would
  otherwise drop rootlessport's forward to the container it belongs to,
  which made every published port time out. The network unit pins its
  subnet to `10.89.0.0/24` so the rule can name it exactly. `egress = "none"` joins the internal Podman network, which has no
  route out; Serve still reaches the loopback publish. Either class sits behind
  the same fail-closed table: a placeholder with the allow-list's name drops the
  whole account from earlier in boot, so a ruleset that fails to load leaves the
  tenant dropped rather than open (see Boot order).
- **Ingress.** Only Serve: core apps own the root paths on 443, 8443 and 10000,
  so `tailscale-serve` puts each app on `/apps/<name>` at 443 and
  removes a path the plan no longer names. Nothing is published off loopback.

## Boot order

    sysusers -> smortress-apps-deny -> smortress-apps-egress
             -> smortress-apps-user
             -> zfs-ready@raw-apps -> smortress-apps-quota
             -> systemd-logind -> user@<uid> (lingering) -> tenant units

The egress boundary is fail-closed, and what makes it so is a table, not only an
ordering. `smortress-apps-deny.service` loads a placeholder ruleset first: the
same table the allow-list uses, `inet smortress_apps_egress`, holding one chain
on the `output` hook at `priority filter` with one rule, `meta skuid apps drop`.
`smortress-apps-egress.service` then replaces it with the allow-list. A boot
where that replacement loads ends with the allow-list in force; a boot where it
does not — the unit fails, the vendor file is unreadable, the ruleset does not
parse — ends with the placeholder still armed, so the tenant is dropped rather
than left with no table at all and therefore unfiltered.

The replacement is atomic in the sense that matters: `nft -f` applies a file as a
single transaction, and the allow-list opens with
`destroy table inet smortress_apps_egress` before it redefines that table, so the
kernel moves from the blanket drop to the allow-list with no window in which
neither is in force, and a file that fails to parse leaves the drop exactly as it
was. The `destroy` is not optional for a second reason: a table block without it
adds rules to the existing chain instead of replacing it, which would leave the
placeholder's drop above the allow rules and deny the tenant everything.

Both units are ordered `After=systemd-sysusers.service` because both rulesets
name the account, which nft resolves when it loads the file, and the placeholder
unit is `Before=smortress-apps-egress.service` so the allow-list can never land
first and be overwritten by the placeholder. They carry `DefaultDependencies=no`,
so nothing else would order them there; the pool unit carries the same sysusers
ordering for the same reason, since it chowns `/srv/apps` to the account name.

The gate is that ordering, not a drop-in on the tenant's user manager. Each
prerequisite is `Before=systemd-logind.service`, so a lingering user manager —
and every tenant unit it starts — cannot come up before provisioning, the
placeholder (later replaced by the allow-list) and the quotas are in place. It
cannot be expressed as `Requires=` on the tenant's units: those are user units,
and a user manager cannot resolve a system unit, so
`Requires=smortress-apps-user.service` in one fails the unit with "Unit … not
found" instead of ordering it. The old
`user@<uid>.service.d` drop-in had the propagation (restarting a prerequisite
stopped the tenant) but its numeric name meant it would silently stop applying
the moment the uid moved, which is the failure this design rejects; a name-based
equivalent is a system unit that gates the tenant's manager by account name.

Limits are properties of each rendered app unit, not of `user-<uid>.slice`:
every Quadlet carries `MemoryHigh`, `MemoryMax`, `CPUQuota` and `TasksMax` in
its `[Service]` section, which the generator puts in the service it starts. The
tenant's total is therefore the sum of the apps it runs, and the tenant's own
Podman (image layers, container storage) is bounded by nothing yet.

## What the deploy still adds

The tenant's image policy is root-owned at
`/usr/share/smortress/apps-policy.json` and named by every rendered unit with
`PodmanArgs=--signature-policy=…`; it admits any digest-pinned image, which is
the documented risk of an unsupervised repository. The plan's per-app memory,
CPU and task limits are unit settings, so they bound each container's cgroup
directly. The tenant user's `/var` home (image layers, container storage) is not
on a dataset and has no quota yet — the accepted gap until a dataset or quota is
designed for it.

The receiver task (#798) owns the remaining half: fetch the pushed commit, require it
to be the tip of `homelab-apps` `main`, descend from the deployed commit, and
carry a valid signature; re-run the validator from the image; pull each app image by digest as the
tenant user with `--signature-policy=/usr/share/smortress/apps-policy.json`
(the host policy still rejects it for root); install the rendered units into
`~apps/.config/containers/systemd`, create the tenant's Podman secrets from its
SOPS section, reload and restart only the changed apps,
and leave the last good revision running when any step fails. The immediate
reboot snapshot and post-boot health gate belong to that same gate.
