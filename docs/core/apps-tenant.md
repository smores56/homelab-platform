# The apps tenant (T7 of #701)

`homelab-apps` is the one repository an agent may merge without a human. Its
definitions are not units: `scripts/apps-schema.py` validates them and renders
rootless Quadlets plus a plan, and the pieces below turn that plan into a
running, bounded tenant. This document describes what exists on smortress and
what the deploy does, and gives up, when it applies a revision.

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
| `basePath`, `loopbackPort` | Serve route generator, root-owned ingress proxy |
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
the check or the recipient list cannot merge without one. **Signed commits are
not required**, by operator decision: the agent runs unattended, so a signature
would prove possession of a key that has to live on the machine, not that a
human approved anything.

A `main` ruleset requires a pull request and the `apps-schema` check; the only
bypass actor is the repository admin role. The shell path was measured on
2026-11-22: `smores56-agent` (classic `repo` PAT, Write collaborator) pushed
`smores/agent-pr-proof`, opened PR #4, enabled squash auto-merge, and GitHub
merged it at 18:38:17Z with `apps-schema` green and no human approval because
the diff touched only one app definition in the tenant repository. A direct push of the same commit to
`main` was refused with `push declined due to repository rule violations`.
`scripts/agent-tenant-pr-probe.sh` repeats this: its read-only mode checks the
token identity, the Write role, the ruleset and the direct-push refusal, and
`--merge` opens and auto-merges the app-only PR.

The App is gone as a credential too: the `github-apps` enrollment, its
`contents: write` scope and the minting code were retired on 2026-11-22
(`docs/broker.md`, `docs/agent-identity.md`). Every GitHub write in the tenant
path is the machine user's PAT through the shell, measured above.

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
  `egress = "none"` joins the internal Podman network, which has no
  route out; Serve still reaches the loopback publish. Either class sits behind
  the same fail-closed table: a placeholder with the allow-list's name drops the
  whole account from earlier in boot, so a ruleset that fails to load leaves the
  tenant dropped rather than open (see Boot order).
