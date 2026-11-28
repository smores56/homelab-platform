#!/usr/bin/env bats
# bats file_tags=deploy
# The edge verifier (design #939, T6): the server's decision functions under the
# edge's policy, and bootc's own signature verdict.
#
# The subject is bootc/edge/rootfs/usr/libexec/deploy-verify.py, which asks
# bootc/lib/deploy/decisions.py the same questions the server's verifier does --
# the allowlist, the tag name, the digest and label shapes, descendancy, the
# state and denylist records -- and adds the two answers that are the edge's own:
# an absent `edge:sha-<c12>` tag is a hold rather than a verdict, and the
# signature verdict is `bootc switch --enforce-container-sigpolicy`'s exit code.
#
# Two things are proven here, in the order the deploy path meets them:
#
#   - parity: every golden fixture both roles can be asked ends in the same
#     verdict from the edge's verifier as from the server's, byte for byte except
#     the image repository a refusal's detail names. The one document the roles
#     deliberately answer differently -- an absent tag -- is pinned from both
#     sides, so neither can drift alone. tests/deploy/fixtures.bats pins the same
#     documents against the server's own programs; this file is what makes those
#     fixtures a contract between two roles rather than a description of one.
#   - the signature verdict: a policy rejection from bootc is a refusal that
#     stages nothing, and every other way a switch can fail stays retryable,
#     because a flaky registry is not a bad image.
#
#   bats tests/deploy/edge-verify.bats
load ../helpers

fixtures=bootc/lib/deploy/fixtures
server_verify=bootc/server/rootfs/usr/libexec/deploy-verify.py
edge_verify=bootc/edge/rootfs/usr/libexec/deploy-verify.py
decisions=bootc/lib/deploy/decisions.py
# The GitHub API and the ghcr registry, shared with tests/deploy/fixtures.bats:
# both roles replay one document against one implementation of the world, or a
# parity check would be comparing two renderings of it.
world_server=tests/deploy/fixture-server.py

server_image=smores56/homelab-platform/server
edge_image=smores56/homelab-platform/edge

# The one document where the roles answer differently, and why: the edge image is
# built only for commits that touch the edge's tree, so an absent tag on the edge
# can be a publish still in flight. The edge holds it (exit 4, retried, superseded
# by the next request for the repository); the server pops it (exit 5, final,
# because a docs-only main commit never gets a server image and never will).
hold_fixture=tag-missing

commit=0123456789abcdef0123456789abcdef01234567

setup_file() {
    local dir=$BATS_FILE_TMPDIR

    # bootc, as far as this verifier can tell: `switch` either stages the digest
    # it was given or refuses, and the stub makes both observable -- the argv it
    # wrote to $FAKE_BOOTC_LOG, and the boot entry a successful switch leaves in
    # $FAKE_BOOTC_STAGED. The failure texts are bootc's own (containers/image's
    # policy rejection, and a registry that answered nothing), because the
    # verifier only reads them to tell a verdict apart from an outage.
    cat >"$dir/fake-bootc" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_BOOTC_LOG:?fake-bootc: no log}"
case ${1-} in
    switch)
        case ${FAKE_BOOTC_SWITCH:-ok} in
            ok)
                printf '%s\n' "${*: -1}" >"${FAKE_BOOTC_STAGED:?fake-bootc: no staged path}"
                exit 0
                ;;
            bad-signature)
                printf 'error: Setting up deployment: Source image rejected: Signature for identity @smores56 is not accepted\n' >&2
                exit 1
                ;;
            outage)
                printf 'error: Reading manifest: Get "https://ghcr.io/v2/": dial tcp 140.82.112.33:443: i/o timeout\n' >&2
                exit 1
                ;;
        esac
        ;;
esac
exit 0
STUB
    chmod 0755 "$dir/fake-bootc"
}

