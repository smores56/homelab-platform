#!/bin/sh
# Seeds Backrest's config from the Worker-supplied JSON, then hands the process
# off. Container disk is ephemeral: every start rebuilds this state, so the
# config is never the source of truth and must not be relied on across restarts.
#
# Fails closed. A missing config would start Backrest with auth disabled and no
# repository, which is worse than a container that does not start.
set -eu

if [ -z "${BACKREST_CONFIG_JSON:-}" ]; then
	echo "smortress-backrest: BACKREST_CONFIG_JSON is empty; refusing to start" >&2
	exit 1
fi

mkdir -p /config /data /cache
chmod 700 /config /data /cache

umask 077
printf '%s' "${BACKREST_CONFIG_JSON}" >/config/config.json
unset BACKREST_CONFIG_JSON

export BACKREST_CONFIG=/config/config.json
export BACKREST_DATA=/data
export XDG_CACHE_HOME=/cache
export TMPDIR=/tmp
export BACKREST_PORT=0.0.0.0:9898
# The image ships the pinned binary; without this Backrest would try to fetch
# restic from GitHub on first use.
export BACKREST_RESTIC_COMMAND=/bin/restic

exec "$@"
