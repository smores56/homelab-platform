# Core server image (T2)

The smortress core is one immutable uCore bootc deployment, configured by this
repository and nothing else. There is no Nix on the host, no k3s, no Flux and no
Ansible. Podman Quadlets are the only container control plane; ZFS recovery
datasets under `/var/srv` and `/var/lib` are the only service-data layout.

This document covers the image, its signing policy, the Ignition install and the
rollback path. Operator-only actions are in `docs/manual-steps.md#install-a-host-from-the-image`.

## What the image contains

| Path | Purpose |
| --- | --- |
| `/etc/containers/policy.json` | Default-reject policy; trusts the uCore keys by path and `ghcr.io/smores56/homelab-platform` through `/etc/pki/containers/smortress.pub`. |
| `/etc/containers/registries.d/ghcr.io-smortress.yaml` | Enables cosign signature lookup for our GHCR repository. |
| `/etc/pki/containers/smortress.pub` | Public half of the operator cosign key. The private half is an environment secret and a recovery-kit item. |
| `/usr/bin/{sops,age,age-keygen,restic}` | Hash-pinned release binaries from `bootc/lib/pins.env`; no distribution drift. |
| `/var/lib/smortress/secrets/*.json` | The SOPS bundles `boot.json`, `apps.json` and `agents.json`, root-only (`0700` dir, `0600` files), on `/var` so an image never overwrites it. `bootc/server/rootfs/usr/share/smortress/secrets.manifest` fixes each output's bundle, dotted key, decrypted owner, group, mode and format; the seed copies it over `/etc/smortress/secrets.manifest` at every boot, because bootc keeps a host's `/etc` across a rebase. The image also carries a copy of the ciphertext under `/etc/smortress/secrets`, which only seeds a host that has none yet (`scripts/smortress-secrets-seed.sh`). |
| `/usr/lib/systemd/system/zfs-ready@.service` | One readiness instance per recovery group; verifies the mount, not the directory. |
| `/usr/lib/systemd/system/sops-decrypt.service` | Boot-ordered decrypt into `/run/smortress/secrets`. |
| `/usr/lib/systemd/system/smortress-password.service` | Re-applies the `smores` account password hash through `chpasswd -e` at every boot from `/run/smortress/secrets/smores-password-hash.yaml`; bootc never reconciles `/var`, so `/etc/shadow` would otherwise be whatever the install left there. |
| `/usr/libexec/smortress-password` | `scripts/smortress-password.sh`: the sha512crypt guard and the single `chpasswd -e` write, the hash on stdin and never in argv, so no hash handling lives in a unit line. |
| `/usr/lib/systemd/system/smortress-zpool.service` | Creates or imports the `smortress` pool on the encrypted data device. |
| `/usr/lib/systemd/system/smortress-cryptsetup-hdd.service` | Opens the HDD LUKS with its keyfile; non-blocking by contract. |
| `/etc/firewalld/zones/tailscale.xml` | Binds `tailscale0`, permits SSH and Syncthing's 22000/tcp+udp; the default zone is `drop`. |
| `/etc/ssh/sshd_config.d/05-tailnet-ssh.conf` | The one sshd drop-in (design #767). No `ListenAddress` at all, so sshd listens on every local address and the firewall decides who reaches it: the default zone is `drop` and only `tailscale0` accepts `ssh`. No TCP or stream-local forwarding, but agent forwarding is on: the socket relays signature requests to an oracle the client holds, and `pam_rssh` reads the one sshd creates at `~/.ssh/agent`, so `no` there would leave the sudo tap without an agent. `AllowUsers smores`, key-only auth, and the `Match Address 127.0.0.1,::1` block that stops uCore's `90-enable-localhost-passwords.conf` from re-enabling password auth on the loopback route Cockpit still uses. It sorts at `05-` because sshd keeps the first value it obtains in the second config pass. `PubkeyAuthOptions` is deliberately unset, so a per-key option on an `authorized_keys` line stays the whole sk policy. |
| `/etc/ssh/authorized_keys.d/smores` | The one login key: a single `ssh-ed25519` line for `smores@smortress`, root-owned `0644` under `etc_t`, so sshd opens it as root and a key change arrives with `bootc upgrade`. It is the `AuthorizedKeysFile`; nothing reads `~/.ssh` and no Ignition step delivers a key. No FIDO handle, because a resident `sk-` credential is generated with a token and cannot be reviewed in git. |
| `/usr/lib/systemd/system/smortress-tailscale-ssh-off.service` | Re-asserts `tailscale set --ssh=false` at every boot; tailscaled persists the preference, so removing the flag from the enrollment unit is not enough. Tailscale SSH is retired. |
| `/etc/pam.d/sudo` and `/etc/sudoers.d/10-human-gate` | The sudo gate (design #767, T8): a touch on the YubiKey held by the client, with the account password behind it. `pam_faillock` preauth, `libpam_rssh.so` against `/etc/ssh/sudo_authorized_keys` with `cue` (`success=2` reaches `authsucc`; a bare `sufficient` would end dispatch there and the faillock tally would never clear), `pam_unix try_first_pass` as the fallback behind it (`success=1` reaches the same `authsucc`, so either factor clears the tally), then `authfail` and `authsucc`. Every non-success from `pam_rssh` — no `SSH_AUTH_SOCK`, a dead socket, an absent key, a refused touch, and never `PAM_IGNORE` — is ignored and lands on the password, which is the break-glass everywhere: there is no console row any more. A 30-minute ticket per TTY and `log_subcmds`. `Defaults env_keep += "SSH_AUTH_SOCK"` is required: sudo drops the socket from the environment before the PAM stack runs, so without the keep `pam_rssh` finds no agent, logs "SSH agent socket address not configured", and every escalation silently falls back to the password (verified on the host 2026-11-20). The base's `/etc/sudoers.d/coreos-sudo-group` (`%sudo ALL=(ALL) NOPASSWD: ALL`) is deleted by the build, because a `NOPASSWD` line reaches `authsucc` without consulting `pam_authenticate` and would void the touch, the password fallback and the tally together; what remains is the base's own `%wheel ALL=(ALL) ALL`, and `smores` is in `wheel`, so the gate governs every escalation. The build fails if `NOPASSWD` reappears anywhere in `/etc/sudoers` or `/etc/sudoers.d`. `docs/manual-steps.md` section 44 enrolls the credential on each key, proves the tap and the fallback, and carries the AVC drill. |
| `/etc/ssh/sudo_authorized_keys` | The sudo credentials' public halves only, root-owned `0600`: `sk-ssh-ed25519` lines, never `no-touch-required`, because the touch option is fixed at enrollment. Root-owned and not `AuthorizedKeysFile`, so the login credential cannot satisfy sudo and the sudo credential cannot satisfy ssh. Empty until the owner enrolls the keys; an empty list is `PAM_AUTH_ERR`, so the password works in the meantime. |
| `/usr/lib64/security/libpam_rssh.so` | `z4yx/pam_rssh` at the tag and commit pinned in `bootc/lib/pins.env`, built in the image's `sudo-build` stage with the `dep/ssh-agent.rs` submodule and `--locked`, linking the base's openssl and libpam. Not packaged for Fedora, so a cdylib copied from anywhere else would be an ABI mismatch at the first prompt. |
| `/usr/share/smortress/quadlet/pattern.container` | Quadlet base pattern; not enabled, no `[Install]`. |
| `/usr/share/containers/systemd/*.container` | The application Quadlets (T5). A quadlet is a generated unit, so `[Install]` is what starts it; the image never runs `systemctl enable` for one. |
| `/usr/lib/systemd/system/smortress-app-secrets.service` | Turns the decrypted application secrets into Podman secrets before any container that declares one starts. |
| `/usr/lib/systemd/system/smortress-tailscale-serve.service` | Re-declares the Tailscale Serve routes at boot; Serve state is not backed up. |
| `/usr/lib/systemd/system/smortress-backrest.service` and the two `smortress-backrest-watchdog` units | The R2 recovery reader and its watchdog, moved here from the public edge (SDLC #953). The unit renders Backrest's config from `/etc/backrest/env` — the one place the restic password and the corpus-read R2 pair live — and starts the guard, which owns `127.0.0.1:9898` and starts the pinned binary on `127.0.0.1:9899`. The index under `/var/lib/backrest` is a cache and is in no recovery group. |
| `/usr/libexec/smortress-backrest`, `/usr/libexec/backrest-guard`, `/usr/libexec/smortress-backrest-entrypoint` | The reader's three programs: the hash-pinned release binary (`bootc/lib/pins.env`), the read-only guard, and the renderer the unit starts the guard through. |
| `/usr/lib/systemd/system/smortress-immich-dump.{service,timer}` | The logical Immich restore point inside the photos group, at 21:00 UTC, three hours before the R2 run. |
| `/usr/share/containers/systemd/{agent-local,agent-general}.network` | The two agent networks: one with no default route (no route off the host) and one plain bridge (egress, for the hosted proxy). |
| `/usr/share/containers/systemd/{agent-model,agent-local,agent-general,agent-proxy,agent-webui-personal,agent-webui-general,agent-workspace-personal}.container` | The agent deployment Quadlets: the pinned llama.cpp server, the two Hermes gateways, the hosted-model proxy, one browser UI per deployment and the personal Workspace (which shares `agent-local`'s network namespace). |

| `/etc/smortress/agent/{local,general}-config.yaml` | The runtime config templates `smortress-agent-config.service` copies into each state dataset on first boot. No key, no credential and no `mcp_servers` entry: the plane is a mount, not an MCP server. |
| `/usr/lib/systemd/system/smortress-agent-config.service` | Seeds each gateway's `config.yaml` (`cp -n`), rewrites `.env`'s `API_SERVER_KEY` and `webui.env`'s gateway key and UI password at every boot, writes the personal Workspace's `/run/smortress/workspace.env` (`0:0 0400`, outside the agent's dataset), and creates each gateway's memory root, the source watcher's feed directory, and each UI's state and workspace directories; the Workspace's own state is a named volume. |
| `/usr/libexec/agent-config-seed` | `scripts/agent-config-seed.sh`: the seeding itself, so the token is read from a file into a variable instead of being spliced into an `ExecStart` line. |
| `/usr/lib/systemd/system/smortress-nvidia-cdi.service` | Generates `/etc/cdi/nvidia.yaml` at boot so `AddDevice=nvidia.com/gpu=all` resolves for the model container; ordered before it. |
| `/usr/libexec/deploy-verify.py`, `/usr/libexec/deploy/policy.json` | The host's own verification: tip of `main`, descendancy from the deployed commit, tag `sha-<commit[:12]>` → digests, `org.opencontainers.image.revision` label, denylist. Anonymous GitHub and registry calls, 30 s each. One program runs on both hosts (`lib/deploy/verify.py`); what differs is the table installed beside it (`lib/deploy/policy.d/server.json`), which names the repository allowlist, the image repository, the 120 s API cache window, what an absent image means, and which gate has the last word. The questions themselves are pure functions in `/usr/libexec/deploy/decisions.py` (`bootc/lib/deploy/`), and `bootc/lib/deploy/fixtures/` pins the answers both tables have to produce. |
| `/usr/libexec/{deploy-state,deploy-drain,deploy-platform,deploy-apps,deploy-poll}` | `scripts/deploy-*.sh`: the state library, the queue drain (single writer of `state.json`), the platform snapshot gate and stage, the apps apply and revert, and the quarter-hour deploy poll, which is also the deploy dead-man. The apps apply sources its phases from `/usr/libexec/deploy/apps/` (`scripts/deploy/apps/*.sh`). |
| `/usr/libexec/smortress-boot-gate` | `scripts/smortress-boot-gate.sh`: reconciles an interrupted apps apply, then keeps or rolls back the deployment this host just booted. |
| `/usr/libexec/smortress-deploy` | `scripts/deploy-cli.sh`, staged under the name the runbook uses: `status`, `release --force`, `unblock`, `bootstrap`. |
| `/usr/libexec/smortress-apps-health` | `scripts/smortress-apps-health.sh`: the tenant's prober. For every app in `plan.json`, the Quadlet's unit active in the tenant's manager, the plan's loopback port accepting a connect, and the app's base path declared by Serve. Journals `apps-health-failed` with the reason, the app and the unit, and pings the tenant's own Healthchecks check: green on a healthy tick or an apply in flight, `/fail` with the reason on a broken one. Reboots, stages, rolls back and reverts nothing, and never touches the deploy check. |
| `/usr/lib/systemd/system/smortress-deploy.path`, `/usr/lib/systemd/system/smortress-deploy.service` | The queue trigger (`DirectoryNotEmpty=/var/lib/homelab/deploy/queue`) and the one drain of it, `TimeoutStartSec=12600`. |
| `/usr/lib/systemd/system/smortress-deploy-poll.timer`, `/usr/lib/systemd/system/smortress-deploy-poll.service`, `/usr/lib/systemd/system/smortress-deploy-retry.timer`, `/usr/lib/systemd/system/smortress-boot-gate.service` | The quarter-hour deploy poll (the only trigger and the deploy dead-man, design #1010), the five-minute retry of a deferred queue entry, and the gate that runs `Before=boot-complete.target`. |
| `/usr/lib/systemd/system/smortress-apps-health.timer`, `/usr/lib/systemd/system/smortress-apps-health.service` | The five-minute probe of the tenant's apps, `OnBootSec=5min` then `OnUnitActiveSec=5min` with `Persistent=false`: a host that was off owes no probe for the window nothing was running. Ordered after `smortress-tailscale-serve.service`, because a base path is checked against the routes that unit declares. |
| `/usr/share/smortress/deploy-units.txt` | The units the boot gate requires: what "serving" means for this host. The deploy units are deliberately absent — a queue that is not draining must page, not roll the host back — and so is every unit that reads the tenant's plan (`smortress-tailscale-serve`, `smortress-apps-quota`), because one that exits 1 on an app definition would denylist the platform digest for an app's fault. |
| `/boot/grub2/custom.cfg` | greenboot's three-attempt boot counter, installed by `smortress-boot-counter.service` from `/usr/share/smortress/boot-counter.cfg`. `grub.cfg` ends with `41_custom.cfg`, which sources this file, so it is how counting works without bootupd (`docs/manual-steps.md#the-boot-gate-and-its-counter`). The gate reads this file to decide whether the counter is armed. |
| `/etc/systemd/system.conf.d/10-watchdog.conf` | `RuntimeWatchdogSec=1min`, so a hung PID 1 becomes a reboot. No `kernel.panic`: without a bootloader counter, a panic reboot would loop the same image. |
| `/etc/tmpfiles.d/smortress.conf` | Creates `/var/lib/homelab/deploy`, `queue` and `work` at `0700 root`: the deploy queue's state tree, outside every recovery group because the journal and `bootc status` rebuild it. |

`units/quadlet/pattern.container` is the canonical copy in the repository; the
image ships it read-only as the base for a new application. A placeholder
container must never be started automatically. The seven application Quadlets in
`units/quadlet/*.container` are installed into `/usr/share/containers/systemd`
and start from their own `[Install]` section; see `docs/core/applications.md`.

## Base pin

`bootc/lib/pins.env` holds every external reference the image consumes. The base is
not pinned to a digest: it tracks the multi-arch uCore stream tag

```text
ghcr.io/ublue-os/ucore:stable-nvidia
```

`stable-nvidia` is deliberate: uCore ships the NVIDIA userspace and the OpenZFS
module used by `smortress`. The tag is what the build asks for; every other
reference here (host binaries, `pam_rssh`, the tool pins) is hash-pinned, and the
application and Quadlet images stay digest-pinned.

The trade is explicit. The base is always current, with no digest
reproducibility: upstream publishes new stream builds constantly and ghcr/quay
garbage-collect superseded digests within hours, so a pinned base digest rots
into a `manifest unknown` build failure (three times in one day). What replaces
the pin is a record plus a counterweight: `scripts/build-image.sh` and the publish
workflow resolve the tag's digest at build time, pass it as the `BASE_DIGEST`
build arg, and the image carries it in
`org.opencontainers.image.base.digest` (the tag goes in
`org.opencontainers.image.base.name`); the publish run summary prints the same
reference. A built image therefore still says exactly what it was built on, and
the guards on the result are `scripts/check-server-image.sh`, the cosign
signature on the derived image and `bootc rollback`.

The base already provides what the design needs, verified by inspecting the
image: the ZFS kernel module and tools, Podman with the Quadlet generator,
firewalld, Tailscale, clevis with the sss/tang/tpm2 dracut pins, and the
`podman-system-generator` symlink. It does not ship `sops`, `age` or `restic`; the Containerfile adds the
hash-pinned release binaries instead of layering distribution packages.

The image layers no distribution package. sudo's touch factor is `pam_rssh`,
which Fedora does not package, so it is built in a `sudo-build` stage from the tag
and commit pinned in `bootc/lib/pins.env` and arrives as a `.so`. It cannot be copied
from elsewhere: the module links the base's openssl and libpam, so a foreign
build is an ABI mismatch waiting for the first sudo prompt. No local SELinux
policy ships — sudo runs `unconfined_t` on this base, so there is nothing to
allow and `sudo_t` does not exist to name. The build fails if
`libpam_rssh.so` or the sudo key file is absent, if the retired OATH module is
present, or if the image carries no `semodule` for the loader unit.

## Build, push and sign

```sh
scripts/refresh-pins.sh                   # informational: the digest the tag resolves to now
scripts/build-image.sh                    # local build; resolves the base digest, never pushes or signs
scripts/verify-image.sh ghcr.io/smores56/homelab-platform/server@sha256:<digest>
```

`refresh-pins.sh` prints `<tag>@<digest>` and changes nothing: the base is a tag,
so there is no pin to refresh and `--check` has no base drift to report. The
digest that matters is the one a build actually used, and that is on the image
and in the run summary.

CI is `.github/workflows/publish-server-image.yml`: a push to `main` touching
`bootc/server/`, `units/`, `secrets/` or `scripts/`, or a manual dispatch. The job:

1. verifies that `secrets.COSIGN_PRIVATE_KEY` corresponds to the committed
   `lib/containers/cosign.pub` before building anything;
2. resolves the base digest — `skopeo inspect --format '{{.Digest}}'
   docker://ghcr.io/ublue-os/ucore:stable-nvidia` — fails the job if that fails,
   exports it as `BASE_DIGEST` and prints the reference in the run summary;
3. builds with `scripts/build-image.sh`, which passes `BASE_IMAGE` and
   `BASE_DIGEST` to the Containerfile, so the image's
   `org.opencontainers.image.base.digest` label names the base this run built
   on (every tool pin is still hash-pinned);
4. pushes `sha-<first 12 of the commit>`, reads the registry digest from
   Podman's `--digestfile`, signs that digest with
   `cosign sign --key env://COSIGN_PRIVATE_KEY`, and verifies it against the
   committed public key;
5. moves `:latest` onto that digest, from `main` runs only and only after the
   signature verified;
6. prints the digest for the operator to pin in
   `ignition/operator/derived-image`.

The workflow is never triggered by `pull_request`, holds no secret in that
case, and every action is pinned to a 40-character commit SHA
(`scripts/check-action-pins.sh`). `scripts/check-pr-secret-boundary.sh` still
passes.

Signing key handling: the private key is an environment secret on the
`server-image` environment and a file in the offline recovery kit. It is never
committed, never in an image layer, and never in a rendered Ignition file.
Rotating it means re-signing the running digest before replacing
`lib/containers/cosign.pub`, otherwise `bootc` rejects the next switch.

## Signature enforcement

The image inherits uCore's default-reject policy and adds our repository. The
policy is not a file in the host tree: `lib/containers/policy.json` is the half
every host shares (default reject, and the transports that never reach a
registry) and `lib/containers/policy.d/smortress.json` is this host's table, so
the image, the Ignition render and the publish job all render one document
through `lib/containers/render-policy.sh` (SDLC #1024):

```json
"ghcr.io/smores56/homelab-platform": [
  { "type": "sigstoreSigned",
    "keyPath": "/etc/pki/containers/smortress.pub",
    "signedIdentity": { "type": "matchRepository" } }
]
```

`/etc/containers/registries.d/ghcr.io-smortress.yaml` sets
`use-sigstore-attachments: true`, which is what makes `containers/image` fetch
the cosign signature from GHCR. Without it, policy says reject before any
signature is looked for.

Ignition also writes the same policy, registries.d file and public key, so the
second auto-rebase stage (the signed reference) sees them even though it runs
before bootc takes over. `bootc switch` takes `--enforce-container-sigpolicy`;
`bootc upgrade` has no such flag and honors the container policy regardless, so
a reference without a valid signature is refused by either command.

The login key is image content, not Ignition content:
`/etc/ssh/authorized_keys.d/smores` ships with the one `ssh-ed25519` line and the
`05-` drop-in points `AuthorizedKeysFile` at it. It replaced the Ignition-delivered
`/var/lib/homelab/.ssh/authorized_keys`, which existed only because bootc does not
reconcile `/var`: sshd opens `AuthorizedKeysFile` with the target user's uid, so
that path needed a smores-owned directory under a `0711` traversal plus the
`ssh_home_t` label Fedora's `file_contexts` gives `/.ssh`, and a hand-written key
could drift from the deployment. `/etc/ssh` is `etc_t` and world-readable and the
shipped file is root-owned `0644`, so sshd reads it as root: no ownership
machinery, no label step, and a key change is one commit and one `bootc upgrade`.

## Install path

The supported uCore path is a Fedora CoreOS install that auto-rebases to uCore,
not a direct `bootc switch` from FCOS. `ignition/smortress.bu` is derived from
`ucore/examples/ucore-autorebase.butane` at
`75ec7d8d10bc8af6fe23a284ea108bacd50f3173`; both image references point at our
derived image:

- `ucore-unsigned-autorebase.service` rebases through
  `ostree-unverified-registry:<derived digest>`, touches the marker and reboots;
- `ucore-signed-autorebase.service` then rebases through
  `ostree-image-signed:docker://<derived digest>`, touches the signed marker and
  reboots.

Ignition's root LUKS creation uses FCOS root reprovisioning, which requires at
least 4 GiB of RAM on the target. The rendered Ignition is installed with:

```sh
sudo coreos-installer install "$(cat ignition/operator/disk)" \
  --ignition-file ignition/smortress.ign \
  --append-karg ip=dhcp --append-karg rd.neednet=1
```

`ip=dhcp` and `rd.neednet=1` are required for dracut to reach Tang before the
root LUKS is opened. The Tang thumbprint is pinned in the Butane source from
`ignition/operator/tang-thumbprint`; the renderer refuses an empty or malformed
value rather than trusting a first-seen advertisement. After both reboots:

```sh
sudo rpm-ostree status
sudo journalctl -u ucore-unsigned-autorebase.service -u ucore-signed-autorebase.service --no-pager
```

The booted deployment must be the derived digest with the signed reference.
Only then does bootc own the system:

```sh
sudo bootc status
sudo bootc switch --enforce-container-sigpolicy <derived digest>
sudo bootc upgrade
sudo bootc rollback
```

`bootc rollback` reverts the deployment, not `/var`, the ZFS datasets or a
database migration. Application and base images are pinned; `podman-auto-update.timer`,
`rpm-ostreed-automatic.timer` and `zincati` are masked. `bootc-fetch-apply-updates.timer`
is not: `bootc/server/Containerfile` enables it at build time and fails the build if
it is masked, absent or off its window, so this host is meant to upgrade itself. The
window lives in exactly one place, the image's
`bootc/server/rootfs/usr/lib/systemd/system/bootc-fetch-apply-updates.timer.d/10-schedule.conf`
(05:00 America/New_York, the vendor's boot+1h and 8h cycle cleared, no jitter,
`Persistent=false`); no other file carries a second one.

## What each host reports

The reference a host boots is the fact that decides which mechanism can move it, so
it is measured rather than assumed. `sudo rpm-ostree status` on 2026-11-27:

| Host | Booted reference | Active digest | Version | What moves it |
| --- | --- | --- | --- | --- |
| smortress | `ostree-image-signed:docker://ghcr.io/smores56/homelab-platform/server:latest` | `sha256:446846eea0313040d3a58f6a81b38dbf5979ae9569d5109077f38b73385a4ba3` | `45.20261030.3.1 (2026-11-27T03:06:28Z)` | the tag: the update timer stages `bootc upgrade` in its 05:00 window (`AutomaticUpdates: stage`, and a second deployment of the same `:latest` was already staged), and the next reboot boots it |
| smoresnet | `ostree-image-signed:docker://ghcr.io/smores56/homelab-platform/edge:latest` | `sha256:3657b35e128e40f6b31e7cdb77da61701803207788c71626591a95110afb657c` | `45.20261030.3.1 (2026-11-27T03:03:35Z)` | the same `bootc upgrade` on the tag, in the edge image's own 04:00 window (`docs/core/public-edge.md#host`) |
| smorespro (laptop) | `ostree-image-signed:docker://ghcr.io/smores56/smorespro-image:latest` | `sha256:52a74ef36d0826bc825a76587f2d5ee81bb89ef377a7fcdd46cfd7030b6e7d80` | `45.20261124.0 (2026-11-25T04:24:00Z)` | `bootc upgrade` on the tag; that image is `smorespro-image`, a separate repository, and it owns its own schedule |

All three boot a tag, so on all three `bootc upgrade` is a live deploy path: what
`:latest` names is staged by the update timer and becomes the booted deployment at
the next reboot. The other mechanism is `bootc switch ...@sha256:<digest>`, which is
what the deploy's stage runs: it leaves the host on that digest, and from then on
`bootc upgrade` has no tag to follow and only another switch moves the host. Both
paths check the same signature policy; they differ in who chose the digest and in
whether the host can move with no operator involved.

One measured caveat, and it is task #1014's: `smortress-deploy-poll.timer` reads
`disabled` on smortress, disabled by a live-only
`/etc/systemd/system/smortress-deploy-poll.timer.d/10-window.conf` that the image
does not ship, so the quarter-hour poll is not the path moving this host today.

## Moving a host forward by hand

`bootc upgrade` only re-checks the reference the host was last switched to, so a
host switched to a digest never moves and the operator switches it to the new
digest. Every host above boots the tag instead, and CI moves `:latest` onto every
signed `main` build, so on those `bootc upgrade` alone is the update; the switch
below is the digest path, kept for the host that must not follow a tag:

```sh
# Break-glass only: switch to the digest the deploy verified.
sudo bootc switch --enforce-container-sigpolicy \
  ghcr.io/smores56/homelab-platform/server@sha256:<verified-digest>
```

Signature policy applies to the tag unchanged: `signedIdentity: matchRepository`
authorizes any reference in `ghcr.io/smores56/homelab-platform`, and the
signature is attached to the digest the tag resolves to, so a tag that points at
an unsigned or branch-built digest is still refused.

What the tag gives up is the deploy's descendancy check: the poll's verifier
refuses a signed image whose commit does not descend from the deployed one, and
nothing runs that comparison for a bare `bootc upgrade`. Moving
`:latest` backwards therefore deploys an older build, which is why only `main`
runs may move the tag. That trade is the one every host above has taken: the timer
follows the tag in the window and no comparison of the new commit against the
deployed one happens on the host, so a host that must not drift is one the
operator switches by digest.

`bootc rollback` boots the previous deployment. A deploy stage names a digest, so
the next deploy cannot silently re-stage the escaped build; on a host that boots
the tag the timer stages whatever `:latest` names, which is the trade above, not a
second guard. The deploy record can still name the staged digest after a rollback;
the next successful stage and boot gate overwrite it.

The install path keeps a digest (`ignition/operator/derived-image`): a fresh host
must come up on the build that was verified, not on whatever `:latest` names.

## The deploy path

The image is the only delivery, and the host is the only one who asks: since
#1018 nothing reaches in, so a merge to `main` lands when the poll next runs and
not before (design #1010). Its authority is the host's own: the trigger is a
timer on this box, and each decision is re-derived here from the GitHub commit
graph, the registry tag, the image's own label and the signature `bootc` checks.
A request that fails any check changes nothing and leaves the last good
deployment running.

### The trigger

`smortress-deploy-poll.timer` on this host is the trigger: every fifteen minutes
it asks GitHub whether the newest published image differs from the recorded one
and, if it does, writes one `queue/<uuid>.json` naming the repository and the
commit. No listener, no credential and no tailnet grant is involved, which is what
retired the notify path (#1018): the host reaches out and nothing reaches in.

The queue entry is the whole of the request:

```json
{"schema": 1, "id": "<uuid>", "repo": "homelab-platform", "commit": "<40-hex>", "queued_at": <unix>, "source": "poll"}
```

Nothing an entry says is trusted. The repo has to be one this host deploys (the
queue is capped at 32 entries and a foreign repo would take a slot a platform
deploy needs), and the commit is re-derived against GitHub and the registry by
the verifier below before anything is staged.

### The drain

`smortress-deploy.path` watches the queue with `DirectoryNotEmpty=`, and
`smortress-deploy.service` drains it as a oneshot under
`flock /run/smortress-deploy/deploy.lock` — its own `RuntimeDirectory=`, never
`/run/smortress`, which holds the decrypted secrets and stays read-only to every
deploy unit: strict FIFO, except that a newer request for the same repository
replaces an older pending one, with one rescan before exit.
It is the single writer of `state.json`. `TimeoutStartSec=7200` bounds a wedged
drain, and every external command inside it has its own deadline.

The drain's loop is `bootc/lib/deploy/drain.sh` and the answers it acts on are
`bootc/lib/deploy/decisions.py`, both installed under `/usr/libexec/deploy/`;
`scripts/deploy-drain.sh` is only the server role's part -- the snapshot gate, the
stage and the tenant apply. `/usr/libexec/deploy-verify.py` -- the same program
the edge installs, run under this host's `/usr/libexec/deploy/policy.json` --
answers "may this commit deploy" for every entry, fail-closed and journaled with
the reason:

1. The commit is off the denylist, is the tip of `main` *now*
   (`GET /repos/smores56/<repo>/git/ref/heads/main`), is not the deployed commit,
   and `GET /repos/smores56/<repo>/compare/<deployed>...<commit>` answers
   `ahead`. No deployed commit is a `bootstrap-required` rejection, never a guess.
2. Platform only: the tag `sha-<commit[:12]>` is resolved anonymously (ghcr token
   → manifest → `Docker-Content-Digest`, following an index to the amd64
   manifest) and that manifest's config blob must carry
   `org.opencontainers.image.revision` equal to the commit. The digest is
   therefore what the registry says that tag is; the event cannot propose one.
   Both the index and the platform manifest digest are recorded, because `bootc`
   reports either form.
3. The signature is `bootc`'s check at the switch, not ours, so an unsigned or
   foreign digest never stages.

API calls are anonymous and cached for 120 s; each is bounded at 30 s; a
rate-limited answer is an infrastructure failure — the entry stays queued and
the journal says so, and the poll's dead-man pages once one has waited half an
hour.
A rejected commit is popped and never retried, because the next trigger would
fail it identically.

### Platform: snapshot gate, switch, reboot

`deploy-platform prepare` runs the snapshot gate before anything is staged: one
read-only `smortress-restic-verify --local --json` answers with a verdict per
restore unit (newest snapshot for `host,paths`, its `verified` tag, that unit's
max age — 8400 s, or 33600 s for `agent-local`), SSD first and the HDD when the
SSD is absent, and a unit without a fresh verified snapshot is backed up directly
with `smortress-restic-backup --unit <unit> --no-maintenance` (the unit's own
per-attempt deadline plus the 60 s kill-after, so `agent-local` gets 14460 s and
every other unit 1860 s; 900 s of waiting for the hourly driver's unit lock;
17460 s for the whole gate — the longest local backup plus its lock wait and both
verifications; maintenance is excluded so the gate never waits for a prune). A
flat cap here would deadlock the queue on a unit that legitimately needs hours
(issue #139). If no local
repository can take the snapshot, or the budget runs out, the deploy **holds**:
`held.json`, a `/fail` ping, a journal line, and nothing staged. Only
`smortress-deploy release --force`, run by hand as root, releases it.

`deploy-platform stage` follows a green gate: `bootc switch
--enforce-container-sigpolicy ghcr.io/smores56/homelab-platform/server@<manifest-digest>`
(stage only, never `--apply`), then `.status.staged.image.imageDigest` must
equal one of the two digest forms the verifier resolved for the commit. The
switch names the verified digest, never the tag, so a tag that moved between
resolution and switch cannot stage an image nobody verified. It waits for
`ostree-finalize-staged` to publish the entry before writing `pending.json` and
requesting the reboot.

This switch names a digest, so a host it leaves behind is digest-pinned: `bootc
upgrade` has no tag to follow and only the next switch moves it. The host measured
above boots the tag, so until this stage runs `bootc upgrade` on `:latest` is also
a live deploy path. A hand switch by tag bypasses the verifier's descendancy check
and can stage a build nobody verified, so use the digest from the deploy journal.

The sandbox has to re-open `/sysroot` itself, not just `/sysroot/ostree`. bootc's
first act is not a write to a file: `sysroot_is_read_only()` finds `/sysroot`
mounted read-only -- the normal ostree arrangement -- and remounts it writable
before it stages anything. Under `ProtectSystem=strict` that remount is what
fails, and the whole deploy dies as `Initializing storage: Read-only file system`
with nothing staged, on every attempt, while `/sysroot/ostree` sits writable and
unused. The same applies to `bootc rollback --apply` in the boot gate.

### The boot gate

`smortress-boot-gate.service` runs on every boot, `Before=boot-complete.target`
and `After=multi-user.target`, after the same inputs as the drain. It first
reconciles an interrupted apps apply (a bounded `deploy-apps revert`, before any
health check, because the tenant may be half of two revisions), then — only when
`pending.json` exists — compares `.status.booted.image.imageDigest` to the
recorded digests:

- **match.** The host health gate, retried inside 300 s: every unit in
  `/usr/share/smortress/deploy-units.txt` active and none of them `failed`, the
  pool imported, and `/srv/apps` a mountpoint. Success records the deployment,
  sets `boot_success=1`, resets the counter, clears `pending.json` and pings the
  `deploy` check green.
- **no match.** The counter already fell back or an operator rolled back:
  `rolled-back-by-bootloader`, the digest denylisted, a `/fail` ping, the record
  consumed and the GRUB flags reset. A stale `pending.json` therefore cannot roll
  back a healthy host.
- **unreadable.** Nothing is decided: the record stays for the next boot, and the
  counter is what protects the host.

A failed health gate denylists the digest, pages, and runs `bootc rollback
--apply`, resetting `boot_success`, `boot_counter` and `default` so a spent
counter cannot re-select the deployment that just failed.

The split is the whole point of that list being host-only: **the gate judges the
host, the timer judges the tenant's apps.** The gate used to fail its health check
for an app whose unit was inactive, whose loopback port was closed, or whose Serve
path was missing, and roll the host image back for it. That is the wrong coupling
in both directions: a crash-looping app is an apps revision — and one that starts
ten minutes into the boot was never visible to a check that ran once — while a host
image rolled back for a tenant defect teaches the operator nothing about the
platform. The apply refuses to commit a revision whose own apps do not stay up
(`deploy-apps` `check_started_apps`), and what the apply cannot see is the tenant
prober's to report.

### The tenant prober

`smortress-apps-health.timer` runs `smortress-apps-health` every five minutes —
`OnBootSec=5min`, then `OnUnitActiveSec=5min` off the end of the previous probe,
`Persistent=false` — and asks the same three questions about every app in
`/var/lib/homelab/apps/plan.json`: the Quadlet's unit active in the tenant's own
manager (`systemctl --user --machine=apps@.host`), the plan's loopback port
accepting a connect, and the app's `basePath` present in
`tailscale serve status --json`. No plan is a host with no tenant and passes; a
plan that cannot be read is a `plan-unreadable` failure.

A failure journals `apps-health-failed` with the reason, the app and the unit,
and writes the same reason to the unit's stderr; it stops at the first broken app,
so one outage is one line. The journal is the record: read it with
`sudo tail -n 20 /var/lib/homelab/deploy/journal.jsonl | jq -c .` or
`journalctl -u smortress-apps-health.service`.

Paging is the tenant's own Healthchecks check, `apps`, five-minute period and
five-minute grace (`docs/manual-steps.md`, "Create the tenant apps check"): a
healthy tick, a plan with no apps and an apply in flight all ping it green, and a
failure pings `/fail` with `not serving: <reason>` as the body, so the page names
the app instead of only reporting silence. It is deliberately a different check
from `deploy`: one check answered by the poll and by the prober would turn one
crash-looping app into a down/recover pair every quarter hour, and a dead-man
reads one reporter. The URL is read from
`/run/smortress/secrets/healthchecks.yaml` (key `apps-ping-url`, staged in
`secrets/boot.json`'s `healthchecks`), so the prober pages on its own; the one
silent mode is that key being absent, which leaves it journaling without pinging.

An apply in flight passes silently rather than reporting: `deploy-apps` installs
the new plan before it writes the units and restarts Serve, and both the drain
and the gate's revert hold `apply.json` for the whole of that window, so the
record is what keeps a tick from reading a deploy that is still happening as a
revision that broke. The record is read again before a failure is reported, so an
apply that starts mid-probe never becomes a false line on the journal.

It reports and nothing else. It writes no deploy record, reboots nothing, stages
nothing, and rolls back or reverts nothing: a crash-looping app is an apps
revision, and `deploy-apps` already refuses to commit one whose own apps do not
stay up (`check_started_apps`). It is not a boot dependency either: neither
prober unit is listed in `/usr/share/smortress/deploy-units.txt` and neither is
ordered against `boot-complete.target`, so a prober that is missing, stale or
failed costs a journal line and never a boot.

### Below userspace

`bootc` has no boot counting and the gate only runs if userspace starts, so the
image installs greenboot's GRUB snippet as `/boot/grub2/custom.cfg`
(`smortress-boot-counter.service`, `scripts/boot-counter-install.sh`): `grub.cfg`
ends with `41_custom.cfg`, which sources that file, so the counter runs before any
userspace without bootupd. On every boot it sets `boot_success=0` and decrements
`boot_counter` from 3, and at zero it selects the previous deployment
(`default=1`). `greenboot-set-rollback-trigger.service` is greenboot's
staged-deployment hook, installed `RequiredBy=ostree-finalize-staged.service`;
since greenboot 0.16 it records the staged deployment id instead of arming the
counter, so the gate is what keeps it armed (`boot_success=1`, `boot_counter=3`,
no `default`) on every boot it reaches, and only a boot that never gets to
userspace spends an attempt.

The gate's predicate is that file: it journals `boot-counting-absent` only when
`/boot/grub2/custom.cfg` is missing or does not read `boot_counter`, which is the
state a host is in before `smortress-boot-counter.service` has run. The image ships
no `kernel.panic`: a panic that reboots with no counter would loop the same image
forever. `RuntimeWatchdogSec=1min` stays armed, with the same caveat for a PID 1
that hangs on every boot.

Two rollbacks exist. A deployment that boots but fails the health gate is
denylisted and `bootc rollback --apply` reverts it. A deployment that never reaches
userspace is dropped by the bootloader after three attempts, and the gate on that
boot journals `rolled-back-by-bootloader` because the booted digest is not the
recorded one. A host whose counter was never installed has neither: that is a
console recovery, and the recovery point is the pre-reboot snapshot the gate
requires (`docs/manual-steps.md#the-boot-gate-and-its-counter`).

### The two backstops

`smortress-deploy-poll.timer` runs every fifteen minutes and enqueues a request
when the newest published image differs from the recorded one. It is the only
path that deploys an image nobody asked for — the poll is the trigger, not a
window around one (design #1010) — so the interval is the whole of the delay
between a merge and its deployment, and one run is one cached API call per
repository. `Persistent=false` on purpose — a host that was off is not owed every
missed tick on the way up.

The poll is also the dead-man for the deploy plane, which is what #1019
retired `smortress-deploy-heartbeat.timer` for. Each run pings the check's
`/start` and exactly one verdict: green only when no queued request has waited
a poll interval with no drain applying it and no hold is unreleased, and `/fail`
with the reason otherwise. A request nothing is working on therefore pages at
the next tick — the wedge is seen by the run that could have drained
it, not hours later — and the check's own period is the poll interval, so a poll
that stopped running altogether pages on silence. The one case it cannot see is
a drain hung with the lock in hand, which the drain unit's own
`TimeoutStartSec` bounds; a limit low enough to call that stuck would page every
healthy deploy, because the snapshot gate and an apps apply legitimately hold
the lock for hours.

### What a hand-run switch still gives up

`sudo bootc switch --enforce-container-sigpolicy <reference>` still verifies the
signature and still boots, and the GRUB counter still covers a deployment that
never reaches userspace. What it gives up is everything the deploy checks
before and after the reboot:

- the tip and descendancy check, so a signed build from an older commit or a
  divergent branch stages happily (the `:latest` paragraph above is the same
  trade);
- the `org.opencontainers.image.revision` binding from commit to digest, so a
  tag that moved between build and switch is not caught;
- the snapshot gate: nothing proves the restore units have a fresh verified
  local snapshot before the reboot;
- the staged-digest read-back, which is what catches a switch that staged
  something other than the verified manifest;
- the boot gate itself: a hand-run switch writes no `pending.json`, so there is
  no health gate, no denylist entry and no recorded deployment. The record in
  `state.json` stays at the older commit until something else writes it — next
  boot the gate journals `booted-unrecorded` and pages, and leaves the record
  alone. `smortress-deploy reconcile --commit <sha>` is the repair: it reads the
  booted digest from `bootc status` and records it for the commit the operator
  asserts, journaling the previous commit. Neither it nor `bootstrap` (which
  refuses an existing record) is a way to make a hand-run switch look deployed;
  they make the record say what the host is actually running.

### Operating it

`/usr/bin/smortress-deploy` (a symlink to `/usr/libexec/smortress-deploy`,
which is `scripts/deploy-cli.sh`) is the whole operator surface. On smortress
the operator checkout is `/var/home/smores/homelab-platform`; `/srv/git/...` is
the agent workspace and must not be used to run deploy scripts, because the two
can be at different commits. `status` prints the deployed
commits, the tenant's apps table, the held and staged records and both denylist
tables; `release --force`
waives the snapshot gate for the held digest; `unblock` drops one denylist entry;
`bootstrap` records the running commit of a restored host, once, and refuses to
overwrite one. The state
tree is root-only under `/var/lib/homelab/deploy/`, `journal.jsonl` is
append-only and rotates at 5 MiB, and the operator procedure — the two CI
Environments, the three `deploy-*` ciphertexts, the Healthchecks check, the
`bootupctl update`, and how to read a hold — is `docs/manual-steps.md`
section 49.
## Disks and encryption
After a rollback, `status` can name a staged digest the host never booted. The
commit is the descendancy anchor; the digest is only the restore target. Do not
hand-edit `state.json`: the next successful stage and boot gate overwrite the
record. If the recorded commit is not an ancestor of `main`, the deploy refuses
and the host needs the console/restore path, not a state edit.

FCOS owns a fixed raw disk image: `p1` BIOS-BOOT, `p2` EFI-SYSTEM, `p3` boot,
`p4` root. The approved design's "p2 LUKS root, p3 LUKS data" numbering cannot
be produced by that installer without renumbering partitions the raw image
boots from. The supported layout therefore keeps the approved intent — two
encrypted storage volumes on the 980 — as:

| Partition | Use |
| --- | --- |
| `p4` (`root`) | LUKS2 `luks-root`, XFS, 300 GiB; Clevis SSS Tang+TPM2 threshold 2, plus an offline recovery passphrase keyslot the operator adds after the install. |
| `p5` (`luks-data`) | LUKS2 `luks-data`, consumes the remainder; created unformatted by Ignition, formatted on the first boot with a key file the host generates, and opened from that key file. |

Ignition resizes `p4` with `resize: true`/`size_mib: 307200` and creates `p5`
with `size_mib: 0`. Root is 300 GiB because it also carries the container images,
the journal and any restore that does not name a data disk. An installed 100 GiB
host cannot reach that layout in place: a ZFS vdev cannot shrink, so p5 has to be
recreated. The 970 stays a separate ext4 Restic repository disk; the
5 TB HDD keeps its existing LUKS and is opened by
`smortress-cryptsetup-hdd.service` with a keyfile and `nofail` semantics. Its
absence cannot block boot; T3 alerts through backup staleness.

No secret enters Ignition or the installer media (design #701). Root is bound
to Clevis and nothing else: with no key file in the config, Ignition formats the
volume with a key it generates, binds the SSS pin, then removes the generated
key slot, so the only slot left is Tang+TPM2 at threshold 2. The recovery
passphrase does not exist until the operator adds it with
`cryptsetup luksAddKey` (section 37 step 8.1, which also test-opens with it).
Because root has no key file, its generated `/etc/crypttab` entry carries `none`
as the key field and there is no `/etc/luks/root`.

The data key file is the host's own: `smortress-data-init.service` generates
`/etc/luks/data` from the kernel RNG at mode `0400 root`, runs `luksFormat` on
`p5` with it, writes the data `/etc/crypttab` entry and opens the device that
`smortress-zpool.service` creates the pool on. The key stays inside the
encrypted root, so it is not an at-rest bypass by itself — the residual risk is
Dracut copying it into the unencrypted `/boot` initramfs on a later ostree
update, which section 37 step 8.2 checks for. The entry is also why the data
crypttab line must stay out of the initramfs: the device only needs to open
after root. Secure Boot stays off.

## ZFS, readiness and Quadlets

`smortress-zpool.service` creates `smortress` with `cachefile=none`, `ashift=12`,
`compression=zstd`, `atime=off`, `xattr=sa`, `acltype=posixacl`, and creates the
datasets `raw/files`, `raw/photos`, `raw/books`, `raw/music`, `raw/wallpapers` and
the raw groups under `/var/srv` and the state datasets under `/var/lib`. Later boots import the pool; a missing data device
fails this unit and its consumers, not the OS.

`zfs-ready@<group>.service` runs `scripts/zfs-ready.sh <group>`, which checks
`zfs get mounted`, the dataset mountpoint and an exact `/proc/self/mountinfo`
entry. An existing empty directory on the root filesystem does not pass. Each
consumer requires only its own group's instance and `sops-decrypt.service`.

Quadlets publish on `127.0.0.1` only; Tailscale Serve fronts loopback, or a
Quadlet binds an explicit Tailscale address when a protocol needs one.
Application images must be signed by the smortress cosign key and pushed under
`ghcr.io/smores56/homelab-platform` (or their registry key must be added to
policy); the default-reject policy applies to Podman pulls as well, so an
unsigned application image fails before it can start. The
firewall default zone is `drop`, `tailscale0` is the only interface in the
`tailscale` zone, and that zone has SSH plus any application port added when its
Quadlet is installed. Nothing but sshd listens on a wildcard address, and that is
deliberate: sshd takes no `ListenAddress` because the tailnet address is per node,
so the firewall — not the listener — is the gate. Quadlets and units never name
one, and `scripts/check-server-image.sh` asserts that tree-wide.

## Secrets

SOPS/age remains the versioned format. `secrets/boot.json`, `secrets/apps.json`
and `secrets/agents.json` are ciphertext for the host and admin age recipients in
`.sops.yaml`: the host identity is staged
root-only at `/var/lib/homelab/age/keys.txt` from the offline kit (unwrapped to
the `AGE-SECRET-KEY-...` form there; the kit container itself is not readable
without the paper passphrase), while the admin identity stays with the operator
and is the one the install-time render decrypts with.
`sops-decrypt.service` decrypts on every boot into `/run/smortress/secrets`,
extracting each output's dotted key from its bundle with the owner/group/mode and
`format` in `secrets.manifest`. A missing identity, a missing
ciphertext, an unlisted ciphertext or a manifest mismatch fails the unit, so
dependent Quadlets fail closed. Services mount the decrypted file; they do not
receive it as an environment variable.

The manifest is metadata, so the image is its only author: it ships at
`/usr/share/smortress/secrets.manifest`, a path bootc replaces on upgrade, while
the `/etc/smortress/secrets.manifest` the decrypt reads is rewritten from it by
the seed on every run. It cannot ship under `/etc` alone — bootc merges `/etc`
once per deployment and keeps what the host already had, so a line added by a
later image never arrived, and on 2026-11-22 that left a host whose ciphertext set
was newer than its manifest: the decrypt failed "the ciphertext set and the
manifest disagree" and the boot gate rolled the deployment back. Adding a secret
is now one commit; a hand edit of `/etc/smortress/secrets.manifest` is neither
needed nor kept.

The T2 probe is `["canary"]` in `secrets/boot.json`: ciphertext whose plaintext is
`canary: sops-decrypt-ok`. It proves the image, age identity, unit and
least-privilege write path without adding an application secret.

`["smores"]["password_hash"]` in `secrets/boot.json` is the one secret with two
readers, because `/var` and the install are not the same state. The install render
(`scripts/render-ignition.sh`) decrypts it with the operator's identity and writes
the hash into the Ignition `passwd.users[0].password_hash`; on the host,
`smortress-password.service` reads the decrypted copy from `/run` and re-applies
it with `chpasswd -e`, guarded so an empty or non-sha512crypt value fails the unit
instead of writing a field nobody can log in with. The manifest marks it `value`:
`chpasswd -e` takes the bare hash, not a YAML document. Reinstalling therefore
needs no operator file, and the password is changed by minting new ciphertext
(`docs/manual-steps.md#rotate-the-smores-account-password`), not by touching the host.

## Static checks

```sh
scripts/check-server-image.sh
scripts/check-action-pins.sh
scripts/check-pr-secret-boundary.sh
shellcheck scripts/*.sh
tests/deploy/*.bats                       # the deploy path against fakes: verification, gates, apply
scripts/render-ignition.sh --synthetic --check   # needs butane on PATH; CI pins it
actionlint .github/workflows/server-image-static.yml \
  .github/workflows/publish-server-image.yml
yamllint -c .yamllint.yaml .github/workflows/server-image-static.yml \
  .github/workflows/publish-server-image.yml .sops.yaml
```

`check-server-image.sh` fails on a floating base or Quadlet image, a wildcard
`PublishPort`, an unpinned workflow action, a PR workflow that references a
secret, a policy that does not default-reject, a plaintext secret, a private key
in the tree, a LUKS key file or recovery passphrase in the Ignition template, or
an Ignition template missing threshold 2, both rebase stages or the policy
install.

## Known unverified steps

These require the physical host and are not claimed as proven by this task:

- Booting the uCore base on the real 980 and completing both
  auto-rebase stages.
- Tang reachability at `10.0.0.193:7654` from the dracut environment, and the
  TPM2 half of threshold 2 on this board.
- Ignition resizing the FCOS root partition and adding `p5` on the live disk.
- Firewalld binding `tailscale0` after Tailscale creates it, and a non-Tailscale
  LAN peer being unable to reach SSH or any application port.
- `smortress-data-init.service` generating `/etc/luks/data` and formatting `p5`
  on the first boot of the derived image.
- Root-only `/etc/luks/data` unlocking the data LUKS on a non-first boot, and
  ZFS import/mount ordering on a cold boot.
- GHCR serving the cosign signature as an OCI referrer and `bootc
  --enforce-container-sigpolicy` accepting the signed digest with the committed
  public key.
- `bootc rollback` with the real deployment history and the next signed switch.
- The deploy path end to end on the host (#798 T8): a poll run enqueuing a
  request that stages and reboots, `smortress-boot-counter.service` installing
  greenboot's snippet as `/boot/grub2/custom.cfg` with
  `systemctl is-enabled greenboot-set-rollback-trigger` reporting `enabled`, and
  `default=1` being honoured, the SP5100 watchdog arming at
  `RuntimeWatchdogSec=1min`, the gate's sandbox permitting `bootc rollback --apply`
  and `systemctl reboot`, the tenant probes (`systemctl --user --machine=apps@.host`)
  and the shape of `tailscale serve status --json`, plus one real deploy of each
  repository and a
  rollback drill.

## Local proof recorded by T2

The following ran on the development machine, without the operator key:

```text
scripts/render-ignition.sh --synthetic --check
render-ignition: butane accepted

scripts/check-server-image.sh
server image static checks passed

shellcheck scripts/*.sh   # exit 0
actionlint .github/workflows/server-image-static.yml \
  .github/workflows/publish-server-image.yml               # exit 0

HOME=/tmp/podman-home scripts/build-image.sh
Successfully tagged ghcr.io/smores56/homelab-platform/server:sha-0c53b3f4c5a9
```

The build used the operator public key committed at `lib/containers/cosign.pub`; with
that file absent, `build-image.sh` fails closed, which is what a fresh clone does
until section 37 step 1 installs the key. The built image was inspected
with `podman run`: policy, registries.d, sops/age/restic versions, enabled and
masked units, ciphertext mode and the `drop` default zone all matched this
document. `sops-decrypt.service`'s script was then exercised in that image with
a temporary age identity; it wrote `canary: sops-decrypt-ok` at mode 0400 root.

## Access: the tailnet policy, sshd, and sudo

### The tailnet policy and the enrollment key

`tofu/tailscale.tf` owns the policy: one `tailscale_acl`, gated on `var.tailnet`,
admitting `group:owner` to smortress on 22, Serve's 443/8443/8444/8445/8448 and
Syncthing's 22000, and nothing else (the GUI has no host port: it is `svc:sync`). The group member is `var.tailscale_login`, the tailnet's
own `user@provider`, **not** the Access `var.email`: Tailscale accepts a member it
does not know and then admits nobody. The policy's `tests` run on every save, so a
rule that widens access fails the plan instead of reaching the tailnet.

```sh
scripts/secret.sh edit tailscale.yaml     # tailscale.authkey: tskey-auth-...
scripts/secret.sh stage tailscale.yaml
scripts/secret.sh verify
gh secret set TAILSCALE_OAUTH_CLIENT_ID --env cloudflare --repo smores56/homelab-platform
gh secret set TAILSCALE_OAUTH_CLIENT_SECRET --env cloudflare --repo smores56/homelab-platform
# the pre-merge plan's own read-only client (design #841):
gh secret set TAILSCALE_PLAN_OAUTH_CLIENT_ID --env cloudflare-plan --repo smores56/homelab-platform
gh secret set TAILSCALE_PLAN_OAUTH_CLIENT_SECRET --env cloudflare-plan --repo smores56/homelab-platform
tofu -chdir=tofu plan          # expect: tailscale_acl.this will be created
```

The auth key is minted in the admin console (reusable off, pre-approved if device
approval is on); `smortress-tailscale-up.service` reads `authkey:` and skips
enrollment when its decrypted file is absent, so the key is minted before the boot
that enrolls the host. The OAuth client is scope `policy_file` only, encrypted to
the admin
identity, and an environment needs one because Terraform configures a provider
whenever a resource of that provider is in the configuration, `count = 0` included.
`cloudflare-plan` carries the read-only plan pair for both the pre-merge plan and
the weekly drift check (design #841; `docs/manual-steps.md`, "The plan-only
credentials").

```sh
tailscale status                          # expect: smortress listed
ssh smortress true                        # expect: success
curl -sS --max-time 5 http://smortress:80/ && echo open || echo closed
# expect: closed — the policy admits 22, 443, 8443, 8444, 8445, 8448 and 22000 only
```

From a device outside `group:owner`, port 22 must not answer while `tailscale ping
smortress` still succeeds: the policy drops the port, not the node. A re-enrolment
with an untagged key strips the tag — mint it with `--advertise-tags=tag:smortress`,
or re-apply with the client's `devices:core` scope. The tailnet Service needs
`services` write on the same client.

### Tailnet-only sshd

`bootc/server/rootfs/etc/ssh/sshd_config.d/05-tailnet-ssh.conf` is the only drop-in: no
`ListenAddress`, and `AuthorizedKeysFile` points at
`/etc/ssh/authorized_keys.d/smores`, the one `ssh-ed25519` line shipped in the image.
The network half is firewalld: default zone `drop`, `tailscale0` alone in the
`tailscale` zone, which accepts `ssh` and Syncthing's 22000/tcp+udp. The file sorts
at `05-` because uCore ships `90-enable-localhost-passwords.conf` and sshd keeps the
*earlier* value for a directive re-read in a `Match` block. **The order is a lockout
guard**: the tailnet route has to work first, or the host is reachable only from the
console.

```sh
sudo ss -ltnp '( sport = :22 )'                    # one wildcard socket per family
grep -rn ListenAddress /etc/ssh/sshd_config /etc/ssh/sshd_config.d/   # expect: none
sudo firewall-cmd --get-default-zone               # drop
sudo firewall-cmd --zone=tailscale --list-all      # ssh, 22000/tcp+udp, tailscale0
sudo sshd -T -C addr=127.0.0.1,user=smores | \
  grep -iE '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|allowusers|authorizedkeysfile|pubkeyauthoptions|permituserrc|maxauthtries|logingracetime|allowtcpforwarding|allowstreamlocalforwarding|allowagentforwarding) '
ls -lZ /etc/ssh/authorized_keys.d/smores            # root 0644, etc_t
ssh smortress true                                 # from a tailnet laptop, no prompt
```

The grep is case-insensitive on purpose: OpenSSH 10 prints CamelCase names, so a
lowercase pattern matches nothing and "no output" would read as success. Expected:
`PasswordAuthentication` `no` in both queries, `KbdInteractiveAuthentication` `no`,
`PermitRootLogin` `no`, `AllowUsers` `smores`, `AuthorizedKeysFile`
`/etc/ssh/authorized_keys.d/smores`, `PubkeyAuthOptions` `none`, `PermitUserRC` `no`,
`MaxAuthTries` `10`, `LoginGraceTime` `60`, `AllowTcpForwarding` `no`,
`AllowStreamLocalForwarding` `no`, `AllowAgentForwarding` `yes` — the last is what
makes the sudo tap work. From a machine that is **not** on the tailnet, `nc -vz
smortress 22` must hang and then time out.

### Retire Tailscale SSH

`smortress-tailscale-up.service` does not pass `--ssh`, and
`smortress-tailscale-ssh-off.service` runs `tailscale set --ssh=false` on every boot,
because tailscaled persists the preference in its state file. sshd listens on every
address now, so this is what stops tailscaled from intercepting port 22.

```sh
sudo systemctl status smortress-tailscale-ssh-off.service
tailscale debug prefs | jq -r .RunSSH    # expect: false
```

### sudo: one touch on a forwarded agent, password fallback

`ssh -A smortress` forwards the client's agent, which holds a touch-required
`sk-ssh-ed25519` resident credential, and `/etc/pam.d/sudo` asks the key in the
laptop for a signature; the account password sits behind it as the fallback. The
image carries `bootc/server/rootfs/etc/pam.d/sudo` (`pam_faillock` preauth,
`libpam_rssh.so` against `/etc/ssh/sudo_authorized_keys`, `pam_unix` as the
fallback), `bootc/server/rootfs/etc/ssh/sudo_authorized_keys`, the `sudo-build` stage that
compiles `pam_rssh` at the pin in `bootc/lib/pins.env`, and
`lib/sudoers/10-human-gate` (`timestamp_timeout=30`, `timestamp_type=tty`,
`log_subcmds`, installed as `/etc/sudoers.d/10-human-gate`) and
`lib/sudoers/11-agent-socket` (`Defaults env_keep += "SSH_AUTH_SOCK"`, without
which every escalation falls back to the password). There is no
host-local secret; the retired TOTP usersfile under `/var/lib/homelab/sudo` can be
deleted.

The login key is not a token credential: `authorized_keys.d/smores` ships one plain
`ssh-ed25519` key, so `ssh smortress` is touch-free. The only thing on a YubiKey is
the **sudo** credential.

```sh
ssh-keygen -t ed25519-sk -O resident -C "smores-sudo-key1" -f ~/.ssh/id_smortress_sudo_1
cat ~/.ssh/id_smortress_sudo_*.pub >>    bootc/server/rootfs/etc/ssh/sudo_authorized_keys
scripts/check-server-image.sh     # refuses anything but sk lines, no no-touch-required
```

One file per key, the `-C` suffix matching the file (`_2`, `_3`), and the `ykman
info` serial written next to the physical label. A replacement laptop fetches the
resident credentials with `cd ~/.ssh && ssh-keygen -K`, which writes
`id_ed25519_sk*`: rename each handle **and its `.pub`** to
`~/.ssh/id_smortress_sudo_<n>` and `ssh-add` them, because dotfiles' loader adds
every `id_smortress_sudo*` handle and nothing else. Do **not** add
`-O no-touch-required`: that is the whole difference between the two credentials. An
empty `sudo_authorized_keys` is a `PAM_AUTH_ERR` — the password is the way in until
the lines land — and bootc's `/etc` merge keeps a locally modified copy
(`sudo diff /usr/etc/ssh/sudo_authorized_keys /etc/ssh/sudo_authorized_keys`).

```sh
ssh -A -t smortress 'sudo -k; sudo true'      # "Please touch the device.", one tap
ssh -t smortress 'sudo -k; sudo true'         # no tap, the account password
ssh -A -t smortress 'sudo -k; sudo true'      # key unplugged: the account password
ssh -A -t smortress 'sudo -k; sudo true'      # cover the sensor: the account password
ssh -o IdentitiesOnly=yes -i ~/.ssh/id_smortress_sudo_1 smortress true   # refused
for _ in 1 2 3 4 5; do ssh -t smortress 'sudo -k; sudo -S true < /dev/null'; done
faillock --user smores --reset                # every factor refused for 300s until this
```

The covered-sensor case is the only proof the credential is touch-required: the
public half records no touch policy and `pam_rssh` never reads the user-presence
bit, so a credential minted with `-O no-touch-required` signs anyway and looks
identical. `default=ignore` swallows every failure, so a stack mistake degrades to
the password and shows only here:

```sh
sudo journalctl -t sudo -g 'SSH agent|authorized_keys|keys passed' -n 20 --no-pager
```

`SSH agent socket address not configured` means no `SSH_AUTH_SOCK` in sudo's
environment, `Broken pipe` a dead socket, and `None of these keys passed
authentication` with per-key lines means the agent holds keys the file does not.
`IdentitiesOnly=yes` is not decoration: without it the agent offers the login
credential and the "refused" line passes for the wrong reason. The console is not a
way around the tally: Fedora's `login` pulls in `system-auth` and runs `deny=3
unlock_time=600`.

```sh
ssh -A -t smortress 'echo "$SSH_AUTH_SOCK"; ls -ld ~/.ssh/agent'
sudo ausearch -m avc -c sudo                  # empty after a working tap
```
