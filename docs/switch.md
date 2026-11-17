# Switching smorespro to this image

This is the operator runbook for moving an installed Fedora Atomic host to the
`smorespro-image` bootc image, and for getting back. It is the only document
that recommends touching `bootc` on the laptop.

## Before you start

- The user `smores` exists, with a password. greetd autologins as that user;
  if it is missing, greetd exits and VT1 stays black.
- `dotfiles` is deployed (or accept the image's fallback niri config, which has
  one terminal and no full keybind set).
- Network works: WiFi or a USB tether. The switch pulls the image.
- The GHCR package is readable. The first push creates it **private**; either
  make it public in the package settings, or authenticate first with a token
  that has `read:packages`:

  ```sh
  podman login ghcr.io -u smores56
  ```

## 1. Keep a way back

Pin the current deployment. This survives the switch and shows up in the GRUB
menu, so a broken image is one reboot away from a working system.

```sh
sudo ostree admin pin 0
rpm-ostree status          # the current deployment is now pinned
```

## 2. Verify the artifact, then switch to its digest

`bootc switch --enforce-container-sigpolicy` checks the *host's* policy, and a
pre-switch Fedora Atomic host has no `/etc/containers/policy.json` — so the
flag cannot verify anything here and the runbook does not use it. Instead the
pull is verified before the switch, with the same policy the image ships, and
the switch targets the exact digest that was verified. From the first boot
onward the image's own policy enforces every upgrade.

```sh
# Stage the shipped policy against the committed key and pull in a scratch dir.
tmp=$(mktemp -d)
mkdir -p "$tmp/registries.d"
curl -fsSLo "$tmp/cosign.pub" \
  https://raw.githubusercontent.com/smores56/smorespro-image/main/image/cosign.pub
curl -fsSLo "$tmp/policy.json" \
  https://raw.githubusercontent.com/smores56/smorespro-image/main/image/rootfs/etc/containers/policy.json
jq --arg k "$tmp/cosign.pub" \
  '.transports.docker["ghcr.io/smores56/smorespro-image"][0].keyPath=$k' \
  "$tmp/policy.json" >"$tmp/policy.local.json"
curl -fsSLo "$tmp/registries.d/smorespro.yaml" \
  https://raw.githubusercontent.com/smores56/smorespro-image/main/image/rootfs/etc/containers/registries.d/ghcr.io-smorespro-image.yaml
skopeo copy --policy "$tmp/policy.local.json" --registries.d "$tmp/registries.d" \
  docker://ghcr.io/smores56/smorespro-image:latest "dir:$tmp/out"
digest=$(skopeo inspect --format '{{.Digest}}' docker://ghcr.io/smores56/smorespro-image:latest)
echo "verified digest: $digest"
```

A failure here means the signature or the key does not match; stop.

Then drop the layered packages. `bootc` refuses to touch a deployment with
local rpm-ostree modifications, and the pinned deployment keeps its layers as
the rollback target.

```sh
sudo rpm-ostree reset
sudo bootc switch "ghcr.io/smores56/smorespro-image@$digest"
sudo systemctl reboot
```

If `bootc switch` reports that this host is not bootc-managed, the equivalent
ostree-native command is:

```sh
sudo rpm-ostree rebase "ostree-unverified-image:registry:ghcr.io/smores56/smorespro-image@$digest"
```

The reset drops the layered packages from the booted deployment; the pinned
deployment keeps them, which is what makes it a real rollback target. `/etc`
three-way merges, `/var` and the LUKS/btrfs layout are untouched.

## 3. First boot checklist

```sh
bootc status                      # booted image is the verified digest
```

Then, in the session:

| Check | Command / action |
| --- | --- |
| Power-on prompts | LUKS is the only one; no greeter, no keyring prompt |
| Passwordless keyring | see below, once |
| WiFi | connects on its own; `nmcli device status` |
| Bluetooth | Noctalia's control center toggles it; `bluetoothctl` |
| Audio | `wpctl status`; volume keys work |
| Brightness | brightness keys work |
| Fingerprint | `fprintd-enroll` then lock and unlock |
| Suspend/resume | close the lid, reopen |
| External display | plug in a monitor |
| Flatpak | launch an app; check its file chooser |
| Screen share | start a call or `xdg-desktop-portal` test flow |
| Polkit | a privileged app shows Noctalia's auth prompt |
| Lock/idle | wait 10 minutes, or `noctalia msg session lock` |
| Tailscale | `sudo tailscale up` once, then `tailscale status` |
| Firmware | `fwupdmgr get-updates` |

Keyring, once, before any app stores a secret. Autologin gives no PAM
password, so the login keyring is provisioned empty; this is what keeps the
power-on prompt count at one.

```sh
printf '' | gnome-keyring-daemon --unlock --components=secrets
```

## 4. If the session does not come up

- `Ctrl+Alt+F2` reaches a TTY (logind's autovt) even when VT1 is black.
- `systemctl status greetd` and `journalctl -u greetd -b` name the cause; the
  usual one is a missing `smores` user or a PAM failure.
- `niri-session` run by hand from the TTY starts the session for debugging.
- `bootc rollback` returns to the previous deployment; the pinned Fedora
  deployment is also selectable in the GRUB menu.

## 5. If image pulls start failing

The shipped policy rejects anything without a valid signature for
`ghcr.io/smores56/smorespro-image`, and `/etc/containers/policy.json` is a
machine-local file. From a TTY:

```sh
sudo cp /etc/containers/policy.json /etc/containers/policy.json.bak
sudo jq '.transports.docker = {}' /etc/containers/policy.json >/tmp/p.json
sudo mv /tmp/p.json /etc/containers/policy.json
```

That disables signature enforcement until you restore the backup; it is the
escape hatch of last resort, not a normal operation.
