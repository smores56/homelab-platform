#!/usr/bin/env bats
# bats file_tags=image
# The lib/ drift comparison, and the mutations it must refuse (SDLC #1024).
#
# Design #1011 asks for one copy per contract and a CI comparison that fails on
# drift. scripts/check-lib-drift.sh is that comparison: one copy of each shared
# artifact, no host tree keeping its own, every host wiring lib/, the per-host
# halves composing, and nothing naming a retired path.
#
# A comparison nobody has seen fail is a comparison that proves nothing, so every
# rule has at least one mutation here: the fixture is a copy of the tree the
# checker reads, one thing is reverted the way a merge would revert it, and the
# run must fail naming the rule that owned it.
#
#   bats tests/image/lib-drift.bats
load ../helpers

checker=scripts/check-lib-drift.sh

# fixture <dir>: the tree the checker derives from its own location, which is
# lib/ (the artifacts and their halves), the three host trees it holds copies
# against, the Containerfiles that state which lib files each host installs, and
# bootc/lib/deploy (the role table each policy has to agree with).
fixture() {
    local dir=$1
    mkdir -p "$dir/lib" "$dir/scripts" "$dir/bootc/server" "$dir/bootc/edge" "$dir/hosts/laptop"
    cp -a lib/. "$dir/lib/"
    cp scripts/check-lib-drift.sh "$dir/scripts/"
    cp bootc/server/Containerfile "$dir/bootc/server/"
    cp bootc/edge/Containerfile "$dir/bootc/edge/"
    cp hosts/laptop/Containerfile "$dir/hosts/laptop/"
    mkdir -p "$dir/bootc/lib" "$dir/bootc/server/rootfs/etc" "$dir/bootc/edge/rootfs/etc" \
        "$dir/hosts/laptop/rootfs/etc"
    cp -a bootc/lib/deploy "$dir/bootc/lib/"
}

@test "the drift comparison passes on the tree as committed" {
    run bash "$checker"
    assert_success
    refute_output --partial 'FAIL'
    # The summary is the line a reader looks for, and 0 problems is the pass.
    assert_output --partial 'checks, 0 problems'
}

# CI invokes it by path, so the mode is part of the contract.
@test "the drift checker is tracked as an executable" {
    run git ls-files -s "$checker"
    assert_output --partial '100755'
}

# The artifacts themselves, not just the checker: `git grep` names only lib/ for
# the two files whose copies were byte-identical, and the Containerfiles that
# copy them. A second copy anywhere is the drift this task removes.
@test "the shared artifacts are found only in lib/" {
    run git grep -l 'BEGIN PUBLIC KEY' -- '*cosign.pub'
    assert_success
    assert_output --partial 'lib/containers/cosign.pub'
    refute_output --partial 'bootc/server/cosign.pub'
    refute_output --partial 'hosts/laptop/cosign.pub'

    run git ls-files '*20-sops-env' '*10-human-gate' '*11-agent-socket' '*policy.d/*' \
        '*containers/registries.d/*'
    assert_success
    # Every path is under lib/: one copy of each artifact, and the per-host
    # differences are the tables beside them.
    refute_output --regexp '^(bootc|hosts)/'
}

@test "the drift comparison selects its own suite" {
    run sh tests/tags.sh lib/containers/policy.d/smortress.json
    assert_output --partial 'tests/image/lib-drift.bats'
}

# mutation_fails <fragment> <command...>: copy the fixture, run <command>, and
# require the run to fail naming <fragment>. The command is the mutation: a write
# into the fixture, a chmod, a removal.
mutation_fails() {
    local fragment=$1
    shift
    local dir=$BATS_TEST_TMPDIR/repo out
    rm -rf "$dir"
    fixture "$dir"
    (cd "$dir" && "$@")
    out=$(bash "$dir/scripts/check-lib-drift.sh" 2>&1) && {
        printf 'the comparison passed a mutated tree; it was looking for %s\n%s\n' "$fragment" "$out" >&2
        return 1
    }
    assert_contains "$out" "$fragment"
}

# A host tree that grows its copy back is how the second version of every one of
# these artifacts appeared. The copy is mutated relative to lib/ as well as extra,
# which is the shape drift actually takes.
@test "a second copy of the key in a host tree fails the comparison" {
    mutation_fails 'one copy of the cosign public key' \
        bash -c 'printf "not the key\n" >bootc/server/cosign.pub'
}

@test "a second copy of the sudoers drop-in fails the comparison" {
    mutation_fails 'one copy of the sops env drop-in' \
        bash -c 'mkdir -p bootc/server/rootfs/etc/sudoers.d && cp lib/sudoers/20-sops-env bootc/server/rootfs/etc/sudoers.d/'
}

@test "a policy in a host rootfs fails the comparison" {
    mutation_fails 'holds no copy of etc/containers/policy.json' \
        bash -c 'mkdir -p hosts/laptop/rootfs/etc/containers && cp lib/containers/policy.json hosts/laptop/rootfs/etc/containers/'
}

@test "a registries.d entry in a host rootfs fails the comparison" {
    mutation_fails 'holds no copy of etc/containers/registries.d' \
        bash -c 'mkdir -p bootc/server/rootfs/etc/containers/registries.d && cp lib/containers/registries.d/ghcr.io-smortress.yaml bootc/server/rootfs/etc/containers/registries.d/'
}

# The wiring is the half a host can quietly stop doing: drop the COPY and the
# image builds from whatever the tree still happens to contain.
@test "a Containerfile that stops copying lib/ fails the comparison" {
    mutation_fails 'installs its lib/ files' \
        sed -i 's|^COPY lib/containers/policy.d/smorespro.json |COPY nothing-here |' hosts/laptop/Containerfile
}

