#!/usr/bin/env bash
# Render one host's containers signature policy from the shared contract and
# that host's own registry table.
#
#   lib/containers/render-policy.sh smortress   # the server image and both installs
#   lib/containers/render-policy.sh smorespro   # the laptop image
#
# The policy is one contract with one per-host difference, and the difference is
# which registries this host trusts and under which key. So the file splits in
# two: policy.json is the half no host may vary (reject by default, and the
# transports that never reach a registry at all), and policy.d/<host>.json is the
# docker repository map that is that host's.
#
# Nothing carries a rendered copy: both Containerfiles render at build time,
# scripts/render-ignition.sh renders the document the installer writes, the
# publish job renders the one entry it pulls with, and scripts/check-lib-drift.sh
# renders both hosts to prove the halves still compose. A second copy of the
# finished document is the thing this file exists to make impossible.
#
# jq is the renderer because every consumer already has it: both images run it at
# build time and the publish runner ships it.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if (($# != 1)); then
  printf 'usage: %s <host>\n' "${0##*/}" >&2
  printf '  hosts: %s\n' "$(cd -- "$here/policy.d" && printf '%s ' *.json | sed 's/\.json//g')" >&2
  exit 2
fi

host=$1
table=$here/policy.d/$host.json
if [[ -s $table ]]; then
  jq --indent 4 --slurpfile table "$table" '.transports = ({docker: $table[0]} + .transports)' "$here/policy.json"
  exit 0
fi
# A host with no table would render a policy that trusts nothing but its base,
# which the image pulls with, so it would only fail at the first signed pull.
printf '%s: no registry table for %q (%s)\n' "${0##*/}" "$host" "${table#"$here"/}" >&2
exit 2
