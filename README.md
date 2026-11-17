# smorespro-image

The bootc image for the smorespro laptop: Fedora's minimal `fedora-bootc` base
plus a niri session with the Noctalia shell. Built, signed, and published to
`ghcr.io/smores56/smorespro-image` by GitHub Actions.

The design and the task graph live in the private ledger: `sdlc show 732`.
The migration runbook is `docs/switch.md`.

## Contract

| File | Owns |
| --- | --- |
| `image/pins.env` | every external reference; the only file a base refresh edits |
| `image/Containerfile` | the derived image: one explicit package set, config copy, unit enables, `bootc container lint` |
| `image/rootfs/` | files copied into `/`: greetd autologin, portal override, signature policy |
| `image/cosign.pub` | the public half of the signing key shared with `homelab-platform` |
| `scripts/refresh-pins.sh` | resolves the current base digest; `--check` for the watcher, `--write` to pin |
| `scripts/build-image.sh` | local build; never pushes or signs |
| `tests/check.sh` | static checks over the files above |

## Rules

- The base is always digest-pinned. `scripts/build-image.sh` and the
  Containerfile both refuse a tag.
- No secrets, private keys, or per-machine state enter the image.
- The signing key is the `homelab-platform` keypair; only its public half is
  committed here. Policy scoping (`signedIdentity: matchRepository`) is what
  keeps the two image families from trusting each other's signatures.
- Host packages only come from this repository. `rpm-ostree install` on the
  running laptop is never the answer.

## Rebuilds

Nothing rebuilds on a schedule. A build happens when this repository changes.
To move to a newer base:

```sh
scripts/refresh-pins.sh --check   # is there a newer digest?
scripts/refresh-pins.sh --write   # pin it
```

then commit the `image/pins.env` change. The scheduled watcher opens an issue
when `--check` sees a newer digest.

## Package sources

The image installs from the Fedora 45 repositories configured in the pinned
base. The base digest fixes the kernel, glibc, and systemd; packages added here
resolve from Fedora 45 updates at build time, which is why a build only happens
on a reviewed commit.