setup() {
    local file

    work=$BATS_TEST_TMPDIR
    state_dir=$work/state
    bootc=$BATS_FILE_TMPDIR/fake-bootc

    for file in "$server_verify" "$edge_verify" "$decisions" "$world_server"; do
        [[ -r $file ]] || fail "$file is missing"
    done
    for file in jq python3 curl cmp; do
        command -v "$file" >/dev/null || fail "$file is required"
    done

    mkdir -p "$state_dir"
    chmod 0700 "$state_dir"

    export DEPLOY_STATE_DIR=$state_dir
    export BOOTC_BIN=$bootc
    export DEPLOY_SWITCH_TIMEOUT=20
    export FAKE_BOOTC_LOG=$work/bootc.log
    export FAKE_BOOTC_STAGED=$work/staged
}

teardown() {
    kill "${server_pid:-}" 2>/dev/null || true
    wait 2>/dev/null || true
}

free_port() {
    python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

# start_world <fixture>: one server answering out of the fixture's world. The
# port is per test, so the verifier's API base is too, which is why a fixture's
# detail text may say $BASE instead of a URL.
start_world() { # <fixture>
    port=$(free_port)
    base=http://127.0.0.1:$port
    python3 "$world_server" "$1" "$port" >"$work/server.log" 2>&1 &
    server_pid=$!
    local _
    # 20 s, not 10: the gate runs four suites at once on a shared box, and a
    # box under that load is not a reason to fail a fixture.
    for _ in $(seq 1 200); do
        if python3 -c 'import socket, sys
s = socket.socket()
s.settimeout(0.2)
sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)' "$port"; then
            return 0
        fi
        sleep 0.1
    done
    fail "the fixture server never answered on $base: $(cat "$work/server.log")"
}

# seed <fixture>: the host's own records, exactly as the fixture states them. A
# null state is a host with no record at all, which is the bootstrap case.
seed() { # <fixture>
    local state denylist
    state=$(jq -c '.state' "$1")
    denylist=$(jq -c '.denylist' "$1")
    if [[ $state != null ]]; then
        jq -c . <<<"$state" >"$state_dir/state.json"
    fi
    if [[ $denylist != null ]]; then
        jq -c . <<<"$denylist" >"$state_dir/denylist.json"
    fi
    return 0
}

# replay <binary> <fixture> <out> <err> [<VAR=value>...]: one verifier run
# against the fixture's world and its host records. The exit code is left in $rc:
# a command substitution would run the run in a subshell and lose it.
replay() { # <binary> <fixture> <out> <err> [<VAR=value>...]
    local binary=$1 fixture=$2 out=$3 err=$4 repo sha
    shift 4
    repo=$(jq -r '.request.repo' "$fixture")
    sha=$(jq -r '.request.commit' "$fixture")
    rc=0
    env "$@" DEPLOY_GITHUB_API=$base DEPLOY_REGISTRY=$base \
        python3 "$binary" --repo "$repo" --commit "$sha" >"$out" 2>"$err" || rc=$?
}

