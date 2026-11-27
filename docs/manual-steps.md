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
cosign verify --key bootc/server/cosign.pub "$(cat ignition/operator/derived-image)" >/dev/null \
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
install -m 0644 "$HOME/.config/smortress/cosign.pub" bootc/server/cosign.pub
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
`bootc/lib/pins.env`'s tag), verify the read-back hash, then install:

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
  `ignition/smortress.bu`, re-run `bats tests/image/ignition-boundary.bats`.
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

### The plan-only credentials

`cloudflare-plan` is the environment the pre-merge plan and the weekly drift check
read, so every secret in it is read-only by permission, not by promise. Three
pairs, and what each may do:

- `CLOUDFLARE_PLAN_API_TOKEN`, a token from Zero Trust → My Profile → API Tokens
  with exactly three permissions and nothing else: **Zone:Read** (list the zone
  the records live in), **DNS:Read** (the records themselves) and **Workers R2
  Storage:Read** on the account (the `homelab-tofu-state` bucket, and therefore
  the state). No `Edit`, no `Zone Settings`, no token or tunnel permission: a
  write permission here would be the whole risk of planning on a PR.
- `R2_STATE_READONLY_ACCESS_KEY_ID` / `R2_STATE_READONLY_SECRET_ACCESS_KEY`, an
  R2 token scoped to object read on `homelab-tofu-state`. The plan passes
  `-lock=false`, so it never writes the lock either.
- `TAILSCALE_PLAN_OAUTH_CLIENT_ID` / `TAILSCALE_PLAN_OAUTH_CLIENT_SECRET`, the
  plan's own OAuth client (design #841), below.

The plan's Tailscale client is minted in the admin console under Trust
credentials → OAuth client, with exactly these four scopes -- every one of them
the read-only half of its pair -- and no tags:

| Scope | What the plan uses it for |
| --- | --- |
| `policy_file:read` | reads, validates and previews the policy: every Tailscale call `tofu plan` makes |
| `devices:core:read` | required by the API beside `policy_file:read`, and resolves `data.tailscale_device.smortress` |
| `devices:posture_attributes:read` | the other half of that required pair |
| `services:read` | refreshes the six `tailscale_service` resources (the catalogue, the four core apps' and the Syncthing GUI's) |

```sh
read -rsp 'plan OAuth client ID: ' PLAN_CLIENT_ID
printf '%s' "$PLAN_CLIENT_ID" | gh secret set TAILSCALE_PLAN_OAUTH_CLIENT_ID --env cloudflare-plan --repo smores56/homelab-platform
read -rsp 'plan OAuth client secret: ' PLAN_CLIENT_SECRET
printf '%s' "$PLAN_CLIENT_SECRET" | gh secret set TAILSCALE_PLAN_OAUTH_CLIENT_SECRET --env cloudflare-plan --repo smores56/homelab-platform
gh api repos/smores56/homelab-platform/environments/cloudflare-plan/secrets --jq '.secrets[].name'
```

`tofu/tailscale.tf` asks its client for exactly those four scopes
(`local.tailscale_plan_scopes`, gated on `TF_VAR_tailscale_readonly`, which only
the plan sets), so a client granted less fails the plan at configure time instead
of quietly widening. That is the second line of defence; the first is the probe:
`tofu-plan-pr.yml` mints a token from this pair, posts a body that is not a
policy to `POST /api/v2/tailnet/-/acl` and fails the job unless the answer is
403, and separately asks the token endpoint for the `policy_file` write scope,
which a read-only client must refuse. It posts an empty body to
`POST /client/v4/zones/<id>/dns_records` with the Cloudflare token and fails
unless that is 403 as well. Neither attempt can mutate anything even if the
credential is wrong — an empty DNS body creates no record and a body that does
not parse as a policy saves no policy — so the check is safe to run against a
credential that is over-granted, which is the only case where it matters.
Read-only is therefore observed on every plan, not asserted here.

Both the pre-merge plan and the weekly drift check use the plan pair, so
`cloudflare-plan` no longer needs the apply's write client. Delete
`TAILSCALE_OAUTH_CLIENT_ID` and `TAILSCALE_OAUTH_CLIENT_SECRET` from that
environment; the write pair stays in `cloudflare` for the apply.

### Environments and their branch policies

No repository-level secrets: every workflow secret lives in an Environment, and the
ones holding write or signing credentials allow `main` only. `cloudflare-plan` is
the deliberate exception (read-only plan pair, `main`, `smores/*` and
`refs/pull/*/merge`, because the pre-merge plan has to run on the PR's merge
ref). None allows an agent branch.

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

GitHub evaluates the policy before the job starts, so a branch outside the list gets
no step and no secret. A `pull_request` run is evaluated as `refs/pull/<n>/merge`,
which `main` and `smores/*` cannot match (wildcards do not cross `/`); the third
policy is the one that admits it. With it in place `tofu-plan-pr.yml` runs on every
same-repo PR, and the credentials it reaches are the read-only pair above.
The accepted residual is a PR that edits the guard itself: it runs before review,
bounded by those read-only credentials and the guard's own allowlists. `deploy-notify` is a third main-only environment
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

