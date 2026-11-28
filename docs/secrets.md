# Secrets: one table for every credential and who can read it

Every credential this repository or one of its hosts holds, one row each. Two
files are the authoritative sets for the host rows: `secrets/index.json` maps an
output to its bundle, key and consumer, and
`bootc/server/rootfs/usr/share/smortress/secrets.manifest` pins the owner, group,
mode and format it lands with.

`scripts/secret.sh edit <output>` runs as the operator, never as root — root
holds the machine key. `scripts/secret.sh stage <output>` re-installs the bundle
at `/var/lib/smortress/secrets`, restarts `sops-decrypt.service` and names the
consumers to restart. `scripts/secret.sh rotate <output>` only re-wraps a bundle
with a new SOPS data key: it changes no credential. "edit + stage" below means
those two steps, with a new value from the provider first.

## The host's ciphertext

Each `secrets/*.json` row is ciphertext for five recipients — the machine age
identity (the unattended reader, staged root-only at
`/var/lib/homelab/age/keys.txt` from the kit), the admin identity and the three
YubiKeys. All five decrypt every row below; a decrypted value lands
`root:root 0400` under `/run/smortress/secrets`.

| Secret | Where it lives | Who can read it | How it rotates |
| --- | --- | --- | --- |
| `canary.yaml` | `secrets/boot.json` key `canary`, `yaml` | root; `units/quadlet/pattern.container` probes it | edit + stage |
| `restic-password.yaml` | `secrets/boot.json` key `restic.password`, `value` | root; `scripts/restic-plane-common.sh` | edit + stage, and the kit's restic-password item changes with it |
| `r2-credentials.yaml` | `secrets/boot.json` key `r2`, `yaml` | root; `scripts/restic-plane-common.sh` | never hand-edited: `scripts/cloudflare-derive.sh` writes it from `restic-backup-rw-*`, then stage |
| `healthchecks.yaml` | `secrets/boot.json` key `healthchecks`, `yaml` | root; `scripts/restic-plane-common.sh` | edit + stage |
| `tailscale.yaml` | `secrets/boot.json` key `tailscale`, `yaml` under `authkey:` because the unit greps the field | root; `units/systemd/smortress-tailscale-up.service` | mint a single-use pre-authorized key in the Tailscale console, then edit + stage |
| `smores-password-hash.yaml` | `secrets/boot.json` key `smores.password_hash`, `value`: sha512crypt, since `chpasswd -e` takes the bare hash | root; `units/systemd/smortress-password.service` at every boot and `scripts/render-ignition.sh` at install | `docs/manual-steps.md` section 37; the password itself is a kit item and is not in git |
| `deploy-ping-url.yaml` | `secrets/boot.json` key `deploy.ping_url`, `value` | root; `scripts/deploy-state.sh` | edit + stage |
| `immich-db-password.yaml` | `secrets/apps.json` key `immich.db_password` | root; `units/systemd/smortress-app-secrets.service` turns it into a Podman secret via `scripts/app-secrets.sh` | edit + stage, then set the same password on the database's own user |
| `opdshelf-admin-password.yaml` | `secrets/apps.json` key `opdshelf.admin_password` | root; `scripts/app-secrets.sh` into a Podman secret | edit + stage, then the app's own admin password |
| `agent-local-api-key.yaml` | `secrets/agents.json` key `agent.local_api_key` | root; `scripts/app-secrets.sh` | edit + stage |
| `agent-general-api-key.yaml` | `secrets/agents.json` key `agent.general_api_key` | root; `scripts/app-secrets.sh` | edit + stage |
| `agent-hosted-key.yaml` | `secrets/agents.json` key `agent.hosted_key` | root; `scripts/app-secrets.sh` | edit + stage |
| `agent-github-token.yaml` | `secrets/agents.json` key `agent.github_token`, `value`, root `0400`; the trusted dispatcher mounts it as the systemd credential `/run/secrets/github-token` | root on the host, and the one general job the dispatcher mounts it into — never a home directory, never an interactive shell, never the Hermes gateway container | revoke the PAT at GitHub, then edit + stage; both tokens are in `agents.json`, so one stage covers the pair |
| `sdlc-github-token.yaml` | `secrets/agents.json` key `agent.sdlc_github_token`, delivered as `/run/secrets/sdlc-token` and named by `SDLC_GH_TOKEN_FILE` | same as the row above | revoke and issue a replacement: a fine-grained PAT belongs to the account that owns the repository, so this one is `smores56`'s, cannot be handed to the machine user, and cannot be re-scoped |
| `agent-ui-personal-password.yaml` | `secrets/agents.json` key `ui.personal_password` | root; `scripts/agent-config-seed.sh` | edit + stage |
| `agent-ui-general-password.yaml` | `secrets/agents.json` key `ui.general_password` | root; `scripts/agent-config-seed.sh` | edit + stage |
| `simplefin-access-url.yaml` | `secrets/agents.json` key `simplefin.access_url` | root; `scripts/app-secrets.sh` | re-issue the access URL at SimpleFIN, then edit + stage |
| `tmail-bridge-password.yaml` | `secrets/agents.json` key `tmail.bridge_password` | root; `scripts/app-secrets.sh` | edit + stage |
| `brave-sync-seed.yaml` | `secrets/agents.json` key `brave.sync_seed` | root; `scripts/app-secrets.sh` | start a new sync chain in Brave, then edit + stage |

