#!/usr/bin/env bats
# bats file_tags=deploy
# Offline checks for the edge's post-boot gate (design #939, T7).
#
# The gate judges one deployment and has two classes of input, and the whole
# contract is which class a failure belongs to: a verdict input denylists the
# digest and rolls the host back, an infrastructure input journals, stamps
# `retry_at` and pages, and never touches the denylist. Each class has a test per
# input, and the tests are what hold the split -- a gate that rolled back for a
# dead tailnet, or held for a crashed Caddy, fails here.
#
# `bootc`, `systemctl`, `tailscale`, `getent` and `curl` are fakes on PATH, the
# records and the journal are real files in a throwaway directory, and the gate
# itself runs from an installed copy of the image tree, so the library paths it
# resolves are the ones the image gives it. No root, no reboot, no image, no
# network.
#
# The server's gate is tests/deploy/boot-gate-*.bats: same shape, a snapshot
# plane, a tenant and a GRUB counter behind it.
#
#   bats tests/deploy/edge-boot.bats
load ../helpers

source_file=bootc/edge/rootfs/usr/libexec/edge-boot-gate
lib=scripts/deploy-state.sh
unit=bootc/edge/rootfs/usr/lib/systemd/system/edge-boot-gate.service
units_file=bootc/edge/rootfs/usr/share/smoresnet/deploy-units.txt

commit=9f2c0d3b1a4e5f60718293a4b5c6d7e8f9012345
digest_index=sha256:1111111111111111111111111111111111111111111111111111111111111111
digest_manifest=sha256:2222222222222222222222222222222222222222222222222222222222222222
digest_other=sha256:3333333333333333333333333333333333333333333333333333333333333333
digests=$(jq -nc --arg i "$digest_index" --arg m "$digest_manifest" '{index:$i,manifest:$m}')
ping_url=https://hc.invalid/ping/edge
names="photos.sammohr.dev opds.sammohr.dev recovery.sammohr.dev"
host_ip=203.0.113.7

setup_file() {
    bin=$BATS_FILE_TMPDIR/bin
    image=$BATS_FILE_TMPDIR/image
    mkdir -p "$bin"
    install -D -m 0755 "$source_file" "$image/usr/libexec/edge-boot-gate"
    install -D -m 0644 scripts/lib/log.sh "$image/usr/libexec/lib/log.sh"
    install -D -m 0644 "$lib" "$image/usr/libexec/deploy-state"

    # `bootc` reports whatever the test put in its state file and logs the argv, so
    # "the booted digest is not the request" and "nothing was rolled back" are one
    # file and one log.
    cat >"$bin/bootc" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/bootc-calls"
case ${1-} in
  status)
    [[ " $* " == *" --booted "* ]] || exit 0
    [[ -z ${STUB_BOOTC_STATUS_FAIL:-} ]] || exit 1
    digest=$(sed -n 's/^booted=//p' "$STUB_BOOTC_STATE" 2>/dev/null)
    jq -nc --arg d "$digest" \
      '{status:{booted:{image:{imageDigest:(if $d == "" then null else $d end)}}}}'
    ;;
  rollback) exit "${STUB_BOOTC_ROLLBACK_EXIT:-0}" ;;
  *) exit 0 ;;
esac
STUB

    # `is-system-running` answers with the state the test names, and the unit
    # queries answer `active`/`inactive` and `failed`/`inactive` off two lists, so
    # a healthy boot is two empty files.
    cat >"$bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/systemctl-calls"
verb=${1-}
target=${2-}
case $verb in
  is-system-running)
    state=${STUB_SYSTEM_RUNNING:-running}
    printf '%s\n' "$state"
    [[ $state == running || $state == degraded ]] || exit 1
    ;;
  is-active)
    if grep -qxF -- "$target" "$STUB_SYSTEMCTL_INACTIVE" 2>/dev/null; then
      printf 'inactive\n'
      exit 3
    fi
    printf 'active\n'
    ;;
  is-failed)
    if grep -qxF -- "$target" "$STUB_SYSTEMCTL_FAILED" 2>/dev/null; then
      printf 'failed\n'
      exit 1
    fi
    printf 'inactive\n'
    exit 1
    ;;
  *) ;;
