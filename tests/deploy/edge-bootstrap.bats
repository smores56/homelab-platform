#!/usr/bin/env bats
# bats file_tags=deploy
# Offline checks for the one operator step on a fresh edge (design #939, T10).
#
# The image is the whole host, so this script is what an image may not carry: the
# operator's Caddy values, the two plaintext secrets, the kit's SSH host key, the
# tailnet node ID and the first deploy record. Every path it writes is redirected
# into the test's own tree, `systemctl`, `caddy`, `bootc`, `tailscale`, `ostree`
# and `id` are fakes on PATH, and the host key is a real key pair the test
# generates -- so no test needs root, a tailnet or a bootc host.
#
#   bats tests/deploy/edge-bootstrap.bats
load ../helpers

script=scripts/edge-bootstrap.sh
commit=0123456789abcdef0123456789abcdef01234567
other_commit=89abcdef0123456789abcdef0123456789abcdef
digest=sha256:1111111111111111111111111111111111111111111111111111111111111111
other_digest=sha256:2222222222222222222222222222222222222222222222222222222222222222
node_id=nAbCdEf123CNTRL
authkey=tskey-auth-kTestKeyCNTRL-abcdefghijklmnop
ping_url=https://hc.invalid/ping/edge

# The fakes record what they were asked to do, and the `systemctl` one records
# whether the auth key existed at that moment: the join unit reads that file as a
# credential, so a start that ran before the write would enroll with nothing.
setup_file() {
    bin=$BATS_FILE_TMPDIR/bin
    mkdir -p "$bin"
    cat >"$bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s auth=%s\n' "$*" \
  "$([[ -s ${FAKE_AUTHKEY:-/nonexistent} ]] && echo yes || echo no)" >>"$FAKE_LOG/systemctl-calls"
exit "${STUB_SYSTEMCTL_EXIT:-0}"
STUB
    cat >"$bin/caddy" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG/caddy-calls"
printf '%s\n' "${EDGE_ACME_EMAIL:-}" "${IMMICH_UPSTREAM:-}" \
  >>"$FAKE_LOG/caddy-env"
exit "${STUB_CADDY_EXIT:-0}"
STUB
    # One document per host fact, read from a file so a test can change the host
    # between two runs without touching the script.
    cat >"$bin/bootc" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG/bootc-calls"
cat "${FAKE_BOOTC_DOC:?}"
STUB
    cat >"$bin/ostree" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG/ostree-calls"
cat "${FAKE_OSTREE_METADATA:?}"
STUB
    cat >"$bin/tailscale" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG/tailscale-calls"
cat "${FAKE_TAILSCALE_DOC:?}"
STUB
    # The uid is read with `id -u`, so two fakes decide who runs the script.
    mkdir -p "$BATS_FILE_TMPDIR/uid0" "$BATS_FILE_TMPDIR/nonroot"
    printf '#!/usr/bin/env bash\nprintf "0\\n"\n' >"$BATS_FILE_TMPDIR/uid0/id"
    printf '#!/usr/bin/env bash\nprintf "1000\\n"\n' >"$BATS_FILE_TMPDIR/nonroot/id"
    chmod 0755 "$bin"/* "$BATS_FILE_TMPDIR/uid0/id" "$BATS_FILE_TMPDIR/nonroot/id"
    # A kit pair ssh-keygen itself made: the derivation the script checks is the
    # real one, not a fixture that assumes it.
    install -d -m 0700 "$BATS_FILE_TMPDIR/kit"
    ssh-keygen -q -t ed25519 -N '' -C kit -f "$BATS_FILE_TMPDIR/kit/ssh_host_ed25519_key"
}

setup() {
    work=$BATS_TEST_TMPDIR
    log=$work/log
    mkdir -p "$log"
    export FAKE_LOG=$log
    export DEPLOY_STATE_DIR=$work/deploy-state
    export DEPLOY_LOCK_FILE=$work/deploy.lock
    export DEPLOY_SECRETS_DIR=$work/etc/smoresnet
    export EDGE_STATE_DIR=$work/var/lib/smoresnet
    export EDGE_CADDY_DIR=$work/etc/caddy
    export EDGE_CADDY_CONFIG=$work/usr/share/smoresnet/Caddyfile
    export EDGE_SSH_DIR=$work/etc/ssh
    export EDGE_CADDY_GROUP EDGE_CADDY_USER EDGE_CADDY_HOME
    EDGE_CADDY_GROUP=$(id -gn)
    EDGE_CADDY_USER=$(id -un)
    EDGE_CADDY_HOME=$work/var/lib/caddy
    # A tailnet that is up is the normal case; a test that wants it down says so
    # by rewriting the document, and no test waits for the retry budget.
    export EDGE_TAILNET_WAIT=0
    export SMORTRESS_FQDN=smortress.stonecat-jazz.ts.net
    export EDGE_ACME_EMAIL=ops@example.com
    export FAKE_AUTHKEY=$DEPLOY_SECRETS_DIR/tailscale-authkey
    export FAKE_BOOTC_DOC=$work/bootc.json
    export FAKE_OSTREE_METADATA=$work/image-config.json
    export FAKE_TAILSCALE_DOC=$work/tailscale.json
    kit_key=$BATS_FILE_TMPDIR/kit/ssh_host_ed25519_key
    : >"$log/systemctl-calls"
    : >"$log/caddy-calls"
    : >"$log/caddy-env"
    : >"$log/bootc-calls"
    : >"$log/ostree-calls"
    : >"$log/tailscale-calls"
    bootc_doc "$commit" "$digest"
    revision_doc "$commit"
    tailscale_doc Running "$node_id"
}

bootc_doc() { # <commit> <digest>: what `bootc status --booted --json` reports
    # The ostree checksum is what the revision label is read through, so it is
    # derived from the commit: one document, one identity.
    jq -nc --arg d "$2" --arg c "ostree-$1" \
        '{status:{booted:{image:{imageDigest:$d},ostree:{checksum:$c}}}}' >"$FAKE_BOOTC_DOC"
}

revision_doc() { # <commit>|'': the image config ostree prints for that checksum
    # ostree prints the metadata value as the JSON string it holds.
    jq -nc --arg c "$1" \
        '{architecture:"amd64",config:{Labels:{"org.opencontainers.image.revision":$c}}}
         | if $c == "" then .config.Labels = {} else . end' |
        jq -Rs . >"$FAKE_OSTREE_METADATA"
}

tailscale_doc() { # <backend-state> <node-id>
    jq -nc --arg s "$1" --arg id "$2" \
        '{BackendState:$s,Self:{ID:$id,HostName:"smoresnet"}}' >"$FAKE_TAILSCALE_DOC"
}

standard_document() {
    cat <<EOF
TS_AUTHKEY=$authkey
DEPLOY_PING_URL=$ping_url
EOF
}

# bootstrap <document> [args...]; the uid is the fake's answer, so the refusal
# and the happy path run the same code.
bootstrap() {
    local doc=$1 ids=$BATS_FILE_TMPDIR/uid0
    shift
    if [[ ${1-} == --as-nonroot ]]; then
        ids=$BATS_FILE_TMPDIR/nonroot
        shift
    fi
    rc=0
    out=$(printf '%s\n' "$doc" |
        PATH="$ids:$BATS_FILE_TMPDIR/bin:$PATH" bash "$script" "$@" 2>&1) || rc=$?
}

run_ok() { # <document> [args...]
    bootstrap "$@"
    assert_equal "$rc" 0
}

mode_of() { stat -c %a "$1"; }
group_of() { stat -c %G "$1"; }

wrote_nothing() {
    assert [ ! -e "$DEPLOY_SECRETS_DIR" ]
    assert [ ! -e "$EDGE_CADDY_DIR/edge.env" ]
    assert [ ! -e "$EDGE_SSH_DIR" ]
    assert_equal "$(cat "$log/systemctl-calls")" ""
}

# --- the two facts it refuses to guess ------------------------------------

@test "a non-root caller is refused before anything is written" {
    bootstrap "$(standard_document)" --as-nonroot --host-key "$kit_key"
    assert_not_equal "$rc" 0
    assert_contains "$out" "run as root"
    wrote_nothing
}

@test "a FQDN with no tailnet domain is refused" {
    SMORTRESS_FQDN=smoresnet bootstrap "$(standard_document)" --host-key "$kit_key"
    assert_not_equal "$rc" 0
    assert_contains "$out" "SMORTRESS_FQDN 'smoresnet' has no tailnet domain"
    wrote_nothing
}

@test "a missing EDGE_ACME_EMAIL is refused" {
    EDGE_ACME_EMAIL='' bootstrap "$(standard_document)" --host-key "$kit_key"
    assert_not_equal "$rc" 0
    assert_contains "$out" "set EDGE_ACME_EMAIL"
    wrote_nothing
}

# --- the Caddy environment file -------------------------------------------

@test "edge.env carries the three upstreams derived from the tailnet domain" {
    run_ok "$(standard_document)" --host-key "$kit_key"
    assert_equal "$(sed -n 's/^IMMICH_UPSTREAM=//p' "$EDGE_CADDY_DIR/edge.env")" \
        https://immich.stonecat-jazz.ts.net
    assert_equal "$(sed -n 's/^OPDS_UPSTREAM=//p' "$EDGE_CADDY_DIR/edge.env")" \
        https://opds.stonecat-jazz.ts.net
    assert_equal "$(sed -n 's/^RECOVERY_UPSTREAM=//p' "$EDGE_CADDY_DIR/edge.env")" \
        https://recovery.stonecat-jazz.ts.net
    assert_equal "$(sed -n 's/^SMORTRESS_FQDN=//p' "$EDGE_CADDY_DIR/edge.env")" \
        smortress.stonecat-jazz.ts.net
    assert_equal "$(sed -n 's/^EDGE_ACME_EMAIL=//p' "$EDGE_CADDY_DIR/edge.env")" \
        ops@example.com
}

# caddy.service runs as User=caddy and reads the file through EnvironmentFile,
# so the mode and the group are the difference between a proxy that starts and one
# that cannot read its own configuration.
@test "edge.env is 0640 root:caddy" {
    assert grep -qF 'EDGE_CADDY_GROUP:-caddy' "$script"
    run_ok "$(standard_document)" --host-key "$kit_key"
    assert_equal "$(mode_of "$EDGE_CADDY_DIR/edge.env")" 640
    assert_equal "$(group_of "$EDGE_CADDY_DIR/edge.env")" "$EDGE_CADDY_GROUP"
}

@test "caddy validates the new values before the file they live in is replaced" {
    STUB_CADDY_EXIT=1 bootstrap "$(standard_document)" --host-key "$kit_key"
    assert_not_equal "$rc" 0
    assert_contains "$out" "refused $EDGE_CADDY_CONFIG"
    assert [ ! -e "$EDGE_CADDY_DIR/edge.env" ]
    run grep -q '^restart caddy ' "$log/systemctl-calls"
    assert_failure
}

@test "the validated values are the ones about to be installed" {
    run_ok "$(standard_document)" --host-key "$kit_key"
    assert grep -qx 'ops@example.com' "$log/caddy-env"
    assert grep -qx 'https://immich.stonecat-jazz.ts.net' "$log/caddy-env"
    assert grep -qx 'validate --config '"$EDGE_CADDY_CONFIG"' --adapter caddyfile' "$log/caddy-calls"
}

# --- the secrets on stdin -------------------------------------------------

@test "a key that is not tskey-shaped is refused before anything is written" {
    bootstrap "$(standard_document | sed 's/^TS_AUTHKEY=.*/TS_AUTHKEY=not-a-key/')" \
        --host-key "$kit_key"
    assert_not_equal "$rc" 0
    assert_contains "$out" "TS_AUTHKEY is not a tailnet auth key"
    wrote_nothing
}

