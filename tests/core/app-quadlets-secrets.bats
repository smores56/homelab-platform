#!/usr/bin/env bats
# bats file_tags=core
# Every Podman secret exists only because a decrypted file produced it, and
# every one has a decrypt manifest entry.
#
# One file of the suite that was tests/core/app-quadlets.bats, split so bats can
# run the sections as parallel files (a file is one job). The tables, the
# file-scope sources and every checker more than one section calls are in
# tests/core/app-quadlets_lib.bash; the checkers only this file uses stay here.
#
#   bats tests/core/app-quadlets-secrets.bats
load ../helpers
load ./app-quadlets_lib

setup_file() { aq_setup_file; }
setup() { aq_setup; }

# 3. A Podman secret only exists because a decrypted file produced it.
secret_is_created_from_a_decrypted_file() { # secret
  grep -qE "^readonly names=\(.*\b$1\b" scripts/app-secrets.sh
}

secret_has_a_decrypt_manifest_entry() { # secret
  grep -qE "^${1//./\\.}\.yaml[[:space:]]" bootc/server/rootfs/usr/share/smortress/secrets.manifest
}

declared=$(grep -h '^Secret=' "${app_quadlets[@]}" | cut -d= -f2 | cut -d, -f1 | sort -u)
for _secret in $declared; do
  registered "secret $_secret is created from a decrypted file" \
    secret_is_created_from_a_decrypted_file "$_secret"
  registered "secret $_secret has a decrypt manifest entry" \
    secret_has_a_decrypt_manifest_entry "$_secret"
done
unset _secret declared
