# recovery page

Future-inheritance, not an everyday password manager. This is the static, public recovery page for
the homelab-platform backup groups. It replaces the single-repository page in `nix-config/recovery`
with one page over every per-group repository the platform renders.

- The page is public and contains no secret. `public/data-keys.enc` is public ciphertext; the
  recovery password is the only gate.
- One **recovery password** (printed on the letter/drive) derives an Argon2id key, decrypts the blob
  in the browser, and yields:
  - **one restic password**, shared by every group repository, and
  - **one read-only R2 key pair**, scoped to the shared backup bucket.
- Repository addresses are **not** in the blob. They come from the public manifest, so adding or
  moving a group does not require a new blob.
- Restore runs entirely client-side with the TypeScript restic reader in `src/restic/`. No server
  ever sees the password, keys, or files.
- The page never persists the password or the decrypted keys. They live in the tab's memory for its
  lifetime and disappear on refresh or close; there is no lock button or idle timeout. A link
  fragment is stripped with `history.replaceState` before the derivation starts.

## Group model

The platform's backup inventory (`ansible/group_vars/all.yml`, `ansible/group_vars/backup.yml`,
`scripts/render-recovery-groups.py`) defines recovery groups such as `photos`, `notes`, `books`,
`memory-external`, and `data-plane-state`. Each group has its own restic repository (an `s3:` URL on
the shared R2 bucket, optionally with a per-group prefix) and its own data root inside a snapshot.

After unlock the page shows a **group picker**: every group in the manifest, with its label and the
newest snapshot date once that repository has opened. Choosing a group opens that repository's
newest snapshot and browses the group's tree. The browser uses the manifest `data_root`; downloads
are made relative to its parent, so a photo restores as `photos/...` under the folder the relative
picks, not flattened into it. Symlinks inside a snapshot are skipped during restore, not
materialised.

A single manifest entry that fails to open is shown on its row and does not stop the other groups. A
**malformed manifest fails the unlock closed**: the page will not guess a repository.

## Manifest contract

The platform renderer writes `public/manifest.json`:

```json
{
  "schema_version": 1,
  "groups": [
    {
      "id": "photos",
      "label": "photos",
      "repo": "s3:https://<account>.r2.cloudflarestorage.com/<bucket>/photos",
      "data_root": "/photos"
    }
  ]
}
```

- `id` — stable group id, `[A-Za-z0-9][A-Za-z0-9._-]*`, unique.
- `label` — human name shown in the picker; the platform renderer currently uses the id.
- `repo` — the group's restic repository as `<tier root>/<group id>`. For the public page this must
  be the R2 tier, e.g. `s3:https://host/bucket/<group id>`: no credentials, query, fragment, or
  `..`. A bare `https://` URL is also accepted. The path after the bucket must be exactly the group
  id or a nested prefix ending in it (`.../teams/photos` for `photos`), so a manifest entry cannot
  point one group at another group's repository.
- `data_root` — absolute path inside the newest snapshot that holds the group's data (`/photos`,
  `/srv/photos`, `/var/lib/data-plane/events`). `/`, `..` and backslashes are refused. The browser
  opens at this directory and restores relative to its parent, so a photo restores as `photos/...`.
  The directory is resolved exactly or as the shallowest directory whose trailing segments match, so
  the renderer's `/photos` finds a snapshot backed up from `/run/data-plane/current/photos`.

In the monorepo `scripts/build.ts` builds from `deploy/data-plane/config/recovery-groups.json`,
which `scripts/render-recovery-groups.py` writes from the host inventory; that renderer is the only
manifest producer it must agree with. The checked-in `public/manifest.json` is a synthetic example
used when the deploy manifest is absent, and the build validates whichever file it picks before
shipping it.

The renderer refuses a group whose tiers omit R2, and its public output always points at the R2
repository, so every listed group is restorable from a browser. The app must be served on the same
origin as the manifest.

### Store pinning

