# Operator steps

Everything here needs a human at the keyboard: a token in a port, a PIN, or a
reboot. The image ships the mechanism and nothing else — no credential, PIN,
hash or database is in this repository or in the image, by design. Run the
steps in order, once per machine, from the running laptop.

## 1. Enrol the key for disk unlock

The disk keeps its passphrase keyslot. FIDO2 is added beside it, so a lost or
blocked token costs the passphrase, not the volume.

Find the volume and the token first:

```sh
lsblk -o NAME,FSTYPE,UUID,MOUNTPOINTS
systemd-cryptenroll --fido2-device=list
```

The volume is the `crypto_LUKS` line whose child is `/`. `--fido2-device=list`
prints the plugged-in tokens and their `/dev/hidraw` nodes; if it prints nothing,
the token is not in a working port and the rest of this section cannot work.

Then enrol it:

```sh
sudo systemd-cryptenroll --fido2-device=auto --fido2-with-client-pin=yes /dev/nvme0n1p3
```

Replace the device with the one from `lsblk`. The command prompts for the
token's FIDO2 PIN — **setting it first if the token has none** — and then for a
touch. `--fido2-with-client-pin=yes` is the default, and it is repeated here
because it is the whole point: the PIN the token verifies at boot is the same
secret the lock screen later asks for, and a stolen-but-docked token cannot
unwrap the volume without it. Touch here is genuine, because you are at the
keyboard at boot.

Prove the new keyslot works before rebooting:

```sh
uuid=$(lsblk -no UUID /dev/nvme0n1p3)
sudo systemd-cryptsetup attach fido2test "/dev/disk/by-uuid/$uuid" none fido2-device=auto
sudo systemd-cryptsetup detach fido2test
```

`attach` prints nothing when it succeeds and asks for the PIN and a touch.
`detach` unmounts nothing — the test activation was never mounted.

Now make boot ask for the token. This image builds one generic initramfs, so it
carries no `/etc/crypttab`; root is unlocked in the initramfs from
`rd.luks.uuid=`, and a crypttab written on the running host would never be read
at boot. The option therefore goes on the kernel command line, per machine:

```sh
sudo rpm-ostree kargs --append="rd.luks.options=$uuid=fido2-device=auto"
```

If this host does have a `/etc/crypttab` carrying the root entry, the option
belongs in that line's third field instead, and nothing else changes:

```
luks-<uuid> UUID=<uuid> none,fido2-device=auto
```

Confirm the shipped initramfs can do FIDO2 at all. Both matches must appear: the
image builds every non-hostonly initramfs with dracut's `fido2` module, which is
what puts the library and systemd's cryptsetup token plugin there.

```sh
lsinitrd | grep -E 'libfido2|cryptsetup-token-systemd-fido2'
```

Record the keyslots, then reboot:

```sh
sudo cryptsetup luksDump "/dev/disk/by-uuid/$uuid" | grep -A6 Tokens
sudo systemctl reboot
```

At the next boot the prompt wants the FIDO2 PIN and a touch before it offers
anything else. Two checks that it is really a fallback and not a new lock:

- Pull the key out and reboot: boot must stop at the passphrase prompt.
- With the key in, type the wrong PIN: boot must reach the passphrase prompt
  after the retries.

If either one fails, `Ctrl+Alt+F2` on a booted system is the way back in; the
initramfs prompt is the only place a broken boot can strand you, and the
passphrase keyslot was never touched.

## 2. Enrol the key for the lock screen and TTY

The lock screen and a TTY authenticate through `/etc/pam.d/login`, which this
image shadows to run `pam_u2f.so pinverification=1 cue` ahead of the password
stack. What is missing on a fresh host is the mapping file the module reads —
one line binding one credential to the account — and only the physical key can
produce it:

```sh
sudo pamu2fcfg -N -u smores | sudo tee /etc/u2f_mappings >/dev/null
sudo chmod 0644 /etc/u2f_mappings
```

`-N` marks the credential as requiring PIN verification, which is the property
the module line enforces. The command asks for the FIDO2 PIN set in step 1 and
then for a touch.

Leave the origin alone. `pamu2fcfg` defaults the relying party to
`pam://$HOSTNAME` and `pam_u2f.so` verifies against that same default — which is
why the PAM line carries no `origin=` option and must not gain one. Renaming
the machine invalidates the mapping; delete `/etc/u2f_mappings` and run the two
commands again.