The edge's key is a second value and rotates on its own clock: `EDGE_DEPLOY_WEBHOOK_SECRET`
in this repository's `deploy-notify` Environment, and the box's
`/etc/smoresnet/webhook-secret.yaml` written by `edge-bootstrap --force` with
`WEBHOOK_SECRET` (and `WEBHOOK_SECRET_NEXT` for the window the listener accepts
both). Nothing here touches smortress's `["webhook"]`, which is the point: the
public box never holds the key that posts to the host.

## Deploy

### Publish and pin the platform image

`publish-server-image.yml` builds, signs and pushes on a push to `main` touching
`bootc/server/`, `units/`, `secrets/` or `scripts/`, and on dispatch. It prints the digest
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
tag to the two receivers — `tag:smortress:8484` and `tag:vps:8484` — and to port
443 of each of the six Services behind the application names (the daily names
probe, below) and nowhere else. A compromised notify job can therefore re-tag the
smortress device itself; that write cannot be separated from `auth_keys`, and a
static auth key in the Environment would never expire.

The edge's receiver takes a value of its own instead of
`["webhook"]["secret"]`, in the same `deploy-notify` Environment of this
repository under a second name:

```sh
printf '%s' "$(openssl rand -hex 32)" | GH_TOKEN="$OWNER" \
  gh secret set EDGE_DEPLOY_WEBHOOK_SECRET --env deploy-notify --repo smores56/homelab-platform
```

It is a separate key because the edge is the box anybody can reach: with one
value, a popped edge would hold the key that posts a deploy to smortress, and the
design's residual — a popped edge can only force a reboot into an already
published, signed image — would not hold. The value is also what
`edge-bootstrap`'s `WEBHOOK_SECRET` writes to the box, so the two are entered
together and nothing derives one from the other.

### Create the tailnet names check

`verify-tailnet-names.yml` runs daily and proves the six tailnet Service names
still work for a node that is not the owner's laptop (`docs/core/applications.md`,
the tailnet name service): `immich.<tailnet>.ts.net`,
`navidrome.<tailnet>.ts.net`, `assistant.<tailnet>.ts.net`,
`agent.<tailnet>.ts.net`, `sync.<tailnet>.ts.net` and `opds.<tailnet>.ts.net`,
each behind a Service of its own. The probe derives the suffix from its own node
(`tailscale status --json`, `.Self.DNSName`), so a renamed tailnet needs no edit,
and `TAILNET_NAMES_SUFFIX` states it outright for a node with no `tailscale`
binary. It pages through a Healthchecks check of its own: a daily period with a
six-hour grace, because the probe answers once a day and one late run should not
page.

Every name is four claims. It resolves into `100.64.0.0/10`, and **all six
addresses are distinct**: one Service owns one VIP, so a name answering on
another Service's address, on the retired `svc:agent-ui` one or on the device
itself fails. Its certificate chains to a public root with that exact name in it
and is not within `TAILNET_NAMES_MIN_DAYS` (14) of expiry. And `GET /` answers
the status class the application owns -- 2xx Immich and the Syncthing GUI, 3xx
Navidrome and the two agent UIs, 4xx the OPDShelf catalogue. A class and not a
code, so a login redirect spelled differently does not page, while a drained
Service (no route at all) and a stopped application (502) both fall outside it.

CI is the only node that is not the owner's, so the probe's `tag:deploy` grants
are what make it a proof for anyone else: one grant on port 443 per Service, six
in all, with the policy's tests pinning that set (`tofu/tailscale.tf`). Wider in
count and narrower in reach than the single Service it replaces: each granted VIP
terminates at one application on one port, where the old one fronted everything
through one Caddy whose routes grew without a policy change, and the only host
port `tag:deploy` reaches is the deploy receiver's own 8484.

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

### Create the public edge check

`verify-public-edge.yml` runs daily and proves the three public names still
answer as their applications, and that the CA behind the edge's certificate is
one the zone's `CAA` records admit (`docs/core/public-edge.md`, "Validation").
It is the only check that sees the VPS, so it pages through a Healthchecks
check of its own: a daily period with a six-hour grace, because the probe answers
once a day and one late run should not page.

Create the check in the project with a `1 day` period and a `6 hour` grace, then
copy its ping URL into the environment:

```sh
OWNER=$(cat ~/.config/smores56-agent/owner-token)
printf '%s' '<ping url>' | GH_TOKEN="$OWNER" \
  gh secret set EDGE_PING_URL --env deploy-notify --repo smores56/homelab-platform
```

Then run it once so the check has an answer, and read the job's own output: it
prints one `ok`/`FAIL`/`note` line per probe.

```sh
GH_TOKEN="$OWNER" gh workflow run verify-public-edge.yml --repo smores56/homelab-platform
GH_TOKEN="$OWNER" gh run watch --repo smores56/homelab-platform
```

The probe needs only DNS and TLS, so the same scripts are the operator's tool
during an outage; run them from any host with `curl`, `openssl` and `dig`:

```sh
scripts/verify-public-edge.sh
scripts/verify-caa.sh
EDGE_CERT_MIN_DAYS=100000 scripts/verify-public-edge.sh   # the expiry leg, red
CAA_ZONE=example.com scripts/verify-caa.sh                # a zone with no CAA, a notice
```

