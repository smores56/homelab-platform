# Core server image (T2)

The smortress core is one immutable uCore bootc deployment, configured by this
repository and nothing else. There is no Nix on the host, no k3s, no Flux and no
Ansible. Podman Quadlets are the only container control plane; ZFS recovery
datasets under `/var/srv` and `/var/lib` are the only service-data layout.

This document covers the image, its signing policy, the Ignition install and the
rollback path. Operator-only actions are in `docs/manual-steps.md` section 37.

## What the image contains

| Path | Purpose |
| --- | --- |
| `/etc/containers/policy.json` | Default-reject policy; trusts the uCore keys by path and `ghcr.io/smores56/homelab-platform` through `/etc/pki/containers/smortress.pub`. |
| `/etc/containers/registries.d/ghcr.io-smortress.yaml` | Enables cosign signature lookup for our GHCR repository. |
| `/etc/pki/containers/smortress.pub` | Public half of the operator cosign key. The private half is an environment secret and a recovery-kit item. |
| `/usr/bin/{sops,age,age-keygen,restic}` | Hash-pinned release binaries from `image/pins.env`; no distribution drift. |
| `/etc/smortress/secrets/*.yaml` | SOPS ciphertext only. `image/rootfs/etc/smortress/secrets.manifest` fixes the decrypted owner, group and mode. |
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
| `/usr/lib64/security/libpam_rssh.so` | `z4yx/pam_rssh` at the tag and commit pinned in `image/pins.env`, built in the image's `sudo-build` stage with the `dep/ssh-agent.rs` submodule and `--locked`, linking the base's openssl and libpam. Not packaged for Fedora, so a cdylib copied from anywhere else would be an ABI mismatch at the first prompt. |
| `/usr/share/smortress/quadlet/pattern.container` | Quadlet base pattern; not enabled, no `[Install]`. |
| `/usr/share/containers/systemd/*.container` | The application Quadlets (T5). A quadlet is a generated unit, so `[Install]` is what starts it; the image never runs `systemctl enable` for one. |
| `/usr/lib/systemd/system/smortress-app-secrets.service` | Turns the decrypted application secrets into Podman secrets before any container that declares one starts. |
| `/usr/lib/systemd/system/smortress-tailscale-serve.service` | Re-declares the Tailscale Serve routes at boot; Serve state is not backed up. |
| `/usr/lib/systemd/system/smortress-immich-dump.{service,timer}` | The logical Immich restore point inside the photos group, at 21:00 UTC, three hours before the R2 run. |
| `/usr/share/containers/systemd/{agent-local,agent-general}.network` | The two agent networks: one internal (no route off the host) and one plain bridge (egress, for the hosted proxy). |
| `/usr/share/containers/systemd/{agent-model,agent-local,agent-general,agent-proxy,agent-facade-personal,agent-facade-general,agent-webui-personal,agent-webui-general}.container` | The agent deployment Quadlets: the pinned llama.cpp server, the two Hermes gateways, the hosted-model proxy, one source facade per deployment and one browser UI per deployment. |