Lock the session (`Super+Alt+L`) and unlock it:

- With the key in: type the FIDO2 PIN, then touch. A touch alone fails, which is
  what keeps a docked token from unlocking the machine by itself.
- The account password is the fallback, but Noctalia's lock screen supplies a
  single answer per attempt, so the password path there needs a second attempt
  in practice (design open question 1). A TTY asks twice and always falls back:

```sh
# Ctrl+Alt+F2, then log in as smores
# the first prompt is pam_u2f asking for the FIDO2 PIN: type the account
# password instead, let it fail, and answer the password prompt that follows
```

If the token is lost or its PIN is blocked, unlock from the TTY, remove
`/etc/u2f_mappings`, and the lock screen is password-only again until a new
mapping exists. A blocked PIN is a token reset, which erases every resident
credential at once — the disk keyslot from step 1 included, which is why the
passphrase stays enrolled.

## 3. Build the sudo PIN database

`/etc/pam.d/sudo` authenticates against an eight-digit PIN in a gdbm database,
`/etc/security/sudopin.db`. The key is the PAM user name, and the account that
logs in and runs sudo on this machine is **`smores`**.

Two properties of the shipped stack decide what the database may contain. Both
were checked against this image's own `pam_userdb` (Linux-PAM 1.7.2), and both
differ from what the design text assumes:

- `db=/etc/security/sudopin` is opened literally. Linux-PAM no longer appends
  `.db`, so the image ships `/etc/security/sudopin` as a symlink to
  `sudopin.db`, the file tmpfiles declares. The database goes in
  `sudopin.db`; the symlink is never written.
- The module line carries no `crypt=` option, and pam_userdb's documented
  default is a literal comparison ("default to plaintext password storage"), so
  the stored value is the PIN itself, not a hash of it. This is not a weaker
  secret than the design describes: 0600 root:root is the whole property, and an
  eight-digit sha512crypt hash is 10^8 candidates — seconds of work for anything
  that can already read the file. Adding `crypt=crypt` to the line is what would
  let the file hold a hash, and that is a change to both hosts' stack.

`db_load -T -t hash` is never the tool here, whatever the stack holds:
Fedora's `pam_userdb` links libgdbm and cannot read a Berkeley DB file.

```sh
read -rsp 'new sudo PIN (8 digits): ' pin; echo
read -rsp 'again: ' pin2; echo
[[ $pin =~ ^[0-9]{8}$ && $pin == "$pin2" ]] \
  || { echo 'not eight digits, or the two entries differ' >&2; exit 1; }
db=$(mktemp -d)
printf 'store "smores" "%s"\n' "$pin" | gdbmtool -n "$db/sudopin.db"
unset pin pin2
printf 'fetch "smores"\n' | gdbmtool -r "$db/sudopin.db"   # reads the value back
sudo install -m 0600 -o root -g root "$db/sudopin.db" /etc/security/sudopin.db
rm -rf "$db"
```

Nothing here is recoverable later: no copy in this repository, in SOPS or in the
image, on purpose — a hash an agent can read is a PIN an agent can hold. Build
the same PIN by hand on the other host; consistency comes from that, never from
a shared file.

Before relying on the gate, make sure a way to root exists that is not sudo:
`su -` on root's password if one is set, or a rescue boot. The stack below ends
the authentication itself, so the account password does not reach past it.

Prove it:

```sh
sudo -k; sudo true      # the PIN
sudo true               # no prompt: the same TTY, inside 30 minutes
```

- A different TTY prompts again (`timestamp_type=tty`), and a process without a
  TTY gets no ticket at all.
- Five wrong PINs cost five minutes in which sudo refuses everything, the right
  PIN included. Recover from a TTY with `su -`, then
  `faillock --user smores --reset`.
- A wrong PIN does **not** fall through to the account password:
  `[default=die]` on the faillock line ends the stack before `system-auth` runs,
  which is the opposite of the design's "the account password covers a lost
  PIN". Both hosts ship that line byte for byte, so this is a decision for the
  stack, not for this machine: `[default=die]` is what makes faillock a hard
  gate, and `[default=ignore]` is what would let the password through — at the
  cost of letting it through during a lockout too.
- Every sudo command raises its subcommands in the journal (`log_subcmds`).
