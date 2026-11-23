# Secrets: who consumes a credential decides where it lives

Two stores exist, and a secret belongs to exactly one of them. The question is
never "which repo is convenient" but "what reads this value, and what may
decrypt it".

| Consumer | Store | Encrypted to | Applied by |
| --- | --- | --- | --- |
| Operator tooling in this repository (`tofu`, scripts) | `secrets/*.yaml` | all five recipients | the operator, via `sops -d` |
| Ciphertext the host reads | `secrets/server/*.yaml` | the machine identity, the admin identity and the three YubiKeys | `sops-decrypt.service` at every boot (`docs/manual-steps.md`) |
| A host unit's copy of that ciphertext | `/var/lib/smortress/secrets` | all five recipients (the machine identity is the unattended reader) | `sops-decrypt.service` at boot, into `/run/smortress/secrets` |

The admin identity is the operator's passphrase-wrapped age key. Trusting it in
both repository stores is deliberate: everything here is maintained by one
person, and the alternative — a ciphertext file nobody can edit — is worse.

## Image ciphertext on the server

`secrets/server/*.yaml` holds values a host unit needs at boot, carried inside
this repository instead of only in the recovery kit. `.sops.yaml` encrypts that
path to five recipients: the shared machine identity that is the unattended root
reader, staged root-only at `/var/lib/homelab/age/keys.txt` from the kit, and the
admin identity plus the three YubiKeys, so the operator can edit a value without
touching the host. Every reader in the rule can decrypt every file the rule
matches; that is deliberate, and the machine identity is the unattended
reader that boots the host.
`sops-decrypt.service` reads the ciphertext from `/var/lib/smortress/secrets`
(root-only, `0700`/`0600`) and writes each file into `/run/smortress/secrets` with
the owner, mode and `format` named in
`image/rootfs/usr/share/smortress/secrets.manifest`.

That manifest is metadata — a name, an owner, a mode — never a secret, so the
image owns it. It does **not** ship under `/etc`: bootc merges `/etc` once per
deployment and keeps whatever the host already had, so a line a later image adds
never reaches an existing host. It ships at
`/usr/share/smortress/secrets.manifest`, a path bootc does update, and the seed
copies it over `/etc/smortress/secrets.manifest` — which is what
`sops-decrypt.service` reads — on every run. The copy is skipped when the content
is unchanged and renamed into place when it changes, so a new manifest line is
one boot and a crash cannot leave half a manifest. Adding a secret is therefore a
commit; a hand edit of `/etc/smortress/secrets.manifest` is neither needed nor
kept.

`/etc` stays the path the decrypt reads on purpose: a rollback to a deployment
whose seed predates this copy must still find a manifest where its own
`sops-decrypt.service` looks for it, and the `/etc` copy is the one that survives
a rebase.

The image also carries the same set under `/etc/smortress/secrets`, and that copy
is *only* a seed. `sops-decrypt.service`'s `ExecStartPre` copies each ciphertext
the host does not have yet and never overwrites one that is there, so a *new*
secret reaches `/var` on the next boot by itself, while a rotation stays a host
write. One procedure covers every value:

```sh
scripts/secret.sh edit <output>     # opens the committed ciphertext
scripts/secret.sh stage <output>    # installs it, restarts the decrypt unit,
                                    # and names the consumers to restart
scripts/secret.sh verify            # keyless policy and index checks
```

`scripts/secret.sh rotate <output>` also generates a new data key first.

### Bundling the ciphertext

`secrets/index.bundles.json` is the target: the same outputs, grouped into
`boot.json`, `apps.json`, and `agents.json` with dotted keys. The migration is
operator-run because it decrypts every value:

```sh
python3 scripts/secrets-bundle.py --apply --write-index
scripts/secret.sh verify
git diff                                      # bundles + target index
git mv secrets/index.bundles.json secrets/index.json
git rm -r secrets/server                      # after the diff is reviewed
```

The tool decrypts each current file, writes and encrypts the bundles, verifies
every value round-trips, and leaves the old set in place. The seed retires the
old names on the first boot after the swap, so a rollback keeps them.

The seed and the baked copy go away in the release after this one, at which point
a fresh install stages the ciphertext from the checkout next to the age identity.

The table below is a reference for the two consumers whose file shape or ordering
is load-bearing, not an inventory: the directory holds 25 ciphertext files, and
the rest are one value each, named by the unit or script that reads them (the
manifest is the set).

| File | Read by | Rule |
| --- | --- | --- |
| `smores-password-hash.yaml` | `scripts/render-ignition.sh` (install) and `smortress-password.service` (every boot, `chpasswd -e`) | the `smores` account password, sha512crypt. Not in git as plaintext: only this ciphertext is, and the password itself is a recovery-kit item. `value` format, because `chpasswd -e` takes the bare hash. Rotate with `docs/manual-steps.md` section 37. |
| `tailscale.yaml` | `smortress-tailscale-up.service` | the pre-signed, single-use Tailscale auth key under `authkey:`, `yaml` format (the unit greps the field). It must land with its manifest line: ciphertext without the line is never decrypted into `/run`, and a line without ciphertext fails the decrypt unit's set comparison and takes every consumer down with it. |

The account hash is the reason the path exists: bootc never reconciles `/var`, so
a password written only by Ignition at install time would be whatever the last
install left in `/etc/shadow`, and a reinstall would need the operator to carry
the hash on the installer media.

## This repository's operator store

`secrets/cloudflare.yaml` holds the Cloudflare credentials the tofu runs need:
`cloudflare-api-token` (the zone token) and the state-backend pair
`r2-state-access-key-id` / `r2-state-secret-access-key`. The state token is
scoped to `homelab-tofu-state` alone and is deliberately **not** the host's
restic pair: state decides what the next apply does, so a backup credential must
not be able to rewrite it.

`secrets/660-host.yaml` is the host-plane bundle: a freshly generated restic
password, the event and broker tokens, and the R2 read-only pair. Each value is
the exact content of one file — the password and tokens verbatim, the R2 pair as
raw hex, `consumers_json` as JSON text — so what the operator stores is what the
host uses. `scripts/unpack-host-secrets.py` writes exactly the paths
`host_secret_files` names and never prints a value.

`scripts/tofu-cloudflare.sh` reads that file by default; `CLOUDFLARE_SECRETS_FILE`
overrides it, and pre-set `AWS_*` / `CLOUDFLARE_API_TOKEN` skip SOPS entirely
(that is how CI runs).

Create or edit it interactively, which keeps values out of shell history:

```sh
sops secrets/cloudflare.yaml
```

## Not secrets

Internal addresses, hostnames, account tags and recipients are configuration and
live in `tofu/terraform.tfvars`, `docs/`, or the manifests. Do not seal a value
that a manifest already publishes in the clear.
