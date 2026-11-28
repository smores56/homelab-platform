# Laptop runbook

The steps only a hand at the keyboard can do, in order, once per machine, from the
running laptop. The image ships the mechanism and the public half of the token
mapping — key handles and public keys, which are not secrets — and nothing else.

## 1. Enrol the key for disk unlock

FIDO2 is added beside the passphrase keyslot, so a lost or blocked token costs the
passphrase, not the volume. Find the volume and the token first:

```sh
lsblk -o NAME,FSTYPE,UUID,MOUNTPOINTS
systemd-cryptenroll --fido2-device=list
```

The volume is the `crypto_LUKS` line whose child is `/`. `--fido2-device=list` must
print the plugged-in token and its `/dev/hidraw` node; an empty list means the token
is not in a working port and the rest of this procedure cannot work.

Then enrol it, replacing the device with the one `lsblk` showed. The command prompts
for the token's FIDO2 PIN — **set it first if the token has none** — and then for a
touch. **A lost PIN is a token reset, which erases every resident credential on the
token**:

```sh
sudo systemd-cryptenroll --fido2-device=auto --fido2-with-client-pin=yes /dev/nvme0n1p3
```

Prove the new keyslot works before rebooting. `attach` prints nothing when it
succeeds and asks for the PIN and a touch:

```sh
uuid=$(lsblk -no UUID /dev/nvme0n1p3)
sudo systemd-cryptsetup attach fido2test "/dev/disk/by-uuid/$uuid" none fido2-device=auto
sudo systemd-cryptsetup detach fido2test
```

Now make boot ask for the token. The image builds one generic initramfs, so the
option goes on the kernel command line rather than in a crypttab:

```sh
sudo rpm-ostree kargs --append="rd.luks.options=$uuid=fido2-device=auto"
```

If this host does have a `/etc/crypttab` carrying the root entry, the option belongs
in that line's third field instead, and nothing else changes:

```
luks-<uuid> UUID=<uuid> none,fido2-device=auto
```

Both matches must appear: the `fido2` module is what puts the library and systemd's
cryptsetup token plugin in the initramfs.

```sh
lsinitrd | grep -E 'libfido2|cryptsetup-token-systemd-fido2'
```

Record the keyslots, then reboot:

```sh
sudo cryptsetup luksDump "/dev/disk/by-uuid/$uuid" | grep -A6 Tokens
sudo systemctl reboot
```

At the next boot the prompt wants the FIDO2 PIN and a touch before it offers
anything else. Two checks that it is a fallback and not a new lock:

- Pull the key out and reboot: boot must stop at the passphrase prompt.
- With the key in, type the wrong PIN: boot must reach the passphrase prompt after
  the retries.

If either one fails, `Ctrl+Alt+F2` on a booted system is the way back in; the
passphrase keyslot was never touched.

## 2. The key for sudo

`/etc/pam.d/sudo` runs `pam_u2f` ahead of `pam_unix`: a tap alone escalates and the
account password sits behind it. **Neither prompt ever asks for the FIDO2 PIN: eight
wrong PINs block the token and wipe every credential on it, the disk keyslot from
step 1 included.**

The mapping is public credential data, committed at `rootfs/etc/u2f_mappings` and
shipped to `/etc/u2f_mappings`. All three 5C Nanos are registered. To rotate it, or
to add a replaced key, plug in one 5C Nano at a time and register on the laptop
itself, from the repository root. The first key prints the username; every further
key uses `-n`, which prints only its credential, because a second `smores:` inside
the line would be read as a key handle:

```sh
first=$(pamu2fcfg -u smores)      # key 1 in the port
second=$(pamu2fcfg -n -u smores)  # key 2
third=$(pamu2fcfg -n -u smores)   # key 3, the spare
printf '%s:%s:%s\n' "$first" "$second" "$third" >rootfs/etc/u2f_mappings
```

Then commit the file and `bootc upgrade`; neither command needs root. Compare the
deployment's copy before trusting the running one — bootc's `/etc` merge keeps a
mapping this host wrote by hand:

```sh
diff /usr/etc/u2f_mappings /etc/u2f_mappings
sudo cp /usr/etc/u2f_mappings /etc/u2f_mappings && sudo chmod 644 /etc/u2f_mappings
sudo -k; sudo true      # one touch, no PIN
```

A stale mapping falls through to the password, or asks for the FIDO2 PIN that
`pinverification=0` exists to keep out of sudo's reach. `bootc rollback` brings the
previous deployment's copy back the same way. The `printf` is not decoration:
`pamu2fcfg` ends its line without a newline.

Leave the origin alone: `pamu2fcfg` and `pam_u2f.so` both default the relying party
to `pam://$HOSTNAME`, so **registering on another machine or renaming this one
invalidates the mapping** — neither PAM line may gain an `origin=` option.
**Register without `-N`**: it writes `+pin`, and `pam_u2f` turns that into a PIN
request even where a stack says `pinverification=0`.

Lock the session (`Super+Alt+L`) and unlock it. With a per-user mapping at
`~/.config/Yubico/u2f_keys` the lock screen asks for the FIDO2 PIN and a touch;
without one — the stock image — it asks for the account password:

- With a per-user mapping and the key in: type the FIDO2 PIN, then touch. A touch
  alone fails.