The manifest is public and untrusted, while the blob holds a real secret. The page refuses a group
whose `repo` host does not match the blob's R2 endpoint or whose bucket does not match the blob's
bucket, so a tampered manifest cannot make the read-only token authenticate against an attacker's
store.

## Data-keys blob

`deno task blob` reads `restic-password`, `r2-access-key-id-readonly`, and
`r2-secret-access-key-readonly` from a sops file (default `../../secrets/recovery.yaml`), prompts
for the recovery password twice, and writes `public/data-keys.enc` with Argon2id (3 passes, 64 MiB,
4 lanes) plus AES-256-GCM. The Argon2 parameters are unchanged from the legacy page.

The endpoint and bucket default to the values every manifest group shares; pass
`--endpoint`/`--bucket` only when they equal the manifest (the script refuses a mismatch). There is
no password-file option and no legacy scrypt envelope.

In the monorepo, build the blob against the manifest the site ships, not the
synthetic example, or `--check-only` proves groups that are not published:

```sh
cd apps/recovery-page
deno task blob --manifest ../../deploy/data-plane/config/recovery-groups.json \
  --secrets ../../secrets/recovery.yaml
deno task blob --check-only \
  --manifest ../../deploy/data-plane/config/recovery-groups.json
```

The operator prerequisites — the real R2 account id in
`ansible/group_vars/backup.yml` and the rendered manifest, a passed host
`preflight`, and a real restore drill before this page can retire the legacy
one — are `docs/manual-steps.md` step 35.

Before the blob is renamed into place it asks for the recovery password a third time, from scratch,
and opens the file that was just written with that entry.

`deno task blob --check-only` needs only the recovery password and the manifest: it decrypts the
committed blob and, **for every group**, opens the newest snapshot and proves the declared
`data_root` exists and is not empty. There is no magic marker file; the manifest is the contract.

```sh
cd apps/recovery-page
deno task blob --manifest public/manifest.json --secrets ../../secrets/recovery.yaml
deno task blob --check-only --manifest public/manifest.json
```

## Build, tests, and fixture

```sh
cd apps/recovery-page
deno task typecheck
deno task test
deno task build
deno task smoke    # headless Chrome: CHROME=<path> or --chrome <path>
```

The build writes `dist/`. Serve it over HTTPS or on `localhost`; `crypto.subtle` requires a secure
context. Opening `index.html` with `file://` is not supported by the fetch-based blob/manifest
loader.

Tests cover blob crypto/hardening, manifest validation (including fail-closed cases), the group
picker, path stripping, filenames, the link fragment, the zip fallback, and the restic reader. The
reader fixture is **generated** by `scripts/fixture.ts` into a temp directory: the legacy
`test-fixtures/restic` tree was not ported (it is several megabytes). The generated repository pins
the same shapes — scrypt key file, sealed config/snapshot/index, one pack, nested and empty files, a
long name, binary content, and a multi-blob file.

`deno task smoke` serves `dist/` on a loopback port and asserts the built page renders its shell,
unlocks from a link fragment, and renders the group picker.

## Deploy

Cloudflare Pages. The deploy is a **documented operator step**, not a workflow step: this repository
holds no Cloudflare token and the workflow does not deploy. A human with the Pages-scoped token
runs:

```sh
cd apps/recovery-page
deno task build
CLOUDFLARE_API_TOKEN=... CLOUDFLARE_ACCOUNT_ID=... \
  npx wrangler pages deploy dist --project-name <pages-project>
```

The token is a Pages-only API token, held in the operator's secret store, never committed, echoed,
or placed in a workflow. `.github/workflows/recovery-page.yml` typechecks, tests, and builds on
every change under `apps/recovery-page/` and uploads `dist/` as a workflow artifact for the operator
to inspect or deploy.

## Legacy page

The legacy `nix-config/recovery` page and its repository stay live until a restore drill passes
against this page: unlock with the printed recovery password, open every group, restore a sample
tree, and verify the restored files open. Only then may the legacy page be retired.