`verify-caa.sh` is deliberately quiet until the zone's `CAA` records exist: an
empty set prints a `note` and exits 0, because a red check over a missing record
teaches the operator to ignore it. Once the records are there the assertion is
live, and a certificate from a CA the records do not admit turns the daily run
red — the failure prints the `issue`/`issuewild` values it read and the CA
domain it expected.

Like the names check this one is deliberately not a key in `secrets/boot.json`'s
`healthchecks` object: the probe never runs on the host, so the capability URL
belongs in the `deploy-notify` Environment alone.

#### T5: the owner's first run

One sitting, in this order — step 1 can block everything after it.

1. **Apply the CAA records**: `tofu -chdir=tofu apply -no-color` from a clean
   checkout of `main`. That lands `cloudflare_dns_record.caa_issue` and
   `.caa_issuewild`, both `0 … "letsencrypt.org"`, unconditional.
2. **Read the zone back**: `dig +short CAA sammohr.dev` must print **both**
   `0 issue "letsencrypt.org"` and `0 issuewild "letsencrypt.org"` **plus**
   Cloudflare's appended set (`pki.goog`, `sectigo.com`, DigiCert, `ssl.com`) —
   Cloudflare adds its own records to any CAA-bearing zone, and the effective
   policy is the union. Anything short of the two declared values: `git revert`
   the commit and re-apply; never edit the zone by hand
   (`docs/cloudflare.md`, "CAA").
3. **Force the renewal** on the VPS — owner only, destructive; delete the name's
   certificate directory and restart because `admin off` exposes no API. List
   first, copy the path into the delete — `rm -rf` on the wrong path takes every
   name's certificate with it:

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
   for these identifiers not found`, the account's reused authorization has gone
   stale on Let's Encrypt's side: stop Caddy, move
   `/var/lib/caddy/.local/share/caddy/acme` aside, start Caddy so it registers a
   fresh account, and let it obtain — `CAA` names the CA, not an account, so the
   replacement is authorized immediately. The issuer under
   `/var/lib/caddy/.local/share/caddy/certificates/` must be `acme-v02`, not
   `acme-staging-v02`: a staging certificate verifies against no public store,
   and `admin off` means a replaced Caddyfile takes effect only on
   `systemctl restart caddy`, so a staging run can outlive the file that replaced
   it. Then `scripts/verify-caa.sh` exits 0 and `scripts/verify-public-edge.sh`
   shows a fresh window.
4. **Kanbei's Universal SSL re-validation**: SSL/TLS → Edge Certificates must
   show `kanbei.sammohr.dev` (and the zone's wildcard) active, not pending or
   expired. Cloudflare re-validates on its own against the union of the two
   records and its appended set; if it fails, the appended set is what stopped
   being visible (`docs/cloudflare.md`, "CAA").
5. **Create the Healthchecks check and `EDGE_PING_URL`**: `1 day` period, `6 hour`
   grace, then the `gh secret set` above.
6. **One green dispatch**: `gh workflow run verify-public-edge.yml`, then read the
   `ok`/`note` lines.
7. **One deliberate failure**: from a scratch branch, point one probe in
   `scripts/verify-public-edge.sh` at a host that cannot answer, run
   `gh workflow run verify-public-edge.yml --ref <branch>`, and watch the run go
   red and the page arrive — the ping takes the `${EDGE_PING_URL%/}/fail` form.
   Delete the branch; the next green run `/` the same URL.

### Create the tenant apps check

`smortress-apps-health.timer` asks the three serving questions every five minutes
and answers a Healthchecks check of its own, `apps`: a five-minute period with a
five-minute grace, because the probe answers every five minutes and one late tick
should not page. It is not the `deploy` check: that one is the heartbeat's
dead-man and has to stay silent to mean anything (`docs/core/server-image.md`,
"The tenant prober").

The ping URL lives on the host rather than in an Environment, because the prober
reads it there: `/run/smortress/secrets/healthchecks.yaml` under `apps-ping-url`,
sops-encrypted in `secrets/boot.json`'s `healthchecks` object beside
`restic-ping-url`. Create the check in the project with a `5 minute` period and a
`5 minute` grace, put its ping URL there, and let the decrypt units carry it:

```sh
sops secrets/boot.json     # healthchecks: apps-ping-url: <ping url>
sudo systemctl restart sops-decrypt.service smortress-app-secrets.service
sudo grep -o '^[a-z-]*ping-url:' /run/smortress/secrets/healthchecks.yaml | sort -u
```

Both keys must print and no value is echoed. Then prove the page once, which is
the only evidence the check is wired: stop the tenant's one app, wait for the next
tick, read the page, and put the app back.

```sh
quadlet=$(sudo jq -r '.apps | to_entries[0] | .value.unitName // (.key + ".container")' \
  /var/lib/homelab/apps/plan.json)
