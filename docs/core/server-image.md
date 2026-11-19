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
| `/usr/lib/systemd/system/smortress-zpool.service` | Creates or imports the `smortress` pool on the encrypted data device. |
| `/usr/lib/systemd/system/smortress-cryptsetup-hdd.service` | Opens the HDD LUKS with its keyfile; non-blocking by contract. |
| `/etc/firewalld/zones/tailscale.xml` | Binds `tailscale0`, permits SSH and Syncthing's 22000/tcp+udp; the default zone is `drop`. |
| `/etc/ssh/sshd_config.d/05-deny-loopback-passwords.conf` | The only route into sshd: loopback listeners in both families, `AuthorizedKeysFile` under `/var/lib/homelab/.ssh`, no forwarding, and the `Match Address 127.0.0.1,::1` block that stops uCore's `90-enable-localhost-passwords.conf` from re-enabling password auth. It sorts at `05-` because sshd keeps the first value it obtains in the second config pass. `PubkeyAuthOptions` is deliberately unset, so the per-key `no-touch-required` on each `authorized_keys` line is the whole sk policy. |
| `/usr/lib/systemd/system/smortress-tailscale-ssh-off.service` | Re-asserts `tailscale set --ssh=false` at every boot; tailscaled persists the preference, so removing the flag from the enrollment unit is not enough. Tailscale SSH is retired. |
| `/etc/pam.d/sudo` and `/etc/sudoers.d/10-human-gate` | The sudo PIN gate: `pam_faillock` preauth, then `pam_userdb` against the literal path `/etc/security/sudopin.db` with `crypt=crypt`, so the stored value is a sha512crypt hash and not the PIN; then `pam_unix` re-verifying the same string the prompt already cached. A 30-minute ticket per TTY and `log_subcmds`. The database is a host file built from `docs/manual-steps.md` section 45 and never enters the image. |
| `/usr/share/smortress/quadlet/pattern.container` | Quadlet base pattern; not enabled, no `[Install]`. |
| `/usr/share/containers/systemd/*.container` | The application Quadlets (T5). A quadlet is a generated unit, so `[Install]` is what starts it; the image never runs `systemctl enable` for one. |
| `/usr/lib/systemd/system/smortress-app-secrets.service` | Turns the decrypted application secrets into Podman secrets before any container that declares one starts. |
| `/usr/lib/systemd/system/smortress-tailscale-serve.service` | Re-declares the Tailscale Serve routes at boot; Serve state is not backed up. |
| `/usr/lib/systemd/system/smortress-immich-dump.{service,timer}` | The logical Immich restore point inside the photos group, at 21:00 UTC, three hours before the R2 run. |

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
before bootc takes over. `bootc switch` and `bootc upgrade` use
`--enforce-container-sigpolicy`; a digest without a valid signature is refused.

Ignition likewise delivers `/var/lib/homelab/.ssh/authorized_keys`, inlining the
committed `ignition/smortress-authorized-keys`, because bootc does not reconcile
`/var`: an image-baked copy would never appear on an installed host. The
committed file carries instructions and no key — a resident `sk-` handle can only
be created with the token — so sshd authenticates nobody until a key line is
appended (`docs/manual-steps.md` section 42). The file and its `.ssh` directory
are smores-owned, and `/var/lib/homelab` is `0711`, because sshd opens
`AuthorizedKeysFile` with the target user's uid rather than root's.

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
sudo bootc upgrade --enforce-container-sigpolicy
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
sudo bootc upgrade --enforce-container-sigpolicy   # every later update
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
Quadlet is installed. Nothing publishes `0.0.0.0` or `::`.

## Secrets

SOPS/age remains the versioned format. `secrets/server/*.yaml` is ciphertext for
the admin age recipient in `.sops.yaml`; the same passphrase-wrapped identity is
staged root-only at `/var/lib/homelab/age/keys.txt` from the offline kit
(unwrapped to the `AGE-SECRET-KEY-...` form there; the kit container itself is
not readable without the paper passphrase).
`sops-decrypt.service` decrypts on every boot into `/run/smortress/secrets`
with the owner/group/mode in `secrets.manifest`. A missing identity, a missing
ciphertext, an unlisted ciphertext or a manifest mismatch fails the unit, so
dependent Quadlets fail closed. Services mount the decrypted file; they do not
receive it as an environment variable.

The T2 probe is `secrets/server/canary.yaml`: ciphertext whose plaintext is
`canary: sops-decrypt-ok`. It proves the image, age identity, unit and
least-privilege write path without adding an application secret.

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

