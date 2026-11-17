# Secrets: who consumes a credential decides where it lives

Three stores exist, and a secret belongs to exactly one of them. The question is
never "which repo is convenient" but "what reads this value, and what may
decrypt it".

| Consumer | Store | Encrypted to | Applied by |
| --- | --- | --- | --- |
| Operator tooling in this repository (`tofu`, scripts) | `secrets/*.yaml` | the admin identity only | the operator, via `sops -d` |
| A workload this cluster runs | `clusters/**/*.sops.yaml` | the `flux-system` `sops-age` identity | Flux, with `spec.decryption` on the owning Kustomization |
| A host unit in `smores56/nix-config` | `nix-config/secrets/smortress.yaml` | the admin and host identities | sops-nix at boot |
| A host unit on the Nix-free plane | `/etc/homelab/secrets` | the operator bundle only, never in git | the `secrets` role from a decrypted directory |

The admin identity is the operator's passphrase-wrapped age key. Trusting it in
both repository stores is deliberate: everything here is maintained by one
person, and the alternative — a ciphertext file nobody can edit — is worse.

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

## Cluster ciphertext

Nothing is sealed this way yet; the mechanism is wired for the first workload
secret to move out of the operator's hands. The rules:

- the file lives beside the object it becomes and ends in `.sops.yaml`;
- the owning Kustomization carries the contract from
  `clusters/homelab/platform/secrets/sops-contract.yaml`, because the controller
  runs with `--no-cross-namespace-refs` and the `sops-age` Secret lives in
  `flux-system`;
- `.sops.yaml` gains the `flux-system` recipient when the first file lands, so a
  mistyped path fails to encrypt instead of landing in the wrong key group.

## What stays in `nix-config`, and what retires it

A credential whose daily reader is a host unit stays host-side until that unit is
gone. These are the holdovers, each with the task that ends it:

| nix-config key | Host reader | Retired by |
| --- | --- | --- |
| `cloudflare-api-token` | `kanbei-access.nix` DNS-01, the `cloudflare-*` flake apps | flake apps: the step-14 state move; Kanbei: a DNS-scoped token of its own |
| `cloudflared-credentials` | the host tunnel (`web-proxy.nix`) | #615, when the last host-owned route moves; SSH got its own dashboard tunnel, whose connector token is `secrets/server/cloudflared-tunnel.yaml` |
| `restic-password`, `r2-access-key-id`, `r2-secret-access-key` | `restic-backup.nix` | #660: one repository per recovery group, then the restore drill (`docs/manual-steps.md` step 35) |
| `memory-mcp-token` | the maki memory shim | #617's cluster route with an Access service token |

### The #660 data plane

| Credential | Lives at | Read by | Rule |
| --- | --- | --- | --- |
| One restic password | generated in `secrets/660-host.yaml`, installed to `/etc/homelab/secrets/restic/data-plane.password` | every `homelab-backup` run and the recovery entrypoint | one password covers every group and tier; never per-group keys |
| Read-only R2 key pair | `/etc/homelab/secrets/restic/r2.env` (`AWS_*`), root-only | `restic copy` to R2, the page blob source | cannot read, delete or change bucket policy; the write credential is not on the host |
| Page blob keys | `secrets/recovery.yaml` in this repository, SOPS to the admin identity | `deno task blob` only | `restic-password` and the `r2-*-readonly` pair; the blob itself is public and encrypted |
| Event append/read tokens | `/etc/homelab/secrets/event-service/` on the host, cluster Secret `event-service-secrets` in the cluster | `event` only | must differ; the service refuses equal values, and a relay holds neither |
| Broker identity and approval key | `/etc/homelab/secrets/write-broker/` on the host, Secret `write-broker-secrets` in the cluster | `broker` only | the broker mounts both; no other workload receives either |
| Relay tokens | one Secret per source (`relay-brave`, …) | that collector only | never shared between sources; the host runs no relay |

Host secret files are installed by the `secrets` play (`--tags secrets`, one
decrypted directory) from the single `host_secret_files` policy. An entry a unit
mounts installs on the data-plane host at `0640 root:65532` and is mounted
read-only; an entry without a unit installs on the storage host at `0600 root`.
The parent chain stays `0700`, so the numeric gid is not a host group. The copy
owns the final owner and mode, so a drift is corrected on the next run, and a
rotation restarts only a running unit whose content changed
(`systemctl try-restart`); a stopped or fenced unit stays stopped. The host
backup units read `/etc/homelab/secrets/restic` directly. The cluster Secrets
are created by the operator from `deploy/data-plane/README.md`, because this
tree creates no Secret.

Until each row moves, the same value may exist in two stores. The host copy stays
authoritative for the host reader; the platform copy is written with the host
reader in mind, not copied blindly.

## Not secrets

Internal addresses, hostnames, account tags and recipients are configuration and
live in `tofu/terraform.tfvars`, `docs/`, or the manifests. Do not seal a value
that a manifest already publishes in the clear.
