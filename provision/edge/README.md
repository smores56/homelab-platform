# The public edge

The RackNerd KVM VPS that serves `photos.sammohr.dev`, `opds.sammohr.dev` and
`recovery.sammohr.dev` (design #725). It is a tailnet node carrying `tag:vps`,
and its only public listener is Caddy on 443. Nothing here is in the smortress
image: the box is a separate host with a hand-run bootstrap, because RackNerd's
ctrl panel offers no cloud-init and no API to declare one.

| File | Purpose |
| --- | --- |
| `bootstrap.sh` | the whole provisioning step: packages, tailnet join, firewall, Caddy, unattended upgrades, then `verify.sh` |
| `Caddyfile` | the three names, TLS-ALPN-01 only: two proxy to Serve ports 8446/8447, the third to the box's own Backrest |
| `nftables.conf` | second firewall layer: 443 and 41641 public, 22 on the tailnet only |
| `05-edge-hardening.conf` | sshd drop-in; sshd keeps the first value, so `05-` beats cloud-init's `50-` |
| `verify.sh` | on-box proof of the design's shape; run it after any hand change |
| `authorized_keys` | the login key the bootstrap appends, so a replacement box trusts it without a console step |

## Order

1. Deploy the VPS from the panel's **Ubuntu 24.04** template, in the datacenter
   recorded in the runbook, and note the IPv4 in `docs/core/public-edge.md`.
   The Caddyfile is validated against noble's Caddy 2.6.2; jammy's 2.4 is
   refused by the bootstrap.
2. Leave the ctrl network firewall off (decision 2026-11-22). The host
   nftables ruleset is the only layer; the accepted residual is that a broken
   host firewall or a compromised host is unbounded.
3. From the HTML5 console, run `bootstrap.sh` with a `tag:vps` preauthorized
   key, the host's MagicDNS name and an ACME contact address. It names the box
   `smoresnet` on the OS and the tailnet, and appends `authorized_keys`. A root
   SSH key must already be in `/root/.ssh/authorized_keys`; the template takes
   it from the order form, and the bootstrap leaves key auth as the only way in.
4. Reconnect over the tailnet (`ssh root@smoresnet`) and run `verify.sh`. Its upstream half (the two
   Serve ports and the 443 refusal) is gated on `EXPECT_UPSTREAM=1`: run that
   once the image that declares 8446/8447 is on smortress, and before cutover.

5. After the cutover, run `scripts/verify-public-edge.sh` from a host with
   public resolution: it is the only check that sees the VPS. Then confirm the
   issuer under `/var/lib/caddy/.local/share/caddy/certificates/` is
   `acme-v02`, not `acme-staging-v02`. A staging certificate verifies against no
   public store, and `admin off` means a replaced `Caddyfile` takes effect only
   on `systemctl restart caddy`, so a staging run can outlive the file that
   replaced it — that is exactly how the first cutover came up untrusted.

6. **Forced renewal** (owner only, destructive). `admin off` leaves no API to
   trigger an order, so the renewal is forced by deleting the name's certificate
   directory and restarting Caddy; it re-orders on the next handshake. List
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

   `subject` must be `photos.sammohr.dev` and `notAfter` the new window; from
   outside, `scripts/verify-public-edge.sh` and `scripts/verify-caa.sh` confirm
   the same two things.

   If finalize fails with `urn:ietf:params:acme:error:unauthorized - authorizations for these identifiers not found`, the account's reused authorization has gone stale on Let's Encrypt's side. Rotate the ACME account: stop Caddy, move `/var/lib/caddy/.local/share/caddy/acme` aside, start Caddy so it registers a fresh account, and let it obtain. CAA names the CA, not an account, so the replacement is authorized immediately; the old account key can be deleted once the certificate is renewed. The re-issue needs the public name to resolve to this
   box: before the cutover the order fails and Caddy keeps retrying, which is why
   this step sits on the cutover's side of the line.

The DNS cutover is not part of this: it waits for #709's retirement gate, and it
is one commit applied by CI — `edge_ipv4` in `tofu/terraform.tfvars` — which
creates the three grey `A` records. The two-commit dance (pin `cluster_hosts`,
then set `edge_ipv4`) existed only while the cluster tunnel still owned the
names; that tunnel and `cluster_hosts` are retired (SDLC #833). Dropping
`edge_ipv4` is the rollback. See `docs/core/public-edge.md`.

`verify.sh`'s direct-path check can fail in the first seconds after the join,
before the WireGuard path is established; re-run it rather than changing
anything.