@test "the document never reaches argv" {
    run_ok "$(standard_document)" --host-key "$kit_key"
    # Every program the script ran was told an argument or a file, never a secret:
    # the fake logs its argv, and the secret is in none of them.
    run grep -rqF -- "$authkey" "$log"
    assert_failure
    run grep -rqF -- "$ping_url" "$log"
    assert_failure
}

@test "both secrets are written 0600" {
    run_ok "$(standard_document)" --host-key "$kit_key"
    assert_equal "$(mode_of "$DEPLOY_SECRETS_DIR/tailscale-authkey")" 600
    assert_equal "$(mode_of "$DEPLOY_SECRETS_DIR/deploy-ping-url")" 600
    assert_equal "$(mode_of "$DEPLOY_SECRETS_DIR")" 700
}

# The auth key is bare because `tailscale up` reads the file as a credential; the
# ping URL is bare because deploy_notify takes the first non-empty line as the URL
# itself. Neither is a YAML document, and a webhook secret is no key this step
# knows any more (#1018).
@test "each secret is written in the shape its reader parses" {
    run_ok "$(standard_document)" --host-key "$kit_key"
    # shellcheck disable=SC2016 # the pattern is the file's literal content
    assert_equal "$(cat "$DEPLOY_SECRETS_DIR/tailscale-authkey")" "$authkey"
    assert_equal "$(cat "$DEPLOY_SECRETS_DIR/deploy-ping-url")" "$ping_url"
    assert [ ! -e "$DEPLOY_SECRETS_DIR/webhook-secret.yaml" ]
}