sudo systemctl --user --machine=apps@.host stop "${quadlet%.container}.service"
journalctl -u smortress-apps-health.service -n 3 --no-pager   # within 5 minutes
sudo tail -n 5 /var/lib/homelab/deploy/journal.jsonl | jq -c 'select(.event=="apps-health-failed")'
sudo systemctl --user --machine=apps@.host start "${quadlet%.container}.service"
```

The journal line and the page carry the same body,
`not serving: tenant-unit-inactive:<app>`, and the next tick after the restart
pings green. Quicker evidence that the URL is staged and accepted: the prober
warns `could not be pinged` on every tick when the check answers 404, and stays
silent only when it has no key at all.

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
the reason, the app and the unit ("Create the tenant apps check").

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

Expect seven routes: 443 to `http://127.0.0.1:2283` (Immich, plus `/wallpapers/`,
`/apps/agent-local` and `/apps/agent-general`), 8443 to `http://127.0.0.1:8083`
(OPDShelf), 10000 to `http://127.0.0.1:8384` (Syncthing GUI), 8444 and 8445 to the
agent web UIs, 8448 to `http://127.0.0.1:4533` (Navidrome), and the deploy
receiver's `tcp/8484` forward. The public edge is not in this table: it proxies the
`svc:immich` and `svc:opds` Services. Nothing here is Funnel. The
wallpaper route shows a `Path` target rather than a `Proxy`:

```sh
curl -fsS https://smortress.<tailnet>.ts.net/wallpapers/ | head
systemctl status zfs-ready@raw-wallpapers.service   # an empty listing means not mounted
```

Syncthing refuses a proxied Host header, and Serve forwards the client's Host
unchanged, so its check has to be off for `https://sync.<tailnet>.ts.net/` to
answer -- this is the route's prerequisite, not a troubleshooting step: turn it off
with the key from the config on its dataset. That setting is host state, not image
state (it lives in `config.xml` on `state/syncthing-config`), so a host rebuilt from
the image comes back with the default and the key has to be applied again:

```sh
key=$(sudo sed -n 's:.*<apikey>\(.*\)</apikey>.*:\1:p' /var/lib/syncthing/config/config.xml)
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
is `verified`. Restic's `--path` keeps a snapshot that contains the given path
*among its paths*, so it matches both families. Select the old family by its
single-path set and forget those snapshots by ID instead. Check the count first:

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

A new-family snapshot lists both `/var/srv/music/.zfs/snapshot/<backend>` and
`/var/lib/navidrome/.zfs/snapshot/<backend>`, so it never counts above. When the
counts match what the old family held, drop exactly those snapshots:

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
  | grep -E 'agent-(model|local|general|proxy)\.(service|network)'
systemctl cat agent-proxy.service | head -40
```

```sh
sudo systemctl stop agent-webui-personal agent-local agent-model
sudo systemctl stop agent-local-network.service
sudo podman network rm systemd-agent-local
sudo systemctl start agent-local-network.service agent-model.service \
  agent-local.service agent-webui-personal.service
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

Five containers answer `Up`. The memory directories must be `1000:1000 0750` before
the gateways start, and `nvidia-smi` must list `llama-server` — a separate fact from
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

The same two UIs also answer at `https://assistant.<tailnet>.ts.net/` and
`https://agent.<tailnet>.ts.net/` through their own Services, which is the only
publicly trusted name either has: the `*.sammohr.dev` aliases, their `A` records
and the Caddy that answered them are retired.

The first-run wizard is disabled, so `Missing imports: run_agent` is expected;
the gateways are the tool surface.

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

### The replica store cutover (already done)

Before #961 a pass published `<source>/<generation>/`, and the mail replica grew to
16.4 million paths over 304,478 inodes, which is what broke the backup window. A
pass now writes content-addressed objects under `objects/<2hex>/<sha256>` and one
`state.sqlite` beside them (`docs/raw-replicas.md`); the Restic plane is the history
the old trees carried.

The cutover ran on smortress on 2026-11-26 from the image built at `263e6ab`
(agent-runtime `6c6964bf94dd…`), after the front ends were signed in again: writers
stopped, the replica root cleared, collectors unmasked and one pass started each.
All eight sources publish a store, and the first mail pass re-downloaded every body:
74,479 objects committed at 22:06, six and a half hours after it started, with
`INBOX` at 684.

Do not repeat it. The wipe was only correct for sources that had never published a
store; the same `find /var/lib/agent/local/replica -mindepth 1 -delete` now throws
away live state and costs a full re-collection, mail included (hours, and one Tuta
sign-in to keep). A single stale source is a single directory: stop its writer,
remove only that one, start the pass again.

Two mail passes after the cutover carried 74,478 and 74,483 objects in a couple of
minutes each, and the third committed one new message, so a live stream proves
itself with a line whose `version` rises and whose `carried` is close to `objects`.

How the store should look — one state per source and nothing else at the root:

```sh
sudo find /var/lib/agent/local/replica -maxdepth 2 -name state.sqlite
sudo find /var/lib/agent/local/replica -path '*/objects/*' -type f \
  | awk -F/ '{print $7}' | sort | uniq -c
```

Brave's file count is small on purpose: one `brave::db` object plus one per table,
while its report's `objects` is the row count across those tables. A source with no
`state.sqlite` answers `unavailable` and the reader reports the source as absent; its first
`sources.read` or `sources.search` pays one projection over that source.

### The agent data plane is a mount, not a service

