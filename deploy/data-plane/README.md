# Data-plane deployment tree

What is left of the #660 data plane's deploy tree is data, not manifests. The
Kubernetes base (namespace, service accounts, Deployments, Services, claims,
NetworkPolicies, the image contract and the kind/minikube overlay) went with the
k3s/Flux tree: the host runs Quadlets, and the data-plane processes are host
units.

Nothing here is applied to a cluster. The tree holds two things:

| Path | What it is | Produced by |
| --- | --- | --- |
| `config/recovery-groups.json` | the public recovery-page manifest | `scripts/render-recovery-groups.py` |
| `config/source-catalog.json`, `config/sources/*.json` | the collector source catalog and one relay schema per source | `scripts/render-source-schemas.py` |

## `config/recovery-groups.json`

This is the only manifest the recovery page ships. `apps/recovery-page` imports
it at build time (`apps/recovery-page/scripts/build.ts`) and the page's blob
step is given the same path, so the site can never describe a group the host
does not back up.

It is generated, never hand-edited. `recovery/inventory.yml` is the only source
of dataset names and mount points and `recovery/backup.yml` adds display paths,
cadences and tiers; the renderer joins them into one record per group:

```json
{
  "id": "books",
  "label": "Books",
  "repo": "s3:https://ACCOUNT.r2.cloudflarestorage.com/homelab-restic/books",
  "data_root": "/srv/books"
}
```

```sh
scripts/render-recovery-groups.py            # rewrite the manifest
scripts/render-recovery-groups.py --check    # fail when it drifted
scripts/render-recovery-groups.py --host-plan  # the host's /etc/homelab/backup.json
```

`--check` is what CI runs: `tests/data-plane/test_host_secrets_bundle.py` and
`tests/data-plane/test_inventory_contract.py` invoke the renderer and fail on
drift, so a change to either inventory file must ship with the re-rendered
manifest in the same commit. `--host-plan` prints the same model in the shape the
host installs; the operator diffs it against `/etc/homelab/backup.json` on the
host (`docs/manual-steps.md` section 35, item 1).

The manifest is public: it names recovery groups, data roots and repository URLs
and nothing else. No credential, no bucket key and no restic password reaches it.

## The collector catalog and relay schemas

The source catalog and the four relay schemas are data for the data-plane
processes that read them by exact path; the schemas are generated from the
packaged descriptors under `libs/data_plane/collectors/schemas` so the deployed
copy and the loader cannot disagree:

```sh
scripts/render-source-schemas.py          # rewrite
scripts/render-source-schemas.py --check  # fail if stale
```

The catalog rows are synthetic examples that exercise every field the contract
model validates; no entry names a real person, account, host or message.