- That PIN prompt is the token's, not the account's: **whatever is typed there goes
  to the key, and a wrong entry burns one of its attempts**. Never type the account
  password into it.
- The account password is reached only after `pam_u2f` gives up. Noctalia's lock
  screen supplies a single answer per attempt, so leave the PIN prompt empty, let it
  fail, and the password prompt follows. A TTY asks twice and always falls back:

```sh
# Ctrl+Alt+F2, then log in as smores
# the first prompt is pam_u2f asking for the FIDO2 PIN: press Enter with
# nothing typed, let it fail, and answer the password prompt that follows
```

If the token is lost or its PIN is blocked, the lock screen still opens with the
account password. A replaced key is a rotation of the mapping above.

## 3. Prove the sudo gate

```sh
sudo -k; sudo true      # touch
sudo true               # no prompt: the same TTY, inside 30 minutes
```

```sh
sudo -k; sudo true      # key unplugged: password prompt, then in
sudo -k; sudo true      # key in, tap refused: password prompt, then in
```

A docked key holding no credential for this user is the slow case: `pam_u2f` runs
one `fido_dev_get_assert` per credential in the mapping behind a single `cue`, each
waiting out libfido2's device timeout. Plug the key in when you mean to tap.

- The ticket lasts 30 minutes and only on the TTY that earned it
  (`timestamp_timeout=30`, `timestamp_type=tty` in
  `/etc/sudoers.d/10-human-gate`).
- A tap and a password both clear the tally; only password failures reach
  `authfail`, so five refused taps lock nothing while five wrong passwords do.
- faillock counts one row per PAM transaction and sudo makes three per invocation,
  so **five wrong prompts**, not five invocations, are what cost five minutes. While
  the lock stands the correct password is refused too. Clear it from a root shell
  reached without sudo: `faillock --user smores --reset`.

**Before relying on the gate, make sure a way to root exists that is not sudo**:
`su -` on root's password if one is set, or a rescue boot.

## 4. Grant the Tailnet widget operator access

Noctalia's Tailnet widget drives the Tailscale CLI as `smores`. A fresh join passes
the grant in the command that creates the profile:

```sh
sudo tailscale up --operator=smores
```

On a host that is already joined, set it without `up`, which would re-apply the full
preference set and reset options such as exit nodes and accepted routes:

```sh
sudo tailscale set --operator=smores
```

Verify the stored grant. It prints `"OperatorUser": "smores"` once the grant is
persisted; opening the panel and disconnecting is the end-to-end check:

```sh
tailscale debug prefs | grep OperatorUser
```

Operator is Tailscale's whole LocalAPI write permission — `tailscale serve`,
`tailscale ssh` and preference changes without the FIDO2 sudo gate — which is why
the grant belongs to `smores` alone.

## 5. Join the Syncthing cluster

The image ships the package and enables the user unit globally, so the service
starts at the first login with nothing to type. The GUI is loopback only:
`http://127.0.0.1:8384`.

1. Add smortress as a device by the ID its own GUI shows under Actions → Show ID,
   with the address `tcp://smortress:22000`. Tailscale must be up: the ACL admits
   22000 only on the tailnet.
2. Accept the laptop on the smortress GUI and share the one folder with it as
   Send & Receive: ID `files`, path `/srv/files`, holding `todos/`, `notes/` and
   `vault/`.
3. Check it without the GUI. The first sync is about 5.1G; subsequent ones are
   incremental.

```sh
systemctl --user status syncthing
ls -ld /var/srv/files /var/srv/files/todos
```

**Never run the old per-directory layout (`notes` and `vault` as two folders) on one
device in the same window as this one**: Syncthing does not support nesting folders.
A phone that should not hold the vault can ignore `/vault` in its own `.stignore`.

**After smortress has restored the vault's Syncthing identity, do not connect this
laptop until smortress has designated a primary**: a peer that syncs first writes
over a tree whose identity was just replaced.

## 6. Reboot for a staged update

Nothing reboots this laptop for you. The image follows
`ghcr.io/smores56/smorespro-image:latest` and stages what the tag names; the
reboot is the update, and it is yours to ask for. The vendor unit would instead
run `bootc upgrade --apply` an hour after boot and every 8h with jitter, which is
a laptop that reboots mid-session and stalls at the disk's FIDO2 prompt.

A staged update is announced at the start of every session and written down at

```
~/.local/state/bootc-update-pending
```

which holds `version=<staged version>` and `command=sudo systemctl reboot`. The
reminder derives it from `rpm-ostree status` on each session start and removes it
when nothing is staged, so a prompt that reads it never asks for a reboot that
would do nothing.

Check what is waiting, then reboot and check what came back:

```sh
systemctl cat bootc-fetch-apply-updates.service   # one ExecStart, and no --apply
rpm-ostree status                                 # a deployment marked "Staged: yes"
sudo systemctl reboot
rpm-ostree status                                 # that version is now booted
```

"The update landed" and "the laptop did not reboot itself" are two different
facts, and the second is what this image exists for. After a publish, leave the
laptop up across the window -- a day, or resume it after a missed one -- and
check that the deployment staged while the session kept running:

```sh
rpm-ostree status   # "Staged: yes", and the booted deployment unchanged
uptime -s           # the session that started before the window
```

`sudo bootc rollback` reverts a deployment that booted badly; it does not revert
`/var`.
