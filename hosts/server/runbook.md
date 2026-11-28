# Server runbook

The steps for `smortress`, in the order an operator runs them: install, GitHub
secrets, rotation, the deploy state, the applications, recovery, access and
decommission. Run one procedure to completion before the next, and record the
date and who ran it.

## 1. Install the server from the image

### 1.1 Preflight

**The install wipes the target disk.** A line that does not print what its comment
says it must stops the install.

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
cosign verify --key lib/containers/cosign.pub "$(cat ignition/operator/derived-image)" >/dev/null \
  && echo signature-verified                        # P5: the image is signed
ip -o link show | awk '$2 != "lo:" {print $2, $9}'  # P6: from the live media
ip -4 route get 10.0.0.193                          # wired UP, route, 200
curl -sS -m5 -o /dev/null -w '%{http_code}\n' http://10.0.0.193:7654/adv
```

P4 expects a `/dev/disk/by-id/nvme-…` path, a MODEL containing `980`, `931.5G`,
`nvme`, `1000204886016` bytes and `0` mounts. P6 expects a wired link `UP`, a
route and an answer of `200`. **A smaller disk cannot be grown into this layout
in place**: a ZFS vdev cannot shrink, so `p5` is recreated, not resized.

Have the kit at hand: both 980 LUKS passphrases, the cosign key and password, the
admin age identity and the smortress SSH host key (`docs/core/recovery-kit.md`).
The console is the only way to enter a LUKS passphrase.

### 1.2 Sign and publish the image

Once per signing key. The private key and password go into the recovery kit; only
the public key is committed.

```sh
install -d -m 0700 "$HOME/.config/smortress"
export COSIGN_PASSWORD="$(openssl rand -base64 32)"
cosign generate-key-pair --output-key-prefix "$HOME/.config/smortress/cosign"
install -m 0644 "$HOME/.config/smortress/cosign.pub" lib/containers/cosign.pub
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

**Replacing `lib/containers/cosign.pub` without re-signing the running digest
first makes `bootc` reject the next switch.**

### 1.3 Stage the operator values

`ignition/operator/` is gitignored. No secret enters Ignition or the installer
media: the recovery passphrases are not staged for the renderer at all.

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

The account hash (`["smores"]["password_hash"]` in `secrets/boot.json`) is not an
operator file: it ships as ciphertext, minted by 3.3.

### 1.4 Render Ignition and install

```sh
export SOPS_AGE_KEY_FILE=/path/to/admin-keys.txt
scripts/render-ignition.sh --check    # prints: render-ignition: butane accepted
scripts/render-ignition.sh            # prints the install command to run
stat -c '%a %n' ignition/smortress.ign
jq -r '.storage.luks | map(.name) | join(",")' ignition/smortress.ign
jq -r '.storage.luks | map(has("keyFile")) | join(",")' ignition/smortress.ign
jq -r '.storage.luks | map(.clevis.threshold) | join(",")' ignition/smortress.ign
```

Expect `root`, `false`, `2`: **a `true`, a second device name or another threshold
means a secret or a weaker binding entered the config — stop, do not install.** The
file carries the account password hash: keep it `0600` and remove it afterwards.

