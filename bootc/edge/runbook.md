# Edge runbook

The steps for the public VPS (`smoresnet`): render its Ignition, install it from the
live ISO, bootstrap the values only a person can supply, and release a build. It
runs the repository's own signed image and terminates TLS for `photos`, `opds` and
`recovery`.

**There are no provider snapshots and no API**: a rebuild from the live ISO is the
only way back, so anything stateful that the image and `edge-bootstrap.sh` do not
recreate must be a recovery-kit item or must not exist.

## Render and commit the edge Ignition

Regenerate the document whenever the published edge digest changes, and never with a
placeholder: the renderer refuses a tag, a missing reference, `--synthetic` and
`--stock`.

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

**Never edit the committed JSON by hand**: a change belongs in `ignition/edge.bu`,
then a re-render, so the file and its hash cannot disagree with the template.

## Install the edge from the live ISO

On the console: pick the BIOS/GRUB disk (`/dev/vda`), and give dracut the static
address as kernel arguments. The install reads the committed file from `main` and
the hash of that same file.

```sh
hash="sha512-$(sha512sum ignition/edge.json | cut -d' ' -f1)"
url="https://raw.githubusercontent.com/smores56/homelab-platform/$(git rev-parse main)/ignition/edge.json"
sudo coreos-installer install /dev/vda \
  --ignition-url "$url" --ignition-hash "$hash" \
  --append-karg ip=192.236.188.99::192.236.188.65:255.255.255.192:smoresnet:eth0:none \
  --append-karg nameserver=8.8.8.8 --append-karg net.ifnames=0
```

After the install and before the bootstrap, prove every tmpfiles path the units name
exists. One missing `ReadWritePaths` target is a unit that dies in namespace setup
with `226/NAMESPACE`:

```sh
systemd-tmpfiles --cat-config | grep -E '/var/lib/(caddy|homelab/deploy|smoresnet)'
```

**A reinstall destroys the node identity**: mint a fresh single-use preauthorized
`tag:vps` key in the Tailscale console, and without the admin login and its 2FA
recovery codes the box never rejoins.

## Bootstrap the fresh edge

`scripts/edge-bootstrap.sh` runs on the box as root, refuses a bad value before it
writes anything, and is idempotent. Have the values at hand before it: the
preauthorized `tag:vps` auth key, the deploy ping URL, the
`SMORTRESS_FQDN` and the ACME address, plus Caddy's data directory from the
recovery kit. The edge keeps the host key sshd made on the box, so a reinstall
presents a new one.

The first session is the only one on the public side: sshd accepts the key from the
Ignition document and nothing else, and firewalld publishes 22 until
`smoresnet-tailscale-up.service` has joined the tailnet.

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

**Both secrets are on stdin and never in argv**: an argument is in
`/proc/<pid>/cmdline` for every user on the box and in the shell's history, and a
here-document is in neither. `TS_AUTHKEY` is the preauthorized `tag:vps` key, typed
once; the box keeps it root-only at `/etc/smoresnet/tailscale-authkey`, and the join
unit re-runs on every boot until the node has enrolled.

**The first boot after an install or a reinstall holds, pages once and writes the
marker that says it did**: the previous deployment on a fresh box is the install
medium's, so there is no history to roll back on. **A popped edge yields no corpus
access at all**: the reader and its R2 credential run on smortress, and this box is
only a TLS proxy.

What it refuses, before writing anything: an `SMORTRESS_FQDN` with no tailnet
domain, a missing `EDGE_ACME_EMAIL`, a key that is not `tskey-`-shaped, a secret
carrying whitespace, and `caddy validate` on the values about to be installed.

A re-run converges the derived files and leaves every secret already written alone;
a value for a file that holds a different one is refused, and `--force` is what
rotates it. Then prove the box from a checkout — and if this box's public IPv4 is
not the one committed in `tofu/terraform.tfvars`, update `edge_ipv4` and apply
**before** the probe, or the probe measures the old box:

```sh
scripts/verify-fleet.sh
```

**Issuance needs the public name**: ACME resolves a name before it can validate it,
so while the record is proxied or points elsewhere the order fails and Caddy keeps
retrying. A new box or an `edge_ipv4` change is followed by a wait, not a config
edit. A 502 on `recovery` while `photos` works is the reader or its Service on
smortress, never this box.

**10 TB/month is a null-route, not a throttle**: over the allowance RackNerd
suspends the service, which takes both public names down while every tailnet route
stays up — the same allowance is why this box advertises no exit node.

## Release and deploy the edge

A push to `main` that touches the image's inputs builds, signs and publishes the
edge, and stops there: the box with the least rollback is deployed by a dispatch and
never by a merge. Review the digest the publish run printed, then release it:

```sh
gh workflow run publish-edge-image.yml --repo smores56/homelab-platform --ref main
gh run watch "$(gh run list --workflow publish-edge-image.yml --limit 1 \
  --json databaseId --jq '.[0].databaseId')"
```

Read the result on the box:

```sh
journalctl -u smoresnet-deploy.service -n 50 --no-pager
journalctl -u edge-boot-gate.service -b -n 50 --no-pager
```

A request resolves against the **tip of `main`**, and the edge image is published
only for the commits that touch its tree, so a request that lands on a tip which did
not rebuild is `no-artifact` and the next request supersedes it. Until
`edge-bootstrap` has seeded `/var/lib/homelab/deploy/state.json` every request is
`bootstrap-required`.

**There is no boot counting on this box**: a deployment whose PID1 never reaches
userspace is the RackNerd HTML5 console and the previous boot entry, and no
automatic rollback is coming. The gate's only rollback is the one it runs in
userspace.

## The zone, when it changes

Applied from the smortress checkout; what a wrong apply takes down is on this box.

- **`prevent_destroy` is read from configuration, not from state**: deleting a
  resource block plans a destroy, with no `tofu state rm` first and no dashboard
  deletion before the apply.
- **A plan that says replace on a record is wrong**: a replacement is a window in
  which the name publishes nothing. Stop and compare.
- **Never `init` against an empty or partial state**: the first plan then proposes
  creating every object that already exists. A leftover `/var/lib/cloudflare-tofu`
  plans a whole-zone create the API rejects object by object, and a stale
  `tofu/terraform.tfstate` in a checkout is an orphan a later `init` offers to copy
  back.
- The zone allows exactly one `http_ratelimit` rule, and a second fails the apply.
- **Do not pin the ACME account in `CAA`**: a rebuild registers a new account, so an
  `accounturi` pin turns it into an outage that surfaces at renewal. Turning on
  Advanced Certificate Manager stops Cloudflare appending its own CAA set, so add
  the new CA to the records first and move the certificate afterwards — otherwise
  renewal stops weeks before anyone notices.
- `recovery.sammohr.dev` is password-only and has no Access gate: write denial is
  the control. If that denial weakens, add an Access application back as a reviewed
  change, never as a dashboard edit.