@test "a host that installs the server-only agent-socket keep fails the comparison" {
    mutation_fails 'installs no agent-socket keep' \
        sed -i 's|^COPY lib/sudoers/10-human-gate |COPY lib/sudoers/11-agent-socket |' hosts/laptop/Containerfile
}

# The policy is contract plus table, so a table that no longer merges cleanly is
# a policy that trusts a whole transport -- the rule that shadows the global
# reject for every registry reference.
@test "a registry table that trusts a whole transport fails the comparison" {
    mutation_fails 'trusts no repository transport-wide' \
        bash -c 'jq ". + {\"\": [{\"type\": \"insecureAcceptAnything\"}]}" lib/containers/policy.d/smortress.json >t && mv t lib/containers/policy.d/smortress.json'
}

@test "a table whose key path nothing installs still composes, and the image check owns it" {
    # The comparison proves the halves compose; what a key path must be is the
    # image's own assertion (scripts/check/server/access.sh), so this mutation is
    # accepted here rather than silently duplicated as a second rule.
    local dir=$BATS_TEST_TMPDIR/repo
    rm -rf "$dir"
    fixture "$dir"
    (cd "$dir" && jq '.["ghcr.io/smores56/homelab-platform"][0].keyPath = "/etc/pki/containers/elsewhere.pub"' \
        lib/containers/policy.d/smortress.json >t && mv t lib/containers/policy.d/smortress.json)
    run bash "$dir/scripts/check-lib-drift.sh"
    assert_success
}

# The greenboot split: one program, and what a host asserts is that host's file.
@test "a host name in the shared greenboot check fails the comparison" {
    mutation_fails 'carries no host' \
        sed -i 's|^set -uo pipefail|# smortress\nset -uo pipefail|' lib/greenboot/required.d/10-health.sh
}

@test "a second assertion file in one host's directory fails the comparison" {
    mutation_fails 'assertions are one file' \
        bash -c 'cp lib/greenboot/assertions.d/edge/10-health.sh lib/greenboot/assertions.d/server/20-extra.sh'
}

@test "an assertion file without assertions() fails the comparison" {
    mutation_fails 'define assertions()' \
        sed -i 's|^assertions() {|assertions_gone() {|' lib/greenboot/assertions.d/edge/10-health.sh
}

@test "a greenboot check that is not executable fails the comparison" {
    mutation_fails 'ships executable' \
        chmod 0644 lib/greenboot/required.d/10-health.sh
}

# The deploy verifier (SDLC #1025): one program, and what a host deploys is its
# table. The names the program must not carry are the whole check -- a host, an
# owner, a repository or an image in the program is the line the second copy used
# to differ on -- and the table must say what the rest of the deploy plane says.
@test "a host name in the shared verifier fails the comparison" {
    mutation_fails 'carries no host' \
        bash -c 'printf "\n# the smortress verifier\n" >>lib/deploy/verify.py'
}

@test "a verifier that names a role in code fails the comparison" {
    mutation_fails 'picks no role' \
        bash -c 'printf "\nROLE = decisions.role(decisions.SERVER)\n" >>lib/deploy/verify.py'
}

@test "a second copy of the verifier in a host rootfs fails the comparison" {
    mutation_fails 'one copy of the deploy verifier' \
        bash -c 'mkdir -p bootc/edge/rootfs/usr/libexec && cp lib/deploy/verify.py bootc/edge/rootfs/usr/libexec/deploy-verify.py'
}

@test "a verifier committed non-executable fails the comparison" {
    mutation_fails 'ships executable' chmod 0644 lib/deploy/verify.py
}

@test "a Containerfile that stops installing the verifier fails the comparison" {
    mutation_fails 'installs its lib/ files' \
        sed -i 's|^COPY lib/deploy/verify.py |COPY nothing-here |' bootc/edge/Containerfile
}

# The allowlist and the image repository are stated twice -- in the policy table
# and in the shared role table the drain refuses a queued entry by -- so the two
# statements are compared rather than trusted.
@test "a policy table that allows a repository the role does not run fails the comparison" {
    mutation_fails 'agrees with the shared role table' \
        bash -c 'jq ".repos += [\"homelab-other\"]" lib/deploy/policy.d/edge.json >t && mv t lib/deploy/policy.d/edge.json'
}

@test "a policy table that resolves the other host's image fails the comparison" {
    mutation_fails 'agrees with the shared role table' \
        bash -c 'jq ".images[\"homelab-platform\"] = \"smores56/homelab-platform/server\"" lib/deploy/policy.d/edge.json >t && mv t lib/deploy/policy.d/edge.json'
}

@test "a policy table for a host that runs no deploy fails the comparison" {
    mutation_fails 'installs no deploy verifier' \
        bash -c 'printf "COPY lib/deploy/policy.d/server.json /tmp/policy.json\n" >>hosts/laptop/Containerfile'
}

# The retired paths: a reader of a file that no longer exists fails on a booted
# host, not in review.
@test "a file that still names a retired path fails the comparison" {
    mutation_fails 'nothing names the retired path bootc/server/cosign.pub' \
        bash -c 'mkdir -p scripts && printf "install -m 0644 x bootc/server/cosign.pub\n" >scripts/stale.sh'
}

@test "a file that still names the retired greenboot check fails the comparison" {
    mutation_fails 'nothing names the retired path 10-smortress-health.sh' \
        bash -c 'printf "test -x /etc/greenboot/check/required.d/10-smortress-health.sh\n" >scripts/stale.sh'
}