@test "a secret already written is left alone by a re-run" {
    run_ok "$(standard_document)" --host-key "$kit_key"
    run_ok "$(standard_document)" --host-key "$kit_key"
    assert_contains "$out" "already holds this value; left alone"
}

# Rotation is the one thing --force exists for: a different value for a file this
# step already wrote.
@test "a different secret is refused without --force" {
    run_ok "$(standard_document)" --host-key "$kit_key"
    bootstrap "$(standard_document | sed 's|^DEPLOY_PING_URL=.*|DEPLOY_PING_URL=https://hc.invalid/ping/other|')" \
        --host-key "$kit_key"
    assert_not_equal "$rc" 0
    assert_contains "$out" "--force rotates a secret"
    assert_equal "$(cat "$DEPLOY_SECRETS_DIR/deploy-ping-url")" "$ping_url"
}

@test "--force rotates a secret this step already wrote" {
    run_ok "$(standard_document)" --host-key "$kit_key"
    run_ok "$(standard_document | sed 's|^DEPLOY_PING_URL=.*|DEPLOY_PING_URL=https://hc.invalid/ping/other|')" \
        --force --host-key "$kit_key"
    assert_equal "$(cat "$DEPLOY_SECRETS_DIR/deploy-ping-url")" https://hc.invalid/ping/other
}