esac
exit 0
STUB

    # A sequence lets one test prove the gate retries inside its budget: the nth
    # call answers with the nth state, and the last one repeats.
    cat >"$bin/tailscale" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/tailscale-calls"
case ${1-} in
  status)
    [[ -z ${STUB_TAILSCALE_FAIL:-} ]] || exit 1
    state=${STUB_TAILSCALE_BACKEND:-Running}
    if [[ -n ${STUB_TAILSCALE_SEQUENCE:-} ]]; then
      count=$(cat "$STUB_LOG/tailscale-count" 2>/dev/null || printf 0)
      count=$((count + 1))
      printf '%s\n' "$count" >"$STUB_LOG/tailscale-count"
      state=$(tr ',' '\n' <<<"$STUB_TAILSCALE_SEQUENCE" | sed -n "${count}p")
      [[ -n $state ]] || state=$(tr ',' '\n' <<<"$STUB_TAILSCALE_SEQUENCE" | tail -n 1)
    fi
    jq -nc --arg s "$state" '{BackendState:$s}'
    ;;
  *) exit 0 ;;
esac
STUB

    # `getent ahostsv4 <name>` off a two-column file. A name with no row is
    # NXDOMAIN (exit 2, getent's own code), and the `resolver` address stands in
    # for a resolver that cannot run at all.
    cat >"$bin/getent" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/getent-calls"
name=${2-}
address=$(awk -v want="$name" '$1 == want { print $2; exit }' "$STUB_DNS_FILE" 2>/dev/null)
case ${address:-} in
  '') exit 2 ;;
  resolver) exit 1 ;;
  *) printf '%s  STREAM %s\n' "$address" "$name" ;;
esac
STUB

    # One curl for three jobs: the page (its URL arrives as a config on stdin, so
    # it never reaches argv), the loopback handshake (a status code on stdout) and
    # this host's public address (an address on stdout).
    cat >"$bin/curl" <<'STUB'
#!/usr/bin/env bash
url=
stdin_config=false
while (($#)); do
  case $1 in
    --config)
      [[ ${2-} == - ]] && stdin_config=true
      shift 2
      ;;
    --max-time | --output | --write-out) shift 2 ;;
    -*) shift ;;
    *)
      url=$1
      shift
      ;;
  esac
done
if [[ -z $url && $stdin_config == true ]]; then
  url=$(sed -n 's/^url = "\(.*\)"$/\1/p' | head -n 1)
fi
printf '%s\n' "${url:-none}" >>"$STUB_LOG/curl-urls"
case $url in
  *hc.invalid*) exit "${STUB_PING_EXIT:-0}" ;;
  *loopback.invalid*)
    printf '%s' "${STUB_LOOPBACK_CODE:-200}"
    exit "${STUB_LOOPBACK_EXIT:-0}"
    ;;
  *ip.invalid*)
    [[ -z ${STUB_PUBLIC_IPV4:-} ]] || printf '%s\n' "$STUB_PUBLIC_IPV4"
    exit "${STUB_PUBLIC_IP_EXIT:-0}"
    ;;
  *) exit 0 ;;
