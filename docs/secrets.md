# Secrets: who consumes a credential decides where it lives

Two stores exist, and a secret belongs to exactly one of them. The question is
never "which repo is convenient" but "what reads this value, and what may
decrypt it".

| Consumer | Store | Encrypted to | Applied by |
| --- | --- | --- | --- |
| Operator tooling in this repository (`tofu`, scripts) | `secrets/*.yaml` | all five recipients | the operator, via `sops -d` |
| Ciphertext the host reads | `secrets/boot.json`, `secrets/apps.json`, `secrets/agents.json` | the machine identity, the admin identity and the three YubiKeys | `sops-decrypt.service` at every boot (`docs/manual-steps.md`) |
| A host unit's copy of that ciphertext | `/var/lib/smortress/secrets` | all five recipients (the machine identity is the unattended reader) | `sops-decrypt.service` at boot, into `/run/smortress/secrets` |

The admin identity is the operator's passphrase-wrapped age key. Trusting it in
both repository stores is deliberate: everything here is maintained by one
person, and the alternative — a ciphertext file nobody can edit — is worse.

## Image ciphertext on the server

`secrets/*.json` holds values a host unit needs at boot, carried inside this
repository instead of only in the recovery kit. `.sops.yaml` encrypts that path
to five recipients: the shared machine identity that is the unattended root
reader, staged root-only at `/var/lib/homelab/age/keys.txt` from the kit, and the
admin identity plus the three YubiKeys, so the operator can edit a value without
touching the host. Every reader in the rule can decrypt every file the rule
matches; that is deliberate, and the machine identity is the unattended
reader that boots the host.
`sops-decrypt.service` reads the ciphertext from `/var/lib/smortress/secrets`
(root-only, `0700`/`0600`) and writes each output into `/run/smortress/secrets` by
extracting the dotted `key` from the `bundle` its line names, with the owner, mode
and `format` from `image/rootfs/usr/share/smortress/secrets.manifest`.

That manifest is metadata — a name, a bundle, a key, an owner, a mode, a format —
never a secret, so the image owns it. It does **not** ship under `/etc`: bootc
merges `/etc` once per deployment and keeps whatever the host already had, so a
line a later image adds never reaches an existing host. It ships at
`/usr/share/smortress/secrets.manifest`, a path bootc does update, and the seed
copies it over `/etc/smortress/secrets.manifest` — which is what
`sops-decrypt.service` reads — on every run. The copy is skipped when the content
is unchanged and renamed into place when it changes, so a new manifest line is
one boot and a crash cannot leave half a manifest. Adding a secret is therefore a
commit — an index entry, its key in a bundle, and the consumer that reads it;
a hand edit of `/etc/smortress/secrets.manifest` is neither needed nor kept.

`/etc` stays the path the decrypt reads on purpose: a rollback to a deployment
whose seed predates this copy must still find a manifest where its own
`sops-decrypt.service` looks for it, and the `/etc` copy is the one that survives
a rebase.

The image also carries the same set under `/etc/smortress/secrets`, and that copy
is *only* a seed. `sops-decrypt.service`'s `ExecStartPre` copies each bundle the
host does not have yet and never overwrites one that is there, so a *new* bundle
reaches `/var` on the next boot by itself, while a rotation stays a host write.

The seed retires a bundle the index no longer names on the first boot after the
swap, so a rollback still finds the old ciphertext.

### Bundling the ciphertext

Three bundles hold every host value, each a SOPS-encrypted JSON object with one
dotted key per output. Two operator YAML files hold what no host unit reads, and
`secrets/index.json` is the index over all of them:

| Ciphertext | Holds |
| --- | --- |
| `secrets/boot.json` | the boot plane: `canary`, `restic.password`, `r2`, `healthchecks`, `tailscale`, `smores.password_hash`, `webhook.secret`, `webhook.next`, `deploy.ping_url` |
| `secrets/apps.json` | the application plane: `immich.db_password`, `opdshelf.admin_password` |
| `secrets/agents.json` | the agent plane: `agent.*`, `facade.*`, `ui.*`, `simplefin.access_url`, `tmail.bridge_password`, `brave.sync_seed` |
| `secrets/660-host.yaml`, `secrets/cloudflare.yaml` | operator files: `tofu` and `scripts/unpack-host-secrets.py` only, one key per run |