@test "a secret the document omits is refused when there is no file to keep" {
    bootstrap "$(printf 'TS_AUTHKEY=%s\n' "$authkey")" --host-key "$kit_key"
    assert_not_equal "$rc" 0
    assert_contains "$out" "stdin is missing DEPLOY_PING_URL"
    wrote_nothing
}

# A retired key is not a key this step keeps: WEBHOOK_SECRET left with the
# receiver (#1018), and an operator re-running an old document must be told.
@test "the retired webhook keys are refused by name" {
    bootstrap "$(standard_document)$(printf '\nWEBHOOK_SECRET=deadbeef\n')" --host-key "$kit_key"
    assert_not_equal "$rc" 0
    assert_contains "$out" "'WEBHOOK_SECRET' is not one of"
    wrote_nothing
}

# An empty value is a paste that lost its value, and it is refused rather than
# read as "keep what is there": omitting the line is how a re-run keeps it.
@test "a blank secret is refused and no value is echoed" {
    bootstrap "$(standard_document | sed 's|^DEPLOY_PING_URL=.*|DEPLOY_PING_URL=|')" \
        --host-key "$kit_key"
    assert_not_equal "$rc" 0
    assert_contains "$out" "DEPLOY_PING_URL is blank"
    wrote_nothing
    bootstrap "$(printf '%s\n' "$authkey")" --host-key "$kit_key"
    assert_not_equal "$rc" 0
    assert_contains "$out" "a stdin line is not KEY=value"
    [[ $out != *"$authkey"* ]] || fail "the refused line was echoed"
}

