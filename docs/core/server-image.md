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
| `/usr/bin/{sops,age,age-keygen,restic,cloudflared}` | Hash-pinned release binaries from `image/pins.env`; no distribution drift. |
| `/etc/smortress/secrets/*.yaml` | SOPS ciphertext only. `image/rootfs/etc/smortress/secrets.manifest` fixes the decrypted owner, group and mode. |
| `/usr/lib/systemd/system/zfs-ready@.service` | One readiness instance per recovery group; verifies the mount, not the directory. |
| `/usr/lib/systemd/system/sops-decrypt.service` | Boot-ordered decrypt into `/run/smortress/secrets`. |
| `/usr/lib/systemd/system/smortress-password.service` | Re-applies the `smores` account password hash with `usermod -p` at every boot from `/run/smortress/secrets/smores-password-hash.yaml`; bootc never reconciles `/var`, so `/etc/shadow` would otherwise be whatever the install left there. |
| `/usr/libexec/smortress-password` | `scripts/smortress-password.sh`: the sha512crypt guard and the single `usermod -p` exec, so no hash handling lives in a unit line. |
| `/usr/lib/systemd/system/smortress-zpool.service` | Creates or imports the `smortress` pool on the encrypted data device. |
| `/usr/lib/systemd/system/smortress-cryptsetup-hdd.service` | Opens the HDD LUKS with its keyfile; non-blocking by contract. |
| `/etc/firewalld/zones/tailscale.xml` | Binds `tailscale0`, permits SSH and Syncthing's 22000/tcp+udp; the default zone is `drop`. |
| `/etc/ssh/sshd_config.d/05-tailnet-ssh.conf` | The one sshd drop-in (design #767). No `ListenAddress` at all, so sshd listens on every local address and the firewall decides who reaches it: the default zone is `drop` and only `tailscale0` accepts `ssh`. No forwarding, `AllowUsers smores`, key-only auth, and the `Match Address 127.0.0.1,::1` block that stops uCore's `90-enable-localhost-passwords.conf` from re-enabling password auth on the loopback route Cockpit and the tunnel's connector still use during the cutover. It sorts at `05-` because sshd keeps the first value it obtains in the second config pass. `PubkeyAuthOptions` is deliberately unset, so a per-key option on an `authorized_keys` line stays the whole sk policy. |
| `/etc/ssh/authorized_keys.d/smores` | The one login key: a single `ssh-ed25519` line for `smores@smortress`, root-owned `0644` under `etc_t`, so sshd opens it as root and a key change arrives with `bootc upgrade`. It is the `AuthorizedKeysFile`; nothing reads `~/.ssh` and no Ignition step delivers a key. No FIDO handle, because a resident `sk-` credential is generated with a token and cannot be reviewed in git. |
| `/usr/lib/systemd/system/smortress-tailscale-ssh-off.service` | Re-asserts `tailscale set --ssh=false` at every boot; tailscaled persists the preference, so removing the flag from the enrollment unit is not enough. Tailscale SSH is retired. |
| `/etc/pam.d/sudo` and `/etc/sudoers.d/10-human-gate` | The sudo gate (design #767, T8): a touch on the YubiKey held by the client, with the account password behind it. `pam_faillock` preauth, `libpam_rssh.so` against `/etc/ssh/sudo_authorized_keys` with `cue` (`success=2` reaches `authsucc`; a bare `sufficient` would end dispatch there and the faillock tally would never clear), `pam_unix try_first_pass` as the fallback behind it (`success=1` reaches the same `authsucc`, so either factor clears the tally), then `authfail` and `authsucc`. Every non-success from `pam_rssh` — no `SSH_AUTH_SOCK`, a dead socket, an absent key, a refused touch, and never `PAM_IGNORE` — is ignored and lands on the password, which is the break-glass everywhere: there is no console row any more. A 30-minute ticket per TTY and `log_subcmds`. No `env_keep`: `pam_rssh` reads `SSH_AUTH_SOCK` with `getenv()` and sudo does not scrub its environ before `pam_authenticate`. `docs/manual-steps.md` section 45 enrolls the two credentials per key, proves the tap and the fallback, and carries the AVC drill. |
| `/etc/ssh/sudo_authorized_keys` | The sudo credentials' public halves only, root-owned `0600`: `sk-ssh-ed25519` lines, never `no-touch-required`, because the touch option is fixed at enrollment. Root-owned and not `AuthorizedKeysFile`, so the login credential cannot satisfy sudo and the sudo credential cannot satisfy ssh. Empty until the owner enrolls the keys; an empty list is `PAM_AUTH_ERR`, so the password works in the meantime. |
| `/usr/lib64/security/libpam_rssh.so` | `z4yx/pam_rssh` at the tag and commit pinned in `image/pins.env`, built in the image's `sudo-build` stage with the `dep/ssh-agent.rs` submodule and `--locked`, linking the base's openssl and libpam. Not packaged for Fedora, so a cdylib copied from anywhere else would be an ABI mismatch at the first prompt. |
| `/usr/share/smortress/selinux/smortress_sudo_rssh.pp` | The local SELinux module (`image/selinux/smortress_sudo_rssh.te`) granting `sudo_t` `connect` on `ssh_home_t`, where OpenSSH >= 10.1 puts the forwarded agent socket under `~/.ssh/agent`. The targeted policy grants no such access and broke forwarding outright once (selinux-policy#3384), so without this the touch falls back to the password on every escalation. The exact permission set is unproven until the host drill in section 45. |
| `/usr/lib/systemd/system/smortress-selinux-sudo-rssh.service` | Loads the module with `semodule -i` at boot when the shipped `.pp`'s digest differs from the one recorded, or when the module is absent from the policy; the policy store is in `/etc` and `/var`, which bootc never reconciles, so shipping a new `.pp` is not loading it. |
| `/usr/share/smortress/quadlet/pattern.container` | Quadlet base pattern; not enabled, no `[Install]`. |
| `/usr/share/containers/systemd/*.container` | The application Quadlets (T5). A quadlet is a generated unit, so `[Install]` is what starts it; the image never runs `systemctl enable` for one. |
| `/usr/lib/systemd/system/smortress-app-secrets.service` | Turns the decrypted application secrets into Podman secrets before any container that declares one starts. |
| `/usr/lib/systemd/system/smortress-tailscale-serve.service` | Re-declares the Tailscale Serve routes at boot; Serve state is not backed up. |
| `/usr/lib/systemd/system/smortress-immich-dump.{service,timer}` | The logical Immich restore point inside the photos group, at 21:00 UTC, three hours before the R2 run. |
| `/usr/share/containers/systemd/{agent-local,agent-general}.network` | The two agent networks: one internal (no route off the host) and one plain bridge (egress, for the hosted proxy). |
| `/usr/share/containers/systemd/{agent-model,agent-local,agent-general,agent-proxy,agent-facade-personal,agent-facade-general,agent-webui-personal,agent-webui-general}.container` | The agent deployment Quadlets: the pinned llama.cpp server, the two Hermes gateways, the hosted-model proxy, one source facade per deployment and one browser UI per deployment. |
| `/usr/libexec/agent-proxy` | `apps/agent_proxy/proxy.py`, installed executable and not stripped of its `.py` name: the only program that holds the hosted provider key, pinned to one upstream host. The unit bind-mounts this path into the container, because the program is not in the pinned runtime image. |
| `/usr/lib/agent-facade/` | `apps/agent_facade/` (every module, no `tests/`) at `/usr/lib/agent-facade/apps/agent_facade/` and `libs/data_plane/` at `/usr/lib/agent-facade/libs/data_plane/`: the two facade Quadlets mount this tree read-only and set `PYTHONPATH` to it, so the facade that runs is the code the booted deployment carries. |
| `/etc/smortress/agent/{local,general}-config.yaml` | The runtime config templates `smortress-agent-config.service` copies into each state dataset on first boot. No key, no credential: the `mcp_servers` entry carries the literal placeholder `__FACADE_TOKEN__` where the gateway's facade token goes. |
| `/usr/lib/systemd/system/smortress-agent-config.service` | Seeds each gateway's `config.yaml` (`cp -n`), substitutes the facade token from its decrypted ciphertext while the placeholder is still there, rewrites `.env`'s `API_SERVER_KEY` and `webui.env`'s gateway key and UI password at every boot, and creates each facade's memory root and each UI's state and workspace directories. |
| `/usr/libexec/agent-config-seed` | `scripts/agent-config-seed.sh`: the seeding itself, so the token is read from a file into a variable instead of being spliced into an `ExecStart` line. |
| `/usr/lib/systemd/system/smortress-nvidia-cdi.service` | Generates `/etc/cdi/nvidia.yaml` at boot so `AddDevice=nvidia.com/gpu=all` resolves for the model container; ordered before it. |

`units/quadlet/pattern.container` is the canonical copy in the repository; the
image ships it read-only as the base for a new application. A placeholder
container must never be started automatically. The six application Quadlets in
`units/quadlet/*.container` are installed into `/usr/share/containers/systemd`
and start from their own `[Install]` section; see `docs/core/applications.md`.

## Base pin

`image/pins.env` is the single pin file. The base is the multi-arch uCore
`stable-nvidia` index at

```text
ghcr.io/ublue-os/ucore@sha256:bf251f7668136af11d482dc3c86b49e40d7ef017fea37c5774679a693541a5ed
```

published 2026-11-15 03:09:12Z. The amd64 manifest in that index is
`sha256:e97dd4593a3b6845820da3aea11c0245f1f243d28df6510ed2da48c3848700f2`.
The tag is recorded for humans; every consumer uses the digest. `stable-nvidia`
is deliberate: uCore ships the NVIDIA userspace and the OpenZFS module used by
`smortress`.

The base already provides what the design needs, verified by inspecting the
image: the ZFS kernel module and tools, Podman with the Quadlet generator,
firewalld, Tailscale, clevis with the sss/tang/tpm2 dracut pins, and the
`podman-system-generator` symlink. It does not ship `sops`, `age`, `restic` or `cloudflared`;
the Containerfile adds the hash-pinned release binaries instead of layering
distribution packages.

The image layers no distribution package. sudo's touch factor is `pam_rssh`,
which Fedora does not package, and the SELinux module is local to this
repository; both are built in a `sudo-build` stage from the tag and commit pinned
in `image/pins.env` and arrive in the final image as a `.so` and a `.pp`. Neither
can be copied from elsewhere: the module links the base's openssl and libpam, so
a foreign build is an ABI mismatch waiting for the first sudo prompt, and the
policy store needs the base's own type names. The build fails if
`libpam_rssh.so` or the sudo key file is absent, if the retired OATH module is
present, or if the image carries no `semodule` for the loader unit.

## Build, push and sign

```sh
scripts/refresh-pins.sh --write           # re-read the uCore tag; rewrites only the digest
scripts/build-image.sh                    # local build; never pushes or signs
scripts/verify-image.sh ghcr.io/smores56/homelab-platform/server@sha256:<digest>
```

`refresh-pins.sh` is the one place that reads a moving uCore tag; it prints the
digest or rewrites `image/pins.env`, and every other consumer is digest-only.

CI is `.github/workflows/publish-server-image.yml`: a push to `main` touching
`image/`, `units/`, `secrets/` or `scripts/`, or a manual dispatch. The job:

1. verifies that `secrets.COSIGN_PRIVATE_KEY` corresponds to the committed
   `image/cosign.pub` before building anything;
2. builds with `scripts/build-image.sh` (the base and every tool are
   digest/hash-pinned);
3. pushes `sha-<first 12 of the commit>`, reads the registry digest from
   Podman's `--digestfile`, signs that digest with
   `cosign sign --key env://COSIGN_PRIVATE_KEY`, and verifies it against the
   committed public key;
4. moves `:latest` onto that digest, from `main` runs only and only after the
   signature verified;
5. prints the digest for the operator to pin in
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
sudo bootc switch --enforce-container-sigpolicy \
  ghcr.io/smores56/homelab-platform/server:latest
sudo bootc upgrade   # every later update
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

`bootc rollback` is not sticky on a tag-following host: it boots the previous
deployment but leaves the reference alone, so the next `bootc upgrade` re-stages
the build that was just escaped. After a rollback, switch back to the digest you
trust instead of leaving the host on the tag.

The install path keeps a digest (`ignition/operator/derived-image`): a fresh host
must come up on the build that was verified, not on whatever `:latest` names.

## Disks and encryption

FCOS owns a fixed raw disk image: `p1` BIOS-BOOT, `p2` EFI-SYSTEM, `p3` boot,
`p4` root. The approved design's "p2 LUKS root, p3 LUKS data" numbering cannot
be produced by that installer without renumbering partitions the raw image
boots from. The supported layout therefore keeps the approved intent — two
encrypted storage volumes on the 980 — as:

| Partition | Use |
| --- | --- |
| `p4` (`root`) | LUKS2 `luks-root`, XFS, 100 GiB; Clevis SSS Tang+TPM2 threshold 2 plus an offline recovery passphrase keyslot. |
| `p5` (`luks-data`) | LUKS2 `luks-data`, consumes the remainder; opened with a root-only keyfile stored on the encrypted root. |

Ignition resizes `p4` with `resize: true`/`size_mib: 102400` and creates `p5`
with `size_mib: 0`. The 970 stays a separate ext4 Restic repository disk; the
5 TB HDD keeps its existing LUKS and is opened by
`smortress-cryptsetup-hdd.service` with a keyfile and `nofail` semantics. Its
absence cannot block boot; T3 alerts through backup staleness.

Ignition writes a key file for every LUKS device under `/etc/luks/<name>`,
including the Clevis root, and generates a `/etc/crypttab` entry for each. The
root passphrase therefore exists as `/etc/luks/root` on the encrypted root and
as the recovery keyslot; the keyslot is what the kit needs. The file is inside
the container, so it is not an at-rest bypass by itself — the residual risk is
Dracut copying it into the unencrypted `/boot` initramfs on a later ostree
update, which section 37 step 8.1 checks for. The data keyfile at
`/etc/luks/data` is deliberate: it is how the pool opens without a second
prompt, and it is why the data crypttab entry must stay out of the initramfs.
Secure Boot stays off.

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

`secrets/server/smortress-password-hash.yaml` is the one secret with two readers,
because `/var` and the install are not the same state. The install render
(`scripts/render-ignition.sh`) decrypts it with the operator's identity and writes
the hash into the Ignition `passwd.users[0].password_hash`; on the host,
`smortress-password.service` reads the decrypted copy from `/run` and re-applies
it with `usermod -p`, guarded so an empty or non-sha512crypt value fails the unit
instead of writing a field nobody can log in with. The manifest marks it `value`:
`usermod -p` takes the bare hash, not a YAML document. Reinstalling therefore
needs no operator file, and the password is changed by minting new ciphertext
(`docs/manual-steps.md` section 37), not by touching the host.

## Static checks

```sh
scripts/check-server-image.sh
scripts/check-action-pins.sh
scripts/check-pr-secret-boundary.sh
nix shell nixpkgs#shellcheck -c shellcheck scripts/*.sh
nix shell nixpkgs#butane -c scripts/render-ignition.sh --synthetic --check
nix run nixpkgs#actionlint -- .github/workflows/server-image-static.yml \
  .github/workflows/publish-server-image.yml
nix run nixpkgs#yamllint -- -c .yamllint.yaml .github/workflows/server-image-static.yml \
  .github/workflows/publish-server-image.yml .sops.yaml
```

`check-server-image.sh` fails on a floating base or Quadlet image, a wildcard
`PublishPort`, an unpinned workflow action, a PR workflow that references a
secret, a policy that does not default-reject, a plaintext secret, a private key
in the tree, or an Ignition template missing threshold 2, both rebase stages,
the two keyfiles or the policy install.

## Known unverified steps

These require the physical host and are not claimed as proven by this task:

- Booting the pinned uCore digest on the real 980 and completing both
  auto-rebase stages.
- Tang reachability at `10.0.0.193:7654` from the dracut environment, and the
  TPM2 half of threshold 2 on this board.
- Ignition resizing the FCOS root partition and adding `p5` on the live disk.
- Firewalld binding `tailscale0` after Tailscale creates it, and a non-Tailscale
  LAN peer being unable to reach SSH or any application port.
- Root-only `/etc/luks/data` unlocking the data LUKS on a non-first boot, and
  ZFS import/mount ordering on a cold boot.
- GHCR serving the cosign signature as an OCI referrer and `bootc
  --enforce-container-sigpolicy` accepting the signed digest with the committed
  public key.
- `bootc rollback` with the real deployment history and the next signed switch.

## Local proof recorded by T2

The following ran on the development machine, without the operator key:

```text
nix shell nixpkgs#butane -c scripts/render-ignition.sh --synthetic --check
render-ignition: butane accepted

scripts/check-server-image.sh
server image static checks passed

nix shell nixpkgs#shellcheck -c shellcheck scripts/*.sh   # exit 0
nix run nixpkgs#actionlint -- .github/workflows/server-image-static.yml \
  .github/workflows/publish-server-image.yml               # exit 0

HOME=/tmp/podman-home nix shell nixpkgs#podman -c scripts/build-image.sh
Successfully tagged ghcr.io/smores56/homelab-platform/server:sha-0c53b3f4c5a9
```

The build used the operator public key committed at `image/cosign.pub`; with that
file absent, `build-image.sh` fails closed, which is what a fresh clone does
until section 37 step 1 installs the key. The built image was inspected
with `podman run`: policy, registries.d, sops/age/restic versions, enabled and
masked units, ciphertext mode and the `drop` default zone all matched this
document. `sops-decrypt.service`'s script was then exercised in that image with
a temporary age identity; it wrote `canary: sops-decrypt-ok` at mode 0400 root.