# expect_bytes <fixture> <jq-path>: the fixture's expected bytes, with the one
# substitution the run needs. The sentinel is what keeps a trailing newline: a
# command substitution strips them, and the verdict is one line *with* its
# newline.
expect_bytes() { # <fixture> <jq-path>
    local want
    want=$(jq -j "$2" "$1"; printf 'x')
    want=${want//\$BASE/$base}
    printf '%s' "${want%x}"
}

# map_image <file>: the fixture's expected bytes for the edge. A refusal's detail
# names the image repository it resolved the tag out of, and the edge resolves
# out of its own; every other byte is the same document.
map_image() { # <file>
    local text
    text=$(cat "$1"; printf 'x')
    text=${text//$server_image/$edge_image}
    printf '%s' "${text%x}"
}

compare_bytes() { # <expected> <actual> <label>
    if cmp -s "$1" "$2"; then
        return 0
    fi
    fail "$3" "$(diff -u "$1" "$2" | tail -n +3)"
}

absent() { # <path> <what>
    [[ ! -e $1 ]] || fail "$2: $1 exists ($(cat "$1" 2>/dev/null))"
}

bootc_calls() { cat "$FAKE_BOOTC_LOG" 2>/dev/null; }

# parity <fixture>: the edge's answer to a document the server is also asked,
# compared with the server's and with the fixture's own expectation.
parity() { # <fixture>
    local fixture=$1 name manifest
    name=${fixture##*/}
    start_world "$fixture"
    seed "$fixture"

    replay "$server_verify" "$fixture" "$work/server.out" "$work/server.err"
    server_rc=$rc
    replay "$edge_verify" "$fixture" "$work/edge.out" "$work/edge.err" FAKE_BOOTC_SWITCH=ok
    edge_rc=$rc

    if [[ $name == "$hold_fixture.json" ]]; then
        # Both sides, pinned: a verifier that quietly stopped holding, or a
        # server that started holding, fails here.
        assert_equal "$server_rc" "$(jq -r '.expect.exit' "$fixture")" "the server's exit code"
        assert_equal "$(jq -r .verdict "$work/server.out")" not-deployable "the server's verdict"
        assert_equal "$(jq -r .reason "$work/server.out")" tag-missing "the server's reason"
        assert_equal "$edge_rc" 4 "the edge holds an absent tag"
        assert_equal "$(jq -r .verdict "$work/edge.out")" infra-failure "the edge's verdict"
        assert_equal "$(jq -r .reason "$work/edge.out")" no-artifact "the edge's reason"
        assert_contains "$(jq -r .detail "$work/edge.out")" \
            "$edge_image:$(jq -r '.world.tag.name' "$fixture")"
        # A hold is a hold because nothing was asked of bootc.
        assert_equal "$(bootc_calls)" ""
        return 0
    fi

    assert_equal "$edge_rc" "$(jq -r '.expect.exit' "$fixture")" "the edge's exit code"
    assert_equal "$edge_rc" "$server_rc" "the two verifiers disagree on the exit code"
    assert_equal "$(jq -r .verdict "$work/edge.out")" \
        "$(jq -r .verdict "$work/server.out")" "the two verifiers disagree on the verdict"
    # Two anchors, so the comparison does not rest on either program being right:
    # the fixture document, and the server's actual output.
    expect_bytes "$fixture" '.expect.stdout' >"$work/fixture.want"
    map_image "$work/fixture.want" >"$work/want"
    compare_bytes "$work/want" "$work/edge.out" "the edge against the fixture"
    map_image "$work/server.out" >"$work/want"
    compare_bytes "$work/want" "$work/edge.out" "the edge against the server"

    # A verified document is also the staged boot entry: the switch is the one
    # thing the edge does that the server's verifier does not, and it names the
    # digest the verification just resolved, never the tag.
    if ((edge_rc == 0)); then
        manifest=$(jq -r '.digests.manifest' "$work/edge.out")
        assert_equal "$(bootc_calls)" "switch --enforce-container-sigpolicy $edge_image@$manifest"
        assert_equal "$(cat "$FAKE_BOOTC_STAGED")" "$edge_image@$manifest"
    else
        assert_equal "$(bootc_calls)" "" "a refusal spends no switch"
    fi
}

# Every verify document both roles can be asked is a parity case. The apps
# fixture is the queue's refusal (a repository the edge does not run) and the gate
# documents are the server's snapshot gate, which the edge does not have.
for fixture in "$fixtures"/*.json; do
    [[ $(jq -r '.kind' "$fixture") == verify ]] || continue
    [[ $(jq -r '.request.repo' "$fixture") == homelab-platform ]] || continue
    register "the fixture ${fixture##*/} gets the same verdict from both verifiers" \
        parity "$fixture"
done

@test "the parity set is every platform verify fixture and nothing else" {
    # A new fixture has to be a decision, not a silent omission from the loop
    # above: this fails until the count and the one exclusion are restated.
    local -a platform=()
    local fixture excluded=''
    for fixture in "$fixtures"/*.json; do
        [[ $(jq -r '.kind' "$fixture") == verify ]] || continue
        if [[ $(jq -r '.request.repo' "$fixture") == homelab-platform ]]; then
            platform+=("${fixture##*/}")
        else
            excluded+="${fixture##*/} "
        fi
    done
    assert_equal "${#platform[@]}" 9
    assert_equal "$excluded" "apps-verified.json "
}

@test "an absent edge tag is a hold and the commit is not switched" {
    # The same case as the fixture above, asserted on its own terms because it is
    # the one verdict the two roles do not share: the entry keeps its slot, and
    # the reason is the word the drain journals.
    local fixture=$fixtures/tag-missing.json
    start_world "$fixture"
    seed "$fixture"
    replay "$edge_verify" "$fixture" "$work/edge.out" "$work/edge.err" FAKE_BOOTC_SWITCH=ok
    assert_equal "$rc" 4
    assert_equal "$(jq -r .reason "$work/edge.out")" no-artifact
    assert_equal "$(jq -r .repo "$work/edge.out")" homelab-platform
    assert_equal "$(bootc_calls)" ""
    absent "$FAKE_BOOTC_STAGED" "an absent tag staged a boot entry"
}

@test "a bad signature is a refusal and stages nothing" {
    local fixture=$fixtures/platform-verified.json
    start_world "$fixture"
    seed "$fixture"
    replay "$edge_verify" "$fixture" "$work/edge.out" "$work/edge.err" \
        FAKE_BOOTC_SWITCH=bad-signature
    assert_equal "$rc" 3
    assert_equal "$(jq -r .verdict "$work/edge.out")" rejected
    assert_equal "$(jq -r .reason "$work/edge.out")" signature-rejected
    # bootc's own words, not a second implementation's: the verdict is the exit
    # code, and the text only tells a verdict apart from an outage.
    assert_contains "$(jq -r .detail "$work/edge.out")" "Source image rejected"
    assert_contains "$(jq -r .detail "$work/edge.out")" "@smores56 is not accepted"
    # The boot entry is what a reboot would land: bootc writes none when the
    # policy rejects the image, so a refusal here leaves the host on what it runs.
    absent "$FAKE_BOOTC_STAGED" "a refused signature staged a boot entry"
    # ... but the switch was attempted, and on the digest, not on the tag.
    assert_equal "$(bootc_calls)" \
        "switch --enforce-container-sigpolicy $edge_image@$(jq -r '.world.tag.manifest' "$fixture")"
}

@test "a switch that fails for any other reason stays retryable" {
    # A registry that answered nothing is not a verdict about the commit: exit 4
    # keeps the entry queued, where exit 3 would denylist a good image for one
    # dial timeout.
    local fixture=$fixtures/platform-verified.json
    start_world "$fixture"
    seed "$fixture"
    replay "$edge_verify" "$fixture" "$work/edge.out" "$work/edge.err" FAKE_BOOTC_SWITCH=outage
    assert_equal "$rc" 4
    assert_equal "$(jq -r .verdict "$work/edge.out")" infra-failure
    assert_equal "$(jq -r .reason "$work/edge.out")" switch-failed
    assert_contains "$(jq -r .detail "$work/edge.out")" "i/o timeout"
    absent "$FAKE_BOOTC_STAGED" "a failed switch staged a boot entry"
}

@test "a verifier with no bootc to ask is an infrastructure failure" {
    # The signature verdict cannot be inferred from a missing program, and a
    # verifier that answered "rejected" would denylist every commit on a host
    # whose bootc is not where the unit says.
    local fixture=$fixtures/platform-verified.json
    start_world "$fixture"
    seed "$fixture"
    replay "$edge_verify" "$fixture" "$work/edge.out" "$work/edge.err" BOOTC_BIN=/nonexistent/bootc
    assert_equal "$rc" 4
    assert_equal "$(jq -r .reason "$work/edge.out")" bootc-missing
}

@test "a bootstrap host is refused, exactly as the server refuses it" {
    # Nothing here is the edge's own: `bootstrap-required` is the shared answer,
    # and the edge keeps it so `edge-bootstrap` seeds the ancestor rather than the
    # first deploy guessing one.
    local fixture=$fixtures/platform-verified.json
    start_world "$fixture"
    jq -nc '{schema:1,repos:{}}' >"$state_dir/state.json"
    replay "$edge_verify" "$fixture" "$work/edge.out" "$work/edge.err" FAKE_BOOTC_SWITCH=ok
    assert_equal "$rc" 3
    assert_equal "$(jq -r .reason "$work/edge.out")" bootstrap-required
    assert_equal "$(bootc_calls)" ""
}