@test "an unknown or repeated stdin key is refused" {
    bootstrap "$(printf 'TS_AUTHKEY=%s\nWHATEVER=1\n' "$authkey")" \
        --host-key "$kit_key"
    assert_not_equal "$rc" 0
    assert_contains "$out" "'WHATEVER' is not one of"
    bootstrap "$(printf 'TS_AUTHKEY=%s\nTS_AUTHKEY=tskey-auth-x-y\n' "$authkey")" \
        --host-key "$kit_key"
    assert_not_equal "$rc" 0
    assert_contains "$out" "TS_AUTHKEY appears twice"
}

# --- the join unit reads the key before it runs ---------------------------

@test "the join unit is started only after the key it reads exists" {
    run_ok "$(standard_document)" --host-key "$kit_key"
    assert grep -qx 'start smoresnet-tailscale-up.service auth=yes' "$log/systemctl-calls"
}

# --- the kit host key -----------------------------------------------------

@test "a kit host key that does not match its public key is refused" {
    install -d -m 0700 "$work/kit"
    cp "$kit_key" "$work/kit/ssh_host_ed25519_key"
    # A pair drawn from a different key: the two halves of the kit disagree, so a
    # client's known_hosts entry would pin an identity the kit does not name.
    ssh-keygen -q -t ed25519 -N '' -C other -f "$work/other"
    install -m 0600 "$work/other.pub" "$work/kit/ssh_host_ed25519_key.pub"
    bootstrap "$(standard_document)" --host-key "$work/kit/ssh_host_ed25519_key"
    assert_not_equal "$rc" 0
    assert_contains "$out" "does not match the public key"
    assert [ ! -e "$EDGE_SSH_DIR/ssh_host_ed25519_key" ]
    run grep -q '^restart sshd ' "$log/systemctl-calls"
    assert_failure
}

@test "the kit host key is installed at the standard paths and sshd restarted" {
    run_ok "$(standard_document)" --host-key "$kit_key"
    assert_equal "$(mode_of "$EDGE_SSH_DIR/ssh_host_ed25519_key")" 600
    assert_equal "$(mode_of "$EDGE_SSH_DIR/ssh_host_ed25519_key.pub")" 644
    cmp -s "$kit_key" "$EDGE_SSH_DIR/ssh_host_ed25519_key"
    assert_equal "$(awk '{ print $1" "$2 }' "$EDGE_SSH_DIR/ssh_host_ed25519_key.pub")" \
        "$(ssh-keygen -y -f "$kit_key" </dev/null | awk '{ print $1" "$2 }')"
    assert grep -q '^restart sshd ' "$log/systemctl-calls"
    assert grep -q '^restart caddy ' "$log/systemctl-calls"
}

@test "no --host-key keeps what sshd generated" {
    # The edge's identity is the machine's own: logins arrive over the tailnet,
    # whose node key authenticates the host, and the pre-join window is minutes of
    # key-only sshd. A copy of the key in a recovery kit bought a stable
    # known_hosts line and cost a credential to fetch and rotate.
    run_ok "$(standard_document)"
    assert_contains "$out" "keeping the host key sshd generated"
    refute grep -qF 'restart sshd' "$log/systemctl-calls"
    [[ ! -e $EDGE_SSH_DIR/ssh_host_ed25519_key ]] ||
        fail 'the bootstrap installed a host key nobody gave it'
}

@test "--host-key names a path that must exist" {
    bootstrap "$(standard_document)" --host-key "$work/absent"
    assert_not_equal "$rc" 0
    assert_contains "$out" "no host key at $work/absent"
}

# --- the tailnet node identity --------------------------------------------

@test "the node ID is pinned from Self.ID, never from the name" {
    run_ok "$(standard_document)" --host-key "$kit_key"
    assert_equal "$(cat "$EDGE_STATE_DIR/tailnet-node-id")" "$node_id"
    assert_equal "$(mode_of "$EDGE_STATE_DIR/tailnet-node-id")" 600
}

@test "a tailnet that is not up is a refusal, not a silent skip" {
    tailscale_doc NeedsLogin ''
    bootstrap "$(standard_document)" --host-key "$kit_key"
    assert_not_equal "$rc" 0
    assert_contains "$out" "the tailnet is not up (NeedsLogin)"
    assert [ ! -e "$EDGE_STATE_DIR/tailnet-node-id" ]
}

