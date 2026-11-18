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

The shipped module line is
`pam_userdb.so crypt=crypt db=/etc/security/sudopin.db`. Two options decide what
the file may hold:

- `crypt=crypt` makes the stored value a **sha512crypt hash**, not the PIN. That
  is what the design asks for: an eight-digit space is 10^8 candidates, so
  anything an unprivileged process can read is not a secret — a hash at least
  keeps a reader of the file from holding the PIN itself.
- `db=` is opened literally. Linux-PAM never appends `.db`, so the path in the
  stack is the whole file name and the image ships no second name for it.

`db_load -T -t hash` is never the tool here, whatever the file holds: Fedora's
`pam_userdb` links libgdbm and cannot read a Berkeley DB file.

Take the PIN at a prompt, hash it, and store the hash under the key `smores`.
`openssl passwd -6 -stdin` reads the PIN from standard input, so it never
appears in an argument list where `ps` would show it:

```sh
read -rsp 'new sudo PIN (8 digits): ' pin; echo
read -rsp 'again: ' pin2; echo
[[ $pin =~ ^[0-9]{8}$ && $pin == "$pin2" ]] \
  || { echo 'not eight digits, or the two entries differ' >&2; exit 1; }
hash=$(printf '%s\n' "$pin" | openssl passwd -6 -stdin)
unset pin pin2
sudo rm -f /etc/security/sudopin.db
printf 'store smores %s\n' "$hash" | sudo gdbmtool /etc/security/sudopin.db
unset hash
sudo chown root:root /etc/security/sudopin.db
sudo chmod 0600 /etc/security/sudopin.db
printf 'fetch smores\n' | sudo gdbmtool -r /etc/security/sudopin.db
```

The last line prints the hash back, which is the check that the key is spelled
`smores` and nothing else is in the database.

Nothing here is recoverable later: no copy in this repository, in SOPS or in the
image, on purpose — a hash an agent can read is a PIN an agent can hold. Build
the same PIN by hand on the other host; consistency comes from that, never from
a shared file.

Before relying on the gate, make sure a way to root exists that is not sudo:
`su -` on root's password if one is set, or a rescue boot. A forgotten PIN is
not the case this covers — the account password answers that at the sudo prompt
— it covers a stack that no longer parses.

Prove it:

```sh
sudo -k; sudo true      # the PIN
sudo true               # no prompt: the same TTY, inside 30 minutes
```

- A different TTY prompts again (`timestamp_type=tty`), and a process without a
  TTY gets no ticket at all.
- The fallback is **one prompt, not two**. `pam_userdb` caches the value typed
  at that prompt and `pam_unix.so try_first_pass` re-verifies it, so typing the
  account password instead of the PIN authenticates without a second prompt.
  The TTY that asks twice in step 2 is the `pam_u2f` lock-screen stack, where
  two different modules ask for two different credentials; that does not happen
  here.
- faillock counts one row per PAM transaction and sudo makes three per
  invocation, so **five wrong prompts**, not five invocations, are what cost
  five minutes. A successful authentication clears the tally. While the lock
  stands the correct password is refused too, because `preauth` denies the
  transaction before anything compares a value. Clear it manually from a root
  shell reached without sudo: `faillock --user smores --reset`.
- Every sudo command raises its subcommands in the journal (`log_subcmds`).
