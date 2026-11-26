#!/bin/sh
# Renders Backrest's config from the environment, then hands the process off.
#
# This is the only place the config is built, so the image the Cloudflare
# deployment used and the smortress unit (SDLC #953) run the same rules. The
# state it renders into is rebuilt at every start and nothing on it is the source
# of truth.
#
# Fails closed. A missing value would start Backrest with auth disabled or
# without a repository, which is worse than a container that does not start.
set -eu

: "${BACKREST_INSTANCE:?BACKREST_INSTANCE is required}"
: "${BACKREST_REPO_ID:?BACKREST_REPO_ID is required}"
: "${BACKREST_REPO_URI:?BACKREST_REPO_URI is required}"
: "${BACKREST_REPO_GUID:?BACKREST_REPO_GUID is required}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD is required}"
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is required}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is required}"
: "${BACKREST_OPERATOR_USER:?BACKREST_OPERATOR_USER is required}"
: "${BACKREST_OPERATOR_BCRYPT:?BACKREST_OPERATOR_BCRYPT is required}"
: "${BACKREST_BOOTSTRAP_USER:?BACKREST_BOOTSTRAP_USER is required}"
: "${BACKREST_BOOTSTRAP_BCRYPT:?BACKREST_BOOTSTRAP_BCRYPT is required}"

case $BACKREST_REPO_GUID in
  *[!0-9a-f]* | "") echo "smortress-backrest: BACKREST_REPO_GUID must be lowercase hex" >&2; exit 1 ;;
esac
if [ "${#BACKREST_REPO_GUID}" -ne 64 ]; then
  echo "smortress-backrest: BACKREST_REPO_GUID must be the 64-character restic repository id" >&2
  exit 1
fi

# The paths and the bind address are the caller's, because the same renderer has
# run in two places with different constraints: the retired Cloudflare image kept
# its state on an ephemeral disk (the Dockerfile sets those three back), and the
# smortress unit (SDLC #953) keeps it under /var/lib/backrest. The bind default
# is loopback: the guard is what starts Backrest, and a renderer that defaulted
# to a public address would be a second way to expose an unguarded reader.
: "${BACKREST_CONFIG:=/var/lib/backrest/config.json}"
: "${BACKREST_DATA:=/var/lib/backrest/data}"
: "${BACKREST_CACHE:=/var/lib/backrest/cache}"
: "${BACKREST_BIND:=127.0.0.1:9899}"
: "${BACKREST_RESTIC:=/usr/bin/restic}"

mkdir -p "$(dirname "$BACKREST_CONFIG")" "$BACKREST_DATA" "$BACKREST_CACHE" "$BACKREST_CACHE/tmp"
chmod 700 "$(dirname "$BACKREST_CONFIG")" "$BACKREST_DATA" "$BACKREST_CACHE"

# --no-lock skips the lock directory a write-denied token cannot create;
# --no-cache keeps restic's cache off a small, ephemeral disk. No plans means
# nothing that writes is ever scheduled.
umask 077
jq -n \
  --arg instance "$BACKREST_INSTANCE" \
  --arg repo "$BACKREST_REPO_ID" \
  --arg uri "$BACKREST_REPO_URI" \
  --arg guid "$BACKREST_REPO_GUID" \
  --arg password "$RESTIC_PASSWORD" \
  --arg ak "$R2_ACCESS_KEY_ID" \
  --arg sk "$R2_SECRET_ACCESS_KEY" \
  --arg ou "$BACKREST_OPERATOR_USER" \
  --arg ob "$BACKREST_OPERATOR_BCRYPT" \
  --arg bu "$BACKREST_BOOTSTRAP_USER" \
  --arg bb "$BACKREST_BOOTSTRAP_BCRYPT" \
  '{
    modno: 0,
    version: 6,
    instance: $instance,
    repos: [{
      id: $repo,
      uri: $uri,
      guid: $guid,
      password: $password,
      env: ["AWS_ACCESS_KEY_ID=" + $ak, "AWS_SECRET_ACCESS_KEY=" + $sk, "AWS_DEFAULT_REGION=auto"],
      flags: ["--no-lock", "--no-cache"],
      autoUnlock: false,
      autoInitialize: false
    }],
    plans: [],
    auth: {
      disabled: false,
      users: [
        { name: $ou, passwordBcrypt: $ob },
        { name: $bu, passwordBcrypt: $bb }
      ]
    }
  }' >"$BACKREST_CONFIG"

# Backrest passes repo env to restic itself; the process environment does not
# need to keep the credentials around.
unset RESTIC_PASSWORD R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY

export BACKREST_CONFIG BACKREST_DATA
export XDG_CACHE_HOME="$BACKREST_CACHE"
export TMPDIR="$BACKREST_CACHE/tmp"
export BACKREST_PORT="$BACKREST_BIND"
# The image ships the pinned binary; without this Backrest would try to fetch
# restic from GitHub on first use. On the host it is the restic the backup plane
# already runs, at the same version the retired image bundled.
export BACKREST_RESTIC_COMMAND="$BACKREST_RESTIC"

exec "$@"
