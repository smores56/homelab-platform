# Recovery reader for the R2 restic repository. The base image is the pinned
# official Backrest release because it bundles restic 0.19.1 at /bin/restic;
# nothing is downloaded at boot, so a cold start works with binary-download
# egress unavailable.
FROM ghcr.io/garethgeorge/backrest:v1.14.1@sha256:b852979754281026230cc69fb11428e6d57c9a97784ab4a444ffc7934c53a215

# jq renders the config inside the image so a container run and a VPS run share
# one implementation. The package is resolved at build time; the base image and
# the bundled restic are what the deploy pins. python3 carries the read-only
# guard, because a host without the Cloudflare Worker has nothing else refusing
# the admin RPCs (design #725, T2).
RUN apk add --no-cache jq python3

# The stock entrypoint only defaults env vars; this one also renders the
# ephemeral config from the environment before Backrest starts.
COPY --chmod=0755 entrypoint.sh /usr/local/bin/smortress-backrest-entrypoint

# The guard owns the public port and starts Backrest itself on loopback, so a
# host cannot expose an unguarded reader by forgetting a flag. The Cloudflare
# deployment keeps CMD=/backrest and the Worker's own guard.
COPY --chmod=0755 guard.py /usr/local/bin/backrest-guard

# The renderer's own defaults are the smortress host's (SDLC #953): state under
# /var/lib/backrest and a loopback bind, because there the guard is what starts
# Backrest. A container keeps the ephemeral paths and the bundled restic here; the
# bind address stays the guard's to choose.
ENV BACKREST_CONFIG=/config/config.json \
    BACKREST_DATA=/data \
    BACKREST_CACHE=/cache \
    BACKREST_RESTIC=/bin/restic

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/smortress-backrest-entrypoint"]
CMD ["/backrest"]
