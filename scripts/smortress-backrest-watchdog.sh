#!/usr/bin/env bash
# Keeps the recovery reader answering, and tells Healthchecks when it does not
# (SDLC #953 moved this with the reader; it ran on the public edge before).
#
# `Restart=always` covers a process that exits. It does not cover a guard that is
# still running but stops answering, which is the failure this timer exists for:
# one restart, then a dead-man ping if the restart did not help.
#
# The ping URL is optional and never in the image: write it to
# /etc/backrest/healthcheck-url (one line) and this reports to it. Without the
# file only the restart happens.
#
#   BACKREST_WATCHDOG_URL      what to probe (default http://127.0.0.1:9898/)
#   BACKREST_WATCHDOG_HC       ping URL file (default /etc/backrest/healthcheck-url)
#   BACKREST_WATCHDOG_TIMEOUT  per-request timeout in seconds (default 10)
#   BACKREST_WATCHDOG_UNIT     the unit to restart (default smortress-backrest.service)
set -uo pipefail

url=${BACKREST_WATCHDOG_URL:-http://127.0.0.1:9898/}
hc_file=${BACKREST_WATCHDOG_HC:-/etc/backrest/healthcheck-url}
timeout_s=${BACKREST_WATCHDOG_TIMEOUT:-10}
unit=${BACKREST_WATCHDOG_UNIT:-smortress-backrest.service}

probe() { curl -fsS -o /dev/null --max-time "$timeout_s" "$url"; }

ping() { # suffix: "" for success, "/fail" otherwise
  local hc
  [[ -r $hc_file ]] || return 0
  hc=$(head -1 "$hc_file")
  [[ -n $hc ]] || return 0
  curl -fsS -o /dev/null --max-time "$timeout_s" "${hc}${1}" || true
}

if probe; then
  ping ''
  exit 0
fi

logger -t backrest-watchdog "reader did not answer; restarting it"
systemctl restart "$unit"
sleep 5
if probe; then
  logger -t backrest-watchdog "reader answers again after a restart"
  ping ''
  exit 0
fi

logger -t backrest-watchdog "reader is still down after a restart; leaving it to the next run"
ping '/fail'
exit 1
