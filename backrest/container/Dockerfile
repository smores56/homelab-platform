# Recovery reader for the R2 restic repository. The base image is the pinned
# official Backrest release because it bundles restic 0.19.1 at /bin/restic;
# nothing is downloaded at boot, so a cold start works with binary-download
# egress unavailable.
FROM ghcr.io/garethgeorge/backrest:v1.14.1@sha256:b852979754281026230cc69fb11428e6d57c9a97784ab4a444ffc7934c53a215

# The stock entrypoint only defaults env vars; this one also materialises the
# ephemeral config from the Worker-supplied JSON before Backrest starts.
COPY --chmod=0755 entrypoint.sh /usr/local/bin/smortress-backrest-entrypoint

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/smortress-backrest-entrypoint"]
CMD ["/backrest"]
