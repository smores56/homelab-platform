# smorespro-image

The bootc image for the smorespro laptop: Fedora's minimal `fedora-bootc` base
plus a niri session with the Noctalia shell. Built, signed, and published to
`ghcr.io/smores56/smorespro-image` by GitHub Actions.

The design and the task graph live in the private ledger: `sdlc show 732`.
The migration runbook is `docs/switch.md`.

## Contract

| File | Owns |
| --- | --- |
| `image/pins.env` | every external reference: the `FEDORA_VERSION` knob the base tag follows, and the NymVPN pin a refresh edits |
| `image/Containerfile` | the derived image: one explicit package set, config copy, unit enables, `bootc container lint` |
| `image/rootfs/` | files copied into `/`: greetd autologin, portal override, signature policy, the NymVPN unit and its polkit action, the `login` and `sudo` PAM stacks, and the FIDO2 mapping the `sudo` stack reads |
| `image/cosign.pub` | the public half of the signing key shared with `homelab-platform` |
| `scripts/refresh-pins.sh` | resolves the NymVPN release and prints the base tag's current digest; `--check` for the watcher, `--write` to move the NymVPN pin |
| `scripts/build-image.sh` | local build; never pushes or signs |
| `docs/manual-steps.md` | the steps only a hand at the keyboard can do: token enrolment for the disk keyslot, the lock screen and sudo, and rotating the FIDO2 mapping |
| `tests/check.sh` | static checks over the files above |

## Rules

- The base tracks the `fedora-bootc` release tag (`FEDORA_VERSION=45` in
  `image/pins.env`), not a digest. Quay garbage-collects the manifests behind
  that tag within hours, so a pinned digest rots into `manifest unknown`: three
  build failures in one day is what moved this repository off pinning. Each
  build resolves the tag and records the result in the
  `org.opencontainers.image.base.digest` label, so every published image still
  says exactly which base it was built on. The trade is deliberate: two builds
  of the same commit can differ in base packages, so the base is not
  reproducible. What stands in for that is `tests/check.sh`, the cosign
  signature on the image this repository builds, and `bootc rollback` on the
  laptop.
- No secrets, private keys, or per-machine state enter the image. The one
  carve-out is `/etc/u2f_mappings`: it is public credential data (a key handle
  and a public key per token, useless without the token itself, and bound to
  this hostname), not a secret and not machine state, and shipping it is what
  lets a fresh host gate sudo on a touch without a hand at the keyboard.
- The shipped policy rejects by default, requires a signature only for this
  image's repository, and allows unsigned pulls from `docker.io`, `quay.io`,
  and `registry.fedoraproject.org` so `podman pull` and local builds keep
  working next to the signature check.
- The signing key is the `homelab-platform` keypair; only its public half is
  committed here. Policy scoping (`signedIdentity: matchRepository`) is what
  keeps the two image families from trusting each other's signatures.
- Host packages only come from this repository. `rpm-ostree install` on the
  running laptop is never the answer.

## Rebuilds

Nothing rebuilds on a schedule. A build happens when this repository changes,
and a change to `image/**` or `scripts/**` is what publishes a new image. The
base needs no refresh step: the next build picks up whatever
`fedora-bootc:${FEDORA_VERSION}` resolves to, and the digest it got is on the
image.

A NymVPN release is the one thing worth moving by hand:

```sh
scripts/refresh-pins.sh          # the base tag's current digest, informationally
scripts/refresh-pins.sh --check  # is there a newer NymVPN release?
scripts/refresh-pins.sh --write  # move that pin
```

then commit the `image/pins.env` change. The scheduled watcher opens an issue
when `--check` sees a newer release; it has nothing to say about the base.

CI keeps the package layer in `ghcr.io/smores56/smorespro-image-cache`, a
sibling package to the image. A cache key covers the parent layer and the
instruction's text, not the repositories the instruction reads, so the layer is
reused until the base digest in `image/pins.env` or the `RUN` line changes — the
pin bump is what re-resolves packages. `scripts/build-image.sh` never touches the
cache; a local build is uncached and offline-safe.

## Package sources

The image installs from the Fedora 45 repositories configured in the base tag it
builds from. Because the base is a tag, the kernel, glibc and systemd are
whatever that tag resolved to at build time, and packages added here resolve
from Fedora 45 updates at the same moment; the image's
`org.opencontainers.image.base.digest` label and its
`/usr/share/smorespro/package-manifest` are how a given build is identified
after the fact.

Two exceptions, both absent from Fedora:

- Brave Origin ships only from Brave's official `brave-browser` RPM repository,
  which the Containerfile writes into `/etc/yum.repos.d/`, installs from, and
  re-disables so nothing else in the image trusts it.
- NymVPN publishes no RPM (`.deb`, AUR, AppImage, Flatpak and a shell installer
  only), so the Containerfile vendors the pinned release tarball: the daemon and
  the CLI, checked against the per-architecture sha256 in `image/pins.env`.
  `scripts/refresh-pins.sh` is what moves that pin.

kitty (terminal), dolphin (file manager), ImageMagick and jq come from Fedora.