## The operator store

`secrets/*.yaml` is the same five-recipient rule, so the operator can edit a
value without touching a host. GitHub environments, the host and the edge are
sinks, never sources: this file is where a value is authored.

| Secret | Where it lives | Who can read it | How it rotates |
| --- | --- | --- | --- |
| `platform-zone-rw-api-token` | `secrets/cloudflare.yaml`, and the `cloudflare` Actions environment secret `CLOUDFLARE_API_TOKEN` | the operator; `scripts/tofu-cloudflare.sh`; workflows in the `cloudflare` environment, which allows `main` only | re-issue in the Cloudflare dashboard, `sops secrets/cloudflare.yaml`, `gh secret set --env cloudflare` |
| `platform-zone-ro-api-token` | `secrets/cloudflare.yaml`, and `cloudflare-plan` as `CLOUDFLARE_PLAN_API_TOKEN` | read-only; workflows in `cloudflare-plan`, which allows any branch | same, into `cloudflare-plan` |
| `homelab-tofu-state-rw-*` (access-key id + secret) | `secrets/cloudflare.yaml`, and `cloudflare` as `R2_STATE_ACCESS_KEY_ID` / `R2_STATE_SECRET_ACCESS_KEY`; bucket policy scoped to `homelab-tofu-state` alone, never the backup pair | the operator; the `cloudflare` environment | re-issue the R2 token, sops edit, `gh secret set` |
| `homelab-tofu-state-ro-*` | `secrets/cloudflare.yaml`, and `cloudflare-plan` | read-only state reader | same, into `cloudflare-plan` |
| `restic-backup-rw-*` | `secrets/cloudflare.yaml`; the source `boot.json["r2"]` is derived from; reaches the data-plane host through `scripts/unpack-host-secrets.py --cloudflare` | the operator; `scripts/cloudflare-derive.sh`; the unpacker | re-issue, sops edit, re-derive `r2`, re-run the unpacker |
| `restic-backup-ro-*` | `secrets/cloudflare.yaml`; installed root-only in `/etc/backrest/env` on smortress, the host the recovery reader runs on | Backrest at `recovery.sammohr.dev`; the kit carries the same read-only token | re-issue, sops edit, rewrite that env file, update the kit |
| `tailnet-dns-api-token` | still in `secrets/cloudflare.yaml` | nothing reads it | revoke it in the Cloudflare dashboard |
| `restic_password` | `secrets/660-host.yaml`, unpacked to `restic/data-plane.password` | root on the data-plane host | sops edit, then re-run `scripts/unpack-host-secrets.py`, which writes only the paths it names and never prints a value |
| `event_append_token` | `secrets/660-host.yaml`, unpacked to `event-service/append-token` | root on the data-plane host | same |
| `event_read_token` | `secrets/660-host.yaml`, unpacked to `event-service/read-token` | root on the data-plane host | same |
| `broker_identity` | `secrets/660-host.yaml`, unpacked to `write-broker/identity` | root on the data-plane host | same |
| `broker_operator_key` | `secrets/660-host.yaml`, unpacked to `write-broker/operator-key` | root on the data-plane host | same |
| `consumers_json` | `secrets/660-host.yaml`, unpacked to `event-service/consumers.json` | the consumer list, not a credential | sops edit, re-run the unpacker |

