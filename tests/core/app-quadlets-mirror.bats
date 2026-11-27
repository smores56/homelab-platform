#!/usr/bin/env bats
# bats file_tags=core
# The platform manifests the mirror signs and the units the runtime image
# has to carry for the generator.
#
# One file of the suite that was tests/core/app-quadlets.bats, split so bats can
# run the sections as parallel files (a file is one job). The tables, the
# file-scope sources and every checker more than one section calls are in
# tests/core/app-quadlets_lib.bash; the checkers only this file uses stay here.
#
#   bats tests/core/app-quadlets-mirror.bats
load ../helpers
load ./app-quadlets_lib

setup_file() { aq_setup_file; }
setup() { aq_setup; }

# 1c. containers/image verifies the platform manifest it copies, not the index
#     digest, so the mirror has to sign every pullable manifest of an index and
#     not just the index. Signing the index alone left every Quadlet pull on the
#     first T5 boot failing with "A signature was required, but no signature
#     exists".
@test "platform digests skip attestation manifests" {
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  local fixture
  fixture='{"manifests":[
  {"digest":"sha256:aa","platform":{"os":"linux","architecture":"amd64"}},
  {"digest":"sha256:bb","platform":{"os":"linux","architecture":"arm64"}},
  {"digest":"sha256:cc","platform":{"os":"unknown","architecture":"unknown"}}]}'
  assert_equal "$(printf '%s' "$fixture" | app_image_platform_digests | paste -sd' ')" \
    "sha256:aa sha256:bb"
}

@test "a single-manifest image yields no platform digests" {
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  assert_equal "$(printf '{"schemaVersion":2,"layers":[]}' | app_image_platform_digests)" ""
}

# 1d. Every unit the generator has to convert ships in the image. A network file
#     left out of the Containerfile makes the generator drop the container that
#     requests it, and opdshelf.network did exactly that on the first T5 boot.

for _u in units/quadlet/*.container units/quadlet/*.network; do
  _unit=${_u#units/quadlet/}
  if [[ $_unit == pattern.container ]]; then
    continue
  fi
  registered "image installs $_unit" image_installs "$_unit"
done
unset _u _unit
