# Manual steps

Everything here needs a human: account creation, 2FA, token issuance, LUKS
passphrases, and console work a machine cannot do. Record the date and who ran it.

## Install a host from the image

What the image is: `docs/core/server-image.md`. This is the operator order.

### Preflight

The install wipes the target: `coreos-installer install` rewrites the partition
table and the first boot formats `p4` with `wipe_volume: true`. The rendered
config carries neither a LUKS key nor a passphrase — root is bound to Clevis alone,
`smortress-data-init.service` generates the data key on the host — so both offline
recovery passphrases exist only after "Add the offline recovery passphrases". A
line that does not print what it says it must stops the install.

```sh
tang_url=$(cat ignition/operator/tang-url 2>/dev/null \
  || printf '%s\n' http://10.0.0.193:7654)          # P1: Tang serves the bound key
curl -sS -m5 -o /tmp/tang-adv.json "$tang_url/adv"
served=$(jose fmt -j /tmp/tang-adv.json -g payload -y -o - \
  | jose jwk thp -i - -a S256 | head -n1)
printf 'served: %s\npinned: %s\n' "$served" "$(cat ignition/operator/tang-thumbprint)"
rm -f /tmp/tang-adv.json                            # both thumbprints must be identical
ls -l /dev/tpmrm0                                   # P2: TPM2 present and healthy
cat /sys/class/tpm/tpm0/tpm_version_major
export SOPS_AGE_KEY_FILE=/path/to/admin-keys.txt    # P3: the kit decrypts (expect $6$)
sops --decrypt --extract '["smores"]["password_hash"]' secrets/boot.json | cut -c1-3
disk=$(cat ignition/operator/disk)                  # P4: the disk is the 980
lsblk -dno MODEL,SIZE,TRAN "$disk"
lsblk -bno SIZE "$disk"
lsblk -rno MOUNTPOINTS "$disk" | grep -c .
grep -qE '@sha256:[0-9a-f]{64}$' ignition/operator/derived-image && echo digest-pinned
cosign verify --key image/cosign.pub "$(cat ignition/operator/derived-image)" >/dev/null \
  && echo signature-verified                        # P5: the image is signed
ip -o link show | awk '$2 != "lo:" {print $2, $9}'  # P6: from the live media
ip -4 route get 10.0.0.193                          # wired UP, route, 200
curl -sS -m5 -o /dev/null -w '%{http_code}\n' http://10.0.0.193:7654/adv
```

P4 expects a `/dev/disk/by-id/nvme-...` path, a MODEL containing `980`, `931.5G`,
`nvme`, `1000204886016` bytes and `0` mounts. P3's paper half is manual: the
Bitwarden item **homelab core recovery** and its printed copy carry both 980 LUKS
passphrases, the cosign key and password, the admin age identity and the smortress
SSH host key (`docs/core/recovery-kit.md`). The console is the only way to enter a
LUKS passphrase.

### Sign and publish the image

Once per signing key. The private key and password go into the recovery kit; only
the public key is committed, and the same commands are in
`docs/core/server-image.md`, "Build, push and sign".

```sh
install -d -m 0700 "$HOME/.config/smortress"
export COSIGN_PASSWORD="$(openssl rand -base64 32)"
cosign generate-key-pair --output-key-prefix "$HOME/.config/smortress/cosign"
install -m 0644 "$HOME/.config/smortress/cosign.pub" image/cosign.pub
gh api -X PUT "repos/smores56/homelab-platform/environments/server-image" \
  --input - <<<'{}' >/dev/null
gh secret set COSIGN_PRIVATE_KEY --env server-image <"$HOME/.config/smortress/cosign.key"
printf '%s' "$COSIGN_PASSWORD" | gh secret set COSIGN_PASSWORD --env server-image
gh secret list --env server-image        # COSIGN_PASSWORD, COSIGN_PRIVATE_KEY
```

```sh
gh workflow run publish-server-image.yml
gh run watch "$(gh run list --workflow publish-server-image.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
read -r digest   # the sha256:... value from the run summary
printf '%s\n' "ghcr.io/smores56/homelab-platform/server@${digest}" \
  >ignition/operator/derived-image
```

### Stage the operator values

`ignition/operator/` is gitignored, and the recovery passphrases are not staged for
the renderer at all: no secret enters Ignition or the installer media.

```sh
install -d -m 0700 ignition/operator /tmp/smortress-kit
install -m 0644 "$HOME/.ssh/id_ed25519.pub" ignition/operator/ssh_authorized_keys
( umask 077
  openssl rand -base64 48 >/tmp/smortress-kit/root-recovery-passphrase
  openssl rand -base64 48 >/tmp/smortress-kit/data-recovery-passphrase
)
curl -sf "$(cat ignition/operator/tang-url 2>/dev/null \
  || printf '%s\n' http://10.0.0.193:7654)/adv" >/tmp/tang-adv.json
jose fmt -j /tmp/tang-adv.json -g payload -y -o - \
  | jose jwk thp -i - -a S256 | head -n1 >ignition/operator/tang-thumbprint
chmod 0600 ignition/operator/tang-thumbprint
rm -f /tmp/tang-adv.json
read -r disk     # the /dev/disk/by-id path of the 931.5G 980
printf '%s\n' "$disk" >ignition/operator/disk
```

```sh
shred -u /tmp/smortress-kit/root-recovery-passphrase \
  /tmp/smortress-kit/data-recovery-passphrase
rmdir /tmp/smortress-kit
```

The account hash (`["smores"]["password_hash"]` in `secrets/boot.json`) is not
an operator file: it ships as ciphertext because bootc never reconciles `/var`,
and both the renderer and `smortress-password.service` read it. Minting a new one
is "Rotate the smores account password".

### Render Ignition and install

```sh
export SOPS_AGE_KEY_FILE=/path/to/admin-keys.txt
scripts/render-ignition.sh --check    # prints: render-ignition: butane accepted
scripts/render-ignition.sh            # prints the install command to run
stat -c '%a %n' ignition/smortress.ign
jq -r '.storage.luks | map(.name) | join(",")' ignition/smortress.ign
jq -r '.storage.luks | map(has("keyFile")) | join(",")' ignition/smortress.ign
jq -r '.storage.luks | map(.clevis.threshold) | join(",")' ignition/smortress.ign
```