## Identities and keys

| Secret | Where it lives | Who can read it | How it rotates |
| --- | --- | --- | --- |
| Admin age identity | a passphrase-wrapped copy per machine, and a kit item; first recipient in `.sops.yaml` | the operator, for every `secrets/*` file | `scripts/secret.sh rekey --rotate` after the recipient list changes |
| Machine age identity | `/var/lib/homelab/age/keys.txt`, root-only, staged from the kit | root on the host; the unattended reader of `sops-decrypt.service` | same |
| Three YubiKey age recipients | the physical keys | their holder | `scripts/secret.sh rekey --rotate` with the new recipients |
| `smores` account password | the kit only, Bitwarden plus the paper copy; git holds the sha512crypt hash | the operator | `docs/manual-steps.md` section 37 |
| `luks-root` passphrase | a key slot on the OS disk, and the kit | the operator; Clevis (Tang + TPM2, threshold 2) is the unattended path | `cryptsetup luksAddKey` the new one, then remove the old slot |

## GitHub settings no token here can set

| Setting | Where it is set | Who applies it | Verify |
| --- | --- | --- | --- |
| `main` protection: PR with CODEOWNERS review and one approval, strict required checks, linear history, no force-push, no deletion, conversation resolution, `enforce_admins` false so the owner can bootstrap while the machine user and every other account stay bound | the GitHub API, `PUT /repos/smores56/homelab-platform/branches/main/protection` | the owner with an admin token: the machine user and the owner's fine-grained token carry no Administration, and the recorded call answers `403 Resource not accessible by personal access token` | `GET` the same path |
| Actions: GitHub-owned and verified actions only, SHA pinning required, default `GITHUB_TOKEN` read-only and unable to approve reviews, every fork PR waits for owner approval | `/repos/smores56/homelab-platform/actions/permissions`, `.../permissions/workflow`, `.../permissions/fork-pr-contributor-approval` | same, and the same recorded `403` | `GET` the three paths |
| Private vulnerability reporting on | `/repos/smores56/homelab-platform/private-vulnerability-reporting` | same | the response is `{"enabled":true}` |
| `ghcr.io/smores56/smorespro-image` is pullable | the package settings | the owner | the first push creates the package **private**: make it public, or `podman login ghcr.io -u smores56` with a token that has `read:packages` |

## Rules an operator cannot infer

- The manifest and the bundle set land together: an output the manifest does not name is never extracted, and a bundle `secrets/index.json` does not name fails the decrypt's set comparison, takes every consumer down and rolls the deployment back.
- `/etc/smortress/secrets.manifest` is a copy — do not hand-edit it. Adding a secret is one commit: an index entry, its key in a bundle, and the consumer that reads it.
- The ciphertext the image carries under `/etc/smortress/secrets` is a seed only: the decrypt's `ExecStartPre` never overwrites a bundle the host already has, so a new bundle arrives by itself and a rotation stays a host write.
- `boot.json["r2"]` is generated. A hand edit survives until the next `scripts/cloudflare-derive.sh` run.
- `scripts/unpack-host-secrets.py --cloudflare` warns and ignores the legacy `r2_access_key_id` / `r2_secret_access_key` keys; `660-host.yaml` does not author the R2 pair.
- Nothing about the agent's GitHub write path is a GitHub App, and no `github-*` logical host may come back: the dispatcher's systemd credentials are the only path.
- An interactive session acts as `smores56`, the ruleset bypass actor. Only a general job gets the machine user, and the dispatcher, not the model, chooses the mount.
- The machine user's PAT is classic and non-expiring: what bounds a leak is the rulesets and the absent `workflow` scope, not a lifetime.
- The agent may restart its runtime; it may not re-pin it. Bumping `agent-runtime` or the server image is a pull request to this repository, and the required approving review makes that your merge.
- The image signature policy on the laptop is the machine-local `/etc/containers/policy.json`: emptying it disables verification until the backup is restored, and it is the escape hatch of last resort.
- `luks-root` keeps a passphrase key slot beside Clevis and FIDO2. That slot is the kit's way in; a lost token must cost a passphrase, not the volume.
- Internal addresses, hostnames, account tags and recipients are configuration, not secrets: they live in `tofu/terraform.tfvars`, `docs/` or the manifests. Do not seal a value a manifest already publishes in the clear.