The personal gateway reads `/srv/files` directly (SDLC #995): `todo.txt` and the
notes are read-write, the vault is a read-only bind, and the runtime's own
`terminal` and `file` toolsets are the interface. There is no source facade and no
virtual terminal to start, so nothing here needs staging.

Two settings need an operator, because the gateway's `config.yaml` is seeded once
(`cp -n`) and never reconciled: a deployment seeded before this change still
carries `mcp_servers` entries for containers that no longer exist (every turn pays
a connect timeout against them) and keeps `approvals.mode: manual`, which prompts
in the chat for every command the shell now runs.

    sudo python3 - <<'PY'
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
        if changed:
            yaml.safe_dump(config, open(path, "w"), sort_keys=False)
            print(f"{path}: " + ", ".join(changed))
    PY
    sudo systemctl restart agent-local.service agent-general.service
    sudo journalctl -u agent-local.service -n 20 --no-pager

The watcher that publishes changes into `/var/lib/agent/local/watch/changes.jsonl`
is `smortress-source-watch.service`; it starts with the host and needs no action.
Its roots are `/etc/smortress/agent/watch-roots.json`.

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

The reader's gate repository, deploy and matrix are `docs/core/backrest.md`,
"Operator order"; the read-only boundary, the gate matrix and where the reader
runs are that document's own sections. The reader runs on smortress since SDLC
#953 (`units/systemd/smortress-backrest.service`), and its credential is the one
thing here the image does not carry: `/etc/backrest/env`, root-only, written once
from the operator store and never committed.

The two hashes come from a host whose container policy allows `docker.io`.
smortress carries the distro policy, which answers `rejected by policy` for
anything it does not name; `smorespro` allows `docker.io`, so run the two
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

The environment file is the whole credential: no restic or R2 value is in the
image, in this repository, or on the public edge, which proxies the name over the
tailnet to the reader's Service instead. The two hashes are the reader's own
logins (`backrest/scripts/hash-password.sh` prints `base64(bcrypt)`); the
bootstrap user exists so the guard can index snapshots.

```sh
sudo systemctl enable --now smortress-backrest.service
sudo systemctl restart smortress-tailscale-serve.service
sudo systemctl start smortress-backrest-watchdog.timer
sudo ss -ltnp 'sport = :9898 or sport = :9899'    # guard on 9898, Backrest on 9899, both loopback
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9898/   # 200: the guard answers
tailscale serve status | grep recovery             # svc:recovery -> http://127.0.0.1:9898
journalctl -u smortress-backrest.service -n 20 --no-pager
```

The watchdog's dead-man ping is optional and is one more root-only line: without
it the timer still restarts the reader, it just reports to nobody.

```sh
sudo install -m 0600 /dev/null /etc/backrest/healthcheck-url
read -rsp 'healthchecks ping url: ' HC_URL
printf '%s\n' "$HC_URL" | sudo tee /etc/backrest/healthcheck-url >/dev/null
unset HC_URL
```

Then prove the public path from anywhere:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' https://recovery.sammohr.dev/   # 200, Backrest's login form
scripts/verify-public-edge.sh                                            # all three names green
```

If the edge answers 502, the reader or its Service is down on smortress: `photos`
and `opds` working while `recovery` fails is that case and nothing else.

## Tailnet and access

### Prove the Access default-deny (retired)

There is nothing to prove: the zone holds no Access application or policy
(SDLC #833), so a name with no DNS record is answered by Cloudflare itself rather
than by a deny policy. The live proof of what the zone serves is the public
probe, which resolves the names and checks each answers as its own application:

```sh
dig +short nothing-here.sammohr.dev
# expect: no output. Empty answer means the name has no record in the zone, so
# the resolver returns NXDOMAIN — an answer here is a name that was re-created
scripts/verify-public-edge.sh     # photos and opds, over valid TLS
```

The static half is `tests/tofu/check.bats`, which asserts there is no Access object
left to reintroduce.

### Kanbei behind Access

Historical: `kanbei.sammohr.dev` was a public hostname behind an Access
application whose policy was the owner's email (SDLC #586). Both are gone — the
application with the rest of the zone's Access objects (SDLC #833) and the
host tunnel's wildcard record that resolved the name. `tofu/kanbei.tf` is now a
note with no resource in it, so there is no state entry to remove and no
`service auth` policy or service token to rotate.

What is left is the `webProxy.services.kanbei` ingress rule in `nix-config`,
which has no connector: a name that does not resolve is refused before any
origin is reached. Publishing it again is a reviewed change — a DNS record here
plus a connector — never a dashboard edit.

### The tailnet policy, sshd, and sudo

The ACL apply and the enrollment key, the tailnet-only sshd prove-out, retiring
Tailscale SSH, and the YubiKey sudo credential and its drills are
`docs/core/server-image.md`, "Access: the tailnet policy, sshd, and sudo".

### The web terminal

`https://terminal.<tailnet>.ts.net/` is zellij's own web client, the only terminal
that needs neither an SSH key nor an agent. `zellij-web.service` runs the server on
`127.0.0.1:8082` in the owner's user manager, Serve terminates TLS for
`svc:terminal`, and the unit creates `main` at every start. No host port, proxy or
container is added.

It is a **user** unit, and that is load-bearing rather than tidy: the server execs
the mise binary and every pane execs the owner's shells, and SELinux denies a
system service an exec into a home file (`init_t` and even `unconfined_service_t`
are refused on `user_tmp_t` and `user_home_t`). The user manager runs in the login
domain, so the server and its panes get what an SSH session gets. The unit and the
`web_sharing "on"` line in `~/.config/zellij/config.kdl` both arrive with
`mise dotfiles`, and the manager starts at boot because the image lingers the
owner.

The socket directory needs no wiring either: the manager and an SSH login both use
`$XDG_RUNTIME_DIR/zellij`, which is per-user, so they see one session list. Without
the config line the browser lists a session it cannot attach to, with no error to
say why; `zellij setup --check` accepts the config, so it is not the probe either.

```sh
mise dot apply                                      # the unit and the config (alias: d)
systemctl --user daemon-reload
systemctl --user enable --now zellij-web.service    # one time, then at every boot
systemctl --user status zellij-web.service
```

The host does not create the session for you: `main` exists once the unit has
started, and a reboot recreates it from scratch (`session_serialization` stays off,
so layout and scrollback do not survive).

One read-write login token, printed once, is the whole credential: store it in the
password manager and never in this repository. The token store follows `HOME`
(`~/.local/share/zellij/tokens.db`), not the socket directory, so the command has
to run as the owner with the owner's home -- `-H` is what makes it work from a
root shell, where it would otherwise write to `/root` and the server would never
see it.

```sh
sudo -u smores -H /var/home/smores/.local/share/mise/shims/zellij web --create-token
sudo -u smores -H /var/home/smores/.local/share/mise/shims/zellij web --list-tokens
```

Zellij 0.46 names every token `token_N` (`--create-token` cannot be combined with
`--token-name`), and a token does not expire, so rotation is a revoke and a mint:

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
the rest of the proof; attaching to the same session from two devices is allowed
and both clients type.

Four residual risks are known and accepted, and none of them is a defect to
report. **The sudo ticket is shared**: `timestamp_type=tty` keys it to the pane's
pty, every client of a pane shares that pty, and the ticket lasts 30 minutes
(`bootc/server/rootfs/etc/sudoers.d/10-human-gate`), so a token holder can run `sudo -n`
in a pane where the owner escalated inside the window. **A browser-created pane
has password sudo only**: the hardware touch needs the key's device, and a browser
has no agent to forward. **The token is the boundary**: no expiry, no rate limit,
no lockout, and the login write is synchronous and unauthenticated -- reachable
only from an owner device. **Sessions outlive the front end**: `KillMode=process`
is what keeps a browser reconnect from ending the work, so a unit stop leaves the
session daemons running and the next start runs beside them.

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
gh workflow run tofu-apply.yml                  # dispatch applies the destroys (it IS the approval)
./scripts/tofu-cloudflare.sh state list | grep ssh || echo "no ssh objects in state"
```

A replace or a destroy anywhere else means the state and the config disagree: stop
and compare. The two tunnel objects are not in `tofu/` state and never were —
one was created in the dashboard and the other went with the cluster tree — so
the apply cannot delete them and the account is the only place to prove they are
gone. List them, and delete any that come back:

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
destroy left are the three proofs; the dashboard equivalent of the listing is
Zero Trust → Networks → Tunnels. An entry that reappears in either list is drift
to delete, not a step in this order: nothing in `tofu/` creates a tunnel any
more, so an apply cannot have made it.

### Remove the reader's Access gate

`tofu/access.tf` declares no Access object at all (SDLC #833), so nothing gates
the name and Backrest's password is the only login. The application is deleted
with the rest of them, and `prevent_destroy` is read from *configuration*: with
the block gone the plan holds a destroy, so there is no `state rm` first and no
dashboard deletion before the apply.

```sh
./scripts/tofu-cloudflare.sh plan -no-color     # expect: destroys only, or no changes once applied
gh workflow run tofu-apply.yml                  # dispatch applies the destroys (it IS the approval)
curl -sS -o /dev/null -D - https://recovery.sammohr.dev/ | head -3
```

The probe must show Backrest's own login, never a redirect to
`*.cloudflareaccess.com`: an Access redirect means something recreated an
application on the name.

### Remove the stale `~/.cloudflared` caches

The tunnels are gone, so every `cloudflared` credential, certificate and connector
config left on an operator machine is dead configuration that will try to
reconnect. They live outside this repository and nothing in `tofu/` or CI removes
them:

```sh
rm -rf ~/.cloudflared                      # per operator machine and per root account
ls ~/.cloudflared 2>/dev/null || echo "no connector cache"
systemctl --user list-units 'cloudflared*'  # a unit left behind keeps retrying
```

A connector that still starts is the only local symptom, and it fails loudly in
its own log while the zone carries no tunnel for it to join.

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
6. **Nothing hand-run is left** — the suite sweep in `README.md` and
   `python3 scripts/check-doc-refs.py` both exit 0, so the tree describes the host
   that is running.


## Public edge VPS

The edge VPS order — tailnet policy, `tag:vps` key, panel firewall, the install
from the live ISO, bootstrap, Serve routes, the cutover and the timed rebuild
drill — is `docs/core/public-edge.md`, "The operator order". The box runs the
repository's own signed image and terminates TLS for three names (`photos`,
`opds`, `recovery`); `bootc/edge/tests/check.sh` asserts exactly those three site
blocks and never a fourth.

### Before the install: what the image makes and what a person does

Every path the edge's units name, and what creates it, is one row of
`bootc/edge/unit-paths.tsv`. That table is the list of record; this is only what
each kind of row asks of you around an install, and
`scripts/check-edge-unit-paths.sh` fails a pull request that lets a row and the
tree disagree.

- **`image-dir`, `tmpfiles`, `system`** — nothing to do, and nothing to leave to
  a later step: `systemd-tmpfiles` makes `/var/lib/caddy`,
  `/var/lib/homelab/deploy` with its queue, and `/var/lib/smoresnet` from
  `/etc/tmpfiles.d/smoresnet-edge.conf` and
  `/usr/lib/tmpfiles.d/smoresnet-deploy.conf` at every boot, and the OS owns
  `/boot`, `/sysroot`, `/tmp` and `/var/tmp`. Most of them are `ReadWritePaths`
  targets, so one missing is a unit that dies in namespace setup with
  `226/NAMESPACE` before its own program runs — `edge-boot-gate.service` was lost
  that way on the boot after the first install. After the install, before the
  bootstrap, `systemd-tmpfiles --cat-config | grep -E
  '/var/lib/(caddy|homelab/deploy|smoresnet)'` names each one.
- **`operator`** — before the install, have the values and the kit at hand: the
  preauthorized `tag:vps` key, the webhook secret, the deploy ping URL, the
  `SMORTRESS_FQDN` and the ACME address, plus Caddy's data directory from the
  recovery kit. Nothing in the image writes them, and none of them is image
  content. (The edge's key is not in the kit: since #185 the edge keeps the host
  key sshd made on the box, so a reinstall presents a new one — smortress's key
  is still the kit's.) After the install they exist because you ran
  [Bootstrap the fresh edge](#bootstrap-the-fresh-edge).
- **`bootstrap`** — no row is one today, and that is the point of the table:
  `edge-bootstrap` writes values and secrets, never a state directory, because no
  unit can wait for a hand step to make the path it needs. Its own `install -d`
  lines on `/var/lib/caddy` and `/var/lib/smoresnet` only re-assert the mode
  tmpfiles already set, which is what keeps a re-run harmless.

### Render and commit the edge Ignition

The edge's document is committed to this repository instead of uploaded
somewhere the install would have to fetch from a bucket: it carries no console
password and no LUKS key, the repository is public, and the sha512 that pins it
is computed from the checked-out file rather than transcribed from a CI log. It
is regenerated when the published edge digest changes, and never with a
placeholder: the renderer refuses a tag, a missing reference, `--synthetic` and
`--stock`, and it has no fixture hash to fall back to — `--no-account` never
reads sops at all.

```sh
gh workflow run publish-edge-image.yml
gh run watch "$(gh run list --workflow publish-edge-image.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
read -r EDGE_REF                     # paste the `pin: ` line: .../edge@sha256:...
export EDGE_REF
scripts/render-ignition.sh --no-account --check          # prints: butane accepted
scripts/render-ignition.sh --no-account                  # writes ignition/edge.json, 0644
jq -r '.passwd.users[] | has("passwordHash")' ignition/edge.json   # expect: false
jq -r '.storage.files[].path' ignition/edge.json         # exactly four public paths
sha512sum ignition/edge.json
git add ignition/edge.json && git commit -m 'chore(edge): pin the published edge digest in Ignition'
```

The committed JSON is never edited by hand: a change belongs in
`ignition/edge.bu`, then a re-render, so the file and its hash cannot disagree
with the template.
The install reads the committed file and the hash of that same file: the two
lines below are the whole console step (BIOS/GRUB disk, so `/dev/vda`; the
address is static, so dracut gets it as kernel arguments instead of a profile).

```sh
hash="sha512-$(sha512sum ignition/edge.json | cut -d' ' -f1)"
url="https://raw.githubusercontent.com/smores56/homelab-platform/$(git rev-parse main)/ignition/edge.json"
sudo coreos-installer install /dev/vda \
  --ignition-url "$url" --ignition-hash "$hash" \
  --append-karg ip=192.236.188.99::192.236.188.65:255.255.255.192:smoresnet:eth0:none \
  --append-karg nameserver=8.8.8.8 --append-karg net.ifnames=0
```

The document's only credential is the operator's public key, and 22 is reachable
on the public interface only until the tailnet join unit closes it.

### Bootstrap the fresh edge

The image is the whole host — packages, the Caddyfile, the units, the firewall
and the sshd policy arrive with it — so what is left for a person is exactly what
a public repository cannot carry: the values and secrets the box serves with, the
tailnet node identity and the first deploy record.
`scripts/edge-bootstrap.sh` is that one step. It runs on the box as root, refuses
a bad value before it writes anything, and is idempotent.

The first session is the only one on the public side: sshd accepts the key from
the Ignition document and nothing else, firewalld publishes 22 there only until
`smoresnet-tailscale-up.service` has joined the tailnet, and that join needs the
auth key this step writes.

```sh
# The script needs no sibling file: the libraries it sources are the image's own,
# at the paths the image's programs use.
scp scripts/edge-bootstrap.sh root@192.236.188.99:/root/          # the box's address
scp <kit>/ssh_host_ed25519_key <kit>/ssh_host_ed25519_key.pub \
  root@192.236.188.99:/root/kit/
ssh root@192.236.188.99
SMORTRESS_FQDN=smortress.stonecat-jazz.ts.net EDGE_ACME_EMAIL=you@example.com \
  /root/edge-bootstrap.sh <<'EOF'
TS_AUTHKEY=tskey-auth-…
WEBHOOK_SECRET=…
DEPLOY_PING_URL=https://hc-ping.com/…
EOF
```

Both secrets are on stdin and never in argv: an argument is in
`/proc/<pid>/cmdline` for every user on the box and in the shell's history, and a
here-document is in neither. `TS_AUTHKEY` is the preauthorized `tag:vps` key from
step 2 of `docs/core/public-edge.md`'s operator order, typed once; the box keeps
it root-only at `/etc/smoresnet/tailscale-authkey`, because the join unit is
conditioned on that file and re-runs on every boot until the node has enrolled.
`WEBHOOK_SECRET` is the HMAC secret the receiver authenticates with — add
`WEBHOOK_SECRET_NEXT` to the same stdin only for a rotation window, and delete
that file when the window closes — and `DEPLOY_PING_URL` is the dead-man
capability URL.

What it refuses, before writing anything: an `SMORTRESS_FQDN` with no tailnet
domain, a missing `EDGE_ACME_EMAIL`, a key that is not `tskey-`-shaped, a secret
carrying whitespace and `caddy validate` on the values about to be installed
— so a truncated paste leaves the box exactly as it booted.

A re-run — after a rebuild's reinstall, or to fix one input — converges the
derived files (the Caddy environment, the node ID, the record) and
leaves every secret already written alone; a value for a file that holds a
different one is refused, and `--force` is what rotates it. Nothing else is
forced: the record is the descendancy anchor every later deploy is checked
against, the node ID is what the tailnet says rather than a name, and
`--commit <40-hex>` is only there to supply the one value `bootc status` does not
report — the revision label of the image config — on a host that carries none.

It ends by saying what remains: `scripts/verify-public-edge.sh` from a checkout
must be all green, and if this box's public IPv4 is not the one committed in
`tofu/terraform.tfvars`, update `edge_ipv4` and apply **before** that probe — the
three names resolve to whatever the records point at, so a probe run first
measures the old box.

### Release and deploy the edge

A push to `main` that touches the image's inputs builds, signs and publishes the
edge, and stops there: the box with the least rollback is deployed by a dispatch
and never by a merge (`docs/core/public-edge.md`, "The deploy path"). Review the
digest the publish run printed, then release it:

```sh
gh workflow run publish-edge-image.yml --repo smores56/homelab-platform --ref main
gh run watch "$(gh run list --workflow publish-edge-image.yml --limit 1 \
  --json databaseId --jq '.[0].databaseId')"
```

On a dispatch from `main` the workflow's last job joins the tailnet as
`tag:deploy` and POSTs a body signed with `EDGE_DEPLOY_WEBHOOK_SECRET` to
`http://smoresnet:8484/v1/deploy`. The receiver verifies the signature and the
repository, writes one queue entry and exits; `smoresnet-deploy.path` starts
`smoresnet-deploy.service` on the first file in the queue, the verifier stages the
digest only after `bootc switch --enforce-container-sigpolicy` accepts it, and the
drain records `pending.json` and reboots. The boot gate judges the boot; a
deployment that does not come up is denylisted and the next boot is the previous
commit.

`smoresnet-deploy-poll.timer` runs the same path at 03:00 local for a release
nobody dispatched — a merge that published and was forgotten. Both triggers only
enqueue; the drain is the only thing that decides.

What to read afterwards, on the box:

```sh
journalctl -u smoresnet-deploy.service -n 50 --no-pager
journalctl -u edge-boot-gate.service -b -n 50 --no-pager
```

A request resolves against the **tip of `main`**, and the edge image is published
only for the commits that touch its tree, so a request that lands on a tip which
did not rebuild is `no-artifact`: the verifier holds it, the drain keeps the
entry, and the next request supersedes it. That is the design — a merge that does
not change the image has nothing to deploy — and it is why a release is
dispatched from a commit that did touch the edge. The same holds immediately
after the install: until `edge-bootstrap` has seeded
`/var/lib/homelab/deploy/state.json` every request is `bootstrap-required`, and
until a commit that changes the edge has published there is no artifact for the
tip to name.

## Former section numbers

Scripts, units and the image still quote the pre-rewrite numbering; this is where
each number landed.

| Old | Now |
| --- | --- |
| §2, §4, §5 | GitHub: identity, environments, and tokens |
| §6, §12 | Secrets and rotation |
| §14, §46 | The tailnet policy and the enrollment key |
| §18 | Prove the Access default-deny (retired with the gate) |
| §21 | Kanbei behind Access |
| §35 | Claim the SimpleFIN access URL; Publish and sign the application images |
| §36 | T0: freeze, rescue, verify, and publish the kit |
| §37 | Install a host from the image |
| §38 | Bring the restic plane up |
| §39 | Hosted Backrest; Remove the reader's Access gate |
| §40.1–40.6 | Applications and agents; Restore an application by hand |
| §40.7, §40.11 | Rotate the agent's credentials; Validate the units |
| §40.8 | Fetch the pinned model |
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
