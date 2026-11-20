# smorespro-image

The bootc image for the smorespro laptop: Fedora's minimal `fedora-bootc` base
plus a niri session with the Noctalia shell. Built, signed, and published to
`ghcr.io/smores56/smorespro-image` by GitHub Actions.

The design and the task graph live in the private ledger: `sdlc show 732`.
The migration runbook is `docs/switch.md`.

## Contract

| File | Owns |
| --- | --- |
| `image/pins.env` | every external reference; the only file a base or NymVPN refresh edits |
| `image/Containerfile` | the derived image: one explicit package set, config copy, unit enables, `bootc container lint` |
| `image/rootfs/` | files copied into `/`: greetd autologin, portal override, signature policy, the NymVPN unit and its polkit action, the `login` and `sudo` PAM stacks, and the FIDO2 mapping the `sudo` stack reads |
| `image/cosign.pub` | the public half of the signing key shared with `homelab-platform` |
| `scripts/refresh-pins.sh` | resolves the base digest and the NymVPN release; `--check` for the watcher, `--write` to pin |
| `scripts/build-image.sh` | local build; never pushes or signs |
| `docs/manual-steps.md` | the steps only a hand at the keyboard can do: token enrolment for the disk keyslot, the lock screen and sudo, and rotating the FIDO2 mapping |
| `tests/check.sh` | static checks over the files above |

## Rules

- The base is always digest-pinned. `scripts/build-image.sh` and the
  Containerfile both refuse a tag.
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

Nothing rebuilds on a schedule. A build happens when this repository changes.
To move to a newer base or NymVPN release:

```sh
scripts/refresh-pins.sh --check   # is there a newer digest or release?
scripts/refresh-pins.sh --write   # pin it
```

then commit the `image/pins.env` change. The scheduled watcher opens an issue
when `--check` sees a newer digest or release.

## Package sources

The image installs from the Fedora 45 repositories configured in the pinned
base. The base digest fixes the kernel, glibc, and systemd; packages added here
resolve from Fedora 45 updates at build time, which is why a build only happens
on a reviewed commit.

Two exceptions, both absent from Fedora:

- Brave Origin ships only from Brave's official `brave-browser` RPM repository,
  which the Containerfile writes into `/etc/yum.repos.d/`, installs from, and
  re-disables so nothing else in the image trusts it.
- NymVPN publishes no RPM (`.deb`, AUR, AppImage, Flatpak and a shell installer
  only), so the Containerfile vendors the pinned release tarball: the daemon and
  the CLI, checked against the per-architecture sha256 in `image/pins.env`.
  `scripts/refresh-pins.sh` is what moves that pin.

kitty (terminal), dolphin (file manager), ImageMagick and jq come from Fedora.
