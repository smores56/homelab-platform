# Operator steps

Everything here needs a human at the keyboard: a token in a port, a PIN, or a
reboot. The image ships the mechanism and the public half of the token mapping —
key handles and public keys, which are not secrets — and nothing else: no
password, PIN, hash or private key is in this repository or in the image, by
design. Run the steps in order, once per machine, from the running laptop.

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

## 2. The key for the lock screen, TTY and sudo

Two PAM stacks read one mapping file, `/etc/u2f_mappings`:

- `/etc/pam.d/login` (the lock screen and a TTY) runs
  `pam_u2f.so pinverification=1 cue` ahead of the password stack: the token's
  FIDO2 PIN, then a touch.
- `/etc/pam.d/sudo` runs
  `pam_u2f.so authfile=/etc/u2f_mappings cue userpresence=1 pinverification=0`
  ahead of `pam_unix`: a tap alone escalates, and the account password sits
  behind it as the fallback, so no key, no credential for `smores` or a refused
  touch costs typing rather than access. No PIN in either case: the FIDO2 PIN is
  the same one the disk keyslot uses, and eight wrong PINs block the token and
  wipe every credential on it, so a sudo prompt that any process running as
  `smores` can trigger must never be able to spend that budget. That is the one
  place the two stacks differ; the lock screen is unchanged.

The mapping is public credential data — a key handle and a public key per token,
no secret — so it is committed at `image/rootfs/etc/u2f_mappings` and shipped to
`/etc/u2f_mappings` with the rest of `image/rootfs`. A fresh host therefore needs
no hand-written file; what it needs is a mapping that describes credentials the
owner's keys actually hold.

All three 5C Nanos are registered (one per laptop, one spare), so any of them
opens both stacks. To rotate the mapping, or to add a replaced key, plug in one
5C Nano at a time and register on the laptop itself, from the repository root.
The first key prints the username; every further key uses `-n`, which prints
only its credential, because a second `smores:` inside the line would be read as
a key handle:

```sh
first=$(pamu2fcfg -u smores)      # key 1 in the port
second=$(pamu2fcfg -n -u smores)  # key 2
third=$(pamu2fcfg -n -u smores)   # key 3, the spare
printf '%s:%s:%s\n' "$first" "$second" "$third" >image/rootfs/etc/u2f_mappings
```

Then commit the file and `bootc upgrade`: the running host keeps its current
mapping until the new deployment boots, and `bootc rollback` restores the old
one. Neither command needs root — `pamu2fcfg` only talks to the token. The
`printf` is not decoration: `pamu2fcfg` ends its line without a newline, so
writing its output directly would give a one-credential file with no terminator
and no room for an appended second credential.

Leave the origin alone. `pamu2fcfg` defaults the relying party to
`pam://$HOSTNAME` and `pam_u2f.so` verifies against that same default — which is
why neither PAM line carries an `origin=` option and neither may gain one.
Registering on another machine, or renaming this one, invalidates the mapping:
re-register with the laptop's own name and commit the result.

Register without `-N`. It writes `+pin` into the credential, and `pam_u2f`
turns `+pin` into a PIN request even where a stack says `pinverification=0`, so
the sudo gate would start asking for the disk's PIN. The credential's
`+presence` (the default) plus `userpresence=1` in the sudo line are what make
the touch mandatory in both stacks.

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

If the token is lost or its PIN is blocked, the lock screen still opens with the
account password: `sufficient` leaves system-auth's password behind `pam_u2f`.
A blocked PIN is a token reset, which erases every resident credential at once —
the disk keyslot from step 1 included, which is why the passphrase stays
enrolled. A replaced key is a rotation of the mapping above.

## 3. Prove the sudo gate

sudo asks for one gesture. With a key in the port it prints the `cue` reminder
and waits for a tap; nothing is typed, and the tap alone opens the gate.

```sh
sudo -k; sudo true      # touch
sudo true               # no prompt: the same TTY, inside 30 minutes
```

The account password is the fallback, and it is a full one: no key in the port,
a key holding no credential for `smores`, or a tap refused (`pam_u2f` reports
each of these as a failed authentication) all fall through to the password
prompt, which works.

```sh
sudo -k; sudo true      # key unplugged: password prompt, then in
sudo -k; sudo true      # key in, tap refused: password prompt, then in
```

Neither prompt ever asks for the FIDO2 PIN: `pinverification=0` keeps the disk
keyslot's PIN budget out of sudo's reach.

- The ticket lasts 30 minutes and only on the TTY that earned it
  (`timestamp_timeout=30`, `timestamp_type=tty` in
  `/etc/sudoers.d/10-human-gate`). A different TTY prompts again, and a process
  without a TTY gets no ticket at all.
- A tap and a password both clear the tally: each row's `success=N` lands on
  `authsucc` rather than terminating the stack, so a success after earlier typos
  resets the count.
- A wrong password and a refused tap both land on `authfail`, which dies, so
  neither can be probed indefinitely.
- faillock counts one row per PAM transaction and sudo makes three per
  invocation, so **five wrong prompts**, not five invocations, are what cost
  five minutes. While the lock stands the correct password is refused too,
  because `preauth` denies the transaction before anything compares a value.
  Clear it manually from a root shell reached without sudo:
  `faillock --user smores --reset`.
- Every sudo command raises its subcommands in the journal (`log_subcmds`).

Before relying on the gate, make sure a way to root exists that is not sudo:
`su -` on root's password if one is set, or a rescue boot. The password is the
break-glass everywhere — a missing or broken key costs typing, not access — and
the console is what covers a forgotten password.
