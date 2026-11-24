# The restic bucket (`restic-backup`) predates tofu and is not managed here, and
# nothing in the zone's config is left to declare: the browser CORS policy that
# used to sit in this file is retired (SDLC #833).
#
# It existed because the static recovery page fetched the repository straight
# from the browser, which put a signed, preflighted request in front of R2. Reads
# are server-side now: the hosted Backrest reader holds the read-only credential
# on the edge VPS and the browser only ever talks to `recovery.sammohr.dev`, so
# no origin needs a policy and re-adding one would only reopen a path nothing
# uses. `docs/core/backrest.md` describes the read path.
