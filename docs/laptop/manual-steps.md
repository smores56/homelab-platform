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

## 2. The key for sudo

One stack names the shipped mapping file, `/etc/u2f_mappings`:

- `/etc/pam.d/sudo` runs
  `pam_u2f.so authfile=/etc/u2f_mappings cue userpresence=1 pinverification=0`
  ahead of `pam_unix`: a tap alone escalates, and the account password sits
  behind it as the fallback, so no key, no credential for `smores` or a refused
  touch costs typing rather than access. No PIN in either case: the FIDO2 PIN is
  the same one the disk keyslot uses, and eight wrong PINs block the token and
  wipe every credential on it, so a sudo prompt that any process running as
  `smores` can trigger must never be able to spend that budget.

`/etc/pam.d/login` — the lock screen and a TTY — is unchanged and names no
`authfile=`, so it reads pam_u2f's per-user default
(`$XDG_CONFIG_HOME/Yubico/u2f_keys`, else `~/.config/Yubico/u2f_keys`). This
image ships no such file, so on a stock host the lock screen opens with the
account password, exactly as before this feature; a host that installs one gets
the FIDO2 PIN and a touch there. The shipped mapping does not apply to it.

The mapping is public credential data — a key handle and a public key per token,
no secret — so it is committed at `rootfs/etc/u2f_mappings` and shipped to
`/etc/u2f_mappings` with the rest of `rootfs/`. A fresh host therefore needs
no hand-written file; what it needs is a mapping that describes credentials the
owner's keys actually hold.

All three 5C Nanos are registered (one per laptop, one spare), so any of them
answers the sudo prompt. To rotate the mapping, or to add a replaced key, plug in one
5C Nano at a time and register on the laptop itself, from the repository root.
The first key prints the username; every further key uses `-n`, which prints
only its credential, because a second `smores:` inside the line would be read as
a key handle:

```sh
first=$(pamu2fcfg -u smores)      # key 1 in the port
second=$(pamu2fcfg -n -u smores)  # key 2
third=$(pamu2fcfg -n -u smores)   # key 3, the spare
printf '%s:%s:%s\n' "$first" "$second" "$third" >rootfs/etc/u2f_mappings
```

Then commit the file and `bootc upgrade`; neither command needs root —
`pamu2fcfg` only talks to the token. What arrives on the host depends on how the
running `/etc/u2f_mappings` got there: one the image shipped is replaced with the
deployment, and one this host wrote by hand is kept, because bootc's `/etc` merge
preserves local modifications. Compare the deployment's copy before trusting the
running one:

```sh
diff /usr/etc/u2f_mappings /etc/u2f_mappings
sudo cp /usr/etc/u2f_mappings /etc/u2f_mappings && sudo chmod 644 /etc/u2f_mappings
sudo -k; sudo true      # one touch, no PIN
```

A stale mapping fails the same silent way as everything else in this stack: the
sudo prompt falls through to the password, or — when the old entry carries
`+pin` — starts asking for the FIDO2 PIN that `pinverification=0` exists to keep
out of sudo's reach. `bootc rollback` brings the previous deployment's copy
back the same way.

The `printf` is not decoration: `pamu2fcfg` ends its line without a newline, so
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
the touch mandatory.

Lock the session (`Super+Alt+L`) and unlock it. With a per-user mapping at
`~/.config/Yubico/u2f_keys` the lock screen asks for the FIDO2 PIN and a touch;
without one — the stock image — it asks for the account password, as it did
before this feature:

- With a per-user mapping and the key in: type the FIDO2 PIN, then touch. A touch alone fails, which is
  what keeps a docked token from unlocking the machine by itself.
- That PIN prompt is the token's, not the account's: whatever is typed there
  goes to the key, and a wrong entry burns one of its attempts. Eight of them
  block the token, and unblocking it is a reset that erases every resident
  credential — the disk keyslot from step 1 among them. Never type the account
  password into it.
- The account password is reached only after `pam_u2f` gives up. Noctalia's lock
  screen supplies a single answer per attempt, so the password path there takes
  a second attempt in practice (design open question 1). Leave the PIN prompt
  empty and let it fail, and the password prompt follows. A TTY asks twice and
  always falls back:

