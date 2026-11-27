#!/usr/bin/env bash
# Create the Podman secrets the application Quadlets mount, from the files
# sops-decrypt wrote into /run. A secret is re-created on every boot, so a
# rotated ciphertext reaches the next container creation with no manual step.
#
# The value never appears in argv or in the environment of this process: podman
# reads it from the decrypted file.
set -euo pipefail

secrets_dir=${SMORTRESS_SECRETS_DIR:-/run/smortress/secrets}
podman_bin=${PODMAN_BIN:-podman}

# Secret name == ciphertext name without the .yaml suffix. Only secrets that a
# Quadlet declares are listed here; an unlisted file is a manifest mistake, not
# something to publish.
# One line on purpose: the application Quadlet suite (tests/core/app-quadlets-*.bats)
# reads the names from the `readonly names=(` line to prove every declared secret has
# a decrypted source.
readonly names=(immich-db-password opdshelf-admin-password agent-local-api-key agent-general-api-key agent-hosted-key simplefin-access-url tmail-bridge-password brave-sync-seed)

for name in "${names[@]}"; do
  src=$secrets_dir/$name.yaml
  if [[ ! -s $src ]]; then
    echo "app-secrets: $src is missing; sops-decrypt did not produce it" >&2
    exit 1
  fi
  # --replace keeps a stale secret from a previous boot from shadowing the
  # current ciphertext. Existing containers keep the value they were created
  # with, and this unit is ordered before every container that declares one.
  if ! "$podman_bin" secret create --replace "$name" "$src" >/dev/null 2>&1; then
    echo "app-secrets: could not create the $name secret" >&2
    exit 1
  fi
  echo "app-secrets: secret $name is current"
done