Expect `root`, `false`, `2`: a `true`, a second device name or another threshold
means a secret or a weaker binding entered the config — stop, do not install. The
result carries the account password hash, so keep it 0600 and remove it afterwards.
Without a sops identity, `--check` validates a fixture hash and the install render
refuses. Write the live media (Fedora CoreOS `live` at the `VERSION_ID` of
`image/pins.env`'s tag), verify the read-back hash, then install:

```sh
iso=$(ls "$HOME"/Downloads/fedora-coreos-*-live.x86_64.iso | tail -n1)
expected=$(grep -oE '[0-9a-f]{64}' "${iso}.sha256" | head -n1)
test "$expected" = "$(sha256sum "$iso" | cut -d' ' -f1)" && echo iso-matches-published-sha256
read -r media    # the /dev/disk/by-id/usb- path of the stick, never the 980
case "$media" in /dev/disk/by-id/usb-*) ;; *) echo "not a usb by-id path" >&2; exit 1 ;; esac
sudo dd if="$iso" of="$media" bs=4M status=progress oflag=direct
sudo head -c "$(stat -c %s "$iso")" "$media" | sha256sum
sudo coreos-installer install "$(cat ignition/operator/disk)" \
  --ignition-file ignition/smortress.ign \
  --append-karg ip=dhcp --append-karg rd.neednet=1
sudo systemctl reboot
```

```sh
lsblk -o NAME,SIZE,PARTLABEL "$(cat ignition/operator/disk)"
sudo blkid /dev/disk/by-partlabel/luks-root 2>/dev/null; echo "blkid exit $?"
```

Expect `p1` `BIOS-BOOT`, `p2` `EFI-SYSTEM`, `p3` `boot` and `p4`, and
`blkid exit 2`: no `luks-root` label and no `p5` yet, because both are first-boot
Ignition's work.

### The first boot: prove the transition

```sh
sudo rpm-ostree status                     # derived digest, signed reference
sudo journalctl -u ucore-unsigned-autorebase.service \
  -u ucore-signed-autorebase.service --no-pager
sudo bootc status
sudo bootc switch --enforce-container-sigpolicy "$(cat ignition/operator/derived-image)"
ls /etc/ucore-autorebase                   # signed, unverified
systemctl is-enabled ucore-unsigned-autorebase.service ucore-signed-autorebase.service || true
scripts/verify-image.sh "$(cat ignition/operator/derived-image)"   # from another machine
```

Expect both markers and `disabled` twice: the units disable themselves in their
last `ExecStart`. `scripts/verify-image.sh` must print `verified <ref>` with a
matching registry digest and a legacy `.sig` lookaside tag — `bootc` cannot verify
an image that has only the OCI 1.1 bundle.

### Add the offline recovery passphrases

The only step that gives the host a way in when Tang is unreachable and the TPM is
gone. Root has no passphrase slot to authenticate a new one with, so the Clevis
slot's key is recovered from the running host and destroyed immediately.

```sh
slot=$(sudo clevis luks list -d /dev/disk/by-partlabel/root | awk -F: 'NR==1 {print $1}')
test -n "$slot"
sudo sh -c "clevis luks pass -d /dev/disk/by-partlabel/root -s $slot >/run/root-clevis.key && chmod 0400 /run/root-clevis.key"
sudo test -s /run/root-clevis.key
sudo cryptsetup luksAddKey --key-file /run/root-clevis.key /dev/disk/by-partlabel/root
sudo shred -u /run/root-clevis.key
sudo cryptsetup luksAddKey --key-file /etc/luks/data /dev/disk/by-partlabel/luks-data
```

```sh
sudo cryptsetup open --test-passphrase /dev/disk/by-partlabel/root
sudo cryptsetup open --test-passphrase /dev/disk/by-partlabel/luks-data
sudo cryptsetup luksDump /dev/disk/by-partlabel/root \
  | grep -cE '^[[:space:]]*[0-9]+: luks2'          # 2: Clevis plus passphrase
sudo cryptsetup luksDump /dev/disk/by-partlabel/luks-data \
  | grep -cE '^[[:space:]]*[0-9]+: luks2'          # 2: key file plus passphrase
```

Then prove console recovery: power off, unplug the wired NIC so the sss threshold
cannot be met, and boot. systemd asks for the root passphrase, and the data LUKS
must open from `/etc/luks/data` without a second prompt (`cryptsetup status data`
→ `active`, the pool → `ONLINE`). No SSH session proves the passphrase reached the
boot prompt. Confirm the key stayed off `/boot`, and repeat after every kernel
update:

```sh
sudo lsinitrd /boot/ostree/*/initramfs-*.img | grep -E '/etc/luks|/etc/crypttab' || true
```

`/etc/luks/data` may not appear; if it does, see `scripts/fix-crypttab.sh`.

### Stage the age identity and prove the decrypt unit

```sh
sudo install -d -m 0700 -o root -g root /var/lib/homelab/age
sudo install -m 0600 -o root -g root /path/to/kit-age-identity \
  /var/lib/homelab/age/keys.txt
sudo systemctl restart sops-decrypt.service
sudo cat /run/smortress/secrets/canary.yaml     # canary: sops-decrypt-ok
```

The file must be the unwrapped `AGE-SECRET-KEY-...` identity
(`stat -c '%a %U'` → `600 root`), not the passphrase-wrapped kit container.
Quadlets start only after the unit succeeds.

### Configure and open the HDD

```sh
ls -l /dev/disk/by-id/ata-*
read -r hdd
printf '%s\n' "$hdd" >/tmp/hdd-device
sudo install -m 0644 -o root -g root /tmp/hdd-device /etc/smortress/hdd-device
openssl rand -base64 48 \
  | sudo install -m 0600 -o root -g root /dev/stdin /var/lib/homelab/keys/hdd.key
sudo cryptsetup luksAddKey "$(cat /etc/smortress/hdd-device)" \
  /var/lib/homelab/keys/hdd.key
sudo systemctl start smortress-cryptsetup-hdd.service
ls -l /dev/mapper/luks-hdd
```

The `luksAddKey` prompt accepts the existing HDD passphrase from the kit. Remove
the HDD and reboot once: boot must complete, the unit must log the absence, and
the restic freshness alert must be the only failure.

### Prove the boundaries

```sh
sudo tailscale up --ssh --hostname smortress
sudo firewall-cmd --zone=bootstrap --list-all   # must show no interfaces
sudo touch /var/lib/homelab/tailscale-enrolled
sudo /usr/libexec/access-lockdown
sudo firewall-cmd --get-active-zones            # default drop, tailscale0 only
sudo zfs unmount smortress/raw/photos
sudo systemctl restart zfs-ready@photos.service # fails: nothing is mounted at /srv/photos
sudo zfs mount smortress/raw/photos
sudo systemctl restart zfs-ready@photos.service
```

A consumer of `photos` is down between the two restarts while `zfs-ready@books` and
unrelated backups stay up, and from a LAN host that is not on Tailscale `ssh
smores@<lan-ip>` and every application port must fail. Then update the kit, run its
drill with only kit material, and repeat the media write through this point on a
scratch disk before the production wipe.

### Failure paths

Stop and read the state; do not continue and do not improvise a workaround.

- **P1 fails.** dracut will not reach Tang either: fix the network or the Tang
  deployment, re-derive the thumbprint, re-run P1. A host installed anyway has a
  Clevis binding it can never open and no passphrase slot — a reinstall.
- **P2 fails.** Threshold 2 can never be met, and the console prompt that would save
  it exists only after the recovery step: fix the board, reinstall.
- **P4 or P5 fails.** Rewrite `disk` and re-render, or restore the signing key from
  the kit and re-publish before pinning a digest.
- **The render shows `keyFile` or a second LUKS device.** Fix
  `ignition/smortress.bu`, re-run `tests/core/ignition-boundary.sh`.
- **No `p4`, or `blkid` exits 0 on `luks-root`.** Re-run the install; `wipefs -a`
  the target from the live media first if it fails again.
- **No `/etc/ucore-autorebase/unverified` marker.** The unsigned rebase never ran,
  so the signed stage was never eligible — usually no network at first boot. The
  same one stage later is `ucore-signed-autorebase.service`. Both restarts end in
  `systemctl reboot`; the marker keeps a completed stage from running twice.

  ```sh
  sudo journalctl -b -u ucore-unsigned-autorebase.service --no-pager
  sudo systemctl restart ucore-unsigned-autorebase.service
  ```

  ```sh
  sudo cryptsetup luksDump /dev/disk/by-partlabel/root | sed -n '/^Keyslots:/,/^Tokens:/p'
  sudo clevis luks list -d /dev/disk/by-partlabel/root
  ```

- **No data mapper.** The idempotent oneshot failed; a missing
  `/dev/disk/by-partlabel/luks-data` is the installer, not the unit.

  ```sh
  sudo journalctl -b -u smortress-data-init.service --no-pager
  sudo systemctl restart smortress-data-init.service smortress-zpool.service
  ```

- **`clevis luks pass` fails.** It needs Tang *and* the TPM, and without it no
  passphrase can be added — the host has **no offline recovery**:

  ```sh
  curl -sS -m5 -o /dev/null -w '%{http_code}\n' http://10.0.0.193:7654/adv
  sudo systemd-cryptenroll --tpm2-device=list
  ```

- **A wrong passphrase at `open --test-passphrase`.** Re-copy from the kit; if it
  still fails, add the value again while Tang and the TPM are healthy.

### Roll back what an install did

Nothing written yet is nothing to roll back (`rm ignition/smortress.ign`). An
install written but not booted is a second media write with the previous signed
digest in `derived-image`; the disk is wiped either way. After the autorebase the
OS deployment is revertible and the disk is not:

```sh
sudo bootc rollback
sudo systemctl reboot
sudo rpm-ostree status
sudo zpool export smortress   # before reinstalling over a host that still boots
```

### Move a running host to a newer build

The reference is a digest, so `bootc upgrade` re-checks that exact digest and never
moves on its own:

```sh
sudo bootc switch --enforce-container-sigpolicy \
  "ghcr.io/smores56/homelab-platform/server@sha256:<digest from the run summary>"
sudo systemctl reboot
```

A host may follow CI's moving `:latest` tag instead — only `main` runs move it, and
only after the signature verified — and then `sudo bootc upgrade` is the update:

```sh
sudo bootc switch --enforce-container-sigpolicy ghcr.io/smores56/homelab-platform/server:latest
sudo systemctl reboot
```

## GitHub: identity, environments, and tokens

### The `cloudflare` environment secret

```sh
read -rsp 'Cloudflare API token: ' CLOUDFLARE_API_TOKEN
gh secret set CLOUDFLARE_API_TOKEN --env cloudflare --repo smores56/homelab-platform
unset CLOUDFLARE_API_TOKEN
gh api repos/smores56/homelab-platform/environments/cloudflare/secrets --jq '.secrets[].name'
```

The state backend's R2 pair is two more secrets in the same environment
(`R2_STATE_ACCESS_KEY_ID`, `R2_STATE_SECRET_ACCESS_KEY`); the plan environment
holds the read-only pair.

### Environments and their branch policies

No repository-level secrets: every workflow secret lives in an Environment, and the
ones holding write or signing credentials allow `main` only. `cloudflare-plan` is
the deliberate exception (read-only plan pair, `main` and `smores/*`, because the
pre-merge plan runs on an owner-pushed branch). None allows an agent branch.

```sh
OWNER=$(cat ~/.config/smores56-agent/owner-token)
GH_TOKEN="$OWNER" gh api -X PUT \
  repos/smores56/homelab-platform/environments/server-image --input - <<'JSON'
{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON
GH_TOKEN="$OWNER" gh api -X POST \
  repos/smores56/homelab-platform/environments/server-image/deployment-branch-policies \
  -f name=main -f type=branch
for p in main 'smores/*'; do
  GH_TOKEN="$OWNER" gh api -X POST \
    repos/smores56/homelab-platform/environments/cloudflare-plan/deployment-branch-policies \
    -f name="$p" -f type=branch
done
for e in cloudflare cloudflare-plan server-image; do
  printf '%-16s ' "$e"
  GH_TOKEN="$OWNER" gh api \
    "repos/smores56/homelab-platform/environments/$e/deployment-branch-policies" \
    --jq '[.branch_policies[].name] | join(",")'
done
# expect: cloudflare main / cloudflare-plan main,smores/* / server-image main
```

GitHub evaluates the policy before the job starts, so a branch outside the list gets
no step and no secret; a `pull_request` run is evaluated as `refs/pull/<n>/merge`,
which no policy matches, so `tofu-plan-pr.yml` is refused for every PR and the
owner's `--admin` merge lands one. `deploy-notify` is a third main-only environment
in both repositories ("Create the notify environment").

### The machine user and its scoped token

The general shell agents act on GitHub as a dedicated machine account, never as
`smores56`. The ceiling is Write — push branches, open pull requests, edit issues —
with no rulesets, Environments, secrets, collaborators or settings. The token is a
classic PAT, because a fine-grained PAT cannot act on another user's repositories as
a collaborator. Both machine credentials are the general agent's, delivered per job
from ciphertext (`docs/agent-identity.md`).

1. Create the account in a browser, with an address that is not the owner's and not
   a `+` alias; enable TOTP 2FA, store the recovery codes, add no SSH key, OAuth
   app, security key or organisation.
2. Create the classic PAT as the machine user, scope `repo` only. Without
   `workflow` the token cannot create or update `.github/workflows/**`.
3. Make it a Write collaborator everywhere (the owner's fine-grained token has no
   Administration permission, so this needs a transient owner classic PAT) and
   accept the invitations as the machine user. Archived repositories refuse the
   change (`Repository was archived so is read-only.`).

   ```sh
   OWNER=$(cat ~/.config/smores56-agent/owner-token)
   MACHINE=$(cat ~/.config/smores56-agent/token)
   while read -r r; do
     out=$(GH_TOKEN="$OWNER" gh api -X PUT \
       "repos/smores56/$r/collaborators/smores56-agent" -f permission=push 2>&1) || {
         printf 'skip %s: %s\n' "$r" "$(printf '%s' "$out" | tr '\n' ' ')"; continue; }
     printf 'invited %s\n' "$r"
   done < <(gh repo list smores56 --limit 400 --json name --jq '.[].name')
   GH_TOKEN="$MACHINE" gh api user/repository_invitations --paginate \
     --jq '.[] | [.id, .repository.full_name] | @tsv' |
   while IFS=$'	' read -r id repo; do
     GH_TOKEN="$MACHINE" gh api -X PATCH "user/repository_invitations/$id" >/dev/null &&
       printf 'accepted %s\n' "$repo"
   done
   ```

   ```sh
   while read -r r; do
     role=$(GH_TOKEN="$OWNER" gh api \
       "repos/smores56/$r/collaborators/smores56-agent/permission" --jq .role_name)
     perms=$(GH_TOKEN="$MACHINE" gh api "repos/smores56/$r" \
       --jq '[.permissions.admin,.permissions.maintain,.permissions.push] | @tsv')
     printf '%-24s %-6s %s\n' "$r" "$role" "$perms"
   done < <(gh repo list smores56 --limit 400 --json name,isArchived \
     --jq '.[] | select(.isArchived|not) | .name')
   ```

### Prove the ceiling

Git's credential helper is the trap: a plain `git push` authenticates as the owner
even when the URL carries `x-access-token`, so every control looks unenforced.

```sh
TOKEN_FILE="$HOME/.config/smores56-agent/token"
printf '#!/bin/sh\ncat "%s"\n' "$TOKEN_FILE" >/tmp/askpass-machine.sh
chmod 700 /tmp/askpass-machine.sh
gitm() {
  env -i PATH=/usr/bin:/bin HOME=/tmp/empty-home GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null GIT_ASKPASS=/tmp/askpass-machine.sh \
    GIT_TERMINAL_PROMPT=0 git -c credential.helper= \
    -c user.name='smores56 agent' \
    -c user.email='smores56-agent@users.noreply.github.com' "$@"
}
gitm clone --depth 1 https://x-access-token@github.com/smores56/homelab-platform.git
cd homelab-platform && git commit --allow-empty -m 'authority probe'
gitm push origin HEAD:refs/heads/probe      # succeeds
gitm push origin HEAD:main                  # rejected: repository rule violations
gitm push --force origin HEAD:main          # the same message
gitm push origin :main                      # refusing to delete the current branch
```

A push touching `.github/workflows/**` is refused earlier, by the missing `workflow`
scope; Administration endpoints answer `404`, and no repository-level secret exists.
Close the probe PR, delete the branch, then revoke the transient owner token and
remove both local copies:

```sh
rm -f ~/.config/smores56-agent/owner-token ~/.config/smores56-agent/token
```

Rotating the machine PAT is: revoke it as the machine user, create a replacement with
scope `repo` only, and replace the `agent-github-token.yaml` ciphertext. The passkey,
password and recovery codes never enter a job, a manifest or this repo.

## Secrets and rotation

### Where a secret lives

`.sops.yaml` is rendered by `scripts/sops-policy.py` and encrypts every
`secrets/*.json` and `secrets/*.yaml` to the admin identity, the machine (host)
identity and the three YubiKeys. In git: `secrets/boot.json`, `secrets/apps.json`
and `secrets/agents.json`, written by the operator at the dotted key the index
names; on the host `/var/lib/smortress/secrets/<bundle>` root `0600`, written by a
rotation or the boot seed; `/run/smortress/secrets/<name>` at the manifest's mode,
written by `sops-decrypt.service` at every boot.

`secrets/index.json` is the contract; the seed renders
`/etc/smortress/secrets.manifest` from it at every boot. A rotation is one
operator path, never a rebuild; a container that already mounts the decrypted
file keeps the old value until it restarts, and `/run` is tmpfs:

```sh
# The R2 pair is authored only in the Cloudflare bundle, then derived.
sops secrets/cloudflare.yaml          # restic-backup-rw-*
scripts/cloudflare-derive.sh
scripts/secret.sh stage r2-credentials.yaml
scripts/secret.sh verify
```

Only a secret whose *manifest line* changes needs the image and a reboot.

### Add an output the index does not name

An output the index already names is `edit` and `stage`, nothing else. A new one is
an index line plus its key in a bundle, in one commit: the manifest the decrypt
reads is rendered from the index, so the image carries the line before any value
can reach `/run`. `deploy-ping-url.yaml` is already such an output, so the shape
below is its rotation, not a step still to run:

```sh
python3 scripts/secrets-index.py list | grep deploy-ping-url   # bundle and consumer
scripts/secret.sh edit deploy-ping-url.yaml    # deploy.ping_url
scripts/secret.sh stage deploy-ping-url.yaml
scripts/secret.sh verify                       # policy, index and bundles agree
python3 scripts/secrets-check.py --shadow      # manifest matches the index
```

### Rotate the smores account password

`sops-decrypt.service` writes the bare hash into `/run/smortress/secrets/` at boot
and `smortress-password.service` re-applies it through `chpasswd -e`.

```sh
read -rsp 'smores account password: ' password; echo
printf '%s\n' "$password" | openssl passwd -6 -stdin   # the hash to paste
unset password
scripts/secret.sh edit smores-password-hash.yaml     # smores.password_hash
scripts/secret.sh stage smores-password-hash.yaml
scripts/secret.sh verify
```

Commit the bundle, put the password in the recovery kit, then apply and prove it at
the console, never over the SSH session the old password protects:

```sh
sudo systemctl restart smortress-password.service
sudo journalctl -b -u smortress-password.service --no-pager
sudo getent shadow smores | cut -d: -f2 | cut -c1-3   # must print $6$
```

The journal must contain `re-applied the smores password field from ciphertext`. A
failed unit leaves the previous password in place, which is recoverable over SSH.

### Rotate an application secret

The age identity is linked at root's default sops path and the sudoers drop-in
strips inherited `SOPS_AGE_*` variables, so plain `sudo sops` is the whole command.
Rotate the ciphertext and stage it, then change the password in PostgreSQL from the
staged copy before restarting the containers that read it:

```sh
scripts/secret.sh edit immich-db-password.yaml   # immich.db_password: openssl rand -hex 32
scripts/secret.sh stage immich-db-password.yaml
sudo podman exec -i immich-postgres psql -U immich -d immich \
  -c "ALTER USER immich WITH PASSWORD '$(sudo sops --decrypt --extract '["immich"]["db_password"]' /var/lib/smortress/secrets/apps.json)'"
sudo systemctl restart smortress-app-secrets.service immich-postgres.service immich-server.service
git commit -am 'chore(core): rotate the Immich database password'
git push
```

### Rotate the agent's credentials

Gateway keys and UI passwords are rewritten by `smortress-agent-config.service`
(`.env` and `webui.env`) on every start, so a rotation lands when that service
restarts:

```sh
scripts/secret.sh edit agent-local-api-key.yaml       # agent.local_api_key: openssl rand -hex 32
scripts/secret.sh edit agent-general-api-key.yaml     # agent.general_api_key: same
scripts/secret.sh edit agent-hosted-key.yaml          # agent.hosted_key: the provider's key, not ours
scripts/secret.sh edit agent-ui-personal-password.yaml   # ui.personal_password
scripts/secret.sh stage agent-local-api-key.yaml      # all four are in agents.json
sudo systemctl restart smortress-agent-config.service
sudo systemctl restart agent-webui-personal.service
```

A facade token lives in three places that must move together: the ciphertext, the
Podman secret the facade mounts, and the gateway's seeded `config.yaml`. The first
two follow `edit` and `stage`; the third does not, because the seed uses `cp -n`.
Rotate the ciphertext and stage it first — reseeding before that copies the *old*
token back:

```sh
scripts/secret.sh edit agent-facade-personal-token.yaml   # facade.personal_token: openssl rand -hex 32
scripts/secret.sh stage agent-facade-personal-token.yaml
git commit -am 'chore(core): rotate the personal facade token'
git push
sudo rm /var/lib/agent/local/config.yaml
sudo systemctl restart smortress-agent-config.service
sudo stat -c '%u:%g %a %n' /var/lib/agent/local/config.yaml   # 1000:1000 0600
sudo systemctl restart agent-facade-personal.service agent-local.service
```

### Rotate the deploy webhook key

`webhook.secret` is what both notify jobs sign with today and `webhook.next` is the
rotation slot; the decrypt writes them to
`/run/smortress/secrets/webhook-secret.yaml` and
`/run/smortress/secrets/webhook-secret-next.yaml`; the listener accepts either, so there is no window in which the old
key is refused. Write the new key into `["webhook"]["next"]` in `secrets/boot.json`,
commit and stage; change `DEPLOY_WEBHOOK_SECRET` in both `deploy-notify`
Environments; move the key into `["webhook"]["secret"]`, put a fresh random value
in the next slot, commit and stage. The next merge journals `queue-enqueued`; a body
signed with the retired key is a `deploy-rejected` with reason `bad-signature`. The
listener refuses to start when `["webhook"]["secret"]` is empty or missing, so a
failed decrypt answers nothing rather than accepting unsigned requests.

## Deploy

### Publish and pin the platform image

`publish-server-image.yml` builds, signs and pushes on a push to `main` touching
`image/`, `units/`, `secrets/` or `scripts/`, and on dispatch. It prints the digest
for `ignition/operator/derived-image` and ends with the `notify` job that asks the
receiver to deploy (`docs/core/server-image.md`, "The deploy path").

### Create the notify environment

Both repositories have a `notify` job on `environment: deploy-notify` with
`permissions: {}` and no checkout. The webhook key is the `["webhook"]["secret"]`
value already encrypted in `secrets/boot.json`, and both Environments and the host
must agree on it byte for byte.

```sh
OWNER=$(cat ~/.config/smores56-agent/owner-token)
WEBHOOK=$(sops decrypt --extract '["webhook"]["secret"]' secrets/boot.json)
for repo in homelab-platform homelab-apps; do
  GH_TOKEN="$OWNER" gh api -X PUT "repos/smores56/$repo/environments/deploy-notify" \
    --input - <<'JSON'
{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON
  GH_TOKEN="$OWNER" gh api -X POST \
    "repos/smores56/$repo/environments/deploy-notify/deployment-branch-policies" \
    -f name=main -f type=branch
  printf '%s' '<oauth client id>' | GH_TOKEN="$OWNER" \
    gh secret set TS_OAUTH_CLIENT_ID --env deploy-notify --repo "smores56/$repo"
  printf '%s' '<oauth client secret>' | GH_TOKEN="$OWNER" \
    gh secret set TS_OAUTH_CLIENT_SECRET --env deploy-notify --repo "smores56/$repo"
  printf '%s' "$WEBHOOK" | GH_TOKEN="$OWNER" \
    gh secret set DEPLOY_WEBHOOK_SECRET --env deploy-notify --repo "smores56/$repo"
done
```

The OAuth client is the tailnet client carrying `tag:deploy`: scopes `auth_keys`
write and `devices` write, tags `tag:deploy`, nothing else, and the ACL admits that
tag on `tag:smortress:8484` (the receiver) and `svc:agent-ui:443` (the daily names
probe, below) and nowhere else. A compromised notify job can therefore re-tag the
smortress device itself; that write cannot be separated from `auth_keys`, and a
static auth key in the Environment would never expire.

### Create the tailnet names check

`verify-tailnet-names.yml` runs daily and proves `assistant.sammohr.dev` and
`agent.sammohr.dev` still work for a node that is not the owner's laptop
(`docs/core/applications.md`, the tailnet name service). It pages through a
Healthchecks check of its own: a daily period with a six-hour grace, because the
probe answers once a day and one late run should not page.

Create the check in the project with a `1 day` period and a `6 hour` grace, then
copy its ping URL into the environment:

```sh
OWNER=$(cat ~/.config/smores56-agent/owner-token)
printf '%s' '<ping url>' | GH_TOKEN="$OWNER" \
  gh secret set NAMES_PING_URL --env deploy-notify --repo smores56/homelab-platform
```

Then run it once so the check has an answer, and read the job's own output: it
prints one `ok`/`FAIL` line per probe.

```sh
GH_TOKEN="$OWNER" gh workflow run verify-tailnet-names.yml --repo smores56/homelab-platform
GH_TOKEN="$OWNER" gh run watch --repo smores56/homelab-platform
```

The probe needs a tailnet node and nothing else, so the same script is the
operator's tool during an outage; run it from any node on the tailnet:

```sh
scripts/verify-tailnet-names.sh
TAILNET_NAMES_MIN_DAYS=100000 scripts/verify-tailnet-names.sh   # the expiry leg, red
```

Unlike the host's own monitors this one is deliberately not a key in
`secrets/boot.json`'s `healthchecks` object: that object is decrypted on the host
and this probe never runs there, so a bundle copy would be dead weight and the
capability URL belongs in the `deploy-notify` Environment alone.

### The operator's view of the receiver

`/usr/libexec/smortress-deploy` is the whole operator surface, and `/usr/libexec`
is not on root's `PATH`. `status` is read-only and takes no lock, so it answers on a
host whose drain is wedged.

```sh
sudo /usr/libexec/smortress-deploy status | jq .
sudo curl -sS http://127.0.0.1:8484/healthz      # {"status":"ok","rejected":{}}
sudo tail -n 20 /var/lib/homelab/deploy/journal.jsonl | jq -c .
sudo journalctl -u smortress-deploy-listener.service -u smortress-deploy.service \
  -u smortress-boot-gate.service -u smortress-apps-health.service --no-pager -n 50
```

`state.json` records what is running, `pending.json` exists only between a staged
platform deploy and the boot gate that judges it, `held.json` only while a snapshot
gate waits for an operator. The journal's events: `queue-enqueued`,
`deploy-rejected`, `already-deployed`, `verified`, `verify-rejected`,
`verify-infra-failure`, `deploy-held`, `gate-released`, `gate-green`,
`stage-digest-mismatch`, `boot-gate-green`, `boot-gate-failed`,
`rolled-back-by-bootloader`, `apps-*`, `denylist-added`, `denylist-cleared`,
`bootstrap-recorded`, `state-reconciled`, `booted-unrecorded`, `notify-sent`,
`notify-failed`.

### A held deploy

A platform deploy whose snapshot gate cannot make one restore unit fresh holds
instead of rebooting: nothing is staged, nothing reboots, the check is red.

```sh
sudo /usr/libexec/smortress-deploy status | jq '.held'
# {"schema":1,"digest":"sha256:…","commit":"…","missingUnits":["books"],
#  "reason":"no-usable-repository","heldAt":"…","released":false}
sudo /usr/libexec/smortress-deploy release --force
```

Fix the repository, or take the break-glass flag, which records the operator, the
digest and the missing units and changes nothing else: the next request for that
commit — the daily 03:00 window while it is still the tip, or a dispatch — reaches
the gate, sees the release, stages and reboots. A release covers one digest only.

### A denylisted commit or digest

A failed gate, a rollback and a rejected apps definition all denylist what they
refused, and a denial is final: the listener refuses the commit and the hourly poll
pages and stops enqueuing it.

```sh
sudo /usr/libexec/smortress-deploy status | jq '.denylist'
sudo /usr/libexec/smortress-deploy unblock digest sha256:…
sudo /usr/libexec/smortress-deploy unblock commit <40-hex>
sudo /usr/libexec/smortress-deploy block commit <40-hex>   # the way on, in reverse
```

Set the value only after the cause is gone — a fixed definition is a *new* commit
and needs no unblock; a denied digest is usually a failed health gate, so read
`journal.jsonl` for its `boot-gate-failed` reason first. Both verbs refuse a
non-root caller, a mistyped table and a value already in the state they would
write, and journal who did it.

### A restored or rebuilt host

`state.json` lives outside every recovery group because it is rebuildable, and the
one thing that cannot be inferred is the commit the host is running: no recorded
ancestor means every deploy is refused with `bootstrap-required`.

```sh
sudo bootc status --json | jq -r '.status.booted.image.imageDigest'
sudo /usr/libexec/smortress-deploy bootstrap homelab-platform <40-hex>
sudo /usr/libexec/smortress-deploy bootstrap homelab-apps <40-hex>
```

```sh
sudo bootc status --booted --json | jq -r '.status.booted.image.imageDigest'
sudo /usr/libexec/smortress-deploy reconcile --commit <40-hex>
```

### Deploy the apps tenant

`scripts/deploy-apps.sh` is the only writer of the tenant and the receiver is the
only thing that runs it: `deploy-apps apply --commit <sha>` fetches, renders,
validates, pulls, installs and commits, and `deploy-apps revert` puts the previous
revision back. A merge to `homelab-apps` `main` is the normal path.

```sh
sudo /usr/libexec/smortress-deploy status | jq '.apps'
sudo systemctl status smortress-apps-user.service smortress-app-secrets.service
sudo systemctl list-timers 'smortress-apps-*'
```

Bounds, plan format and boot order are `docs/core/apps-tenant.md`. The prober
`smortress-apps-health.timer` runs every five minutes: it rolls nothing back, pings
the `apps` check when an app is not serving, and journals `apps-health-failed` with
the reason, the app and the unit.

### Serve routes

`scripts/tailscale-serve.sh` is the producer of every route; the image installs it as
`/usr/libexec/tailscale-serve` and `smortress-tailscale-serve.service` runs it at
every boot. An empty Serve table is repaired by starting the unit, never by retyping
a `tailscale serve` command. HTTPS certificates for the tailnet are an
admin-console toggle.

```sh
sudo systemctl start smortress-tailscale-serve.service
tailscale serve status
```

Expect nine routes: 443 to `http://127.0.0.1:2283` (Immich, plus `/wallpapers/`,
`/apps/agent-local` and `/apps/agent-general`), 8443 to `http://127.0.0.1:8083`
(OPDShelf), 10000 to `http://127.0.0.1:8384` (Syncthing GUI), 8444 and 8445 to the
agent web UIs, 8446/8447 for the public edge, and 8448 to `http://127.0.0.1:4533`
(Navidrome). Nothing here is Funnel. The
wallpaper route shows a `Path` target rather than a `Proxy`:

```sh
curl -fsS https://smortress.<tailnet>.ts.net/wallpapers/ | head
systemctl status zfs-ready@raw-wallpapers.service   # an empty listing means not mounted
```

Syncthing refuses a proxied Host header, so turn its check off with the key from the
config on its dataset, or its GUI answers `403` behind Serve:

```sh
key=$(sudo sed -n 's:.*<apikey>\(.*\)</apikey>.*::p' /var/lib/syncthing/config/config.xml)
sudo curl -fsS -X PATCH -H "X-API-Key: $key" -H 'Content-Type: application/json' \
  -d '{"insecureSkipHostcheck": true}' http://127.0.0.1:8384/rest/config/gui
```

The GUI has no password of its own, so the tailnet-only route is its whole access
control.

## Applications and agents

### Publish and sign the application images

The host's default-reject policy accepts an application image only when it is
signed by the smortress cosign key and pushed under
`ghcr.io/smores56/homelab-platform`, so the images are mirrored before the
Quadlets can start.

```sh
gh workflow run publish-app-images.yml --repo smores56/homelab-platform
gh run watch --repo smores56/homelab-platform
skopeo inspect --no-tags --format '{{.Digest}}' \
  docker://ghcr.io/smores56/homelab-platform/immich-server@sha256:c716dc20f957aafd89fa9d284a2ec63e25c9e2d8d8e87c6197d540a3dce237db
```

A green run prints every mirrored reference; a digest mismatch or a missing `.sig`
lookaside tag fails it. GHCR packages are private by default: make each one public
and confirm the unauthenticated inspect answers, because a private package is a
failed pull on the first boot after the deploy. The mirror signs the index digest
and every platform manifest of it, because `containers/image` verifies the manifest
it copies and rejects an index-only signature with `A signature was required, but
no signature exists`.

```sh
gh workflow run publish-agent-webui.yml --repo smores56/homelab-platform
gh run watch --repo smores56/homelab-platform
```

### Deploy the image that ships the Quadlets

Both planes are image changes, so switch the host and reboot ("Move a running
host"), then read the generator and the containers:

```sh
journalctl -b | grep -i quadlet-generator
systemctl list-units --all 'immich-*' 'opdshelf*' 'syncthing*' 'navidrome*'
sudo podman ps --format '{{.Names}}	{{.Status}}'
```

A container whose network file is missing is dropped by the generator with
`requested Quadlet unit <name>.network was not found` and leaves no unit to start,
so read the generator's own errors first. `immich-server`, `immich-postgres`,
`immich-valkey`, `immich-machine-learning`, `opdshelf`, `syncthing` and
`navidrome` should all be `Up`; a failed unit names its reason in `systemctl status <unit>`. The new
`syncthing` recovery group has no Restic status until its first backup:

```sh
sudo systemctl start smortress-restic-backup@r2.service smortress-restic-verify.service
```

### Navidrome's first boot and the one-time path cleanup

The unit reads `/srv/music` read-only and keeps its database in
`/var/lib/navidrome`. The pin must be published before the reboot that ships the
unit, or the first pull fails under the default-reject policy: the publish section
above must show `navidrome` at its digest in a green run.

The first visit to `https://smortress.<tailnet>.ts.net:8448/` shows Navidrome's
"Create Admin" screen. There is no supported environment variable for it, so the
operator creates the one admin user here; the route is tailnet-only and admits
`group:owner`. `/ping` proves the process is up:

```sh
curl -fsS https://smortress.<tailnet>.ts.net:8448/ping
```

Adding `state/navidrome` to the `music` unit changed its path list, so the first
backup after this deploy reads the whole library again (Restic dedupes the chunks
against the old snapshots, so the upload is small) and starts a new `host,paths`
family. The old family keeps its 14/8/12 retention until it is forgotten.
Until the first new-family snapshot is `verified` in each backend,
`smortress-restic-verify.service` reports `music` stale and pings the failure
URL: that is the expected red window, not a fault.

Run this once, per backend, after the first `music` snapshot of the new family
is `verified`, and check the count before forgetting:

```sh
sudo bash -c '
  source /usr/libexec/restic-plane-common
  for backend in ssd hdd r2; do
    load_backend_env "$backend"
    restic -r "$(repo_for "$backend")" snapshots --json \
      --path "/var/srv/music/.zfs/snapshot/$backend" | jq length
  done'
```

The count is the old family only: the new snapshots name both `/var/srv/music`
and `/var/lib/navidrome`, so the exact `--path` cannot select them. Forget the old
family:

```sh
sudo bash -c '
  source /usr/libexec/restic-plane-common
  for backend in ssd hdd r2; do
    load_backend_env "$backend"
    restic -r "$(repo_for "$backend")" forget --host smortress \
      --tag unit:music,verified --group-by host,paths \
      --path "/var/srv/music/.zfs/snapshot/$backend" --keep-last 0 \
      --unsafe-allow-remove-all
  done'
```

The next daily maintenance prunes the freed snapshot metadata.

### Verify the applications and the closed LAN

```sh
curl -fsS -o /dev/null -w '%{http_code}\n' https://smortress.<tailnet>.ts.net/api/server/ping
curl -fsS -o /dev/null -w '%{http_code}\n' https://smortress.<tailnet>.ts.net:8443/healthz
curl -fsS -o /dev/null -w '%{http_code}\n' https://smortress.<tailnet>.ts.net:10000/rest/noauth/health
```

All three answer 200 from a tailnet device. From a machine on the LAN that is
**not** on the tailnet, `curl --max-time 3 http://10.0.0.125:22000` and `ssh -o
ConnectTimeout=3 smores@10.0.0.125` both time out: a connection means the default
zone is no longer `drop` or a Quadlet published an address it should not have.

### Validate the units and check the listeners

Datasets, ports and unit ordering are `docs/core/applications.md`, "Agent
deployments".

```sh
systemd-analyze verify units/systemd/smortress-nvidia-cdi.service \
  units/systemd/smortress-agent-config.service
sudo /usr/lib/systemd/system-generators/podman-system-generator -dryrun -v 2>&1 \
  | grep -E 'agent-(model|local|general|proxy|facade-personal|facade-general)\.(service|network)'
systemctl cat agent-proxy.service agent-facade-personal.service | head -40
```

```sh
sudo systemctl stop agent-webui-personal agent-local agent-facade-personal agent-model
sudo systemctl stop agent-local-network.service
sudo podman network rm systemd-agent-local
sudo systemctl start agent-local-network.service agent-model.service \
  agent-facade-personal.service agent-local.service agent-webui-personal.service
```

```sh
sudo systemctl start zfs-ready@state-agent-model.service zfs-ready@state-agent-local.service \
  zfs-ready@state-agent-general.service smortress-nvidia-cdi.service
sudo nvidia-ctk cdi list                                     # nvidia.com/gpu=all
sudo systemctl start smortress-agent-config.service
sudo systemctl start agent-proxy.service agent-model.service agent-general.service agent-local.service
sudo systemctl start agent-facade-personal.service agent-facade-general.service
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
sudo podman logs smortress-agent-local 2>&1 | grep -E 'stage2|Changing hermes'
```

Six containers answer `Up`. The memory directories must be `1000:1000 0750` before
the facades start, and `nvidia-smi` must list `llama-server` — a separate fact from
the container being up; no entry means `ggml_cuda_init` failed or
`smortress-selinux-nvidia-map.service` did not load its rule. A `Permission
denied` under `/opt/data` means the `HERMES_UID`/`HERMES_GID` remap did not run,
never fixed by widening the dataset mode.

A template change does not reach an already-seeded deployment, because the config
is copied in once and never rewritten: discard the copy and restart the two units.
`200` on the proxy's `/v1/models` is also the only proof the provider key works,
and `401` means the ciphertext still holds the seeded random value.

```sh
sudo rm /var/lib/agent/local/config.yaml
sudo systemctl restart smortress-agent-config.service agent-local.service
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18003/v1/models
key=$(sudo sed -n 's/^API_SERVER_KEY=//p' /var/lib/agent/local/.env)
curl -fsS -H "Authorization: Bearer $key" http://127.0.0.1:18001/v1/models
```

The personal side must have no egress, checked inside its own namespace: the route
and the failed connection are the proof, not a DNS lookup. `/proc/net/route` rather
than `ip route`, because neither agent image ships iproute2.

```sh
sudo podman exec smortress-agent-local python3 -c \
  'import socket; socket.create_connection(("1.1.1.1", 443), 3)' ; echo "exit=$?"
sudo podman exec smortress-agent-local python3 -c \
  'import socket; print(socket.create_connection(("smortress-agent-model", 8080), 3))'
```

### Check the agent Serve routes

`/apps/agent-local` and `/apps/agent-general` on 443 are core paths of
`scripts/tailscale-serve.sh`, and 8444/8445 are core ports for the two web UIs.
There is no handler for `127.0.0.1:18003` and there must never be one: a tailnet
path to the proxy would let any device spend the provider key.

```sh
read -r key   # the personal gateway key: sudo sed -n 's/^API_SERVER_KEY=//p' /var/lib/agent/local/.env
curl -fsS -H "Authorization: Bearer $key" \
  https://smortress.<tailnet>.ts.net/apps/agent-local/v1/models
curl -fsS -o /dev/null -w '%{http_code}\n' \
  https://smortress.<tailnet>.ts.net/apps/agent-general/v1/models   # 401 without its key
```


### Collector sign-ins

Each collector needs one credential this repository cannot invent, so each has a
sign-in staged by hand: the SimpleFIN access URL, the TutaBridge session and its
local IMAP password, the Tuta calendar session, and the Brave Sync seed. The
commands are `docs/core/applications.md`, "Collector sign-ins".

### Verify the facade wire

The client is the gateway container itself — it is on the deployment's network and
its image carries `python3` — and the token arrives on stdin, never in an argument.
`initialize` must answer `agent-facade-personal` and `tools/list` exactly
`sources.describe`, `sources.read`, `sources.search`, `memory.read`,
`memory.write`, `memory.search` and `memory.rebuild`; the general deployment
answers at `http://smortress-agent-facade-general:18005/mcp` with `repos` and
`books` and no personal source. A request with no token is `401` before any tool
could run.

```sh
sudo podman exec -i smortress-agent-local python3 -c '
import json, sys, urllib.request
token = sys.stdin.readline().strip()
def call(method, ident, params=None):
    request = urllib.request.Request(
        "http://smortress-agent-facade-personal:18004/mcp",
        data=json.dumps({"jsonrpc": "2.0", "id": ident, "method": method,
                         "params": params or {}}).encode(),
        headers={"Content-Type": "application/json", "X-Deployment-Token": token})
    with urllib.request.urlopen(request, timeout=10) as answer:
        return json.load(answer)
print(call("initialize", 1)["result"]["serverInfo"])
print([tool["name"] for tool in call("tools/list", 2)["result"]["tools"]])
' < <(sudo cat /run/smortress/secrets/agent-facade-personal-token.yaml)
sudo podman exec -e HERMES_HOME=/opt/data smortress-agent-local hermes mcp test personal
sudo grep -c '__FACADE_TOKEN__' /var/lib/agent/local/config.yaml   # 0 after seeding
sudo podman logs smortress-agent-facade-personal 2>&1 | tail
```

The gateway's own client is the fastest diagnosis of a rotation that did not reach
the config, and the facade logs the method, the path and the status of every
request — never a header or a token — so its log is safe to paste.

### Verify the two browser UIs

Both run the pre-baked image, so the first check is that starting them installs
nothing (`Downloading uv` means the image is not the baked one), and that each
publishes on loopback only behind its own password gate.

```sh
sudo systemctl start agent-webui-personal.service agent-webui-general.service
sudo journalctl -u agent-webui-personal.service -n 60 --no-pager \
  | grep -E 'already installed|Existing virtual environment|skipping|listening'
for port in 18006 18007; do
  curl -sS -o /dev/null -w "$port / -> %{http_code} %{redirect_url}\n" http://127.0.0.1:$port/
  curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:$port/health
done
```

Each `/` answers `302` toward `/login?next=/` and `/health` `200` without a
session; a `200` on `/` means no password reached the process, so read
`/var/lib/agent/local/webui.env` (which must be `1000:1000 0400`). The personal UI
must reach nothing off the host, and each UI must be a client of its own
deployment's gateway:

```sh
sudo podman exec smortress-agent-webui-personal python3 -c \
  'import socket; socket.create_connection(("1.1.1.1", 443), 3)'; echo "exit=$?"
sudo podman logs --since 2m smortress-agent-local 2>&1 | grep -c 'POST /v1'
```

From a tailnet device open `https://smortress.<tailnet>.ts.net:8444/` (personal, the
pinned local model) and `:8445` (general, through `agent-proxy`), signing in with
each deployment's own password, read from its bundle at the key the index names:

```sh
sops -d --extract '["ui"]["personal_password"]' secrets/agents.json
```

The same two UIs answer at `https://assistant.sammohr.dev/` and
`https://agent.sammohr.dev/` once the zone has applied the `A` records that point
them at the Service VIP. That is a second apply, after #833's destroy of the old
`agent` CNAME (PR #120), because Cloudflare refuses two records at one name.

The first-run wizard is disabled, so `Missing imports: run_agent` is expected;
the facades are the tool surface.

### Fetch the pinned model

The model is in no backup: it is a blob a checksum re-derives. Fetch it once into
`state/agent-model`, which the pool unit must have created and mounted.

```sh
sudo chown 1000:1000 /var/lib/agent/model
sudo curl -fL --retry 3 --continue-at - -o /var/lib/agent/model/Inkling-2-Mini-AD-Q4_K.gguf.part \
  'https://huggingface.co/AtomicChat/Inkling-2-Mini-GGUF/resolve/main/Inkling-2-Mini-AD-Q4_K.gguf?download=true'
echo '2bfc233e10925297cc79dffce5d9be4f2a2b43e499ea6a1bf03b9242867dce9e  /var/lib/agent/model/Inkling-2-Mini-AD-Q4_K.gguf.part' \
  | sudo sha256sum -c -
sudo mv /var/lib/agent/model/Inkling-2-Mini-AD-Q4_K.gguf.part \
        /var/lib/agent/model/Inkling-2-Mini-AD-Q4_K.gguf
sudo chown 1000:1000 /var/lib/agent/model/Inkling-2-Mini-AD-Q4_K.gguf
```

The size and the checksum are the pin (`16525559776` bytes). The name matters:
`units/quadlet/agent-model.container` starts the server with
`-m /models/Inkling-2-Mini-AD-Q4_K.gguf`, so a different file name is an image
change. `AD-Q4_K` is the pinned quant; the neighbouring *Uncensored* variant and
the `mmproj` projector are deliberately not used.

### Agent shell jobs

`smortress-agent-job-provision.service` creates each shell runner's subuid range,
the general runner's ACL on `/var/srv/git` and the uid-keyed egress table. The
pinned job image must be prepulled once per runner; `--pull=never` makes a job on a
host that skipped this fail closed. `docs/agent-jobs.md` is the shape.

```sh
sudo /usr/libexec/agent-job-provision --check
grep -E '^agent-shell-(personal|general):' /etc/subuid /etc/subgid
sudo nft list table inet smortress_agent_jobs
getfacl -p /var/srv/git | grep agent-shell-general
image=$(cat /etc/smortress/agent/job-image)
for runner in agent-shell-personal agent-shell-general; do
  state=${runner#agent-shell-}
  # The runtime directory is logind's, never one under /run/smortress: rootless
  # Podman fails in namespace setup with any other path.
  sudo loginctl enable-linger "$runner"
  sudo -u "$runner" env -i HOME="/var/lib/agent-shell/$state" \
    XDG_RUNTIME_DIR="/run/user/$(id -u "$runner")" PATH=/usr/bin:/bin podman pull "$image"
done
sudo /usr/libexec/agent-job-personal \
  'id; test ! -e /var/srv/git && echo "no general tree"; test -e /run/podman/podman.sock && echo "socket" || echo "no podman socket"'
sudo /usr/libexec/agent-job-personal \
  'python3 -c "import urllib.request; urllib.request.urlopen(\"https://example.com\", timeout=3)" || echo blocked'
```

Both egress refusals must be denials, not timeouts into a successful fetch. An
output over 1 MiB is truncated and reported; a job past 300 seconds has its cgroup
killed and any leftover container removed. Shell jobs are unsupervised by design:
the only approval contract is the write broker's `libs/data_plane/approval.py`.

A facade does not run an entry point itself: it holds a socket served by
`smortress-agent-shell-bridge.service`, and that socket is the only path to a
general job (`docs/agent-jobs.md#transport`). `/run/smortress` is root 0700 and the
socket's directory is 0710 root:1000, so no host uid can traverse to it; the only
client is the container that mounts the directory as `/run/agent-shell`:

```sh
systemctl status smortress-agent-shell-bridge
sudo stat -c '%U:%G %a %n' /run/smortress/agent-shell /run/smortress/agent-shell/general.sock
# root:1000 710 /run/smortress/agent-shell
# root:1000 660 /run/smortress/agent-shell/general.sock
sudo podman exec smortress-agent-facade-general python3 -c '
import socket
sock = socket.socket(socket.AF_UNIX)
sock.connect("/run/agent-shell/general.sock")
sock.sendall(b"{\"command\": \"id -u; ls /var/srv/git | head -3\"}\n")
print(sock.makefile().readline())'
```

The answer names uid 1000 and the general tree, so the job is a container and not
the host. Any other uid is refused by the socket's group, and the host path is
refused before that by the root-only parent -- no gateway, model server or web UI
has a mount to try with:

```sh
sudo runuser -u nobody -- python3 -c '
import socket
socket.socket(socket.AF_UNIX).connect("/run/smortress/agent-shell/general.sock")'    # Permission denied
```

`tools/list` on the general facade names `shell.run` and the personal facade does
not, which is the same fact from the client's side (the token is the deployment's
own, read from its mounted file):

```sh
sudo podman exec smortress-agent-facade-general python3 -c '
import json, urllib.request
token = open("/run/secrets/agent-facade-general-token").read().strip()
body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).encode()
request = urllib.request.Request(
    "http://127.0.0.1:18005/mcp", data=body,
    headers={"Content-Type": "application/json", "X-Deployment-Token": token})
print([tool["name"] for tool in json.load(urllib.request.urlopen(request))["result"]["tools"]])'
```

The same call with the personal deployment's token answers `401`: one token is one
deployment, so a token that names the personal facade cannot reach the general one.

### Run the agent runtime drill

`scripts/agent-runtime-drill.sh` answers three rows of the T6 matrix that no static
check can: the live mount namespaces, the root-only secrets, and a cold restore of
an agent dataset from a real destination. It prints names and modes, never a value,
writes only under the restic data disk's `drill/`, and stops nothing.

```sh
scripts/agent-runtime-drill.sh --dry-run mounts        # plan only, unprivileged
sudo systemctl stop smortress-agent-collect-finance.timer \
  smortress-agent-collect-calendar.timer smortress-agent-collect-brave.path \
  smortress-agent-collect-brave.timer
sudo systemctl stop smortress-agent-mail-stream.service agent-tmail.service \
  agent-brave.service syncthing.service
sudo systemctl stop agent-webui-personal.service agent-webui-general.service \
  agent-facade-personal.service agent-facade-general.service \
  agent-local.service agent-general.service agent-proxy.service
sudo scripts/agent-runtime-drill.sh mounts
sudo scripts/agent-runtime-drill.sh credentials
sudo scripts/agent-runtime-drill.sh restore agent-local --backend all
sudo scripts/agent-runtime-drill.sh restore agent-general --backend all
```

`present and listable` or `readable` on any line is the finding: a container that
can read `/run/smortress/secrets/restic-password.yaml`,
`/run/smortress/secrets/r2-credentials.yaml` or `/var/lib/homelab/age/keys.txt` can
destroy every recovery point. A target inside a mounted dataset is refused, so
drill on `/var/lib/restic/hdd/drill`, never under `/var/tmp`. A good run ends
`0 failed`; start the writers again as "Validate the units" gives, and remove the
leftover tree:

```sh
sudo rm -rf /var/lib/restic/ssd/drill/ssd-agent-*
```

## Recover

### T0: freeze, rescue, verify, and publish the kit

The gate and its evidence live in `docs/core/t0-gate.md`; the kit contract is
`docs/core/recovery-kit.md`. Nothing in T1–T6 may repartition or wipe a disk until
every step below is done and its evidence is posted on #703.

```sh
sudo scripts/legacy/freeze-legacy.sh --check
sudo scripts/legacy/freeze-legacy.sh --apply     # --resume restores the recorded state
sudo systemctl stop syncthing.service 2>/dev/null || true
sudo tar -C /var/lib -c syncthing syncthing-versions \
  | zstd -T0 -o /var/backup/t0-syncthing-state.tar.zst
sudo sha256sum /var/backup/t0-syncthing-state.tar.zst
sudo systemctl start syncthing.service 2>/dev/null || true
sudo systemctl start restic-backups-local.service restic-backups-r2.service
sudo scripts/legacy/verify-legacy-backups.sh --keep
sudo scripts/legacy/legacy-audit.sh --out /var/tmp/t0-audit.md
```

The Syncthing step rescues what no backup holds: the identity and the vault version
history live outside restic's source path, and `/var/backup` is the HDD, which
survives the migration — copy the archive into the kit before the HDD is converted.
`pg_restore` is not on the host's PATH, so the verifier reports the exact
`pg_restore --list <file>` line it needed, and that counts as a failure.

### Bringing the plane up

The first init, the first backup per destination, the first drill and the failure
boundaries are `docs/core/restic-plane.md`, "Bringing the plane up".

### Restore an application by hand

The restore paths and their proofs are `docs/core/applications.md`, "Restore paths";
the mechanical restore and the fencing rules are `docs/core/restic-plane.md`,
"Restore by hand". Stop every writer of the unit's datasets first, including
`smortress-immich-dump.timer`.

```sh
sudo systemctl stop smortress-immich-dump.timer
sudo systemctl stop immich-server.service immich-machine-learning.service immich-postgres.service \
  immich-valkey.service opdshelf.service syncthing.service navidrome.service
drill=/var/lib/restic/ssd/drill
for unit in files photos books music wallpapers git apps repo-archive; do
  sudo /usr/libexec/smortress-restic-restore-drill ssd "$unit" --target "$drill/$unit"
done
sudo chown -R 1000:1000 "$drill"
sudo chcon -R -t container_file_t "$drill"
```

A restored tree is root-owned and unlabelled, because the restore runs as root and
Restic does not carry `security.selinux`: the `chown` and `chcon` are what make it a
tree the application can write and Podman may mount, and a real restore needs both.
Start the units again as "Validate the units" gives, then the dump timer.
`scripts/legacy/retirement-gate.sh` runs the same helper over every unit and destination
for the T6 gate.


### The boot gate and its denials

`bootc` has no boot counting here and `bootupctl update` never copies the static
GRUB snippet, because every component is already current:

```sh
sudo bootupctl status                        # No components are adoptable.
sudo grep -c 'boot_counter' /boot/grub2/grub.cfg   # 0
```

**The host therefore has no pre-userspace rollback.** Do not claim one, and do not
enable `kernel.panic`: a panic that reboots without a counter loops the same image
forever. What exists is the userspace gate — a deployment that boots but fails its
host health check is denylisted and `bootc rollback --apply` reverts it — and the
tenant's apps are not part of it, so a red gate always means the platform itself.

```sh
journalctl -u smortress-boot-gate.service --no-pager -n 20
# "healthy after N attempt(s)" when a deployment was owed; "boot-counting-absent" otherwise
```

`/usr/share/smortress/deploy-units.txt` is what "serving" means for this host. A
host that will not boot is recovered from the console, and the recovery point is the
pre-reboot snapshot the deploy gate took.


### Hosted Backrest

The reader's gate repository, Worker secrets, deploy and matrix are
`docs/core/backrest.md`, "Operator order"; the read-only boundary, the gate
matrix and the preauthorized VPS fallback are that document's own sections.

## Tailnet and access

### Prove the Access default-deny

The static half runs in CI; this is the live half. From a network that is not the
tailnet, with no Cloudflare session, a name the policy does not name must hit the
wildcard deny rather than an origin:

```sh
curl -sS -o /dev/null -D - https://<unnamed-host>.sammohr.dev/ | head -3
# expect: an Access redirect or 403, never an application page
```

### Kanbei behind Access

`tofu/kanbei.tf` creates the Access application for `kanbei.sammohr.dev`. A retired
object carried `prevent_destroy`, so the operator removes the state entry before the
block: `tofu -chdir=tofu state rm cloudflare_zero_trust_access_application.kanbei`.
A machine-to-machine client reaches it through a `service auth` policy and its own
service token, minted in Zero Trust → Access → Service Credentials; rotating the
token is a re-mint plus the policy's token id.


### The tailnet policy, sshd, and sudo

The ACL apply and the enrollment key, the tailnet-only sshd prove-out, retiring
Tailscale SSH, and the YubiKey sudo credential and its drills are
`docs/core/server-image.md`, "Access: the tailnet policy, sshd, and sudo".

## Decommission evidence

### Retire the Cloudflare SSH route

SSH is tailnet-only, so the Cloudflare route is deleted and not replaced. `tofu/`
owned the edge objects, so the apply deletes the `ssh` record, the `ssh` tunnel
config, the `ssh` application, its `service auth` policy and its service token.
Their `prevent_destroy` blocks were deleted with the resources, so this is a plain
destroy: no `tofu state rm` first, and a plan that offers to keep them is a stale
checkout.

```sh
./scripts/tofu-cloudflare.sh plan -no-color     # expect: 5 to destroy, 0 to add, 0 to change
gh workflow run tofu-apply.yml                  # refuses a destructive plan unattended
./scripts/tofu-cloudflare.sh state list | grep ssh || echo "no ssh objects in state"
```

A replace or a destroy anywhere else means the state and the config disagree: stop
and compare. The tunnel object itself was created in the dashboard and this
repository never owned it, so with the ingress gone it has no rules and no
connector: remove it in Zero Trust → Networks → Tunnels. In Access → Applications
the list must then hold `wildcard default-deny`, `memory`, `agent`, `backrest`,
`kanbei` and the public set, and no `ssh`.

### Remove the reader's Access gate

`tofu/access.tf` declares no `backrest` application: the name is in
`local.public_apps`, so Access passes it to the Worker and Backrest's password is
the only login. The application carried `prevent_destroy`, so drop its state entry
**first** — dropping the block alone fails the apply:

```sh
tofu -chdir=tofu state rm cloudflare_zero_trust_access_application.backrest
gh workflow run tofu-apply.yml
curl -sS -o /dev/null -D - https://recovery.sammohr.dev/ | head -3
```

### The T6 retirement gate

The gate's evidence is a cold restore of every recovery unit from every destination,
plus the two agent drills:

```sh
sudo scripts/legacy/retirement-gate.sh --dry-run
sudo scripts/legacy/retirement-gate.sh                  # the whole matrix
sudo scripts/legacy/retirement-gate.sh --keep           # leave the targets for inspection
```

### Decommission checklist

1. **T0 gate closed** — "T0: freeze, rescue, verify, and publish the kit", with the
   kit drill dated in `docs/core/recovery-kit.md`.
2. **The three repositories are fresh** — "Bring the restic plane up", and
   `smortress-restic-verify` exits 0 on every unit.
3. **The retirement matrix is green** — `scripts/legacy/retirement-gate.sh` with no failed
   row, plus `scripts/agent-runtime-drill.sh mounts`, `credentials` and `restore`
   for both agent datasets.
4. **The old plane is proven and then frozen** — the T0 verifier tables; stop
   writing and pruning the old repositories, record the date in the kit, and delete
   them only after 90 days through the reviewed retention process.
5. **The edge reaches no old origin** — "Retire the Cloudflare SSH route" and
   `scripts/verify-public-edge.sh` all green.
6. **Nothing hand-run is left** — `scripts/check-all.sh` and
   `python3 scripts/check-doc-refs.py` both exit 0, so the tree describes the host
   that is running.


## Public edge VPS

The edge VPS order — tailnet policy, `tag:vps` key, panel firewall, console join,
bootstrap, Serve routes, the two-commit cutover and the timed rebuild drill — is
`docs/core/public-edge.md`, "The operator order".

## Former section numbers

Scripts, units and the image still quote the pre-rewrite numbering; this is where
each number landed.

| Old | Now |
| --- | --- |
| §2, §4, §5 | GitHub: identity, environments, and tokens |
| §6, §12 | Secrets and rotation |
| §14, §46 | The tailnet policy and the enrollment key |
| §18 | Prove the Access default-deny |
| §21 | Kanbei behind Access |
| §35 | Claim the SimpleFIN access URL; Publish and sign the application images |
| §36 | T0: freeze, rescue, verify, and publish the kit |
| §37 | Install a host from the image |
| §38 | Bring the restic plane up |
| §39 | Hosted Backrest; Remove the reader's Access gate |
| §40.1–40.6 | Applications and agents; Restore an application by hand |
| §40.7, §40.11 | Rotate the agent's credentials; Validate the units |
| §40.8 | Fetch the pinned model |
| §40.12 | Verify the facade wire |
| §40.13 | Verify the two browser UIs |
| §40.14 | Claim the SimpleFIN access URL |
| §40.15 | Sign in to the Tuta mail bridge |
| §40.16 | Sign in to the Tuta calendar exporter |
| §40.17 | Export the Brave sync seed |
| §40.18 | Run the agent runtime drill |
| §41 | Retire the Cloudflare SSH route |
| §42–§45 | Tailnet and access |
| §47 | Agent shell jobs |
| §48 | The machine user and its scoped token; Prove the ceiling |
| §49 | Create the notify environment; The operator's view of the receiver |
| §50 | Public edge VPS |