Write the live media (Fedora CoreOS `live` at the `VERSION_ID` of
`bootc/lib/pins.env`'s tag), verify the read-back hash, then install:

```sh
iso=$(ls "$HOME"/Downloads/fedora-coreos-*-live.x86_64.iso | tail -n1)
expected=$(grep -oE '[0-9a-f]{64}' "${iso}.sha256" | head -n1)
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

Expect `p1` `BIOS-BOOT`, `p2` `EFI-SYSTEM`, `p3` `boot` and `p4`, and `blkid
exit 2`: no `luks-root` label and no `p5`.

### 1.5 The first boot: prove the transition

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

Expect both markers and `disabled` twice. `scripts/verify-image.sh` must print
`verified <ref>` with a matching registry digest and a legacy `.sig` lookaside
tag.

### 1.6 Add the offline recovery passphrases

**Do not reboot before this procedure finishes: root has no passphrase keyslot
yet, and this is the only way in when Tang is unreachable and the TPM is gone.**
The Clevis slot's key is recovered from the running host and destroyed immediately.

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
opens from `/etc/luks/data` without a second prompt (`cryptsetup status data` →
`active`, the pool → `ONLINE`). Repeat the read-back after every kernel update:

```sh
sudo lsinitrd /boot/ostree/*/initramfs-*.img | grep -E '/etc/luks|/etc/crypttab' || true
```

### 1.7 Stage the age identity and prove the decrypt unit

```sh
sudo install -d -m 0700 -o root -g root /var/lib/homelab/age
sudo install -m 0600 -o root -g root /path/to/kit-age-identity \
  /var/lib/homelab/age/keys.txt
sudo systemctl restart sops-decrypt.service
sudo cat /run/smortress/secrets/canary.yaml     # canary: sops-decrypt-ok
```

The file must be the unwrapped `AGE-SECRET-KEY-…` identity, not the kit container:
`stat -c '%a %U'` prints `600 root`.

### 1.8 Configure and open the HDD

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

The `luksAddKey` prompt accepts the existing HDD passphrase from the kit. Then
remove the HDD and reboot once: boot completes, the unit logs the absence, and the
restic freshness alert is the only failure.

### 1.9 Prove the boundaries

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

While `photos` is unmounted `zfs-ready@books` and unrelated backups stay up. From a
LAN host that is not on Tailscale, `ssh smores@<lan-ip>` and every application port
must fail. Then update the kit, run its drill with only kit material, and repeat
the media write through this point on a scratch disk before the production wipe.

**The `05-` sshd drop-in sorting before uCore's `90-` is a lockout guard**: sshd
keeps the earlier value for a re-read directive, so the tailnet route has to work
first or the host answers only from the console.

### 1.10 Failure paths

Stop and read the state; do not continue and do not improvise a workaround.

- **P1 fails.** dracut will not reach Tang either: fix the network or Tang,
  re-derive the thumbprint, re-run P1. A host installed anyway is a reinstall.
- **P2 fails.** Threshold 2 can never be met: fix the board, reinstall.
- **P4 or P5 fails.** Rewrite `disk` and re-render, or restore the signing key from
  the kit and re-publish before pinning a digest.
- **The render shows `keyFile` or a second LUKS device.** Fix
  `ignition/smortress.bu`, re-run `bats tests/image/ignition-boundary.bats`.
- **No `p4`, or `blkid` exits 0 on `luks-root`.** Re-run the install; `wipefs -a`
  the target from the live media first if it fails again.
- **No `/etc/ucore-autorebase/unverified` marker** (or, one stage later, no
  `signed`): the stage never ran, usually for want of a network at first boot.

  ```sh
  sudo journalctl -b -u ucore-unsigned-autorebase.service --no-pager
  sudo systemctl restart ucore-unsigned-autorebase.service
  ```

  ```sh
  sudo cryptsetup luksDump /dev/disk/by-partlabel/root | sed -n '/^Keyslots:/,/^Tokens:/p'
  sudo clevis luks list -d /dev/disk/by-partlabel/root
  ```

- **No data mapper.** A missing `/dev/disk/by-partlabel/luks-data` is the
  installer:

  ```sh
  sudo journalctl -b -u smortress-data-init.service --no-pager
  sudo systemctl restart smortress-data-init.service smortress-zpool.service
  ```

- **`clevis luks pass` fails.** It needs Tang *and* the TPM, and without it the
  host has no offline recovery:

  ```sh
  curl -sS -m5 -o /dev/null -w '%{http_code}\n' http://10.0.0.193:7654/adv
  sudo systemd-cryptenroll --tpm2-device=list
  ```

- **A wrong passphrase at `open --test-passphrase`.** Re-copy from the kit; if it
  still fails, add the value again while Tang and the TPM are healthy.

### 1.11 Roll back what an install did

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

### 1.12 Move a running host to a newer build

```sh
sudo bootc switch --enforce-container-sigpolicy \
  "ghcr.io/smores56/homelab-platform/server@sha256:<digest from the run summary>"
sudo systemctl reboot
```

A host may follow CI's moving `:latest` tag instead, and then `bootc upgrade` is
the update:

```sh
sudo bootc switch --enforce-container-sigpolicy ghcr.io/smores56/homelab-platform/server:latest
sudo systemctl reboot
```

**A hand switch by tag bypasses the deploy's descendancy check** and can stage a
build nobody verified: take the digest from the deploy journal. **`bootc rollback`
reverts the deployment only** — `/var`, the ZFS datasets and a database migration
are not restored.

## 2. GitHub: identity, environments, and tokens

### 2.1 The `cloudflare` environment secret

```sh
read -rsp 'Cloudflare API token: ' CLOUDFLARE_API_TOKEN
gh secret set CLOUDFLARE_API_TOKEN --env cloudflare --repo smores56/homelab-platform
unset CLOUDFLARE_API_TOKEN
gh api repos/smores56/homelab-platform/environments/cloudflare/secrets --jq '.secrets[].name'
```

The state backend's R2 pair is two more secrets in the same environment:
`R2_STATE_ACCESS_KEY_ID` and `R2_STATE_SECRET_ACCESS_KEY`.

### 2.2 The plan-only credentials

`cloudflare-plan` holds read-only credentials only. Three pairs:

- `CLOUDFLARE_PLAN_API_TOKEN`, minted in Zero Trust → My Profile → API Tokens with
  exactly three permissions and no others: **Zone:Read**, **DNS:Read** and
  **Workers R2 Storage:Read** on the account. No `Edit`, no `Zone Settings`, no
  token or tunnel permission.
- `R2_STATE_READONLY_ACCESS_KEY_ID` / `R2_STATE_READONLY_SECRET_ACCESS_KEY`, an R2
  token scoped to object read on `homelab-tofu-state`.
- `TAILSCALE_PLAN_OAUTH_CLIENT_ID` / `TAILSCALE_PLAN_OAUTH_CLIENT_SECRET`, the
  plan's own OAuth client, minted in the admin console under Trust credentials →
  OAuth client with exactly four scopes and no tags: `policy_file:read`,
  `devices:core:read`, `devices:posture_attributes:read` and `services:read`.

```sh
read -rsp 'plan OAuth client ID: ' PLAN_CLIENT_ID
printf '%s' "$PLAN_CLIENT_ID" | gh secret set TAILSCALE_PLAN_OAUTH_CLIENT_ID --env cloudflare-plan --repo smores56/homelab-platform
read -rsp 'plan OAuth client secret: ' PLAN_CLIENT_SECRET
printf '%s' "$PLAN_CLIENT_SECRET" | gh secret set TAILSCALE_PLAN_OAUTH_CLIENT_SECRET --env cloudflare-plan --repo smores56/homelab-platform
gh api repos/smores56/homelab-platform/environments/cloudflare-plan/secrets --jq '.secrets[].name'
```

Delete `TAILSCALE_OAUTH_CLIENT_ID` and `TAILSCALE_OAUTH_CLIENT_SECRET` from
`cloudflare-plan` if they are still there; the write pair stays in `cloudflare`.

### 2.3 Environments and their branch policies

Every workflow secret lives in an Environment, and the ones holding write or
signing credentials allow `main` only.

```sh
OWNER=$(cat ~/.config/smores56-agent/owner-token)
GH_TOKEN="$OWNER" gh api -X PUT \
  repos/smores56/homelab-platform/environments/server-image --input - <<'JSON'
{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON
GH_TOKEN="$OWNER" gh api -X POST \
  repos/smores56/homelab-platform/environments/server-image/deployment-branch-policies \
  -f name=main -f type=branch
for p in main 'smores/*' 'refs/pull/*/merge'; do
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
# expect: cloudflare main / cloudflare-plan main,smores/*,refs/pull/*/merge / server-image main
```

### 2.4 The machine user and its scoped token

The general shell agents act on GitHub as a dedicated machine account, never as
`smores56`, with a ceiling of Write: push branches, open pull requests, edit
issues, and nothing else.

1. Create the account in a browser, with an address that is not the owner's and not
   a `+` alias; enable TOTP 2FA, store the recovery codes, add no SSH key, OAuth
   app, security key or organisation.
2. Create the classic PAT as the machine user, scope `repo` only. Without
   `workflow` the token cannot create or update `.github/workflows/**`.
3. Make it a Write collaborator everywhere and accept the invitations as the
   machine user. Archived repositories refuse the change.

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

### 2.5 Prove the ceiling

A plain `git push` authenticates as the owner even when the URL carries
`x-access-token`, so the proof must run through a clean environment:

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

A push touching `.github/workflows/**` is refused earlier, by the missing
`workflow` scope; Administration endpoints answer `404`. Close the probe PR,
delete the branch, then revoke the transient owner token and remove both local
copies:

```sh
rm -f ~/.config/smores56-agent/owner-token ~/.config/smores56-agent/token
```

Rotating the machine PAT is: revoke it as the machine user, create a replacement
with scope `repo` only, and replace the `agent-github-token.yaml` ciphertext.

## 3. Secrets and rotation

A container that already mounts a rotated file keeps the old value until it
restarts.

### 3.1 Rotate a Cloudflare-derived secret

The R2 pair is authored only in the Cloudflare bundle, then derived:

```sh
sops secrets/cloudflare.yaml          # restic-backup-rw-*
scripts/cloudflare-derive.sh
scripts/secret.sh stage r2-credentials.yaml
scripts/secret.sh verify
```

### 3.2 Add an output the index does not name

An output the index already names is `edit` and `stage`, nothing else. A new one
is an index line plus its key in a bundle, in one commit.

```sh
python3 scripts/secrets-index.py list | grep deploy-ping-url   # bundle and consumer
scripts/secret.sh edit deploy-ping-url.yaml    # deploy.ping_url
scripts/secret.sh stage deploy-ping-url.yaml
scripts/secret.sh verify                       # policy, index and bundles agree
python3 scripts/secrets-check.py --shadow      # manifest matches the index
```

Only a secret whose *manifest line* changes needs the image and a reboot. A hand
edit of `/etc/smortress/secrets.manifest` is neither needed nor kept: bootc merges
`/etc` once per deployment, so the image's `/usr/share` copy is the author and the
seed rewrites the read copy on every boot.

### 3.3 Rotate the smores account password

```sh
read -rsp 'smores account password: ' password; echo
printf '%s\n' "$password" | openssl passwd -6 -stdin   # the hash to paste
unset password
scripts/secret.sh edit smores-password-hash.yaml     # smores.password_hash
scripts/secret.sh stage smores-password-hash.yaml
scripts/secret.sh verify
```

Commit the bundle, put the password in the recovery kit, then apply it and prove
it at the console — never over the SSH session the old password protects:

```sh
sudo systemctl restart smortress-password.service
sudo journalctl -b -u smortress-password.service --no-pager
sudo getent shadow smores | cut -d: -f2 | cut -c1-3   # must print $6$
```

The journal must contain `re-applied the smores password field from ciphertext`.

### 3.4 Rotate an application secret

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

### 3.5 Rotate the agent's credentials

The gateways read none of these from a `_FILE`: `smortress-agent-config.service`
rewrites `API_SERVER_KEY` into `/var/lib/agent/{local,general}/.env`, the UI's key
and password into `webui.env`, and the workspace's pair into
`/run/smortress/workspace.env` at every start, and
`smortress-app-secrets.service` recreates the Podman secret the Quadlets mount.
A rotation therefore reaches nothing until the writers restart first and the
containers that read them restart after:

```sh
scripts/secret.sh edit agent-local-api-key.yaml       # agent.local_api_key: openssl rand -hex 32
scripts/secret.sh edit agent-general-api-key.yaml     # agent.general_api_key: same
scripts/secret.sh edit agent-hosted-key.yaml          # agent.hosted_key: the provider's key, not ours
scripts/secret.sh edit agent-ui-personal-password.yaml   # ui.personal_password
scripts/secret.sh stage agent-local-api-key.yaml      # all four are in agents.json
sudo systemctl restart smortress-app-secrets.service smortress-agent-config.service
sudo systemctl restart agent-local.service agent-general.service
sudo systemctl restart agent-webui-personal.service agent-webui-general.service
git commit -am 'chore(agent): rotate the agent credentials'
git push
```

Restarting `agent-local` is the step that is easy to skip and the one that
matters: the gateway took the old key into its environment when it started, so
the UI that picks up the new one is refused until the gateway restarts too.
`agent-workspace-personal.service` reads the same pair from
`/run/smortress/workspace.env`; restart it as well once the image ships it, and
restart `agent-proxy.service` when the rotation is the hosted provider key: it
mounts `agent-hosted-key` as a secret and names it in `AGENT_PROXY_KEY_FILE`.


**Both gateway keys sit inside a restorable dataset**, so they are in the Restic
snapshots and in R2; both are self-issued and revocable, and the provider key is in
no dataset at all.


### 3.6 Change the SOPS policy

The recipient list is canonical in `dotfiles` as `scripts/sops-policy.py`, and
`scripts/check-sops-drift.sh` pins the commit this repository is compared against
(`dotfiles_ref`), so CI fails when the vendored copy or `.sops.yaml` is not that
revision's render. Change the policy in `dotfiles`, copy it here unchanged, then
render and rekey:

```sh
python3 scripts/sops-policy.py render --profile platform >.sops.yaml
scripts/secret.sh rekey --rotate
scripts/secret.sh verify
```

Then set `dotfiles_ref` in `scripts/check-sops-drift.sh` to that dotfiles commit
(`git log -1 --format=%H -- scripts/sops-policy.py`).

## 4. Deploy

### 4.1 Create the fleet check

One check covers the public edge and the tailnet names: `scripts/verify-fleet.sh`
iterates both classes and prints one verdict, and
`.github/workflows/verify-fleet.yml` runs it daily. It reads its ping URL from the
`deploy-notify` Environment; give that environment the `main`-only branch policy
2.3 gives `server-image`. Create the check in the project with a `1 day` period
and a `6 hour` grace, then copy its ping URL in:

```sh
OWNER=$(cat ~/.config/smores56-agent/owner-token)
printf '%s' '<ping url>' | GH_TOKEN="$OWNER" \
  gh secret set FLEET_PING_URL --env deploy-notify --repo smores56/homelab-platform
```

Run it once so the check has an answer, and read the job's own output: it prints
one `ok`/`FAIL`/`note` line per probe, then one verdict.

```sh
GH_TOKEN="$OWNER" gh workflow run verify-fleet.yml --repo smores56/homelab-platform
GH_TOKEN="$OWNER" gh run watch --repo smores56/homelab-platform
```

The script needs a tailnet node for the names class and DNS plus TLS for the edge
class, so it is also the operator's tool during an outage; `--dry-run` prints the
plan without contacting anything:

```sh
scripts/verify-fleet.sh --dry-run                     # the nine entries and the CAA row
scripts/verify-fleet.sh                               # one verdict
FLEET_CERT_MIN_DAYS=100000 scripts/verify-fleet.sh     # every certificate leg, red
CAA_ZONE=example.com scripts/verify-caa.sh            # a zone with no CAA, a notice
```

`verify-caa.sh` prints a `note` and exits 0 until the zone's `CAA` records exist;
its exit status folds into the fleet verdict.

### 4.2 T5: the owner's first run

One sitting, in this order — step 1 can block everything after it.

1. **Apply the CAA records**: `tofu -chdir=tofu apply -no-color` from a clean
   checkout of `main`.
2. **Read the zone back**: `dig +short CAA sammohr.dev` must print **both**
   `0 issue "letsencrypt.org"` and `0 issuewild "letsencrypt.org"` **plus**
   Cloudflare's appended set (`pki.goog`, `sectigo.com`, DigiCert, `ssl.com`).
   Anything short of the two declared values: `git revert` the commit and
   re-apply; never edit the zone by hand.
3. **Force the renewal** on the VPS. **`rm -rf` on the wrong path takes every
   name's certificate with it**: list first, copy the path into the delete.

   ```sh
   ssh root@smoresnet
   ls -d /var/lib/caddy/.local/share/caddy/certificates/*/photos.sammohr.dev
   rm -rf /var/lib/caddy/.local/share/caddy/certificates/*/photos.sammohr.dev
   systemctl restart caddy
   openssl s_client -connect photos.sammohr.dev:443 -servername photos.sammohr.dev \
     </dev/null 2>/dev/null | openssl x509 -noout -subject -dates
   ```

   `subject` must be `photos.sammohr.dev` and `notAfter` the new window. If
   finalize fails with `urn:ietf:params:acme:error:unauthorized - authorizations
   for these identifiers not found`, stop Caddy, move
   `/var/lib/caddy/.local/share/caddy/acme` aside, start Caddy so it registers a
   fresh account, and let it obtain. The issuer must be `acme-v02`, not
   `acme-staging-v02`.
4. **Kanbei's Universal SSL re-validation**: SSL/TLS → Edge Certificates must show
   `kanbei.sammohr.dev` (and the zone's wildcard) active, not pending or expired.
5. **Create the Healthchecks check and `FLEET_PING_URL`**: `1 day` period, `6 hour`
   grace, then the `gh secret set` above.
6. **One green dispatch**: `gh workflow run verify-fleet.yml`, then read the
   `ok`/`note` lines.
7. **One deliberate failure**: from a scratch branch, point one probe in
   `scripts/verify-fleet.sh` at a host that cannot answer, run
   `gh workflow run verify-fleet.yml --ref <branch>`, and watch the run go
   red and the page arrive. Delete the branch.

### 4.3 Create the tenant apps check

Create the check in the project with a `5 minute` period and a `5 minute` grace,
put its ping URL in the bundle, and let the decrypt units carry it:

```sh
sops secrets/boot.json     # healthchecks: apps-ping-url: <ping url>
sudo systemctl restart sops-decrypt.service smortress-app-secrets.service
sudo grep -o '^[a-z-]*ping-url:' /run/smortress/secrets/healthchecks.yaml | sort -u
```

Both keys must print and no value is echoed. Then prove the page once: stop the
tenant's one app, wait for the next tick, read the page, and put the app back.

```sh
quadlet=$(sudo jq -r '.apps | to_entries[0] | .value.unitName // (.key + ".container")' \
  /var/lib/homelab/apps/plan.json)
sudo systemctl --user --machine=apps@.host stop "${quadlet%.container}.service"
journalctl -u smortress-apps-health.service -n 3 --no-pager   # within 5 minutes
sudo tail -n 5 /var/lib/homelab/deploy/journal.jsonl | jq -c 'select(.event=="apps-health-failed")'
sudo systemctl --user --machine=apps@.host start "${quadlet%.container}.service"
```

The page and the journal line carry the same body,
`not serving: tenant-unit-inactive:<app>`.

### 4.4 The operator's view of the deploy state

`/usr/libexec/smortress-deploy` is the whole operator surface. `status` is
read-only and takes no lock, so it answers on a host whose drain is wedged.

```sh
sudo /usr/libexec/smortress-deploy status | jq .
sudo tail -n 20 /var/lib/homelab/deploy/journal.jsonl | jq -c .
sudo journalctl -u smortress-deploy.service \
  -u smortress-boot-gate.service -u smortress-apps-health.service --no-pager -n 50
```

Run those scripts only from the operator checkout (`/var/home/smores/homelab-platform`):
`/srv/git/…` is the agent workspace, and the two can be at different commits.

### 4.5 A held deploy

A platform deploy whose snapshot gate cannot make one restore unit fresh holds
instead of rebooting: nothing is staged, nothing reboots, the check is red.

```sh
sudo /usr/libexec/smortress-deploy status | jq '.held'
# {"schema":1,"digest":"sha256:…","commit":"…","missingUnits":["books"],
#  "reason":"no-usable-repository","heldAt":"…","released":false}
sudo /usr/libexec/smortress-deploy release --force
```

Fix the repository, or take the break-glass flag, which records the operator, the
digest and the missing units and changes nothing else. A release covers one
digest only.

### 4.6 A denylisted commit or digest

A failed gate, a rollback and a rejected apps definition all denylist what they
refused, and a denial is final. **Set the value only after the cause is gone**: a
fixed definition is a *new* commit and needs no unblock.

```sh
sudo /usr/libexec/smortress-deploy status | jq '.denylist'
sudo /usr/libexec/smortress-deploy unblock digest sha256:…
sudo /usr/libexec/smortress-deploy unblock commit <40-hex>
sudo /usr/libexec/smortress-deploy block commit <40-hex>   # the way on, in reverse
```

### 4.7 A restored or rebuilt host

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

After a rollback `status` can name a staged digest the host never booted; **do not
hand-edit `state.json`**, because the next stage and gate overwrite it. A recorded
commit that is not an ancestor of `main` needs the console/restore path, not a
state edit.

### 4.8 Deploy the apps tenant

`deploy-apps apply --commit <sha>` fetches, renders, validates, pulls, installs and
commits; `deploy-apps revert` puts the previous revision back. A merge to
`homelab-apps` `main` is the normal path.

```sh
sudo /usr/libexec/smortress-deploy status | jq '.apps'
sudo systemctl status smortress-apps-user.service smortress-app-secrets.service
sudo systemctl list-timers 'smortress-apps-*'
```

The prober `smortress-apps-health.timer` pings the `apps` check when an app is not
serving and journals `apps-health-failed` with the reason, the app and the unit.

### 4.9 Serve routes

`smortress-tailscale-serve.service` declares every route at boot. **Repair an
empty Serve table by starting the unit, never by retyping a `tailscale serve`
command.** HTTPS certificates for the tailnet are an admin-console toggle.

```sh
sudo systemctl start smortress-tailscale-serve.service
tailscale serve status
```

Expect one host route on 443 to `http://127.0.0.1:2283` (Immich, plus
`/wallpapers/`, `/apps/agent-local` and `/apps/agent-general`), and the `svc:`
names. Nothing here is Funnel. The wallpaper route is a `Path` target rather than a
`Proxy`:

```sh
curl -fsS https://smortress.<tailnet>.ts.net/wallpapers/ | head
systemctl status zfs-ready@raw-wallpapers.service   # an empty listing means not mounted
```

The Syncthing GUI is reachable only through the `svc:sync` Service: a loopback
proxy answers on `127.0.0.1:8385` and forwards with the Host rewritten, and
`smortress-syncthing-hostcheck.service` writes the GUI's own host check back on at
every boot.

```sh
sudo systemctl status smortress-syncthing-hostcheck.service
sudo curl -fsS -H 'Host: evil.example' -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:8384/rest/noauth/health          # 403: the check is on
curl -fsS -o /dev/null -w '%{http_code}\n' https://sync.<tailnet>.ts.net/rest/noauth/health
tailscale serve status                              # no :10000 entry
```

A route that still answers on `10000` is a stale handler:
`sudo systemctl start smortress-tailscale-serve.service` retires it, or do it by
hand with `tailscale serve --https=10000 off`.

A dead proxy or a failed enforcement is a GUI nobody can open. This hand recovery
is a stopgap, because a reboot re-runs the enforcement and the Serve producer:

```sh
key=$(sudo sed -n 's:.*<apikey>\(.*\)</apikey>.*:\1:p' /var/lib/syncthing/config/config.xml)
sudo curl -fsS -X PATCH -H "X-API-Key: $key" -H 'Content-Type: application/json' \
  -d '{"insecureSkipHostcheck": true}' http://127.0.0.1:8384/rest/config/gui
sudo tailscale serve --bg --https=10000 http://127.0.0.1:8384
```

The GUI has no password of its own: the tailnet-only route is its whole access
control.

## 5. Applications and agents

### 5.1 Publish and sign the application images

The host's default-reject policy accepts an application image only when it is
signed by the smortress cosign key and pushed under
`ghcr.io/smores56/homelab-platform`.

```sh
gh workflow run publish-app-images.yml --repo smores56/homelab-platform
gh run watch --repo smores56/homelab-platform
skopeo inspect --no-tags --format '{{.Digest}}' \
  docker://ghcr.io/smores56/homelab-platform/immich-server@sha256:c716dc20f957aafd89fa9d284a2ec63e25c9e2d8d8e87c6197d540a3dce237db
```

The images this repository builds itself are one workflow over a matrix
(`publish-images.yml`), so a dispatch publishes all six and each row prints the
pin row for `scripts/app-images.sh`:

```sh
gh workflow run publish-images.yml --repo smores56/homelab-platform
gh run watch --repo smores56/homelab-platform
```

A green run prints every mirrored reference. **Make each GHCR package public and
confirm the unauthenticated inspect answers before the platform image that names
it is deployed**: a private package is a failed pull on the first boot.

**Immich stays on v3.0.3 until the cutover restore has passed**: its database was
written by that version, and a major bump is its own window, never a step inside a
data migration.

### 5.2 Deploy the image that ships the Quadlets

Both planes are image changes, so switch the host and reboot (1.12), then read the
generator and the containers:

```sh
journalctl -b | grep -i quadlet-generator
systemctl list-units --all 'immich-*' 'opdshelf*' 'syncthing*' 'navidrome*'
sudo podman ps --format '{{.Names}}	{{.Status}}'
```

Read the generator's own errors first: a container whose network file is missing
is dropped with `requested Quadlet unit <name>.network was not found`.
`immich-server`, `immich-postgres`, `immich-valkey`,
`immich-machine-learning`, `opdshelf`, `syncthing` and `navidrome` should all be
`Up`. The new `syncthing` recovery group has no Restic status until its first
backup:

```sh
sudo systemctl start smortress-restic-backup@r2.service smortress-restic-verify.service
```

The Immich dump runs at 21:00 UTC so a same-day dump lands inside the 00:00 R2 run
with three hours of margin. **A failed dump leaves the previous one in place**, so
a red dump unit means R2 carries a stale database; the dump is root-only and is in
no other copy.

### 5.3 Navidrome's first boot and the one-time path cleanup

The publish run above must show `navidrome` at its digest and green before the
reboot that ships the unit, or the first pull fails under the default-reject
policy. The first visit to `https://navidrome.<tailnet>.ts.net/` shows Navidrome's
"Create Admin" screen: create the one admin user here. `/ping` proves the process
is up:

```sh
curl -fsS https://navidrome.<tailnet>.ts.net/ping
```

`state/navidrome` changed the `music` unit's path list, so the first backup after
this deploy reads the whole library again and starts a new `host,paths` family.
Until the first new-family snapshot is `verified` in each backend,
`smortress-restic-verify.service` reports `music` stale: that is the expected red
window, not a fault.

Run this once, per backend, after the first `music` snapshot of the new family is
`verified`. Check the count first:

```sh
sudo bash -c '
  source /usr/libexec/restic-plane-common
  for backend in ssd hdd r2; do
    load_backend_env "$backend"
    count=$(restic -r "$(repo_for "$backend")" snapshots --json --host smortress \
      --tag unit:music,verified --path "/var/srv/music/.zfs/snapshot/$backend" \
      | jq "[.[] | select((.paths|length) == 1)] | length")
    echo "$backend: $count old-family snapshot(s)"
  done'
```

When the counts match what the old family held, drop exactly those snapshots:

```sh
sudo bash -c '
  source /usr/libexec/restic-plane-common
  for backend in ssd hdd r2; do
    load_backend_env "$backend"
    repo=$(repo_for "$backend")
    ids=$(restic -r "$repo" snapshots --json --host smortress \
      --tag unit:music,verified --path "/var/srv/music/.zfs/snapshot/$backend" \
      | jq -r ".[] | select((.paths|length) == 1) | .id")
    [[ -z $ids ]] || restic -r "$repo" forget $ids
  done'
```

`restic forget` takes an exclusive lock, so wait until a running backup finishes;
`forget --dry-run --no-lock` previews the same set while one holds the repository.

**There is no routine `unlock`**: an exit 11 is a retried failure, and a stale lock
goes by hand only after the holder is confirmed gone, never from a timer.

### 5.4 Verify the applications and the closed LAN

```sh
curl -fsS -o /dev/null -w '%{http_code}\n' https://immich.<tailnet>.ts.net/api/server/ping
curl -fsS -o /dev/null -w '%{http_code}\n' https://opds.<tailnet>.ts.net/healthz
curl -fsS -o /dev/null -w '%{http_code}\n' https://sync.<tailnet>.ts.net/rest/noauth/health
```

All three answer 200 from a tailnet device. From a machine on the LAN that is
**not** on the tailnet, both of these must time out: a connection means the
default zone is no longer `drop` or a Quadlet published an address it should not
have.

```sh
curl --max-time 3 http://10.0.0.125:22000
ssh -o ConnectTimeout=3 smores@10.0.0.125
```

The e-readers accept **EPUB only and absolute hrefs**: a PDF, CBZ or CBR in the
catalog is dropped without a message, so a book that is present in the tree can
still be invisible to the reader.

### 5.5 Validate the units and check the listeners

```sh
systemd-analyze verify units/systemd/smortress-nvidia-cdi.service \
  units/systemd/smortress-agent-config.service
sudo /usr/lib/systemd/system-generators/podman-system-generator -dryrun -v 2>&1 \
  | grep -E 'agent-(model|local|general|proxy)\.(service|network)'
systemctl cat agent-proxy.service | head -40
```

```sh
sudo systemctl stop agent-webui-personal agent-workspace-personal agent-local agent-model
sudo systemctl stop agent-local-network.service
sudo podman network rm systemd-agent-local
sudo systemctl start agent-local-network.service agent-model.service \
  agent-local.service agent-webui-personal.service agent-workspace-personal.service
```

```sh
sudo systemctl start zfs-ready@state-agent-model.service zfs-ready@state-agent-local.service \
  zfs-ready@state-agent-general.service smortress-nvidia-cdi.service
sudo nvidia-ctk cdi list                                     # nvidia.com/gpu=all
sudo systemctl start smortress-agent-config.service
sudo systemctl start agent-proxy.service agent-model.service agent-general.service agent-local.service
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
sudo podman logs smortress-agent-local 2>&1 | grep -E 'stage2|Changing hermes'
```

Six containers answer `Up`. The memory directories must be `1000:1000 0750` before
the gateways start, and `nvidia-smi` must list `llama-server`. A `Permission
denied` under `/opt/data` means the `HERMES_UID`/`HERMES_GID` remap did not run:
never fix it by widening the dataset mode.

A template change does not reach an already-seeded deployment, because the config
is copied in once and never rewritten: discard the copy and restart the two units.
`200` on the proxy's `/v1/models` is also the only proof the provider key works;
`401` means the ciphertext still holds the seeded random value.

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

**`agent-local.network` cannot be `Internal=true`**: netavark forwards no published
port on an internal network and firewalld never trusts one, so the container
listens, the unit is green, and the host cannot connect.

### 5.6 Check the agent Serve routes

`/apps/agent-local` and `/apps/agent-general` on 443 are core paths. **There is no
handler for `127.0.0.1:18003` and there must never be one**: a tailnet path to the
proxy would let any device spend the provider key.

```sh
read -r key   # the personal gateway key: sudo sed -n 's/^API_SERVER_KEY=//p' /var/lib/agent/local/.env
curl -fsS -H "Authorization: Bearer $key" \
  https://smortress.<tailnet>.ts.net/apps/agent-local/v1/models
curl -fsS -o /dev/null -w '%{http_code}\n' \
  https://smortress.<tailnet>.ts.net/apps/agent-general/v1/models   # 401 without its key
```

### 5.7 Collector sign-ins

Each collector needs one credential this repository cannot invent, entered in the
application's own UI: the SimpleFIN access URL, the TutaBridge session and its
local IMAP password, the Tuta calendar session, and the Brave Sync seed. **The
SimpleFIN access URL embeds the account credentials**: never paste it into a shell
that logs.

**Every collector is personal-only**: the general deployment holds no personal
source, and no collector may run there. `uidvalidity changed` or `folders
disappeared` is a refusal and not a deletion — the collector exits non-zero and a
human reconciles it.

**A fresh `tmail init` regenerates the bridge password**, and the value travels
three hops: `stage` rewrites the ciphertext, `sops-decrypt` re-renders `/run`, and
`smortress-app-secrets` copies it into the Podman secret. Until that last restart
the old password stays in the secret: LOGIN fails, and the restarts park the unit
in `start-limit-hit`.

**The bridge volume and the mail replica restore from one snapshot or neither**:
the bridge always reports `UIDVALIDITY 1`, so a replica restored without its
session volume gives every message a new UID.

A `grep accessToken` hit in the calendar store's `session.gpg` means the seal is
not encrypted, so treat the store as compromised. `HTTP 474`, `412` and `401` from
the exporter are its own refusals: raise `CLIENT_VERSION`, re-dump, or sign in
again.

**The Brave Sync seed is the chain's key inside a restorable dataset**: a profile
restored to another host makes that host a chain member, and a leaked copy is
revoked on the chain, not by rotating a password.

### 5.8 Verify the browser UIs

The general web UI and the legacy personal web UI (kept only as the Workspace
rollback) run the pre-baked image, so the first check is that starting them
installs nothing, and that each publishes on loopback only behind its own password
gate.

```sh
sudo systemctl start agent-webui-personal.service agent-webui-general.service
sudo journalctl -u agent-webui-personal.service -n 60 --no-pager \
  | grep -E 'already installed|Existing virtual environment|skipping|listening'
for port in 18006 18007; do
  curl -sS -o /dev/null -w "$port / -> %{http_code} %{redirect_url}\n" http://127.0.0.1:$port/
  curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:$port/health
done
```

`Downloading uv` means the image is not the baked one. Each `/` answers `302`
toward `/login?next=/` and `/health` `200` without a session; a `200` on `/` means
no password reached the process, so read `/var/lib/agent/local/webui.env` (which
must be `0:0 0400`).

```sh
sudo podman exec smortress-agent-webui-personal python3 -c \
  'import socket; socket.create_connection(("1.1.1.1", 443), 3)'; echo "exit=$?"
sudo podman logs --since 2m smortress-agent-local 2>&1 | grep -c 'POST /v1'
```

From a tailnet device open `https://assistant.<tailnet>.ts.net/` (the personal
Workspace, on the pinned local model) and `https://agent.<tailnet>.ts.net/` (the
general web UI), signing in with each deployment's own password:

```sh
sops -d --extract '["ui"]["personal_password"]' secrets/agents.json
```

The legacy personal web UI is rollback only: it remains on `127.0.0.1:18006`, has
no tailnet name, and its `Missing imports: run_agent` is expected. The personal
Workspace replaces it at the `assistant` name, is a client of the personal gateway
and its dashboard, and uses the same login password:

```sh
sudo systemctl start agent-workspace-personal.service
curl -sS -o /dev/null -w '18008 / -> %{http_code} %{redirect_url}\n' http://127.0.0.1:18008/
curl -sS -o /dev/null -w '18008 /api/sessions -> %{http_code}\n' http://127.0.0.1:18008/api/sessions
sudo stat -c '%u:%g %a' /run/smortress/workspace.env          # expect 0:0 400
sudo podman exec smortress-agent-local python3 -c \
  'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:9119/api/status", timeout=3).status)'
sudo podman exec smortress-agent-workspace-personal curl -sS -m 3 https://1.1.1.1 >/dev/null; echo "exit=$?"
```

`18008 /` answers `200` with the Workspace shell; that shell is public, and
`/api/sessions` answers `401`, which is the login gate. The dashboard probe answers
`200`, and the egress probe exits non-zero. Sign in at
`https://assistant.<tailnet>.ts.net/` with the personal password and confirm the
workspace detects the gateway and dashboard. Reach the rollback UI through an SSH
forward:

```sh
ssh -N -L 18006:127.0.0.1:18006 smortress
# then open http://127.0.0.1:18006
```

### 5.9 Fetch the pinned model

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

The size and the checksum are the pin (`16525559776` bytes). **The name must be
exactly this**: `units/quadlet/agent-model.container` starts the server with
`-m /models/Inkling-2-Mini-AD-Q4_K.gguf`, so a different file name is an image
change.

### 5.10 Run the agent runtime drill

```sh
scripts/agent-runtime-drill.sh --dry-run mounts        # plan only, unprivileged
sudo systemctl stop smortress-agent-collect-finance.timer \
  smortress-agent-collect-calendar.timer smortress-agent-collect-brave.path \
  smortress-agent-collect-brave.timer
sudo systemctl stop smortress-agent-mail-stream.service agent-tmail.service \
  agent-brave.service syncthing.service
sudo systemctl stop agent-webui-personal.service agent-webui-general.service \
  agent-workspace-personal.service agent-local.service agent-general.service agent-proxy.service
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
`0 failed`; start the writers again as 5.5 gives, and remove the leftover tree:

```sh
sudo rm -rf /var/lib/restic/ssd/drill/ssd-agent-*
```

### 5.11 Open the mount's toolsets in a seeded config

The gateway's `config.yaml` is seeded once and never reconciled, so a deployment
seeded before the `/srv/files` plane landed still carries dead `mcp_servers`
entries, `approvals.mode: manual`, and, on the personal side, `terminal` and `file`
under `disabled_toolsets`. `sudo` resolves `python3` from its own path, so name the
system interpreter:

    sudo /usr/bin/python3 - <<'PY'
    import yaml
    for state in ("local", "general"):
        path = f"/var/lib/agent/{state}/config.yaml"
        config = yaml.safe_load(open(path)) or {}
        changed = []
        if config.pop("mcp_servers", None) is not None:
            changed.append("mcp_servers removed")
        approvals = config.get("approvals") or {}
        if approvals.get("mode") != "off":
            approvals["mode"] = "off"
            config["approvals"] = approvals
            changed.append("approvals.mode: off")
        agent = config.get("agent") or {}
        disabled = agent.get("disabled_toolsets") or []
        opened = [t for t in ("terminal", "file") if t in disabled]
        if opened:
            agent["disabled_toolsets"] = [t for t in disabled if t not in opened]
            config["agent"] = agent
            changed.append("enabled: " + ", ".join(opened))
        if changed:
            yaml.safe_dump(config, open(path, "w"), sort_keys=False)
            print(f"{path}: " + ", ".join(changed))
    PY
    sudo systemctl restart agent-local.service agent-general.service
    sudo grep -E '^(approvals|  mode:|  disabled_toolsets:|    - )' /var/lib/agent/local/config.yaml
    sudo journalctl -u agent-local.service -n 20 --no-pager

The grep must show `mode: off` and a `disabled_toolsets` list without `terminal`
or `file`; a line still naming either one means the block did not write.

## 6. Recover

### 6.1 Restore an application by hand

Stop every writer of the unit's datasets first, including
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

**A restored tree is root-owned and unlabelled, and both lines are required**: the
`chown` and `chcon` are what make it a tree the application can write and Podman
may mount. Start the units again as 5.5 gives, then the dump timer.

**Never restore over a live dataset** while an application is writing it, and
never start a restored Syncthing with its folders live: pause every peer first and
only then designate a primary, or the cluster syncs into a tree whose identity was
just restored. A physically restored Immich cluster carries the password that was
current when the snapshot was taken, so set it from the decrypted secret or rotate
the ciphertext, or the server cannot log in.

### 6.2 The boot gate and its counter

The counter comes from the hook `grub.cfg` does read:
`smortress-boot-counter.service` installs greenboot's snippet as
`/boot/grub2/custom.cfg`, which `41_custom.cfg` sources. Prove it on the host:

```sh
sudo bootupctl status                              # No components are adoptable.
sudo grep -c 'boot_counter' /boot/grub2/custom.cfg # 1
systemctl is-enabled greenboot-set-rollback-trigger  # enabled
journalctl -b | grep -c boot-counting-absent       # 0
sudo grub2-editenv /boot/grub2/grubenv list        # boot_success=1, boot_counter=3, no default
```

**Do not enable `kernel.panic`**: a panic that reboots is only survivable while the
counter is installed. `/usr/share/smortress/deploy-units.txt` is what "serving"
means for this host. A boot that never reaches userspace spends one of the three
attempts; **a host whose counter was never installed has neither rollback** and is
a console recovery from the pre-reboot snapshot.

```sh
journalctl -u smortress-boot-gate.service --no-pager -n 20
# "healthy after N attempt(s)" when a deployment was owed; "boot-gate-green" otherwise
```

### 6.3 Hosted Backrest

The reader runs on smortress and its credential is the one thing here the image
does not carry: `/etc/backrest/env`, root-only, written once from the operator
store and never committed.

The two hashes come from a host whose container policy allows `docker.io` —
`smorespro` does; smortress carries the distro policy and refuses it. Run the two
`hash-password.sh` calls there and paste the two printed values into the block
below on smortress.

```sh
# The two login hashes are base64(bcrypt), and the script that makes them runs a
# throwaway container, so they are computed first and pasted into the file below.
read -rsp 'backrest operator password: ' OPERATOR_PW
printf '%s' "$OPERATOR_PW" | backrest/scripts/hash-password.sh   # BACKREST_OPERATOR_BCRYPT
printf '%s' "$OPERATOR_PW" | backrest/scripts/hash-password.sh   # BACKREST_BOOTSTRAP_BCRYPT
unset OPERATOR_PW

sudo install -d -m 0700 /etc/backrest
sudo install -m 0600 /dev/null /etc/backrest/env
read -rsp 'restic password: ' RESTIC_PASSWORD
{
  printf 'RESTIC_PASSWORD=%s\n' "$RESTIC_PASSWORD"
  printf 'R2_ACCESS_KEY_ID=%s\n' \
    "$(mise x -- sops -d --extract '["restic-backup-ro-access-key-id"]' secrets/cloudflare.yaml)"
  printf 'R2_SECRET_ACCESS_KEY=%s\n' \
    "$(mise x -- sops -d --extract '["restic-backup-ro-secret-access-key"]' secrets/cloudflare.yaml)"
  printf 'BACKREST_INSTANCE=smortress\n'
  printf 'BACKREST_REPO_ID=r2\n'
  printf 'BACKREST_REPO_URI=%s\n' \
    "s3:https://385f7d47e2e8438fbda5d6f76d760434.r2.cloudflarestorage.com/homelab-restic/smortress"
  printf 'BACKREST_REPO_GUID=%s\n' "<the 64-character restic repository id>"
  printf 'BACKREST_OPERATOR_USER=smores56\n'
  printf 'BACKREST_OPERATOR_BCRYPT=%s\n' "<the first hash>"
  printf 'BACKREST_BOOTSTRAP_USER=bootstrap\n'
  printf 'BACKREST_BOOTSTRAP_BCRYPT=%s\n' "<the second hash>"
} | sudo tee /etc/backrest/env >/dev/null
unset RESTIC_PASSWORD
```

```sh
sudo systemctl enable --now smortress-backrest.service
sudo systemctl restart smortress-tailscale-serve.service
sudo systemctl start smortress-backrest-watchdog.timer
sudo ss -ltnp 'sport = :9898 or sport = :9899'    # guard on 9898, Backrest on 9899, both loopback
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9898/   # 200: the guard answers
tailscale serve status | grep recovery             # svc:recovery -> http://127.0.0.1:9898
journalctl -u smortress-backrest.service -n 20 --no-pager
```

The watchdog's dead-man ping is optional: without it the timer still restarts the
reader, it just reports to nobody.

```sh
sudo install -m 0600 /dev/null /etc/backrest/healthcheck-url
read -rsp 'healthchecks ping url: ' HC_URL
printf '%s\n' "$HC_URL" | sudo tee /etc/backrest/healthcheck-url >/dev/null
unset HC_URL
```

Then prove the public path from anywhere. If the edge answers 502 the reader or its
Service is down on smortress:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' https://recovery.sammohr.dev/   # 200, Backrest's login form
scripts/verify-fleet.sh                                            # all three names green
```

## 7. Tailnet and access

### 7.1 The web terminal

`https://terminal.<tailnet>.ts.net/` is zellij's own web client.
`zellij-web.service` runs the server on `127.0.0.1:8082` in the owner's user
manager, Serve terminates TLS for `svc:terminal`, and the unit creates `main` at
every start.

```sh
mise dot apply                                      # the unit and the config (alias: d)
systemctl --user daemon-reload
systemctl --user enable --now zellij-web.service    # one time, then at every boot
systemctl --user status zellij-web.service
```

**One read-write login token, printed once, is the whole credential: store it in
the password manager, never in this repository.** The token store follows `HOME`,
so the command must run as the owner with the owner's home — `-H` is what makes it
work from a root shell.

```sh
sudo -u smores -H /var/home/smores/.local/share/mise/shims/zellij web --create-token
sudo -u smores -H /var/home/smores/.local/share/mise/shims/zellij web --list-tokens
```

Zellij 0.46 names every token `token_N`, and a token does not expire, so rotation
is a revoke and a mint:

```sh
sudo -u smores -H /var/home/smores/.local/share/mise/shims/zellij web --revoke-token token_1
```

The host-local proof is the server, the session list and the Service, in that
order. `zellij web --status` is not the probe: it exits 0 whether the server is
running or not.

```sh
systemctl --user is-active zellij-web.service
curl -fsS http://127.0.0.1:8082/info/version
zellij list-sessions                               # main
tailscale serve status --json | jq '.Services["svc:terminal:443"]'
```

From a tailnet device, the login page, the token login and attaching to `main` are
the rest of the proof. **The sudo ticket is shared** through the pane's pty for 30
minutes and **the token has no expiry, rate limit or lockout**: treat the token as
the whole boundary.

### 7.2 Sudo: one touch on the forwarded agent

`ssh -A smortress` forwards the client's agent, which holds the touch-required
`sk-ssh-ed25519` credential; `/etc/pam.d/sudo` asks the client for one tap, and the
account password sits behind it. **`Defaults env_keep += "SSH_AUTH_SOCK"`
(`lib/sudoers/11-agent-socket`) is what lets `pam_rssh` find the agent at all**:
sudo drops the variable before the PAM stack runs, and without the keep every
escalation silently falls back to the password.

**A credential minted with `-O no-touch-required` signs exactly like one without
it** — the public half records no touch policy and `pam_rssh` never reads the
user-presence bit — so covering the sensor is the only proof the tap is required,
and `IdentitiesOnly=yes` is what keeps the login credential from passing the
refusal line for the wrong reason. An empty `sudo_authorized_keys` in the image is
`PAM_AUTH_ERR`, so the password is the way in until the lines land.

## 8. Decommission evidence

### 8.1 Retire the Cloudflare SSH route

SSH is tailnet-only, so the Cloudflare route is deleted and not replaced.

```sh
./scripts/tofu-cloudflare.sh plan -no-color     # expect: 5 to destroy, 0 to add, 0 to change
gh workflow run tofu-apply.yml                  # dispatch applies the destroys (it IS the approval)
./scripts/tofu-cloudflare.sh state list | grep ssh || echo "no ssh objects in state"
```

**A replace or a destroy anywhere else means the state and the config disagree:
stop and compare.** The two tunnel objects were never in `tofu/` state, so the
account is the only place to prove they are gone:

```sh
account=$(awk -F'"' '/^account_id/ { print $2 }' tofu/terraform.tfvars)
export CLOUDFLARE_API_TOKEN=$(sops -d --extract '["platform-zone-rw-api-token"]' secrets/cloudflare.yaml)
curl -sS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$account/cfd_tunnel?is_deleted=false" |
  jq -r '.result[] | "\(.id)  \(.name)  \(.status)"'
# expect: no output — the account holds no live tunnel, so nothing is left to join
curl -sS -X DELETE -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$account/cfd_tunnel/<tunnel-id>"  # only for an id listed above
```

An empty listing, an empty Access → Applications list and a `tofu` plan with no
destroy left are the three proofs.

### 8.2 Remove the reader's Access gate

```sh
./scripts/tofu-cloudflare.sh plan -no-color     # expect: destroys only, or no changes once applied
gh workflow run tofu-apply.yml                  # dispatch applies the destroys (it IS the approval)
curl -sS -o /dev/null -D - https://recovery.sammohr.dev/ | head -3
```

The probe must show Backrest's own login, never a redirect to
`*.cloudflareaccess.com`: an Access redirect means something recreated an
application on the name.

### 8.3 Remove the stale `~/.cloudflared` caches

**Clean every operator machine and root account**: a connector left behind keeps
retrying a tunnel that no longer exists.

```sh
rm -rf ~/.cloudflared                      # per operator machine and per root account
ls ~/.cloudflared 2>/dev/null || echo "no connector cache"
systemctl --user list-units 'cloudflared*'  # a unit left behind keeps retrying
```