esac
STUB
    chmod 0755 "$bin"/*
}

# Every test starts from a host that has booted the staged deployment, is
# serving, and has landed a deployment before; the records, the marker, the logs
# and the fakes' answers are per test.
setup() {
    work=$BATS_TEST_TMPDIR
    log=$work/log
    state_dir=$work/state
    mkdir -p "$log"
    export PATH="$BATS_FILE_TMPDIR/bin:$PATH"
    export DEPLOY_STATE_DIR=$state_dir
    export DEPLOY_LOCK_FILE=$work/deploy.lock
    export DEPLOY_PING_SECRET=$work/ping-url
    export EDGE_DEPLOY_UNITS_FILE=$work/deploy-units.txt
    export EDGE_BOOT_MARKER=$work/marker.json
    export EDGE_PUBLIC_IPV4_URL=https://ip.invalid/
    export EDGE_LOOPBACK_URL=https://loopback.invalid/
    # One second of retries keeps the held cases short while still proving the
    # gate looks twice instead of deciding on the first look.
    export EDGE_BOOT_GATE_BUDGET=1 EDGE_BOOT_GATE_PAUSE=1 EDGE_RETRY_DELAY=300
    export STUB_LOG=$log
    export STUB_BOOTC_STATE=$work/bootc-state
    export STUB_SYSTEMCTL_INACTIVE=$work/inactive-units
    export STUB_SYSTEMCTL_FAILED=$work/failed-units
    export STUB_DNS_FILE=$work/dns
    # shellcheck source=/dev/null
    source "$lib"
    deploy_state_init
    reset_case
}

reset_case() {
    rm -f "$state_dir"/state.json "$state_dir"/pending.json "$state_dir"/denylist.json \
        "$state_dir"/journal.jsonl "$state_dir"/held.json
    rm -f "$EDGE_BOOT_MARKER" "$DEPLOY_PING_SECRET" "$STUB_BOOTC_STATE" \
        "$log/tailscale-count"
    : >"$log/bootc-calls"
    : >"$log/systemctl-calls"
    : >"$log/tailscale-calls"
    : >"$log/getent-calls"
    : >"$log/curl-urls"
    unset STUB_BOOTC_ROLLBACK_EXIT STUB_BOOTC_STATUS_FAIL STUB_SYSTEM_RUNNING \
        STUB_TAILSCALE_BACKEND STUB_TAILSCALE_FAIL STUB_TAILSCALE_SEQUENCE \
        STUB_LOOPBACK_CODE STUB_LOOPBACK_EXIT STUB_PUBLIC_IPV4 STUB_PUBLIC_IP_EXIT \
        STUB_PING_EXIT
    printf 'caddy.service\nfirewalld.service\nsshd.service\n' >"$EDGE_DEPLOY_UNITS_FILE"
    : >"$STUB_SYSTEMCTL_INACTIVE"
    : >"$STUB_SYSTEMCTL_FAILED"
    printf '%s\n' "$ping_url" >"$DEPLOY_PING_SECRET"
    for name in $names; do printf '%s %s\n' "$name" "$host_ip"; done >"$STUB_DNS_FILE"
    export STUB_PUBLIC_IPV4=$host_ip
    printf 'booted=%s\n' "$digest_manifest" >"$STUB_BOOTC_STATE"
    # A host that has landed a deployment before: the marker is the only thing
    # that says so, and every test that is not about a first boot starts with it.
    jq -nc --arg commit "$commit" '{schema:1,commit:$commit}' >"$EDGE_BOOT_MARKER"
}

seed_pending() { # <index> <manifest> [<commit>]
    jq -nc --arg i "$1" --arg m "$2" --arg c "${3:-$commit}" \
        '{schema:1,phase:"staged",commit:$c,digest:$i,digests:{index:$i,manifest:$m},
      stagedAt:"2026-11-20T00:00:00Z"}' | pending_write
}

run_gate() {
    rc=0
    out=$(bash "$BATS_FILE_TMPDIR/image/usr/libexec/edge-boot-gate" 2>&1) || rc=$?
}

journal_field() { # <event> <jq-path>
    jq -r "select(.event==\"$1\") | $2" "$state_dir/journal.jsonl" 2>/dev/null
}

journal_count() { # <event>
    jq -r "select(.event==\"$1\") | .event" "$state_dir/journal.jsonl" 2>/dev/null |
        wc -l | tr -d ' '
}

state_json() {
    cat "$state_dir/state.json" 2>/dev/null || printf '{}'
}

pending_json() {
    cat "$state_dir/pending.json" 2>/dev/null || printf '{}'
}

denylist_json() {
    cat "$state_dir/denylist.json" 2>/dev/null || printf '{}'
}

denied() { # <digest>
    jq -e --arg value "$1" '.digests // {} | has($value)' <<<"$(denylist_json)" >/dev/null
}

rolled_back() {
    grep -q '^rollback' "$log/bootc-calls"
}

paged() { # <suffix>
    grep -qxF -- "$ping_url$1" "$log/curl-urls"
}

# --- the healthy boot -------------------------------------------------------
# The four verdict inputs and the four infrastructure inputs all pass: the
# deployment is recorded, the host keeps it and the check goes green.
healthy_boot() {
    seed_pending "$digest_index" "$digest_manifest"
    run_gate
}

@test "a healthy boot records the deployment" {
    healthy_boot
    assert_equal "$rc" 0
    assert_equal "$(jq -r '.repos["homelab-platform"].commit' <<<"$(state_json)")" "$commit"
}

@test "a healthy boot records both digest forms" {
    healthy_boot
    assert_equal "$(jq -r '.repos["homelab-platform"].indexDigest' <<<"$(state_json)")" \
        "$digest_index"
    assert_equal "$(jq -r '.repos["homelab-platform"].manifestDigest' <<<"$(state_json)")" \
        "$digest_manifest"
}

@test "a healthy boot journals the green gate" {
    healthy_boot
    assert_equal "$(journal_field boot-gate-green '.commit')" "$commit"
}

@test "a healthy boot rewrites the landed marker with the deployment" {
    healthy_boot
    assert_equal "$(jq -r '.commit' "$EDGE_BOOT_MARKER")" "$commit"
    assert_equal "$(jq -r '.digests.index' "$EDGE_BOOT_MARKER")" "$digest_index"
}

@test "a healthy boot clears the pending record" {
    healthy_boot
    assert [ ! -e "$state_dir/pending.json" ]
}

@test "a healthy boot pages the deploy check green" {
    healthy_boot
    assert paged ''
    refute paged /fail
}

@test "a healthy boot denylists nothing and rolls nothing back" {
    healthy_boot
    assert_equal "$(denylist_json)" '{}'
    refute rolled_back
}

@test "a healthy boot says the edge has no boot counter" {
    healthy_boot
    assert_equal "$(journal_count boot-counting-absent)" 1
}

@test "a boot with no staged deployment decides nothing" {
    run_gate
    assert_equal "$rc" 0
    assert [ ! -e "$state_dir/state.json" ]
    assert_equal "$(denylist_json)" '{}'
    refute rolled_back
    refute paged /fail
}

@test "a boot whose status cannot be read decides nothing" {
    seed_pending "$digest_index" "$digest_manifest"
    export STUB_BOOTC_STATUS_FAIL=1
    run_gate
    assert_equal "$rc" 1
    assert_equal "$(denylist_json)" '{}'
    refute rolled_back
    assert paged /fail
    # The record stays, so the next boot asks the same question again.
    assert_equal "$(jq -r '.commit' <<<"$(pending_json)")" "$commit"
}

# --- verdict input: the booted digest ---------------------------------------
# The bootloader fell back, or an operator rolled back: this boot is healthy but
# it is not the deployment. Nothing is rolled back -- there is nothing to roll
# back to -- and the digest is refused from now on so the poll cannot re-stage it.
@test "a booted digest that is not the request denylists both digest forms" {
    seed_pending "$digest_index" "$digest_manifest"
    printf 'booted=%s\n' "$digest_other" >"$STUB_BOOTC_STATE"
    run_gate
    assert_equal "$rc" 0
    assert denied "$digest_index"
    assert denied "$digest_manifest"
}

@test "a booted digest that is not the request is journaled as rolled back by the bootloader" {
    seed_pending "$digest_index" "$digest_manifest"
    printf 'booted=%s\n' "$digest_other" >"$STUB_BOOTC_STATE"
    run_gate
    assert_equal "$(journal_field rolled-back-by-bootloader '.booted')" "$digest_other"
}

@test "a booted digest that is not the request consumes the record and runs no rollback" {
    seed_pending "$digest_index" "$digest_manifest"
    printf 'booted=%s\n' "$digest_other" >"$STUB_BOOTC_STATE"
    run_gate
    assert [ ! -e "$state_dir/pending.json" ]
    refute rolled_back
    assert paged /fail
    assert_equal "$(state_json)" '{}'
}

# --- verdict input: the boot finished ---------------------------------------
# `starting` is a transaction that never completed, so nothing about this boot is
# a fact: roll it back.
@test "a boot that never finished its startup is a verdict failure" {
    seed_pending "$digest_index" "$digest_manifest"
    export STUB_SYSTEM_RUNNING=starting
    run_gate
    assert_equal "$rc" 1
    assert_equal "$(journal_field boot-gate-failed '.reason')" boot-not-complete:starting
    assert denied "$digest_index"
    assert rolled_back
}

@test "a degraded boot is a finished boot" {
    # `degraded` is a completed startup with a failed unit, and which failed unit
    # matters is the deploy-critical list's question, not this one's.
    seed_pending "$digest_index" "$digest_manifest"
    export STUB_SYSTEM_RUNNING=degraded
    run_gate
    assert_equal "$rc" 0
    assert_equal "$(journal_field boot-gate-green '.commit')" "$commit"
}

# --- verdict input: the deploy-critical units -------------------------------
@test "an inactive deploy-critical unit denylists and rolls back" {
    seed_pending "$digest_index" "$digest_manifest"
    printf 'caddy.service\n' >"$STUB_SYSTEMCTL_INACTIVE"
    run_gate
    assert_equal "$rc" 1
    assert_equal "$(journal_field boot-gate-failed '.reason')" unit-inactive:caddy.service
    assert denied "$digest_index"
    assert denied "$digest_manifest"
    assert rolled_back
    assert paged /fail
}

@test "a failed deploy-critical unit denylists and rolls back" {
    seed_pending "$digest_index" "$digest_manifest"
    printf 'sshd.service\n' >"$STUB_SYSTEMCTL_FAILED"
    run_gate
    assert_equal "$(journal_field boot-gate-failed '.reason')" unit-failed:sshd.service
    assert denied "$digest_index"
    assert rolled_back
}

@test "a unit that is not deploy-critical is not the gate's business" {
    seed_pending "$digest_index" "$digest_manifest"
    printf 'wireguard.service\n' >"$STUB_SYSTEMCTL_INACTIVE"
    printf 'unrelated.service\n' >"$STUB_SYSTEMCTL_FAILED"
    run_gate
    assert_equal "$rc" 0
    refute rolled_back
}

@test "the shipped deploy-critical list is caddy, firewalld and sshd" {
    run grep -h -v '^#' "$units_file"
    assert_success
    assert_output --partial 'caddy.service'
    assert_output --partial 'firewalld.service'
    assert_output --partial 'sshd.service'
}

@test "the gate reads the list the image ships" {
    unset EDGE_DEPLOY_UNITS_FILE
    export EDGE_DEPLOY_UNITS_FILE=$repo_root/$units_file
    seed_pending "$digest_index" "$digest_manifest"
    printf 'firewalld.service\n' >"$STUB_SYSTEMCTL_INACTIVE"
    run_gate
    assert_equal "$(journal_field boot-gate-failed '.reason')" unit-inactive:firewalld.service
}

@test "an unreadable deploy-critical list is a verdict failure" {
    export EDGE_DEPLOY_UNITS_FILE=$work/no-such-list.txt
    seed_pending "$digest_index" "$digest_manifest"
    run_gate
    assert_equal "$(journal_field boot-gate-failed '.reason')" units-file-missing
    assert rolled_back
}

# --- verdict input: the landed record ---------------------------------------
# A record state.json does not hold is a host that would poll for the same commit
# for ever and report healthy on property it does not have.
@test "a landed record that cannot be written is a verdict failure" {
    seed_pending "$digest_index" "$digest_manifest"
    # atomic_write renames onto the record, so a directory at that name is a write
    # that fails the way a read-only /var does.
    mkdir -p "$state_dir/state.json"
    run_gate
    assert_equal "$rc" 1
    assert_equal "$(journal_field boot-gate-failed '.reason')" landed-record
    assert denied "$digest_index"
    assert rolled_back
}

# --- infrastructure input: the tailnet --------------------------------------
# The split is the point: a tailnet that is down is a box that cannot be served,
# and the image being deployed did not break it. Hold, page, stamp -- never deny.
hold_tailscaled() {
    seed_pending "$digest_index" "$digest_manifest"
    export STUB_TAILSCALE_BACKEND=Stopped
    run_gate
}

@test "a tailscale backend that is not Running holds the boot" {
    hold_tailscaled
    assert_equal "$rc" 1
    assert_equal "$(journal_field deploy-held '.reason')" infra-tailscaled
    assert_equal "$(journal_field deploy-held '.detail')" 'the tailscale backend is Stopped, not Running'
}

@test "a tailscale hold denylists nothing and rolls nothing back" {
    hold_tailscaled
    assert_equal "$(denylist_json)" '{}'
    refute rolled_back
}

@test "a tailscale hold stamps retry_at on the pending record" {
    now=$(date +%s)
    hold_tailscaled
    retry_at=$(jq -r '.retry_at' <<<"$(pending_json)")
    [[ $retry_at =~ ^[0-9]+$ ]] || fail "retry_at is '${retry_at}'"
    ((retry_at >= now + 250 && retry_at <= now + 400)) ||
        fail "retry_at=$retry_at is not now+300"
    assert_equal "$(jq -r '.deferred' <<<"$(pending_json)")" infra-tailscaled
    assert_equal "$(jq -r '.attempts' <<<"$(pending_json)")" 1
}

@test "a tailscale hold keeps the pending record and writes no landed record" {
    hold_tailscaled
    assert_equal "$(jq -r '.commit' <<<"$(pending_json)")" "$commit"
    assert [ ! -e "$state_dir/state.json" ]
}

@test "a tailscale hold pages once and journals the hold" {
    hold_tailscaled
    assert paged /fail
    assert_equal "$(journal_count deploy-held)" 1
    assert_equal "$(journal_count boot-gate-green)" 0
    assert_equal "$(journal_count boot-gate-failed)" 0
}

@test "an infrastructure input is retried inside the budget instead of holding at once" {
    seed_pending "$digest_index" "$digest_manifest"
    export STUB_TAILSCALE_SEQUENCE=NoState,Running
    export EDGE_BOOT_GATE_BUDGET=5
    run_gate
    assert_equal "$rc" 0
    assert_equal "$(journal_field boot-gate-green '.commit')" "$commit"
}

# --- infrastructure input: DNS ---------------------------------------------
@test "a public name that does not resolve holds the boot" {
    seed_pending "$digest_index" "$digest_manifest"
    # Drop the third name: the gate must notice the missing one, not the two that
    # answered.
    printf 'photos.sammohr.dev %s\nopds.sammohr.dev %s\n' "$host_ip" "$host_ip" >"$STUB_DNS_FILE"
    run_gate
    assert_equal "$rc" 1
    assert_equal "$(journal_field deploy-held '.reason')" infra-dns
    assert_equal "$(journal_field deploy-held '.detail')" 'recovery.sammohr.dev does not resolve'
    assert_equal "$(denylist_json)" '{}'
    refute rolled_back
}

@test "a host with no resolver holds under its own reason" {
    seed_pending "$digest_index" "$digest_manifest"
    printf 'photos.sammohr.dev resolver\n' >"$STUB_DNS_FILE"
    run_gate
    assert_equal "$(journal_field deploy-held '.reason')" infra-dns
    assert_equal "$(journal_field deploy-held '.detail')" 'no resolver ran for photos.sammohr.dev'
}

# --- infrastructure input: the loopback handshake ---------------------------
@test "no TLS answer on loopback holds the boot" {
    seed_pending "$digest_index" "$digest_manifest"
    export STUB_LOOPBACK_EXIT=7
    run_gate
    assert_equal "$rc" 1
    assert_equal "$(journal_field deploy-held '.reason')" infra-loopback
    assert_equal "$(denylist_json)" '{}'
    refute rolled_back
    assert paged /fail
}

@test "an upstream answer on loopback is a completed handshake" {
    # 502 is an upstream's problem: Caddy answered, so the handshake is proven and
    # the deployment is not refused for it.
    seed_pending "$digest_index" "$digest_manifest"
    export STUB_LOOPBACK_CODE=502
    run_gate
    assert_equal "$rc" 0
}

# --- infrastructure input: the public address -------------------------------
@test "a public address that is not the names' address holds the boot" {
    seed_pending "$digest_index" "$digest_manifest"
    export STUB_PUBLIC_IPV4=198.51.100.9
    run_gate
    assert_equal "$rc" 1
    assert_equal "$(journal_field deploy-held '.reason')" infra-public-ipv4
    assert_equal "$(journal_field deploy-held '.detail')" \
        "photos.sammohr.dev resolves to $host_ip, and this host is 198.51.100.9"
    assert_equal "$(denylist_json)" '{}'
    refute rolled_back
}

@test "an unreadable public address holds the boot" {
    seed_pending "$digest_index" "$digest_manifest"
    export STUB_PUBLIC_IP_EXIT=22
    run_gate
    assert_equal "$(journal_field deploy-held '.reason')" infra-public-ipv4
    assert_equal "$(journal_field deploy-held '.detail')" \
        "cannot read this host's public address from https://ip.invalid/"
}

@test "the verdict inputs are judged before the infrastructure" {
    # A crashed Caddy and a dead tailnet together: the commit is the reason, so
    # the digest is refused and the host rolls back, and no hold is written.
    seed_pending "$digest_index" "$digest_manifest"
    printf 'caddy.service\n' >"$STUB_SYSTEMCTL_INACTIVE"
    export STUB_TAILSCALE_BACKEND=NoState
    run_gate
    assert denied "$digest_index"
    assert rolled_back
    assert_equal "$(journal_count deploy-held)" 0
}

# --- the first boot ---------------------------------------------------------
# A host with no landed record in /var: an install or a reinstall. Nothing here
# can say the running deployment is worse than the one it replaced, so nothing is
# denied and nothing rolls back -- one alert, one marker, and the next boot
# decides.
first_boot() {
    rm -f "$EDGE_BOOT_MARKER"
    seed_pending "$digest_index" "$digest_manifest"
    run_gate
}

@test "a first boot alerts and holds" {
    first_boot
    assert_equal "$rc" 1
    assert_equal "$(journal_field deploy-held '.reason')" first-boot
    assert paged /fail
    assert_equal "$(denylist_json)" '{}'
    refute rolled_back
    assert_equal "$(state_json)" '{}'
}

@test "a first boot keeps the pending record for the next boot" {
    first_boot
    assert_equal "$(jq -r '.commit' <<<"$(pending_json)")" "$commit"
}

@test "a first boot writes the marker so the hold is one boot" {
    first_boot
    assert [ -s "$EDGE_BOOT_MARKER" ]
    assert_equal "$(jq -r '.digests.index' "$EDGE_BOOT_MARKER")" "$digest_manifest"
}

@test "the boot after a first boot decides normally" {
    first_boot
    run_gate
    assert_equal "$rc" 0
    assert_equal "$(journal_field boot-gate-green '.commit')" "$commit"
    assert_equal "$(jq -r '.repos["homelab-platform"].commit' <<<"$(state_json)")" "$commit"
}

@test "a first boot with no staged deployment still alerts" {
    rm -f "$EDGE_BOOT_MARKER"
    run_gate
    assert_equal "$rc" 1
    assert_equal "$(journal_field deploy-held '.reason')" first-boot
    assert paged /fail
    refute rolled_back
}

# --- the unit ---------------------------------------------------------------
@test "the shipped unit runs the shipped program and waits for the boot" {
    for line in 'ExecStart=/usr/libexec/edge-boot-gate' 'Before=boot-complete.target' \
        'After=multi-user.target' 'ReadWritePaths=/var/lib/smoresnet'; do
        grep -qF -- "$line" "$unit" || fail "$unit is missing: $line"
    done
}