An index entry names, for one output, its `bundle`, its dotted `key`, the
owner/group/mode it lands with, its `format`, and its consumer. The manifest line
is that entry rendered, so the decrypt extracts one output from one bundle and
writes it under its own name; `format` `value` writes the bare scalar and `yaml`
writes the extracted document verbatim. Nothing is decrypted as a whole bundle at
boot.

One procedure covers every value:

```sh
scripts/secret.sh edit <output>     # opens the bundle that holds the output;
                                    # the index names the key to edit
scripts/secret.sh stage <output>    # installs that bundle, restarts the decrypt
                                    # unit, and names the consumers to restart
scripts/secret.sh verify            # keyless policy, index and bundle checks
```

`scripts/secret.sh rotate <output>` also generates a new data key first. A value
that must not touch the host decrypts directly, in JSON path form:

```sh
sops --decrypt --extract '["restic"]["password"]' secrets/boot.json
```

The table below is a reference for the two consumers whose file shape or ordering
is load-bearing, not an inventory: the index holds 24 outputs across three
bundles, and the rest are one value each, named by the unit or script that reads
them (the manifest is the set).

| Output | Ciphertext and key | Read by | Rule |
| --- | --- | --- | --- |
| `smores-password-hash.yaml` | `secrets/boot.json` `["smores"]["password_hash"]` | `scripts/render-ignition.sh` (install) and `smortress-password.service` (every boot, `chpasswd -e`) | the `smores` account password, sha512crypt. Not in git as plaintext: only this ciphertext is, and the password itself is a recovery-kit item. `value` format, because `chpasswd -e` takes the bare hash. Rotate with `docs/manual-steps.md` section 37. |
| `tailscale.yaml` | `secrets/boot.json` `["tailscale"]` | `smortress-tailscale-up.service` | the pre-signed, single-use Tailscale auth key under `authkey:`, `yaml` format (the unit greps the field). The index line and the key must land together: an output the manifest does not name is never extracted into `/run`, and a bundle the index does not name fails the decrypt unit's set comparison and takes every consumer down with it. |

The account hash is the reason the path exists: bootc never reconciles `/var`, so
a password written only by Ignition at install time would be whatever the last
install left in `/etc/shadow`, and a reinstall would need the operator to carry
the hash on the installer media.

## This repository's operator store

`secrets/cloudflare.yaml` is the single source for every Cloudflare credential:
the zone pair (`platform-zone-rw-api-token`, `platform-zone-ro-api-token`), the
state pair (`homelab-tofu-state-rw-*`, `homelab-tofu-state-ro-*`), the backup
pair (`restic-backup-rw-*`, `restic-backup-ro-*`), and the ACME token
(`tailnet-dns-api-token`). Each R2 token is an access-key id and secret. The
state pair is scoped to `homelab-tofu-state` alone and is deliberately **not**
the backup pair: state decides what the next apply does, so a backup credential
must not be able to rewrite it.

GitHub environments, the host and the edge are sinks, never sources. The
`cloudflare` and `cloudflare-plan` environment secrets are set from this file.
The boot R2 pair is derived from `restic-backup-rw-*` into `secrets/boot.json`
key `r2`, and the name service's DNS-01 token from `tailnet-dns-api-token` into
key `acme.token`, both by `scripts/cloudflare-derive.sh`; never hand-edit either
object. The backup write pair reaches the data-plane host through
`unpack-host-secrets.py --cloudflare`, and the backup read pair is installed in
`/etc/backrest/env` on the edge.

`secrets/660-host.yaml` is the host-plane bundle: a freshly generated restic
password, the event and broker tokens, and `consumers_json`. The R2 pair is not
authored there: the unpacker accepts the existing `r2_access_key_id` /
`r2_secret_access_key` keys for one migration, warns, and ignores them when
`--cloudflare` is passed. `scripts/unpack-host-secrets.py` writes exactly the
paths `host_secret_files` names and never prints a value.

`scripts/tofu-cloudflare.sh` reads `platform-zone-rw-api-token` and the
`homelab-tofu-state-rw-*` pair from this file; `CLOUDFLARE_SECRETS_FILE` overrides
the path, and pre-set `AWS_*` / `CLOUDFLARE_API_TOKEN` skip SOPS entirely (that is
how CI runs).

Create or edit it interactively, which keeps values out of shell history:

```sh
sops secrets/cloudflare.yaml
```

## Not secrets

Internal addresses, hostnames, account tags and recipients are configuration and
live in `tofu/terraform.tfvars`, `docs/`, or the manifests. Do not seal a value
that a manifest already publishes in the clear.