# --- the deploy record ----------------------------------------------------

@test "state.json records the booted commit and digest once" {
    run_ok "$(standard_document)" --host-key "$kit_key"
    assert_equal "$(jq -r '.repos["homelab-platform"].commit' "$DEPLOY_STATE_DIR/state.json")" \
        "$commit"
    assert_equal "$(jq -r '.repos["homelab-platform"].manifestDigest' "$DEPLOY_STATE_DIR/state.json")" \
        "$digest"
    # Both forms are not known here: bootc reports the digest it fetched.
    assert_equal "$(jq -r '.repos["homelab-platform"].indexDigest // ""' "$DEPLOY_STATE_DIR/state.json")" \
        ''
    assert_equal "$(jq -r 'select(.event=="bootstrap-recorded") | .commit' "$DEPLOY_STATE_DIR/journal.jsonl")" \
        "$commit"
}

@test "a re-run never overwrites the record" {
    run_ok "$(standard_document)" --host-key "$kit_key"
    first=$(cat "$DEPLOY_STATE_DIR/state.json")
    # The box now boots something else: the record is the descendancy anchor
    # every later deploy is checked against, so it stays where it is.
    bootc_doc "$other_commit" "$other_digest"
    revision_doc "$other_commit"
    run_ok "$(standard_document)" --host-key "$kit_key"
    assert_contains "$out" "already records homelab-platform at $commit; left alone"
    assert_contains "$out" "this host booted $other_commit, not $commit"
    assert_equal "$(cat "$DEPLOY_STATE_DIR/state.json")" "$first"
    assert_equal "$(grep -c '"event":"state-verified"' "$DEPLOY_STATE_DIR/journal.jsonl")" 1
}

# The commit is the one value bootc's own JSON does not carry: it is the revision
# label inside the image config, so a host whose image has none says so instead of
# recording a digest as a commit.
@test "a host with no revision label refuses without --commit" {
    revision_doc ''
    bootstrap "$(standard_document)" --host-key "$kit_key"
    assert_not_equal "$rc" 0
    assert_contains "$out" "re-run with --commit <40-hex>"
    assert [ ! -e "$DEPLOY_STATE_DIR/state.json" ]
}

@test "--commit records the commit the operator read off the published image" {
    revision_doc ''
    run_ok "$(standard_document)" --host-key "$kit_key" --commit "$commit"
    assert_equal "$(jq -r '.repos["homelab-platform"].commit' "$DEPLOY_STATE_DIR/state.json")" \
        "$commit"
}

@test "a --commit that is not a 40-hex sha is refused" {
    bootstrap "$(standard_document)" --host-key "$kit_key" --commit abc123
    assert_not_equal "$rc" 0
    assert_contains "$out" "--commit takes the 40-character commit"
    wrote_nothing
}

# --- what it leaves the operator ------------------------------------------

@test "the summary names the probe and the tofu ordering" {
    run_ok "$(standard_document)" --host-key "$kit_key"
    assert_contains "$out" "scripts/verify-fleet.sh"
    assert_contains "$out" "tofu/terraform.tfvars"
}

@test "Caddy's home exists before the service is restarted" {
    # The package's User=caddy cannot create /var/lib/caddy, and a Caddy without
    # it serves nothing: every order fails with `mkdir /var/lib/caddy: permission
    # denied` and every name answers 500. The image does not ship the directory,
    # so this step is where it comes from.
    bootstrap "$(standard_document)"
    [[ -d $EDGE_CADDY_HOME ]] || fail "the bootstrap did not create $EDGE_CADDY_HOME"
    assert_equal "$(stat -c '%a' "$EDGE_CADDY_HOME")" 750
    assert_equal "$(stat -c '%U:%G' "$EDGE_CADDY_HOME")" "$EDGE_CADDY_USER:$EDGE_CADDY_GROUP"
    # And it happened before the restart: a directory created afterwards would
    # leave the first start failing and the test green.
    assert grep -qF 'restart caddy' "$log/systemctl-calls"
}