| `/etc/smortress/agent/{local,general}-config.yaml` | The runtime config templates `smortress-agent-config.service` copies into each state dataset on first boot. No key, no credential: the `mcp_servers` entry carries the literal placeholder `__FACADE_TOKEN__` where the gateway's facade token goes. |
| `/usr/lib/systemd/system/smortress-agent-config.service` | Seeds each gateway's `config.yaml` (`cp -n`), substitutes the facade token from its decrypted ciphertext while the placeholder is still there, rewrites `.env`'s `API_SERVER_KEY` and `webui.env`'s gateway key and UI password at every boot, and creates each facade's memory root and each UI's state and workspace directories. |
| `/usr/libexec/agent-config-seed` | `scripts/agent-config-seed.sh`: the seeding itself, so the token is read from a file into a variable instead of being spliced into an `ExecStart` line. |
| `/usr/lib/systemd/system/smortress-nvidia-cdi.service` | Generates `/etc/cdi/nvidia.yaml` at boot so `AddDevice=nvidia.com/gpu=all` resolves for the model container; ordered before it. |
| `/usr/libexec/deploy-receiver.py` | The deploy listener (#798): loopback HTTP on `127.0.0.1:8484`, HMAC over the raw request bytes against two rotation slots, ±300 s skew, nonce ring under its own `flock listener.lock`, 64 KiB body cap, queue cap 32. It resolves no tag and writes no deployment state; it ships in the rootfs because the build's `smortress-src` loop installs `*.sh` only. |
| `/usr/libexec/deploy-verify.py` | The host's own verification: tip of `main`, descendancy from the deployed commit, tag `sha-<commit[:12]>` → digests, `org.opencontainers.image.revision` label, denylist. Anonymous GitHub and registry calls, cached 120 s, 30 s each. Also rootfs, for the same reason. |
| `/usr/libexec/{deploy-state,deploy-drain,deploy-platform,deploy-apps,deploy-poll,deploy-heartbeat}` | `scripts/deploy-*.sh`: the state library, the queue drain (single writer of `state.json`), the platform snapshot gate and stage, the apps apply and revert, the hourly backstop and the five-minute dead-man. |
| `/usr/libexec/smortress-boot-gate` | `scripts/smortress-boot-gate.sh`: reconciles an interrupted apps apply, then keeps or rolls back the deployment this host just booted. |
| `/usr/libexec/smortress-deploy` | `scripts/deploy-cli.sh`, staged under the name the runbook uses: `status`, `release --force`, `unblock`, `bootstrap`. |
| `/usr/lib/systemd/system/smortress-deploy-listener.service` | The listener, `Restart=always`, `Requires=` and `After=` on `sops-decrypt.service`, sandboxed with the state tree as its only writable path. |
| `/usr/lib/systemd/system/smortress-deploy.path`, `/usr/lib/systemd/system/smortress-deploy.service` | The queue trigger (`DirectoryNotEmpty=/var/lib/homelab/deploy/queue`) and the one drain of it, `TimeoutStartSec=12600`. |
| `/usr/lib/systemd/system/smortress-deploy-poll.timer`, `/usr/lib/systemd/system/smortress-deploy-poll.service`, `/usr/lib/systemd/system/smortress-deploy-heartbeat.timer`, `/usr/lib/systemd/system/smortress-deploy-heartbeat.service`, `/usr/lib/systemd/system/smortress-deploy-retry.timer`, `/usr/lib/systemd/system/smortress-boot-gate.service` | The hourly backstop, the dead-man beat for the `deploy` Healthchecks check, the five-minute retry of a deferred queue entry, and the gate that runs `Before=boot-complete.target`. |
| `/usr/share/smortress/deploy-units.txt` | The units the boot gate requires: what "serving" means for this host. The receiver's own units are deliberately absent — a missing deploy secret must page, not roll the host back. |
| `/usr/lib/bootupd/grub2-static/configs.d/10-smortress-count.cfg` | The three-attempt boot counter. It is **not active on this host**: `bootupd` reports every component current and has no way to force a regeneration, so the snippet never reaches `grub.cfg` (`docs/manual-steps.md` §49.5). The gate journals `boot-counting-absent` each boot. |
| `/etc/systemd/system.conf.d/10-watchdog.conf` | `RuntimeWatchdogSec=1min`, so a hung PID 1 becomes a reboot. No `kernel.panic`: without a bootloader counter, a panic reboot would loop the same image. |
| `/etc/tmpfiles.d/smortress.conf` | Creates `/var/lib/homelab/deploy`, `queue` and `work` at `0700 root`: the receiver's state tree, outside every recovery group because the journal and `bootc status` rebuild it. |

`units/quadlet/pattern.container` is the canonical copy in the repository; the
image ships it read-only as the base for a new application. A placeholder
container must never be started automatically. The six application Quadlets in
`units/quadlet/*.container` are installed into `/usr/share/containers/systemd`
and start from their own `[Install]` section; see `docs/core/applications.md`.

## Base pin

`image/pins.env` holds every external reference the image consumes. The base is
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
and commit pinned in `image/pins.env` and arrives as a `.so`. It cannot be copied
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
`image/`, `units/`, `secrets/` or `scripts/`, or a manual dispatch. The job:

1. verifies that `secrets.COSIGN_PRIVATE_KEY` corresponds to the committed
   `image/cosign.pub` before building anything;
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
`image/cosign.pub`, otherwise `bootc` rejects the next switch.

## Signature enforcement

The image inherits uCore's default-reject policy and adds our repository:

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
`bootc-fetch-apply-updates.timer`, `rpm-ostreed-automatic.timer` and `zincati`
are masked, so every deployment change lands in a maintenance-window reboot.

## Moving a host forward by hand

A running host's deployment reference is a digest, and `bootc upgrade` only
re-checks the reference it was given, so a digest-pinned host never moves: the
operator switches it to the new digest. CI also moves `:latest` onto every
signed `main` build, so a host can follow that instead and then upgrade with one
command:

```sh
# Break-glass only: switch to the digest the receiver verified.
sudo bootc switch --enforce-container-sigpolicy \
  ghcr.io/smores56/homelab-platform/server@sha256:<verified-digest>
```

Signature policy applies to the tag unchanged: `signedIdentity: matchRepository`
authorizes any reference in `ghcr.io/smores56/homelab-platform`, and the
signature is attached to the digest the tag resolves to, so a tag that points at
an unsigned or branch-built digest is still refused.

What the tag gives up is the deploy receiver's descendancy check: the receiver
refuses a signed image whose commit does not descend from the deployed one, and
nothing on the host makes that comparison for a hand-run upgrade. Moving
`:latest` backwards therefore deploys an older build, which is why only `main`
runs may move the tag and why the receiver stays the authoritative path. A
tag-following host is the operator's convenience, not the deployment policy.

`bootc rollback` boots the previous deployment. Because the reference is a
digest, the next deploy cannot silently re-stage the escaped build. The deploy
record can still name the staged digest after a rollback; the next successful
stage and boot gate overwrite it.

The install path keeps a digest (`ignition/operator/derived-image`): a fresh host
must come up on the build that was verified, not on whatever `:latest` names.

## The deploy path

The image is the only delivery, so a merge to `main` reaches this host through
the receiver and nothing else. Its authority is the host's own: every input is a
notification, and each decision is re-derived here from the GitHub commit graph,
the registry tag, the image's own label and the signature `bootc` checks. A
request that fails any check changes nothing and leaves the last good deployment
running.

### The trigger

`publish-server-image.yml` ends with a `notify` job — `needs: publish`, `main`
only, `environment: deploy-notify`, `permissions: {}`, no checkout, no cosign key
— that joins the tailnet as an ephemeral node carrying `tag:deploy` and posts one
signed request to `http://smortress:8484/v1/deploy`:

```json
{"repo": "homelab-platform", "commit": "<40-hex>", "ts": <unix>, "nonce": "<32-hex>"}
```

`homelab-apps` posts the same body from its own workflow. `X-Deploy-Signature:
sha256=<hmac>` is computed over the exact bytes that go on the wire, which is why
the job uses `curl --data-binary` and not `-d` (it strips the newline, the bytes
stop matching the signature, and the receiver refuses the body it was sent).
There is no timestamp header: the skew is read from the body's `ts`, the value the
HMAC covers, so a header and a body cannot disagree about which clock a request
belongs to.

`smortress-deploy-listener.service` binds `127.0.0.1:8484`; the tailnet side is
Serve's `--tcp=8484 tcp://127.0.0.1:8484` forward and `8484/tcp` in the
`tailscale` zone, so no unit binds a wildcard address. The listener verifies the
HMAC against either rotation slot, the ±300 s skew of the body's `ts`, the nonce
ring, the shape and the repository, refuses a denylisted commit, answers `200` for
a commit already deployed, and otherwise writes `queue/<uuid>.json` and answers
`202`. Body cap 64 KiB, 10 s read timeout, at most 32 requests being read at once
(`503` above it, taken before the first body byte), queue cap 32 (`429` above it).
Everything a caller without the secret can fail — signature, shape, `ts`, replay —
is answered before the listener takes its lock and is counted in memory instead of
journaled, because a journal line is an fsync and `POST /v1/deploy` is reachable
by anyone on the tailnet; `/healthz` reports that tally beside `status`. It
resolves no tag, checks no signature and writes no deployment state;
`nonces.json` and `listener.lock` are the only files it owns.

### The drain

`smortress-deploy.path` watches the queue with `DirectoryNotEmpty=`, and
`smortress-deploy.service` drains it as a oneshot under
`flock /run/smortress-deploy/deploy.lock` — its own `RuntimeDirectory=`, never
`/run/smortress`, which holds the decrypted secrets and stays read-only to every
deploy unit: strict FIFO, except that a newer request for the same repository
replaces an older pending one, with one rescan before exit.
It is the single writer of `state.json`. `TimeoutStartSec=7200` bounds a wedged
drain, and every external command inside it has its own deadline.

`/usr/libexec/deploy-verify.py` answers "may this commit deploy" for every entry,
fail-closed and journaled with the reason:

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
the journal says so, and the dead-man pages once it has waited half an hour.
A rejected commit is popped and never retried, because the next trigger would
fail it identically.

### Platform: snapshot gate, switch, reboot

`deploy-platform prepare` runs the snapshot gate before anything is staged: one
read-only `smortress-restic-verify --local --json` answers with a verdict per
restore unit (newest snapshot for `host,paths`, its `verified` tag, a max age of
8400 s), SSD first and the HDD when the SSD is absent, and a unit without a fresh
verified snapshot is backed up directly with
`smortress-restic-backup --unit <unit> --no-maintenance` (1800 s
each, 900 s of waiting for the hourly driver's unit lock, 3600 s for the whole
gate; maintenance is excluded so the gate never waits for a prune). If no local
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

The host is digest-pinned. `bootc upgrade` has no tag to follow and is not a
deploy path. A hand switch by tag bypasses the receiver's descendancy check and
can stage a build nobody verified, so use the digest from the deploy journal.

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

- **match.** The health gate, retried inside 300 s: every unit in
  `/usr/share/smortress/deploy-units.txt` active and none of them `failed`, the
  pool imported, `/srv/apps` a mountpoint, every app in `plan.json` up with its
  ingress loopback port accepting a connect, and every expected Serve path
  present in `tailscale serve status --json`. Success records the deployment,
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

### Below userspace

`bootc` has no boot counting and the gate only runs if userspace starts, so the
image ships `/usr/lib/bootupd/grub2-static/configs.d/10-smortress-count.cfg`: on
every boot it would set `boot_success=0`, decrement `boot_counter` from 3, and at
zero select the previous deployment (`default=1`).

**On this host that mechanism is not active.** `bootupctl status` reports every
component at its latest version and `bootupctl update` has no way to force a
regeneration, so the snippet never reaches `/boot/grub2/grub.cfg`; the host was
measured, not assumed (`docs/manual-steps.md` §49.5). The gate therefore journals
`boot-counting-absent` on every boot and writes no GRUB flags, and the image ships
no `kernel.panic`: a panic that reboots with no counter would loop the same image
forever. `RuntimeWatchdogSec=1min` stays armed, with the same caveat for a PID 1
that hangs on every boot.

The rollback guarantee is the userspace one: a deployment that boots but fails the
health gate is denylisted and `bootc rollback --apply` reverts it. A host that
fails before userspace is a console recovery, and the recovery point is the
pre-reboot snapshot the gate requires.

### The two backstops

`smortress-deploy-poll.timer` runs hourly at `:20` and enqueues a request when a
repository's `main` tip differs from the deployed commit: the case an event
cannot cover — a notify job that never ran, a tailnet that was down, a build that
landed while the host was off. It decides nothing; it only enqueues, pages on a
denylisted tip, and stops enqueuing one until `smortress-deploy unblock` removes
that entry.

`smortress-deploy-heartbeat.timer` (every 5 minutes) pings the `deploy` check
green only when `GET /healthz` answers `200` within 5 s *and* no queue entry has
waited more than 30 minutes; anything else pings `/fail` with the reason. It is
separate from the poll on purpose: a poll-driven ping stays green while the drain
is wedged behind a stalled pull with the lock held.

### What a hand-run switch still gives up

`sudo bootc switch --enforce-container-sigpolicy <reference>` still verifies the
signature and still boots, and the GRUB counter still covers a deployment that
never reaches userspace. What it gives up is everything the receiver checks
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
the journal and any restore that does not name a data disk; the rebuild that
takes an installed 100 GiB host to that layout, and why it cannot be done in
place, is `docs/core/pool-rebuild.md`. The 970 stays a separate ext4 Restic
repository disk; the
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

SOPS/age remains the versioned format. `secrets/server/*.yaml` is ciphertext for
the host and admin age recipients in `.sops.yaml`: the host identity is staged
root-only at `/var/lib/homelab/age/keys.txt` from the offline kit (unwrapped to
the `AGE-SECRET-KEY-...` form there; the kit container itself is not readable
without the paper passphrase), while the admin identity stays with the operator
and is the one the install-time render decrypts with.
`sops-decrypt.service` decrypts on every boot into `/run/smortress/secrets`
with the owner/group/mode in `secrets.manifest`. A missing identity, a missing
ciphertext, an unlisted ciphertext or a manifest mismatch fails the unit, so
dependent Quadlets fail closed. Services mount the decrypted file; they do not
receive it as an environment variable.

The T2 probe is `secrets/server/canary.yaml`: ciphertext whose plaintext is
`canary: sops-decrypt-ok`. It proves the image, age identity, unit and
least-privilege write path without adding an application secret.

`secrets/server/smores-password-hash.yaml` is the one secret with two readers,
because `/var` and the install are not the same state. The install render
(`scripts/render-ignition.sh`) decrypts it with the operator's identity and writes
the hash into the Ignition `passwd.users[0].password_hash`; on the host,
`smortress-password.service` reads the decrypted copy from `/run` and re-applies
it with `chpasswd -e`, guarded so an empty or non-sha512crypt value fails the unit
instead of writing a field nobody can log in with. The manifest marks it `value`:
`chpasswd -e` takes the bare hash, not a YAML document. Reinstalling therefore
needs no operator file, and the password is changed by minting new ciphertext
(`docs/manual-steps.md` section 37), not by touching the host.

## Static checks

```sh
scripts/check-server-image.sh
scripts/check-action-pins.sh
scripts/check-pr-secret-boundary.sh
shellcheck scripts/*.sh
tests/deploy/*.sh                         # the deploy path against fakes: listener, verification, gates, apply
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
- The deploy path end to end on the host (#798 T8): a CI notify arriving over
  `tag:deploy` into `127.0.0.1:8484`, `bootupctl update` installing
  `10-smortress-count.cfg` into `/boot/grub2/grub.cfg` and `default=1` being
  honoured, the SP5100 watchdog arming at `RuntimeWatchdogSec=1min`, the gate's
  sandbox permitting `bootc rollback --apply` and `systemctl reboot`, the tenant
  probes (`systemctl --user --machine=apps@.host`) and the shape of
  `tailscale serve status --json`, plus one real deploy of each repository and a
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

The build used the operator public key committed at `image/cosign.pub`; with that
file absent, `build-image.sh` fails closed, which is what a fresh clone does
until section 37 step 1 installs the key. The built image was inspected
with `podman run`: policy, registries.d, sops/age/restic versions, enabled and
masked units, ciphertext mode and the `drop` default zone all matched this
document. `sops-decrypt.service`'s script was then exercised in that image with
a temporary age identity; it wrote `canary: sops-decrypt-ok` at mode 0400 root.