- **Ingress.** Only Serve: core apps own the root paths on 443, 8443 and 10000,
  so `tailscale-serve` puts each app on `/apps/<name>` at 443 and
  removes a path the plan no longer names. Serve proxies to the app's
  `loopbackPort` on the host, and that listener belongs to
  `smortress-app-ingress@<name>`, a root unit: `scripts/apps-ingress.sh` binds
  `127.0.0.1:<loopbackPort>` and forwards over a unix socket into the
  container's network namespace, where it connects to `127.0.0.1:<port>`.

  A rendered unit publishes **nothing**. A rootless publish is performed by a
  forwarder running as the tenant uid, and the tenant egress table drops tenant
  traffic, so every published port timed out while that table was loaded —
  measured on the host for the tenant's own network and for plain pasta. The
  helper is root at both ends, listens only on loopback, and re-verifies the
  plan before it creates either end. A container restart destroys the namespace
  it joined, the unit exits, and systemd restarts it against the new pid.

  The instance **set** is reconciled from the plan at boot by
  `smortress-app-ingress-reconcile.service` (`scripts/apps-ingress-reconcile.sh`):
  it starts one instance per app the plan names and stops the instances of a
  name the plan dropped. The template is static, so an apps apply is the only
  other thing that starts an instance, and without this reconcile a reboot
  restores the tenant's containers and leaves every `/apps/<name>` route
  answering nothing — measured on 2026-11-25, where the route stayed dead across
  six boots until a human started the unit (issue #150).

## Boot order

    sysusers -> smortress-apps-deny -> smortress-apps-egress
             -> smortress-apps-user
             -> zfs-ready@raw-apps -> smortress-apps-quota
             -> systemd-logind -> user@<uid> (lingering) -> tenant units
             -> smortress-app-ingress-reconcile (one ingress per planned app)

The reconcile is ordered after `systemd-logind` rather than after the tenant
manager, which a system unit cannot name: the helper it starts waits up to a
minute for its container to appear, so the manager's own start is the wait,
not a race.

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

A host that acquires one anyway cannot stage a deploy: `deploy-platform prepare`
refuses while any `/etc/systemd/system/user@*.service.d/` exists, journals the
paths as `deploy-drift`, and the drain keeps the entry queued as `host-drift`.
The image checks only prove what a build ships, and the file that did this
survived a week on the host while six apps applies reverted (#152).

Limits are properties of each rendered app unit, not of `user-<uid>.slice`:
every Quadlet carries `MemoryHigh`, `MemoryMax`, `CPUQuota` and `TasksMax` in
its `[Service]` section, which the generator puts in the service it starts. The
tenant's total is therefore the sum of the apps it runs, and the tenant's own
Podman (image layers, container storage) is bounded by nothing yet.

## What the deploy adds

The tenant's image policy is root-owned at
`/usr/share/smortress/apps-policy.json` and named by every rendered unit with
`PodmanArgs=--signature-policy=…`. It is `insecureAcceptAnything`: the flag names
*which* policy applies, and this one enforces nothing, so no tenant image is
signature-checked and no digest is required to be pinned for Policy's sake. What
bounds a tenant image is the schema's digest pin (`image` must be `repo@sha256:…`,
refused by the validator otherwise) and the reviewed commit — not a signature.
The risk is deliberate: `homelab-apps` is one unsupervised repository, and a
cosign key there would sign whatever that repository's automation produced.

The plan's per-app memory, CPU and task limits are unit settings, so they bound
each container's cgroup directly. The tenant user's `/var` home (image layers, container storage) is not
on a dataset and has no quota yet — the accepted gap until a dataset or quota is
designed for it.

## What applies a revision

`scripts/deploy-apps.sh` is the only writer of the tenant, and the deploy
receiver (#798) is the only thing that runs it: `deploy-apps apply --commit
<sha>` for a queued apps request, `deploy-apps revert` when an apply has to be
undone. Nothing on the host pulls `homelab-apps` on its own.

**Verification first, on the host.**
`image/rootfs/usr/libexec/deploy-verify.py --repo homelab-apps --commit <sha>`
refuses the commit unless it is off the denylist, is the tip of `main` *now*,
is not the deployed commit, and `compare/<deployed>...<commit>` answers `ahead`
— descendancy in one request, against the ancestor `state.json` records. No
commit-signature check: signed commits are not required in this repository
(operator decision above), and tip + descendancy + the validator are what
actually bound a commit. A rejection is final — the drain pops the entry and
the same commit is refused at the listener and by the poll until an operator
runs `smortress-deploy unblock commit <sha>`. An operator can refuse a commit the
same way, without waiting for a rejection: `smortress-deploy block commit <sha>`.

**Then the apply, in this order**, with a revert path behind every step:

1. **Fetch and render.** The commit tarball from `codeload.github.com` is
   extracted into `/var/lib/homelab/deploy/work/apps-<commit>/tree`. The
   tenant's `secrets.sops.json` is decrypted once (machine identity) and handed
   to `apps-schema validate --root <tree> --secrets <file>`, then to
   `apps-schema render --root <tree> --out render.next --secrets <file>`.
   `render` runs with `--allow-empty`, which the deploy alone uses: without it a
   tenant could be filled but never emptied, and Serve's existing
   empty-plan pruning would never run. A rejected definition stops here, the
   installed plan untouched, and the commit is denylisted and paged.
2. **Free space.** The floors are 10 GiB on `/var/home/apps` (the pulled
   layers) and 8 GiB on `/` and `/var` (container store, ostree staging), and
   they are checked *before* the apply record is written: a host that cannot
   hold the images is refused while nothing at all has been recorded, so a retry
   after space is freed starts from a clean state instead of reverting an
   apply that never pulled anything.
3. **Record before mutating.** `apply.json` (`phase: pulling`, previous and
   intended unit sets, the previous plan, the previous secret values as
   root-only `0600` files under `work/prev-secrets/`) is written, and the
   previous render tree is kept as `render.prev` until the apply commits. This
   record is what a crash is reverted from.
4. **Pull everything.** Every changed image is pulled by digest as the tenant —
   `runuser -u apps -- podman pull --signature-policy=/usr/share/smortress/apps-policy.json`
   — under a 1800 s deadline. The policy flag names a policy that accepts
   anything, so the pull proves reachability and nothing about the bytes; the
   digest in the reference is what the plan pinned. One failed pull aborts with
   nothing changed, so "pull everything, then change anything" holds: no
   half-revision ever runs.
5. **Plan, then quota.** `plan.json` is installed atomically as
   `/var/lib/homelab/apps/plan.json`, then `smortress-apps-quota.service` is
   restarted so the applier reads the new plan and creates the new apps'
   directories and ZFS project quotas *before* anything starts. The unit is
   `RemainAfterExit=yes`, so `restart` is what re-runs it.
6. **Units, secrets, ingress.** As the tenant, from `/` with
   `XDG_RUNTIME_DIR=/run/user/<uid>`: install the rendered units into
   `~apps/.config/containers/systemd`, remove the units and Podman secrets of
   apps that left the plan, `podman secret create --replace` the changed values
   (rotation included; `rm` then `create` fails on an in-use secret),
   `systemctl --user daemon-reload`, start the new apps, restart the changed
   ones, stop the removed ones, and start/stop
   `smortress-app-ingress@<name>` to match. Root never writes inside the
   tenant's home: every write there runs as the tenant through `runuser`.
   Every app this step started or restarted must then answer health: one
   `systemctl show -p ActiveState -p NRestarts` must read `active`, first
   within `APPS_HEALTH_WAIT_TIMEOUT` (180 s) and then through an
   `APPS_HEALTH_SETTLE` (15 s) window with the restart counter unchanged. The
   counter is what catches a container that starts and exits: `Restart=` brings
   it back fast enough that every sample can still read `active`, while
   `NRestarts` moves. A probe that cannot reach the tenant manager is retried,
   never read as unhealthy; a window that ends without an answer, a `failed`
   state, or a probe cut short because the apply budget is spent
   (`budget-exhausted`) are failures. Apps the commit did not touch are not
   checked, because an apply cannot repair a revision it did not write, and
   refusing every later commit over one stale down app would also refuse the
   commit that fixes it. A failure reverts the apply, journals `apps-unhealthy`
   with the unit and what was seen, and journals `apps-failed` with
   `reason: app-unhealthy`. The drain retries an exit 5 every 300 s, so a
   revision that cannot stay up keeps being attempted (the queue's `attempts` is
   the signal) until it is fixed forward or until an operator runs
   `smortress-deploy block commit <sha>`, which makes the next attempt the
   verifier's refusal. The apply-time check
   covers the unit-active third of what the tenant prober asks: an app that is
   `active` but never binds its loopback port is still a failure, and the
   five-minute `smortress-apps-health.timer` is what finds it. That prober is the
   whole tenant half — the unit, the loopback port and the Serve path — because
   the boot gate judges the host and no longer the tenant. An app down an hour
   after the boot is an apps revision, and rolling the platform image back for one
   was the wrong coupling: the gate's rollback has to mean the platform failed.
   That is why neither `smortress-tailscale-serve` nor `smortress-apps-quota`
   is on the gate's unit list — both read this plan and both exit 1 on a plan they
   cannot act on — and why the apply, not the gate, is what refuses a revision.
   The prober reboots nothing, stages nothing and rolls back nothing, and it
   stands down while `apply.json` says an apply is in flight. It journals
   `apps-health-failed` with the app and the reason — the tenant's signal until it
   has a Healthchecks check of its own (`docs/core/server-image.md`).
7. **Commit, then Serve.** `state.json` records the commit and the unit and
   secret content hashes, `apply.json`, `render.prev` and `work/prev-secrets/`
   are removed, and `smortress-tailscale-serve.service` is restarted. It is a
   `RemainAfterExit` oneshot, so without the restart a new app has no route and
   a removed app keeps one. A Serve failure here is journaled and paged but
   does not revert the revision: Serve also fails on unrelated dataset
   absenteeism, and a healthy apps revision must not be rolled back for a route.

**Revert.** A failure after the first mutation restores every changed unit from
`render.prev`, the previous plan and secret values, restarts the changed apps,
starts the removed ones again, regenerates Serve and clears the record.
`apply.json` is also the crash state: an apply interrupted by a reboot is
reverted by the boot gate at the next boot — before it decides anything, because
the tenant may be half of two revisions, and the tenant prober stands down while
the record exists — or by the drain before it acts on the queue. An apps deploy
reboots nothing, so it has no boot gate and no boot counting; the platform half of
the receiver, and the pre-userspace counter that covers it, are in
`docs/core/server-image.md`.