```sh
# Ctrl+Alt+F2, then log in as smores
# the first prompt is pam_u2f asking for the FIDO2 PIN: press Enter with
# nothing typed, let it fail, and answer the password prompt that follows
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
a key holding no credential for `smores`, or a tap refused all fall through to
the password prompt, which works. `pam_u2f` does not answer one code for these:
a device or touch failure is `PAM_AUTH_ERR`, a key with no credential for this
user is `PAM_USER_UNKNOWN`, a missing, unparsable or foreign-owned
`/etc/u2f_mappings` is `PAM_AUTHINFO_UNAVAIL`, and a configuration failure can
surface as `PAM_SYSTEM_ERR`. The sudo stack ignores every non-success, whatever
its code, so none of them can strand you.

```sh
sudo -k; sudo true      # key unplugged: password prompt, then in
sudo -k; sudo true      # key in, tap refused: password prompt, then in
```

A docked key holding no credential for this user is the slow case, and the cost
is worth knowing before you meet it: `pam_u2f` runs one `fido_dev_get_assert`
per credential in the mapping -- three today -- behind a single `cue`, and each
one waits out libfido2's device timeout before it gives up. `pam_u2f` has no
timeout option to shorten that, and every retry of the password prompt pays the
same wait again. Plug the key in when you mean to tap; a spare that lives in the
port is not free.

Neither prompt ever asks for the FIDO2 PIN: `pinverification=0` keeps the disk
keyslot's PIN budget out of sudo's reach.

- The ticket lasts 30 minutes and only on the TTY that earned it
  (`timestamp_timeout=30`, `timestamp_type=tty` in
  `/etc/sudoers.d/10-human-gate`). A different TTY prompts again, and a process
  without a TTY gets no ticket at all.
- A tap and a password both clear the tally: each row's `success=N` lands on
  `authsucc` rather than terminating the stack, so a success after earlier typos
  resets the count.
- Only password failures reach `authfail`: a refused tap falls through to
  `pam_unix` instead and records no faillock row, so five refused taps lock
  nothing, while five wrong passwords do. `authfail` dies on those, so the
  password cannot be probed indefinitely.
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

## 4. Grant the Tailnet widget operator access

Noctalia's Tailnet widget drives the Tailscale CLI as `smores`. The daemon
refuses every write from a non-root user until that user is the operator, so a
fresh join passes the grant in the command that creates the profile:

```sh
sudo tailscale up --operator=smores
```

On a host that is already joined, set it without `up`, which would re-apply the
full preference set and reset options such as exit nodes and accepted routes:

```sh
sudo tailscale set --operator=smores
```

The image's `tailscale-operator.service` re-applies the same preference at
boot when `/var/lib/tailscale/tailscaled.state` exists, which covers the first
boot after an upgrade. It is a oneshot separate from `tailscaled.service`:
before login Tailscale keeps the preference in memory only, and the root-run
first `tailscale up` clears it, so a `tailscaled` start hook would not help. On
a host that has never joined, use the `up --operator` line above; a green unit
before the profile exists proves nothing.

Verify the stored grant:

```sh
tailscale debug prefs | grep OperatorUser
```

That prints `"OperatorUser": "smores"` once the grant is persisted. It proves
the stored preference, not the widget's write path; opening the panel and
disconnecting is the end-to-end check. Without the grant the widget still shows
status and peers, but connect, disconnect, exit nodes and the preference
toggles are refused.

Operator is Tailscale's whole LocalAPI write permission, not a narrow
connect/disconnect grant: it also permits `tailscale serve`, `tailscale ssh`
and preference changes without the FIDO2 sudo gate. That is deliberate for
this single-user laptop, and it is why the grant belongs to `smores` alone.

## 5. Join the Syncthing cluster

The image ships the package and enables the user unit globally, so the service
starts at the first login with nothing to type. It keeps the file plane's second
copy, fed by smortress over the tailnet.

The GUI is loopback only: open `http://127.0.0.1:8384`. Its host check is a
non-issue here because the browser and the service agree on `localhost`.

Add smortress as a device by the ID its own GUI shows under Actions → Show ID,
with the address `tcp://smortress:22000`. Tailscale must be up: the ACL admits
22000 only on the tailnet, and without it the connection falls back to a relay.
Then accept the laptop on the smortress GUI and share the one folder with it as
Send & Receive.

The share is one folder at the root the tmpfiles entry created:

| Folder | Path | Holds |
| --- | --- | --- |
| `files` | `/srv/files` | `todos/`, `notes/`, `vault/` |

`todos/` holds `todo.txt`, `done.txt` and `inbox.txt` (the list managed with
tuxedo); `notes/` is the Obsidian vault; `vault/` is arbitrary files. The list
used to live inside `notes/`, and Syncthing used to share `notes` and `vault` as
two folders; the migration in the platform's `docs/manual-steps.md` retires both
and replaces them with this one folder. Do not run both layouts on one device in
the same window: Syncthing does not support nesting folders.

`/srv` is a symlink to `var/srv`, and `/var/srv/files` is `smores:smores 0700`,
so Syncthing writes as the login user and needs no elevation. The first sync is
about 5.1G; subsequent ones are incremental. A phone that should not hold the
vault can ignore `/vault` in its own `.stignore`.

Check it without the GUI:

```sh
systemctl --user status syncthing
ls -ld /var/srv/files /var/srv/files/todos
```

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
