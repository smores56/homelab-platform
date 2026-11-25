#!/usr/bin/env bats
# bats file_tags=deploy
# Offline checks for the apps apply and its revert (SDLC #798, T5).
#
# An apps deploy has no reboot, so the whole safety story is in one program: fetch
# a verified commit, validate and render it, snapshot what is installed, write the
# crash record, pull every changed image, install the plan before the quota
# applier reads it, do the tenant-side units/secrets/ingress, commit, and only
# then regenerate Serve. Any failure before the commit puts the previous plan,
# units, secret values and state back; a Serve failure after it does not.
#
# The real renderer runs against fixture tenants. `curl`, `sops`, `podman`,
# `runuser`, `systemctl` and `df` are fakes on PATH, and the state, the tenant
# home and the plan are throwaway paths; the rendered units, the plan, the
# records, the journal and the command lines are real. The drain and the boot
# gate run their real scripts for the interrupted-apply cases, with this same
# deploy-apps as their child. No root, no image, no network.
#
# This file is §1-§16 of the suite that was tests/deploy/apps.sh. A test carries
# one name, so §1-§4 are one test with the shell suite's texts riding along as
# assertion labels, and §11/§11b keep the interrupted-apply tree they stage and
# the aftermath they read in one test each. Where the old suite gave two checks
# the same text (§9 and §9c, §9b and §9j), the second name carries its section.
#
#   bats tests/deploy/apps.bats
load ../helpers

apps=scripts/deploy-apps.sh
schema=scripts/apps-schema.py
lib=scripts/deploy-state.sh
drain=scripts/deploy-drain.sh
gate=scripts/smortress-boot-gate.sh
ping_url=https://hc.invalid/ping/abc

# The fakes, the published commits and the published tarballs are the same for
# every test, so they are built once for the file under $BATS_FILE_TMPDIR and
# read-only afterwards; each test's own tree is under $BATS_TEST_TMPDIR.
setup_file() {
    bin=$BATS_FILE_TMPDIR/bin
    trees=$BATS_FILE_TMPDIR/trees
    fetch_dir=$BATS_FILE_TMPDIR/fetch
    mkdir -p "$bin" "$trees" "$fetch_dir"
    install_fakes "$bin"
    build_fixtures
}

setup() {
    for file in "$apps" "$schema" "$lib" "$drain" "$gate"; do
        [[ -r $file ]] || fail "$file is missing"
    done
    [[ -x $apps ]] || fail "$apps is not executable"
    for tool in jq timeout python3 tar sha256sum; do
        command -v "$tool" >/dev/null || fail "$tool is required"
    done
    bin=$BATS_FILE_TMPDIR/bin
    trees=$BATS_FILE_TMPDIR/trees
    fetch_dir=$BATS_FILE_TMPDIR/fetch
    extract_check=$BATS_FILE_TMPDIR/extract-check
}

# --- the fakes ---------------------------------------------------------------
# `curl` is both the codeload fetch and the deploy ping: an --output names a tar
# this suite published, anything else is a notification URL. It is the one fake
# curl the deploy suites share (tests/deploy/fake-curl.sh), installed the way
# install_fake_curl in tests/deploy/lib.sh does.
install_fakes() { # <bin dir>
    local bin=$1 real_tar
    install -m 0755 "$repo_root/tests/deploy/fake-curl.sh" "$bin/curl"

    cat >"$bin/sops" <<'EOF'
#!/usr/bin/env bash
[[ ${FAKE_SOPS_EXIT:-0} == 0 ]] || exit "$FAKE_SOPS_EXIT"
cat -- "$FAKE_SECRETS_JSON"
EOF

    # `runuser -u apps -- env ... cmd` becomes `env ... cmd`: the tenant boundary is
    # the script's, which every assertion here sees as the runuser calls it logged.
    cat >"$bin/runuser" <<'EOF'
#!/usr/bin/env bash
printf 'runuser %s\n' "$*" >>"$FAKE_LOG/runuser-calls"
if [[ ${1:-} == -u ]]; then shift 2; fi
if [[ ${1:-} == -- ]]; then shift; fi
exec "$@"
EOF

    cat >"$bin/podman" <<'EOF'
#!/usr/bin/env bash
printf 'podman %s\n' "$*" >>"$FAKE_LOG/podman-calls"
cmd=${1:-}
shift || true
case $cmd in
  pull)
    ref=${*: -1}
    printf '%s\n' "$ref" >>"$FAKE_LOG/pulls"
    printf 'pull %s\n' "$ref" >>"$FAKE_LOG/sequence"
    case $ref in
      *"${FAKE_PULL_FAIL:-__no_failure__}"*) exit 1 ;;
    esac
    exit 0
    ;;
  secret)
    sub=${1:-}
    shift || true
    case $sub in
      inspect)
        name=${*: -1}
        file=$FAKE_SECRET_STORE/$name
        [[ -f $file ]] || exit 125
        case " $* " in
          *' --showsecret '*) cat -- "$file"; printf '\n' ;;
          *) printf '{}\n' ;;
        esac
        ;;
      create)
        name=
        for a in "$@"; do
          case $a in
            -*) ;;
            *) name=$a ;;
          esac
        done
        [[ -n $name ]] || exit 125
        cat >"$FAKE_SECRET_STORE/$name"
        printf '%s\n' "$name" >>"$FAKE_LOG/secret-creates"
        ;;
      rm)
        name=${*: -1}
        rm -f -- "$FAKE_SECRET_STORE/$name"
        printf '%s\n' "$name" >>"$FAKE_LOG/secret-removes"
        ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
EOF

    cat >"$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$FAKE_LOG/systemctl-calls"
printf 'systemctl %s\n' "$*" >>"$FAKE_LOG/sequence"
scope=system
rest=()
for a in "$@"; do
  case $a in
    --user | --machine=*) scope=user ;;
    *) rest+=("$a") ;;
  esac
done
verb=${rest[0]:-}
unit=${rest[1]:-}
printf '%s %s %s\n' "$scope" "$verb" "$unit" >>"$FAKE_LOG/actions"
# A snapshot at the quota restart proves the applier read the new plan, and one
# at the Serve restart proves the routes were regenerated from it.
if [[ $unit == smortress-apps-quota.service && -f $APPS_PLAN ]]; then
  cp -- "$APPS_PLAN" "$FAKE_LOG/quota-plan"
fi
if [[ $unit == smortress-tailscale-serve.service && -f $APPS_PLAN ]]; then
  cp -- "$APPS_PLAN" "$FAKE_LOG/serve-plan"
fi
# `show -p ActiveState -p NRestarts <unit>` is the health question. The suite
# decides the answer per unit: down, failed, slow to start, or restarted after a
# few samples -- the shape a container that starts and then exits has.
if [[ $verb == show ]]; then
  unit=${rest[${#rest[@]}-1]}
  state=active restarts=0 samples=0
  if [[ " ${FAKE_UNIT_INACTIVE:-} " == *" $unit "* ]]; then
    state=inactive
  fi
  if [[ " ${FAKE_UNIT_FAILED:-} " == *" $unit "* ]]; then
    state=failed
  fi
  if [[ -n ${FAKE_SHOW_DOWN:-} || (-n ${FAKE_SHOW_TRANSPORT_ONCE:-} && ! -e $FAKE_LOG/show-transport-once) ]]; then
    : >"$FAKE_LOG/show-transport-once"
    printf 'Failed to connect to user scope bus\n' >&2
    exit 1
  fi
  printf '%s\n' "$unit" >>"$FAKE_LOG/shows"
  samples=$(grep -cxF -- "$unit" "$FAKE_LOG/shows")
  if [[ " ${FAKE_UNIT_SLOW:-} " == *" $unit "* ]] && ((samples <= 2)); then
    state=activating
  fi
  if [[ " ${FAKE_UNIT_RESTART:-} " == *" $unit "* ]] && ((samples > 3)); then
    restarts=1
  fi
  printf 'ActiveState=%s\nNRestarts=%s\n' "$state" "$restarts"
  exit 0
fi
# The two answers the apply's retry and its stop mapping exist for: a manager
# that is not reachable yet (transport), and a unit that was never installed
# (systemd exits 5).
if [[ -n ${FAKE_SYSTEMCTL_TRANSPORT:-} && " $* " == *"$FAKE_SYSTEMCTL_TRANSPORT"* ]]; then
  printf 'Failed to connect to user scope bus\n' >&2
  exit 1
fi
if [[ -n ${FAKE_SYSTEMCTL_TRANSPORT_ONCE:-} && " $* " == *"$FAKE_SYSTEMCTL_TRANSPORT_ONCE"* &&
  ! -e $FAKE_LOG/transport-once ]]; then
  : >"$FAKE_LOG/transport-once"
  printf 'Failed to connect to user scope bus\n' >&2
  exit 1
fi
if [[ -n ${FAKE_SYSTEMCTL_RESET_ONCE:-} && " $* " == *"$FAKE_SYSTEMCTL_RESET_ONCE"* &&
  ! -e $FAKE_LOG/reset-once ]]; then
  : >"$FAKE_LOG/reset-once"
  printf 'Connection reset by peer\n' >&2
  exit 1
fi
if [[ -n ${FAKE_SYSTEMCTL_NOTLOADED:-} && " $* " == *"$FAKE_SYSTEMCTL_NOTLOADED"* ]]; then
  printf 'Unit %s not loaded.\n' "$unit" >&2
  exit 5
fi
if [[ -n ${FAKE_SYSTEMCTL_FAIL_ONCE:-} && " $* " == *"$FAKE_SYSTEMCTL_FAIL_ONCE"* &&
  ! -e $FAKE_LOG/failed-once ]]; then
  : >"$FAKE_LOG/failed-once"
  exit 1
fi
if [[ -n ${FAKE_SYSTEMCTL_FAIL:-} && " $* " == *"$FAKE_SYSTEMCTL_FAIL"* ]]; then
  exit 1
fi
exit 0
EOF

    cat >"$bin/df" <<'EOF'
#!/usr/bin/env bash
path=${*: -1}
blocks=999999999
if [[ -f $FAKE_DF_MAP ]]; then
  got=$(awk -v p="$path" '$1 == p { print $2 }' "$FAKE_DF_MAP")
  [[ -n $got ]] && blocks=$got
fi
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/fake %s 0 %s 1%% %s\n' "$blocks" "$blocks" "$path"
EOF

    # The root of an immutable host reports its own size as 100% full, so the space
    # guard has to know the filesystem type; this fake is how the suite can present
    # `/` as composefs and as an ordinary disk.
    cat >"$bin/findmnt" <<'EOF'
#!/usr/bin/env bash
path=${*: -1}
fstype=ext4
if [[ -f $FAKE_FSTYPE_MAP ]]; then
  got=$(awk -v p="$path" '$1 == p { print $2 }' "$FAKE_FSTYPE_MAP")
  [[ -n $got ]] && fstype=$got
fi
if [[ " $* " == *" OPTIONS "* ]]; then
  printf '%s\n' "${FAKE_MOUNT_OPTS:-ro}"
  exit 0
fi
printf '%s\n' "$fstype"
EOF

    cat >"$bin/bootc" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG/bootc-calls"
exit 0
EOF

    # The real tar behind a recorder: the extraction flags are part of the
    # contract, and a call into it must still extract a real tarball for the rest
    # of the suite.
    real_tar=$(command -v tar)
    cat >"$bin/tar" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"\$FAKE_LOG/tar-argv"
exec $real_tar "\$@"
EOF

    chmod 0755 "$bin"/*
}


# --- fixtures ----------------------------------------------------------------
c_v1=1111111111111111111111111111111111111111
c_secret=2222222222222222222222222222222222222222
c_changed=3333333333333333333333333333333333333333
c_depart=4444444444444444444444444444444444444444
c_empty=5555555555555555555555555555555555555555
c_bad=6666666666666666666666666666666666666666
c_pull=7777777777777777777777777777777777777777
c_v2=8888888888888888888888888888888888888888

d_a=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
d_b=sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210
d_c=sha256:aaaabbbbccccddddeeeeffff0000111122223333444455556666777788889999

# The tarball codeload would serve: one top-level directory, `apps/<name>/app.toml`
# and the tenant SOPS file whose key names the validator reads.
new_tree() { # <commit> -> the extracted-tree path
    local dir=$trees/$1/homelab-apps-$1
    rm -rf "${trees:?}/$1"
    mkdir -p "$dir/apps" "$dir/.github/workflows"
    # The real tenant tarball carries repository metadata too. tar creates these
    # directories before writing the files inside them, which is the shape that
    # failed on the host under RestrictSUIDSGID (#824).
    printf 'apps @smores56\n' >"$dir/.github/CODEOWNERS"
    printf 'name: ci\n' >"$dir/.github/workflows/ci.yml"
    printf 'name: deploy\n' >"$dir/.github/workflows/deploy.yml"
    # Only the key names matter here: the real decryption is the fake sops, which
    # answers with the values this suite sets per commit.
    printf '{"apps":{"alpha":{"api-key":"ENC[x]"},"beta":{"beta-key":"ENC[x]"}},"sops":{}}\n' \
        >"$dir/secrets.sops.json"
    printf '%s\n' "$dir"
}
publish() { # <commit> <tree>
    tar -czf "$fetch_dir/$1.tar.gz" -C "$(dirname -- "$2")" "$(basename -- "$2")"
}
clone_tree() { # <from> <to>
    local dir=$trees/$2/homelab-apps-$2
    rm -rf "${trees:?}/$2"
    mkdir -p "$trees/$2"
    cp -a "$trees/$1/homelab-apps-$1" "$dir"
}
alpha_toml() { # <tree> <image-digest> <env-value>
    cat >"$1/apps/alpha/app.toml" <<EOF
image = "ghcr.io/example/alpha@$2"
port = 8080
egress = "none"
quota = "5G"
secrets = ["api-key"]

[env]
TZ = "$3"
EOF
}
beta_toml() { # <tree> <image-digest>
    cat >"$1/apps/beta/app.toml" <<EOF
image = "ghcr.io/example/beta@$2"
port = 9090
egress = "internet"
secrets = ["beta-key"]
EOF
}

secrets_v1='{"apps":{"alpha":{"api-key":"one"},"beta":{"beta-key":"beta-one"}},"sops":{}}'
secrets_v1b='{"apps":{"alpha":{"api-key":"two"},"beta":{"beta-key":"beta-one"}},"sops":{}}'

# --- the published commits ---------------------------------------------------
# The tarballs codeload would serve, published once: they are immutable, so every
# test reads the same bytes and the file pays for the eight of them once.
build_fixtures() {
    local tree

    tree=$(new_tree "$c_v1")
    mkdir -p "$tree/apps/alpha" "$tree/apps/beta"
    alpha_toml "$tree" "$d_a" UTC
    beta_toml "$tree" "$d_b"
    publish "$c_v1" "$tree"

    # Same units, different commit: only the decrypted value moves.
    clone_tree "$c_v1" "$c_secret"
    publish "$c_secret" "$trees/$c_secret/homelab-apps-$c_secret"

    tree=$(new_tree "$c_changed")
    mkdir -p "$tree/apps/alpha"
    alpha_toml "$tree" "$d_c" Europe/Berlin
    publish "$c_changed" "$tree"

    tree=$(new_tree "$c_depart")
    mkdir -p "$tree/apps/alpha"
    alpha_toml "$tree" "$d_a" UTC
    publish "$c_depart" "$tree"

    # The last app leaves: `apps/` exists and is empty, which is the case the
    # renderer refuses without --allow-empty.
    tree=$(new_tree "$c_empty")
    publish "$c_empty" "$tree"

    tree=$(new_tree "$c_bad")
    mkdir -p "$tree/apps/alpha"
    cat >"$tree/apps/alpha/app.toml" <<EOF
image = "ghcr.io/example/alpha:latest"
port = 8080
egress = "none"
EOF
    publish "$c_bad" "$tree"

    tree=$(new_tree "$c_pull")
    mkdir -p "$tree/apps/alpha"
    alpha_toml "$tree" "$d_c" UTC
    publish "$c_pull" "$tree"

    tree=$(new_tree "$c_v2")
    mkdir -p "$tree/apps/alpha"
    alpha_toml "$tree" "$d_a" Europe/Berlin
    publish "$c_v2" "$tree"

    # The commit tarball carries repository metadata as well as app definitions.
    # Extract it once with the exact flags the apply uses, so a future archive or
    # flag change fails here rather than on a drain. On the host this is the step
    # that returned ENOSYS while RestrictSUIDSGID was set (#824). The five paths
    # it must yield are the five tests below, since a preamble check that prints
    # an `ok` line is a test like any other.
    extract_check=$BATS_FILE_TMPDIR/extract-check
    rm -rf "$extract_check"
    mkdir -p "$extract_check"
    tar -xzf "$fetch_dir/$c_v1.tar.gz" -C "$extract_check" \
        --strip-components=1 --no-same-owner --no-same-permissions --no-overwrite-dir
}

# --- the fixture every test starts from --------------------------------------
# One throwaway tree per test: the deploy state, the tenant home, the plan, the
# secret store and the logs the fakes append to all live under $BATS_TEST_TMPDIR,
# so a test can run beside any other. The fakes and the published tarballs are
# read-only and shared through $BATS_FILE_TMPDIR.
fixture() {
    work=$BATS_TEST_TMPDIR/work
    log=$work/log
    secret_store=$work/secret-store
    state_dir=$work/state
    mkdir -p "$log" "$secret_store"

    export PATH="$bin:$PATH"
    export FAKE_LOG=$log
    export FAKE_FETCH_DIR=$fetch_dir
    export FAKE_SECRET_STORE=$secret_store
    export FAKE_SECRETS_JSON=$work/decrypted-secrets.json
    export FAKE_DF_MAP=$work/df-map
    export FAKE_FSTYPE_MAP=$work/fstype-map
    export FAKE_CURL_LOG=$log/curl-argv
    export FAKE_PING_LOG=$log/notify-urls
    export APPS_TAR_BIN=$bin/tar

    export DEPLOY_STATE_DIR=$state_dir
    export DEPLOY_LOCK_FILE=$work/deploy.lock
    export DEPLOY_PING_SECRET=$work/deploy-ping-url.yaml
    export APPS_SCHEMA=$repo_root/$schema
    export APPS_UID=1001
    export APPS_USER=apps
    export APPS_HOME=$work/home/apps
    export APPS_RUNTIME_DIR=$work/run/user/1001
    export APPS_UNIT_DIR=$APPS_HOME/.config/containers/systemd
    export APPS_PLAN=$work/var/lib/homelab/apps/plan.json
    export APPS_POLICY=$work/apps-policy.json
    export SOPS_AGE_KEY_FILE=$work/age.txt
    export APPS_FREE_HOME_PATH=$APPS_HOME
    export APPS_FREE_ROOT_PATH=$work
    export APPS_FREE_VAR_PATH=$work
    # The health wait must expire, not hang. The settle window is off unless a
    # case is testing it: with it at 0 the window is a single sample.
    export APPS_HEALTH_WAIT_TIMEOUT=2
    export APPS_HEALTH_SETTLE=0
    # Two knobs the suite has to bend. Transport failures are retried with a
    # hardcoded `sleep 1` between attempts (scripts/deploy/apps/transport.sh) and
    # the count is the only knob, so 3 bounds an exhausted retry loop at three
    # seconds instead of the host's 180; `sleep` itself is not shadowed on PATH,
    # because the settle window §9e/§9i prove is paced by it -- a fake sleep would
    # turn that window into a fork storm. The boot gate pauses 4 s before its
    # rescan on a real boot; that pause is off here.
    export APPS_CTL_RETRIES=3
    export DEPLOY_BOOT_GATE_PAUSE=0
    export DEPLOY_APPS_BIN=$repo_root/$apps
    export DEPLOY_DRAIN_RESCAN_PAUSE=0

    # The library reads its state directory, its lock and its journal paths when
    # it is sourced, so it is sourced after the environment above.
    # shellcheck source=/dev/null
    source "$repo_root/$lib"
    reset_case
}

# --- drivers -----------------------------------------------------------------
set_secrets() { printf '%s\n' "$1" >"$FAKE_SECRETS_JSON"; }

# The installed state a case starts from: fixture() has already pointed every
# path at this test's tree and sourced the library, so this only refills them.
reset_case() {
    rm -rf "${APPS_HOME:?}" "${work:?}/var" "${work:?}/run" "${state_dir:?}" "${secret_store:?}" "${log:?}"
    mkdir -p "$APPS_HOME" "$work/run/user/1001" "$secret_store" "$log"
    : >"$FAKE_DF_MAP"
    : >"$FAKE_FSTYPE_MAP"
    : >"$log/sequence"
    deploy_state_init || fail "deploy_state_init failed"
    printf '%s\n' "$ping_url" >"$DEPLOY_PING_SECRET"
    printf 'AGE-SECRET-KEY-FAKE\n' >"$SOPS_AGE_KEY_FILE"
    printf 'rules = []\n' >"$APPS_POLICY"
    set_secrets "$secrets_v1"
    unset FAKE_SYSTEMCTL_FAIL FAKE_SYSTEMCTL_FAIL_ONCE FAKE_PULL_FAIL FAKE_CURL_EXIT \
        FAKE_SOPS_EXIT FAKE_UNIT_INACTIVE FAKE_UNIT_FAILED FAKE_UNIT_SLOW FAKE_UNIT_RESTART \
        FAKE_SHOW_DOWN FAKE_SHOW_TRANSPORT_ONCE FAKE_SYSTEMCTL_TRANSPORT \
        FAKE_SYSTEMCTL_TRANSPORT_ONCE FAKE_SYSTEMCTL_RESET_ONCE FAKE_SYSTEMCTL_NOTLOADED
    export APPS_HEALTH_SETTLE=0 APPS_CTL_RETRIES=3
}

# The apply's status and its merged output. A test asserts on the status, so a
# non-zero exit is captured rather than left to errexit.
run_apply() { # <commit>
    rc=0
    out=$(bash "$apps" apply --commit "$1" 2>&1) || rc=$?
}
run_drain() {
    rc=0
    out=$(timeout 60 bash "$drain" 2>&1) || rc=$?
}
run_gate() {
    rc=0
    out=$(timeout 60 bash "$gate" 2>&1) || rc=$?
}
run_revert() {
    rc=0
    out=$(bash "$apps" revert 2>&1) || rc=$?
}
run_sweep() {
    rc=0
    out=$(bash "$apps" sweep 2>&1) || rc=$?
}
line_of() { # <file> <pattern>
    grep -nF -- "$2" "$1" 2>/dev/null | head -n 1 | cut -d: -f1
}
unit_text() { cat "$APPS_UNIT_DIR/$1" 2>/dev/null; }
sha() { sha256sum <"$1" | cut -d' ' -f1; }
json_list() {
    if (($# == 0)); then
        printf '[]\n'
        return 0
    fi
    jq -nc '$ARGS.positional' --args -- "$@"
}
# tests/deploy/lib.sh's reader of the journal this library writes. The shell
# harness retires with the suites it was written for (#931), so this file carries
# the one function of it that it still needs.
journal_field() { # <event> <jq-path>
    jq -r "select(.event==\"$1\") | $2" "${DEPLOY_STATE_DIR:?}/journal.jsonl" 2>/dev/null
}

# --- an interrupted apply, staged by hand ------------------------------------
# §11's staging of the crash state a killed process leaves: apply.json, the new
# plan and units already installed, one secret already replaced, and the previous
# revision saved under work/render.prev. §11 stages it for the drain and for the
# boot gate, and §15 bends the state it saved.
stage_interrupted() { # <intended-commit> <tree>
    local dir=$state_dir/work/apps-$1 tree=$2 prev='{}' name pname
    local -a previous=() intended=() intended_secrets=()
    rm -rf "$dir"
    mkdir -p "$dir/render.prev" "$dir/prev-secrets" "$dir/render.next"
    cp -- "$APPS_PLAN" "$dir/render.prev/plan.json"
    cp -- "$state_dir/state.json" "$dir/render.prev/state.json"
    for name in "$APPS_UNIT_DIR"/*.container "$APPS_UNIT_DIR"/*.network; do
        [[ -f $name ]] || continue
        cp -- "$name" "$dir/render.prev/"
        previous+=("$(basename -- "$name")")
    done
    while IFS= read -r pname; do
        [[ -n $pname ]] || continue
        cp -- "$secret_store/$pname" "$dir/prev-secrets/$pname"
        chmod 0600 "$dir/prev-secrets/$pname"
        prev=$(jq -c --arg n "$pname" --arg p "prev-secrets/$pname" '. + {($n): $p}' <<<"$prev")
    done < <(jq -r '.apps[] | (.secretNames // {}) | .[]' "$APPS_PLAN")
    "$schema" render --root "$tree" --out "$dir/render.next" \
        --secrets "$tree/secrets.sops.json" >/dev/null 2>&1 || return 1
    mapfile -t intended < <(cd "$dir/render.next" && printf '%s\n' *.container *.network 2>/dev/null)
    mapfile -t intended_secrets < <(
        jq -r '.apps[] | (.secretNames // {}) | .[]' "$dir/render.next/plan.json" | sort -u
    )
    # What the failed apply had already done to the host.
    cp -- "$dir/render.next/plan.json" "$APPS_PLAN"
    for name in "${intended[@]}"; do
        [[ -f $dir/render.next/$name ]] || continue
        cp -- "$dir/render.next/$name" "$APPS_UNIT_DIR/$name"
    done
    printf 'two\n' >"$secret_store/app-alpha-api-key"
    jq -c --arg c "$1" '.repos["homelab-apps"] = {commit: $c}' \
        "$state_dir/state.json" | atomic_write "$state_dir/state.json"
    jq -nc --arg phase installing --arg commit "$1" --arg work "$dir" \
        --argjson previousUnits "$(json_list "${previous[@]}")" \
        --argjson intendedUnits "$(json_list "${intended[@]}")" \
        --argjson previousPlan true --argjson previousState true \
        --argjson previousSecrets "$prev" \
        --argjson intendedSecrets "$(json_list "${intended_secrets[@]}")" \
        '{schema:1,phase:$phase,commit:$commit,work:$work,
            previousUnits:$previousUnits,intendedUnits:$intendedUnits,previousPlan:$previousPlan,
            previousState:$previousState,previousSecrets:$previousSecrets,
            intendedSecrets:$intendedSecrets,startedAt:"2026-11-21T00:00:00Z"}' |
        apply_write
}

# One test per path the tarball must yield: the shell suite made the same five
# checks in its preamble, where each `ok` line was already a test like any other.
check_extracted() { # <path in the tree>
    assert [ -s "$extract_check/$1" ]
}

for path in .github/CODEOWNERS .github/workflows/ci.yml .github/workflows/deploy.yml \
    apps/alpha/app.toml apps/beta/app.toml; do
    register "the commit tarball extracts $path" check_extracted "$path"
done

# --- the assertions §1-§4 make through ---------------------------------------
# bats gives a test one name, and §1-§4 are one test, so the text the shell suite
# printed after `ok` rides along as the last argument of each assertion instead:
# it is the same text tests/parity.sh diffs, it survives a failure message, and
# none of the checks lose their name in the source.
same() { # <actual> <expected> <text>
    [[ $1 == "$2" ]] || fail "$3: want '$2', got '$1'"
}
present() { # <path> <text>
    [[ -s $1 ]] || fail "$2: missing or empty: $1"
}
absent() { # <path> <text>
    [[ ! -e $1 ]] || fail "$2: $1 exists"
}
nothing_in() { # <path> <text>: no file, or an empty one, or an empty directory
    local left
    if [[ -d $1 ]]; then left=$(ls -A "$1"); else left=$(cat -- "$1" 2>/dev/null); fi
    [[ -z $left ]] || fail "$2: $left"
}
in_file() { # <file> <fixed string> <text>
    grep -qF -- "$2" "$1" 2>/dev/null || fail "$3: no '$2' in $1"
}
not_in_file() { # <file> <fixed string> <text>
    ! grep -qF -- "$2" "$1" 2>/dev/null || fail "$3: '$2' is in $1"
}
not_matching() { # <file> <ere> <text>: in_file's counterpart for a pattern
    ! grep -qE -- "$2" "$1" 2>/dev/null || fail "$3: $(grep -E -- "$2" "$1")"
}
in_text() { # <text> <fixed string> <text>
    [[ $1 == *"$2"* ]] || fail "$3: no '$2' in: $1"
}
nonempty() { # <value> <text>
    [[ -n $1 ]] || fail "$2: the value is empty"
}
# A line number the journal or the command log gave: the order those two files
# record is the only evidence that the plan reached its consumer first.
assert_before() { # <line> <line> <what>
    [[ -n $1 && -n $2 && $1 -lt $2 ]] || fail "$3: '$1' is not before '$2'"
}

# --- 1. a first apply installs the plan, the units, the secrets and Serve -----
# §1-§4 are one test because each carries the installed state forward with no
# `reset_case`: §2 proves a rejected definition leaves §1's install untouched, and
# §4 proves an empty tenant departs from it. Four tests would reinstall between
# the parts, which is a different thing to prove.
@test "a clean commit applies" {
    fixture
    run_apply "$c_v1"
    same "$rc" 0 "a clean commit applies"
    present "$APPS_PLAN" "the plan is installed"
    same "$(jq -r '.apps | keys | join(" ")' "$APPS_PLAN")" 'alpha beta' \
        "the plan names both apps"
    present "$APPS_UNIT_DIR/alpha.container" "alpha's unit is installed"
    present "$APPS_UNIT_DIR/beta.container" "beta's unit is installed"
    present "$APPS_UNIT_DIR/smortress-apps.network" \
        "the internal network is installed for egress none"
    in_file "$APPS_UNIT_DIR/alpha.container" '# Rendered from apps/alpha/app.toml' \
        "the installed unit is the rendered one"
    same "$(cat "$secret_store/app-alpha-api-key" 2>/dev/null)" one \
        "alpha's secret value is in the store"
    same "$(cat "$secret_store/app-beta-beta-key" 2>/dev/null)" beta-one \
        "beta's secret value is in the store"
    present "$state_dir/state.json" "the applied revision is recorded"
    same "$(jq -r '.repos["homelab-apps"].commit' "$state_dir/state.json")" "$c_v1" \
        "state records the applied commit"
    same "$(journal_field state-verified '.repo')" homelab-apps \
        "the commit is recorded through state_record_verified"
    same "$(jq -r '.apps.apps.alpha.unit' "$state_dir/state.json")" \
        "$(sha "$APPS_UNIT_DIR/alpha.container")" \
        "the recorded unit hash is the installed unit's"
    nonempty "$(jq -r '.apps.apps.alpha.secrets // ""' "$state_dir/state.json")" \
        "the recorded secret hash is present"
    same "$(jq -r '.apps.unitsHash | length' "$state_dir/state.json")" 64 \
        "the whole-set unit hash is recorded"
    absent "$state_dir/apply.json" "a committed apply clears the crash record"
    same "$(tail -n 1 "$log/notify-urls")" "$ping_url" \
        "a clean apply pings the deploy check"
    # The ping URL is the capability to keep the check green: it is handed to curl
    # as a config on stdin, so no local account can read it out of /proc.
    not_in_file "$log/curl-argv" "$ping_url" "the ping URL never reaches curl's argv"
    in_file "$log/curl-argv" '--config -' "the ping URL is a curl config on stdin"
    # The tarball is untrusted bytes extracted as root: tar must not take
    # ownership, modes or the tree's own directory mode from it.
    extract=$(grep -F -- '-xzf' "$log/tar-argv" | head -n 1)
    for flag in --no-same-owner --no-same-permissions --no-overwrite-dir; do
        in_text "$extract" "$flag" "the extraction passes $flag"
    done
    in_file "$log/actions" 'system start smortress-app-ingress@alpha' \
        "alpha's ingress is started"
    in_file "$log/actions" 'system start smortress-app-ingress@beta' \
        "beta's ingress is started"

    # The quota applier must have read the new plan before any container started.
    same "$(sha "$log/quota-plan" 2>/dev/null)" "$(sha "$APPS_PLAN")" \
        "the quota restart reads the new plan"
    plan_at=$(line_of "$state_dir/journal.jsonl" '"event":"apps-plan-installed"')
    quota_at=$(line_of "$state_dir/journal.jsonl" '"event":"apps-quota-applied"')
    assert_before "$plan_at" "$quota_at" "the plan is installed before the quota restart"

    # --- 2. a rejected definition changes nothing and is denylisted -----------
    plan_before=$(sha "$APPS_PLAN")
    unit_before=$(sha "$APPS_UNIT_DIR/alpha.container")
    secret_before=$(cat "$secret_store/app-alpha-api-key")
    : >"$log/pulls"
    : >"$log/actions"
    run_apply "$c_bad"
    same "$rc" 3 "a rejected definition exits 3"
    same "$(sha "$APPS_PLAN")" "$plan_before" \
        "a rejected definition leaves the plan untouched"
    same "$(sha "$APPS_UNIT_DIR/alpha.container")" "$unit_before" \
        "a rejected definition leaves the units untouched"
    same "$(cat "$secret_store/app-alpha-api-key")" "$secret_before" \
        "a rejected definition leaves the secrets untouched"
    absent "$state_dir/apply.json" "a rejected definition writes no crash record"
    same "$(jq -r ".commits[\"$c_bad\"].reason" \
        <<<"$(cat "$state_dir/denylist.json" 2>/dev/null || printf '{}')")" \
        apps:definition-rejected "a rejected commit is denylisted"
    same "$(journal_field apps-rejected '.commit')" "$c_bad" "the rejection is journaled"
    nothing_in "$log/pulls" "a rejected definition pulls nothing"
    nothing_in "$log/actions" "a rejected definition mutates nothing"
    same "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail" \
        "a rejection pages the deploy check"

    # --- 3. an empty tenant is refused by the renderer alone -------------------
    empty_tree=$trees/$c_empty/homelab-apps-$c_empty
    render_rc=0
    "$repo_root/$schema" render --root "$empty_tree" --out "$work/empty-refused" \
        >"$log/empty.log" 2>&1 || render_rc=$?
    [[ $render_rc -ne 0 ]] || fail \
        "the renderer refuses an empty tenant without --allow-empty: $(cat "$log/empty.log")"
    absent "$work/empty-refused/plan.json" "the refused empty render writes no plan"

    # --- 4. an empty tenant applies with --allow-empty and empties Serve's routes
    run_apply "$c_empty"
    same "$rc" 0 "the deploy applies an empty tenant"
    same "$(jq -r '.apps | length' "$APPS_PLAN")" 0 "the empty plan has no app"
    [[ -z $(find "$APPS_UNIT_DIR" -maxdepth 1 -type f -name '*.container' -print -quit) ]] ||
        fail "the emptied tenant has no app unit: $(ls "$APPS_UNIT_DIR")"
    absent "$APPS_UNIT_DIR/smortress-apps.network" \
        "the internal network goes with the last egress-none app"
    nothing_in "$secret_store" "the emptied tenant has no secrets"
    in_file "$log/actions" 'user stop alpha.service' "a departed app is stopped"
    in_file "$log/actions" 'system stop smortress-app-ingress@alpha' \
        "a departed app's ingress is stopped"
    same "$(jq -r '.apps.apps | length' "$state_dir/state.json")" 0 \
        "the emptied tenant records no app"
    in_file "$log/actions" 'system restart smortress-tailscale-serve.service' \
        "Serve is regenerated so the removed route is pruned"
}

# --- 5. a failed pull changes nothing and leaves no crash record -------------
# Every check in a section below reads one aftermath, so each of its tests
# replays the section's own sequence: the same drivers in the same order, with
# nothing between them that a check depends on.
apply_a_failed_pull() {
    fixture
    run_apply "$c_v1"
    plan_before=$(sha "$APPS_PLAN")
    unit_before=$(sha "$APPS_UNIT_DIR/alpha.container")
    secret_before=$(cat "$secret_store/app-alpha-api-key")
    : >"$log/pulls"
    : >"$log/actions"
    : >"$log/systemctl-calls"
    export FAKE_PULL_FAIL=$d_c
    run_apply "$c_pull"
    unset FAKE_PULL_FAIL
}

@test "a failed pull exits 4 for a retry" {
    apply_a_failed_pull
    assert_equal "$rc" 4
}

@test "a failed pull leaves the plan untouched" {
    apply_a_failed_pull
    assert_equal "$(sha "$APPS_PLAN")" "$plan_before"
}

@test "a failed pull leaves the units untouched" {
    apply_a_failed_pull
    assert_equal "$(sha "$APPS_UNIT_DIR/alpha.container")" "$unit_before"
}

@test "a failed pull leaves the secrets untouched" {
    apply_a_failed_pull
    assert_equal "$(cat "$secret_store/app-alpha-api-key")" "$secret_before"
}

@test "a failed pull leaves no crash record" {
    apply_a_failed_pull
    assert [ ! -e "$state_dir/apply.json" ]
}

@test "a failed pull removes its work tree" {
    apply_a_failed_pull
    assert [ ! -e "$state_dir/work/apps-$c_pull" ]
}

@test "the failed pull is journaled" {
    apply_a_failed_pull
    assert_equal "$(journal_field apps-pull-failed '.commit')" "$c_pull"
}

@test "the changed image is the one pulled" {
    apply_a_failed_pull
    assert grep -qF -- "ghcr.io/example/alpha@$d_c" "$log/pulls"
}

@test "a failed pull happens before any mutation" {
    apply_a_failed_pull
    assert [ ! -s "$log/actions" ]
}

@test "a failed pull pages the deploy check" {
    apply_a_failed_pull
    assert_equal "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail"
}

# --- 6. pull-all-then-change, and the plan before the quota restart ----------
apply_a_changed_commit() {
    fixture
    run_apply "$c_v1"
    : >"$state_dir/journal.jsonl"
    : >"$log/pulls"
    : >"$log/actions"
    : >"$log/sequence"
    run_apply "$c_changed"
    last_pull=$(grep -n 'apps-pulled' "$state_dir/journal.jsonl" | tail -n 1 | cut -d: -f1)
    plan_at=$(line_of "$state_dir/journal.jsonl" '"event":"apps-plan-installed"')
    quota_at=$(line_of "$state_dir/journal.jsonl" '"event":"apps-quota-applied"')
    # The command log's own order: every pull is a child of this apply, and the
    # first thing it changes is the plan's consumer.
    last_pull_cmd=$(grep -n '^pull ' "$log/sequence" | tail -n 1 | cut -d: -f1)
    quota_cmd=$(line_of "$log/sequence" 'restart smortress-apps-quota.service')
}

@test "a changed commit applies" {
    apply_a_changed_commit
    assert_equal "$rc" 0
}

@test "the changed image is pulled" {
    apply_a_changed_commit
    assert [ -s "$log/pulls" ]
}

@test "every pull completes before the first mutation" {
    apply_a_changed_commit
    assert_before "$last_pull" "$plan_at" "every pull completes before the first mutation"
}

@test "the plan is installed before the quota reads it" {
    apply_a_changed_commit
    assert_before "$plan_at" "$quota_at" "the plan is installed before the quota reads it"
}

@test "the quota applier reads the new plan" {
    apply_a_changed_commit
    assert_equal "$(sha "$log/quota-plan" 2>/dev/null)" "$(sha "$APPS_PLAN")"
}

@test "the command log shows every pull before the quota restart" {
    apply_a_changed_commit
    assert_before "$last_pull_cmd" "$quota_cmd" \
        "the command log shows every pull before the quota restart"
}

@test "Serve is regenerated from the new plan" {
    apply_a_changed_commit
    assert_equal "$(sha "$log/serve-plan" 2>/dev/null)" "$(sha "$APPS_PLAN")"
}

@test "a changed unit is restarted" {
    apply_a_changed_commit
    assert grep -qF 'user restart alpha.service' "$log/actions"
}

# --- 7. a secret-only change restarts the app that mounts it -----------------
apply_a_secret_only_change() {
    fixture
    run_apply "$c_v1"
    : >"$log/pulls"
    : >"$log/actions"
    : >"$log/secret-creates"
    set_secrets "$secrets_v1b"
    run_apply "$c_secret"
}

@test "a secret-only change applies" {
    apply_a_secret_only_change
    assert_equal "$rc" 0
}

@test "the rotated value is in the store" {
    apply_a_secret_only_change
    assert_equal "$(cat "$secret_store/app-alpha-api-key")" two
}

@test "an unchanged secret keeps its value" {
    apply_a_secret_only_change
    assert_equal "$(cat "$secret_store/app-beta-beta-key")" beta-one
}

@test "a secret-only change pulls nothing" {
    apply_a_secret_only_change
    assert [ ! -s "$log/pulls" ]
}

@test "the app whose secret changed is restarted" {
    apply_a_secret_only_change
    assert grep -qF 'user restart alpha.service' "$log/actions"
}

@test "an app with no change is not restarted" {
    apply_a_secret_only_change
    refute grep -qF 'user restart beta.service' "$log/actions"
}

@test "the changed secret is replaced" {
    apply_a_secret_only_change
    assert grep -qF app-alpha-api-key "$log/secret-creates"
}

@test "a committed secret change clears the crash record" {
    apply_a_secret_only_change
    assert [ ! -e "$state_dir/apply.json" ]
}

# --- 8. a departed app loses its unit, its secret and its Serve route --------
apply_a_departed_app() {
    fixture
    run_apply "$c_v1"
    : >"$log/actions"
    run_apply "$c_depart"
}

@test "a commit that removes an app applies" {
    apply_a_departed_app
    assert_equal "$rc" 0
}

@test "the departed unit is removed" {
    apply_a_departed_app
    assert [ ! -e "$APPS_UNIT_DIR/beta.container" ]
}

@test "the remaining unit stays" {
    apply_a_departed_app
    assert [ -s "$APPS_UNIT_DIR/alpha.container" ]
}

@test "the departed app's secret is removed" {
    apply_a_departed_app
    assert [ ! -e "$secret_store/app-beta-beta-key" ]
}

@test "the remaining secret stays" {
    apply_a_departed_app
    assert [ -s "$secret_store/app-alpha-api-key" ]
}

@test "the departed app is stopped" {
    apply_a_departed_app
    assert grep -qF 'user stop beta.service' "$log/actions"
}

@test "the departed app's ingress is stopped" {
    apply_a_departed_app
    assert grep -qF 'system stop smortress-app-ingress@beta' "$log/actions"
}

@test "Serve is regenerated so the departed route is pruned" {
    apply_a_departed_app
    assert grep -qF 'system restart smortress-tailscale-serve.service' "$log/actions"
}

@test "the plan keeps only the remaining app" {
    apply_a_departed_app
    assert_equal "$(jq -r '.apps | keys | join(" ")' "$APPS_PLAN")" alpha
}

@test "state keeps only the remaining app" {
    apply_a_departed_app
    assert_equal "$(jq -r '.apps.apps | keys | join(" ")' "$state_dir/state.json")" alpha
}

# --- 9. a failure mid-apply reverts units, plan, secrets and state -----------
apply_a_failure_mid_apply() {
    fixture
    run_apply "$c_v1"
    plan_before=$(sha "$APPS_PLAN")
    unit_before=$(sha "$APPS_UNIT_DIR/alpha.container")
    state_before=$(sha "$state_dir/state.json")
    : >"$log/actions"
    set_secrets "$secrets_v1b"
    export FAKE_SYSTEMCTL_FAIL_ONCE='restart alpha.service'
    run_apply "$c_v2"
    unset FAKE_SYSTEMCTL_FAIL_ONCE
}

@test "a failure mid-apply exits 5 after the revert" {
    apply_a_failure_mid_apply
    assert_equal "$rc" 5
}

@test "the revert restores the previous plan" {
    apply_a_failure_mid_apply
    assert_equal "$(sha "$APPS_PLAN")" "$plan_before"
}

@test "the revert restores the previous unit" {
    apply_a_failure_mid_apply
    assert_equal "$(sha "$APPS_UNIT_DIR/alpha.container")" "$unit_before"
}

@test "the revert restores the previous secret value" {
    apply_a_failure_mid_apply
    assert_equal "$(cat "$secret_store/app-alpha-api-key")" one
}

@test "the revert keeps the untouched secret" {
    apply_a_failure_mid_apply
    assert_equal "$(cat "$secret_store/app-beta-beta-key")" beta-one
}

@test "the revert restores the previous state" {
    apply_a_failure_mid_apply
    assert_equal "$(sha "$state_dir/state.json")" "$state_before"
}

@test "the revert clears the crash record" {
    apply_a_failure_mid_apply
    assert [ ! -e "$state_dir/apply.json" ]
}

@test "the failed apply is journaled" {
    apply_a_failure_mid_apply
    assert_equal "$(journal_field apps-failed '.commit')" "$c_v2"
}

@test "the revert is journaled" {
    apply_a_failure_mid_apply
    assert_equal "$(journal_field apps-reverted '.commit')" "$c_v2"
}

@test "the restored app is restarted" {
    apply_a_failure_mid_apply
    assert grep -qF 'user restart alpha.service' "$log/actions"
}

@test "Serve is regenerated for the restored plan" {
    apply_a_failure_mid_apply
    assert grep -qF 'system restart smortress-tailscale-serve.service' "$log/actions"
}

@test "a reverted apply pages the deploy check" {
    apply_a_failure_mid_apply
    assert_equal "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail"
}

@test "the restore ran as the tenant" {
    apply_a_failure_mid_apply
    assert grep -qF 'user restart alpha.service' "$log/actions"
}

# --- 9b. a revert removes the app the failed apply added ---------------------
apply_an_added_app_that_fails() {
    fixture
    run_apply "$c_depart"
    same "$rc" 0 "the single-app revision applies"
    : >"$log/actions"
    set_secrets "$secrets_v1"
    export FAKE_SYSTEMCTL_FAIL_ONCE='start beta.service'
    run_apply "$c_v1"
    unset FAKE_SYSTEMCTL_FAIL_ONCE
}

@test "an added app that fails to start rolls back" {
    apply_an_added_app_that_fails
    assert_equal "$rc" 5
}

@test "the revert removes the added unit" {
    apply_an_added_app_that_fails
    assert [ ! -e "$APPS_UNIT_DIR/beta.container" ]
}

@test "the revert removes the added secret" {
    apply_an_added_app_that_fails
    assert [ ! -e "$secret_store/app-beta-beta-key" ]
}

@test "the revert stops the added app" {
    apply_an_added_app_that_fails
    assert grep -qF 'user stop beta.service' "$log/actions"
}

@test "the revert stops the added app's ingress" {
    apply_an_added_app_that_fails
    assert grep -qF 'system stop smortress-app-ingress@beta' "$log/actions"
}

@test "the revert keeps the previous commit recorded" {
    apply_an_added_app_that_fails
    assert_equal "$(jq -r '.repos["homelab-apps"].commit' "$state_dir/state.json")" "$c_depart"
}

@test "the previous app's unit stays" {
    apply_an_added_app_that_fails
    assert [ -s "$APPS_UNIT_DIR/alpha.container" ]
}

# --- 9c. an app that does not come up is not committed -----------------------
# The next boot's gate would find the unit inactive and roll back the platform
# image, so an apply may not commit a revision whose apps are not running.
apply_an_app_that_stays_down() {
    fixture
    run_apply "$c_v1"
    same "$rc" 0 "the two-app revision applies"
    plan_before=$(sha "$APPS_PLAN")
    unit_before=$(sha "$APPS_UNIT_DIR/alpha.container")
    state_before=$(sha "$state_dir/state.json")
    : >"$log/actions"
    set_secrets "$secrets_v1b"
    export FAKE_UNIT_INACTIVE=alpha.service
    run_apply "$c_v2"
    unset FAKE_UNIT_INACTIVE
}

@test "an app that stays down exits 5 after the revert" {
    apply_an_app_that_stays_down
    assert_equal "$rc" 5
}

@test "the unhealthy app is named" {
    apply_an_app_that_stays_down
    assert_equal "$(journal_field apps-unhealthy '.app')" alpha
}

@test "the unhealthy unit is journaled" {
    apply_an_app_that_stays_down
    assert_equal "$(journal_field apps-unhealthy '.unit')" alpha.service
}

@test "the state systemd reported is journaled" {
    apply_an_app_that_stays_down
    assert_equal "$(journal_field apps-unhealthy '.state')" inactive
}

@test "the failure names health, not a mutation" {
    apply_an_app_that_stays_down
    assert_equal "$(journal_field apps-failed '.reason' | tail -n 1)" app-unhealthy
}

@test "the down app does not commit its revision" {
    apply_an_app_that_stays_down
    assert_equal "$(jq -r '.repos["homelab-apps"].commit' "$state_dir/state.json")" "$c_v1"
}

@test "the revert restores the previous plan (§9c)" {
    apply_an_app_that_stays_down
    assert_equal "$(sha "$APPS_PLAN")" "$plan_before"
}

@test "the revert restores the previous unit (§9c)" {
    apply_an_app_that_stays_down
    assert_equal "$(sha "$APPS_UNIT_DIR/alpha.container")" "$unit_before"
}

@test "the revert restores the previous secret" {
    apply_an_app_that_stays_down
    assert_equal "$(cat "$secret_store/app-alpha-api-key")" one
}

@test "the revert restores the previous state (§9c)" {
    apply_an_app_that_stays_down
    assert_equal "$(sha "$state_dir/state.json")" "$state_before"
}

@test "the revert clears the crash record (§9c)" {
    apply_an_app_that_stays_down
    assert [ ! -e "$state_dir/apply.json" ]
}

@test "the unhealthy apply pages the deploy check" {
    apply_an_app_that_stays_down
    assert_equal "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail"
}

# --- 9d. an app the commit did not touch cannot block it ---------------------
# An apply cannot repair a revision it did not write: a stale inactive app is the
# boot gate's business, not a reason to refuse every later commit.
apply_past_an_inactive_app() {
    fixture
    run_apply "$c_v1"
    set_secrets "$secrets_v1b"
    export FAKE_UNIT_INACTIVE=beta.service
    run_apply "$c_secret"
    unset FAKE_UNIT_INACTIVE
}

@test "an inactive app the commit did not change applies" {
    apply_past_an_inactive_app
    assert_equal "$rc" 0
}

@test "the changed app is still checked" {
    apply_past_an_inactive_app
    assert grep -qF 'show -p ActiveState -p NRestarts alpha.service' "$log/systemctl-calls"
}

@test "the untouched app is not judged" {
    apply_past_an_inactive_app
    assert_equal "$(journal_field apps-unhealthy '.app')" ""
}

# --- 9e. an app that crashes after it starts is not committed ----------------
# Restart= brings a crashed container back fast enough that every sample can
# still read `active`; NRestarts moving past its baseline is the evidence.
apply_an_app_that_restarts() {
    fixture
    run_apply "$c_v1"
    same "$rc" 0 "the two-app revision applies"
    set_secrets "$secrets_v1b"
    export FAKE_UNIT_RESTART=alpha.service APPS_HEALTH_SETTLE=2
    run_apply "$c_v2"
    unset FAKE_UNIT_RESTART
}

@test "an app restarted inside the settle window exits 5" {
    apply_an_app_that_restarts
    assert_equal "$rc" 5
}

@test "the restarted unit is journaled" {
    apply_an_app_that_restarts
    assert_equal "$(journal_field apps-unhealthy '.unit')" alpha.service
}

@test "the restart is journaled as the verdict" {
    apply_an_app_that_restarts
    assert_equal "$(journal_field apps-unhealthy '.state')" restarted
}

# --- 9f. a slow start is not a crash ----------------------------------------
apply_a_slow_start() {
    fixture
    run_apply "$c_v1"
    set_secrets "$secrets_v1b"
    export FAKE_UNIT_SLOW=alpha.service
    run_apply "$c_v2"
    unset FAKE_UNIT_SLOW
}

@test "an app that comes up late still applies" {
    apply_a_slow_start
    assert_equal "$rc" 0
}

# --- 9g. a transport blip is asked again, not judged -------------------------
apply_through_a_probe_blip() {
    fixture
    run_apply "$c_v1"
    set_secrets "$secrets_v1b"
    export FAKE_SHOW_TRANSPORT_ONCE=1
    run_apply "$c_v2"
    unset FAKE_SHOW_TRANSPORT_ONCE
}

@test "one unreachable probe does not fail the apply" {
    apply_through_a_probe_blip
    assert_equal "$rc" 0
}

# --- 9h. a manager that cannot be asked never reads as healthy ---------------
apply_with_an_unreachable_manager() {
    fixture
    run_apply "$c_v1"
    set_secrets "$secrets_v1b"
    export FAKE_SHOW_DOWN=1
    run_apply "$c_v2"
    unset FAKE_SHOW_DOWN
}

@test "an app whose state cannot be read is not committed" {
    apply_with_an_unreachable_manager
    assert_equal "$rc" 5
}

@test "the unknown state is journaled" {
    apply_with_an_unreachable_manager
    assert_equal "$(journal_field apps-unhealthy '.state')" unknown
}

# --- 9i. a healthy app survives a real settle window ------------------------
apply_through_a_settle_window() {
    fixture
    run_apply "$c_v1"
    set_secrets "$secrets_v1b"
    export APPS_HEALTH_SETTLE=2
    run_apply "$c_v2"
}

@test "a healthy app applies through the settle window" {
    apply_through_a_settle_window
    assert_equal "$rc" 0
}

@test "no health verdict is journaled" {
    apply_through_a_settle_window
    assert_equal "$(journal_field apps-unhealthy '.app')" ""
}

# --- 9j. a unit that is not loaded is already stopped -----------------------
# The revert stops the apps the failed apply added. systemd exits 5 for a unit it
# never had, and reading that as a failure left the record behind forever.
apply_an_added_app_a_stop_cannot_load() {
    fixture
    run_apply "$c_depart"
    same "$rc" 0 "the single-app revision applies"
    : >"$log/actions"
    set_secrets "$secrets_v1"
    export FAKE_SYSTEMCTL_FAIL_ONCE='start beta.service' FAKE_SYSTEMCTL_NOTLOADED=stop
    run_apply "$c_v1"
    unset FAKE_SYSTEMCTL_FAIL_ONCE FAKE_SYSTEMCTL_NOTLOADED
}

@test "a failed apply still exits 5" {
    apply_an_added_app_a_stop_cannot_load
    assert_equal "$rc" 5
}

@test "the revert stops the added app (§9j)" {
    apply_an_added_app_a_stop_cannot_load
    assert grep -qF 'user stop beta.service' "$log/actions"
}

@test "the revert stops the added app's ingress (§9j)" {
    apply_an_added_app_a_stop_cannot_load
    assert grep -qF 'system stop smortress-app-ingress@beta' "$log/actions"
}

@test "a not-loaded stop completes the revert" {
    apply_an_added_app_a_stop_cannot_load
    assert [ ! -e "$state_dir/apply.json" ]
}

@test "the revert keeps the previous commit recorded (§9j)" {
    apply_an_added_app_a_stop_cannot_load
    assert_equal "$(jq -r '.repos["homelab-apps"].commit' "$state_dir/state.json")" "$c_depart"
}

# --- 9k. a manager that is gone is not "already stopped" --------------------
# The other side of the same mapping: an unreachable manager must fail the
# revert and keep the record, or the next boot believes the host is consistent.
revert_through_a_dead_manager() {
    fixture
    run_apply "$c_depart"
    set_secrets "$secrets_v1"
    export FAKE_SYSTEMCTL_FAIL_ONCE='start beta.service'
    export FAKE_SYSTEMCTL_TRANSPORT='stop beta.service'
    run_apply "$c_v1"
    unset FAKE_SYSTEMCTL_FAIL_ONCE FAKE_SYSTEMCTL_TRANSPORT
}

@test "an unreachable manager still exits 5" {
    revert_through_a_dead_manager
    assert_equal "$rc" 5
}

@test "a failed revert keeps the record" {
    revert_through_a_dead_manager
    assert [ -s "$state_dir/apply.json" ]
}

@test "the failed revert says why" {
    revert_through_a_dead_manager
    assert_equal "$(journal_field apps-revert-failed '.reason' | tail -n 1)" restore-incomplete
}

@test "the failed revert pages the deploy check" {
    revert_through_a_dead_manager
    assert_equal "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail"
}

# --- 9l. a transport blip on a control call is asked again ------------------
apply_through_a_restart_blip() {
    fixture
    run_apply "$c_v1"
    same "$rc" 0 "the two-app revision applies"
    set_secrets "$secrets_v1b"
    export FAKE_SYSTEMCTL_TRANSPORT_ONCE='restart alpha.service'
    run_apply "$c_v2"
    unset FAKE_SYSTEMCTL_TRANSPORT_ONCE
}

@test "a transport blip on restart does not fail the apply" {
    apply_through_a_restart_blip
    assert_equal "$rc" 0
}

@test "the restart is retried once" {
    apply_through_a_restart_blip
    assert_equal "$(grep -c 'user restart alpha.service' "$log/actions")" 2
}

# --- 9m. a connection reset on a control call is asked again ----------------
apply_through_a_reset() {
    fixture
    run_apply "$c_v1"
    same "$rc" 0 "the two-app revision applies"
    set_secrets "$secrets_v1b"
    export FAKE_SYSTEMCTL_RESET_ONCE='restart alpha.service'
    run_apply "$c_v2"
    unset FAKE_SYSTEMCTL_RESET_ONCE
}

@test "a connection reset on restart does not fail the apply" {
    apply_through_a_reset
    assert_equal "$rc" 0
}

@test "the restart is retried after a reset" {
    apply_through_a_reset
    assert_equal "$(grep -c 'user restart alpha.service' "$log/actions")" 2
}

# --- 10. a Serve failure after the commit does not revert --------------------
apply_with_a_failing_serve() {
    fixture
    run_apply "$c_v1"
    set_secrets "$secrets_v1b"
    export FAKE_SYSTEMCTL_FAIL=smortress-tailscale-serve.service
    run_apply "$c_v2"
    unset FAKE_SYSTEMCTL_FAIL
}

@test "a Serve failure still leaves the commit running" {
    apply_with_a_failing_serve
    assert_equal "$rc" 0
}

@test "the applied commit stays recorded" {
    apply_with_a_failing_serve
    assert_equal "$(jq -r '.repos["homelab-apps"].commit' "$state_dir/state.json")" "$c_v2"
}

@test "the applied secret value stays" {
    apply_with_a_failing_serve
    assert_equal "$(cat "$secret_store/app-alpha-api-key")" two
}

@test "a Serve failure leaves no crash record" {
    apply_with_a_failing_serve
    assert [ ! -e "$state_dir/apply.json" ]
}

@test "the failed Serve restart is journaled" {
    apply_with_a_failing_serve
    assert_equal "$(journal_field apps-serve-failed '.commit')" "$c_v2"
}

@test "a Serve failure does not log a revert" {
    apply_with_a_failing_serve
    assert_equal "$(journal_field apps-reverted '.commit')" ""
}

@test "a Serve failure pages the deploy check" {
    apply_with_a_failing_serve
    assert_equal "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail"
}

# --- 11. an interrupted apply is reverted by the drain and by the boot gate ---
# The state a killed process leaves: apply.json, the new plan and units already
# installed, one secret already replaced, and the previous revision saved under
# work/render.prev. Both entry points must put all of it back, so the two trees
# stage the same crash state and stay one test: a replay per assertion would
# stage it again for a check that reads the other entry point's aftermath.
@test "the drain exits after reverting the interrupted apply (§11: drain and boot gate)" {
    fixture
    run_apply "$c_v1"
    plan_before=$(sha "$APPS_PLAN")
    unit_before=$(sha "$APPS_UNIT_DIR/alpha.container")
    state_before=$(sha "$state_dir/state.json")
    stage_interrupted "$c_v2" "$trees/$c_v2/homelab-apps-$c_v2"
    same "$(sha "$APPS_PLAN")" "$(sha "$state_dir/work/apps-$c_v2/render.next/plan.json")" \
        "the interrupted apply left the new plan installed"
    : >"$log/actions"
    run_drain
    same "$rc" 0 "the drain exits after reverting the interrupted apply"
    same "$(sha "$APPS_PLAN")" "$plan_before" "the drain restores the previous plan"
    same "$(sha "$APPS_UNIT_DIR/alpha.container")" "$unit_before" \
        "the drain restores the previous unit"
    same "$(cat "$secret_store/app-alpha-api-key")" one "the drain restores the previous secret"
    same "$(sha "$state_dir/state.json")" "$state_before" "the drain restores the previous state"
    absent "$state_dir/apply.json" "the drain clears the crash record"
    same "$(journal_field apply-reverted '.by')" drain "the drain journals the reverted apply"
    in_file "$log/actions" 'system restart smortress-tailscale-serve.service' \
        "the drain regenerates Serve after the revert"

    reset_case
    run_apply "$c_v1"
    plan_before=$(sha "$APPS_PLAN")
    unit_before=$(sha "$APPS_UNIT_DIR/alpha.container")
    state_before=$(sha "$state_dir/state.json")
    stage_interrupted "$c_v2" "$trees/$c_v2/homelab-apps-$c_v2"
    : >"$log/actions"
    : >"$log/bootc-calls"
    run_gate
    same "$rc" 0 "the boot gate passes on a boot with no pending deploy"
    same "$(sha "$APPS_PLAN")" "$plan_before" "the gate restores the previous plan"
    same "$(sha "$APPS_UNIT_DIR/alpha.container")" "$unit_before" \
        "the gate restores the previous unit"
    same "$(cat "$secret_store/app-alpha-api-key")" one "the gate restores the previous secret"
    same "$(sha "$state_dir/state.json")" "$state_before" "the gate restores the previous state"
    absent "$state_dir/apply.json" "the gate clears the crash record"
    same "$(journal_field apply-interrupted '.phase')" installing \
        "the gate journals the interrupted phase it found"
    same "$(journal_field apply-reverted '.by')" boot-gate \
        "the gate journals the reverted apply"
    # The gate reads the booted digest even here, so a boot state.json does not
    # name is noticed (tests/deploy/boot.sh owns that check); it must not switch
    # or roll back on a boot with no pending deployment.
    not_matching "$log/bootc-calls" '^(switch|rollback)' \
        "a boot with no pending deploy switches nothing"
}

# --- 11b. work trees do not outlive their apply ----------------------------
# A work tree holds the decrypted tenant secrets, so an exit that is not the
# revert path has to take it with it -- including the exits nobody wrote a branch
# for, which is what the trap on the way out is for. The three blocks below stay
# one test: each reads only the tree and the sweep journal it just wrote, and a
# replay per text would lay down the same plaintext work trees again.
@test "a failed apply takes its work tree with it (§11b: work-tree lifetime)" {
    fixture
    mkdir -p "$state_dir/work/apps-$c_v1/tree"
    printf '{"apps":{}}\n' >"$state_dir/work/apps-$c_v1/tree/secrets.json"
    printf 'plaintext\n' >"$state_dir/work/apps-$c_v1/secrets.json"
    # A journal that cannot be appended stops the apply before its first mutation.
    rm -f "$state_dir/journal.jsonl"
    mkdir -p "$state_dir/journal.jsonl"
    run_apply "$c_v1"
    rmdir "$state_dir/journal.jsonl"
    same "$rc" 4 "an exit before the first mutation exits 4"
    absent "$state_dir/work/apps-$c_v1" "a failed apply takes its work tree with it"

    # A tree an interrupted apply left behind is plaintext nothing will clean up, and
    # an unbounded state directory is a leak that grows with every failed deploy.
    reset_case
    run_apply "$c_v1"
    mkdir -p "$state_dir/work/apps-$c_pull/tree"
    printf '{"apps":{}}\n' >"$state_dir/work/apps-$c_pull/tree/secrets.json"
    printf 'plaintext\n' >"$state_dir/work/apps-$c_pull/secrets.json"
    touch -d '3 days ago' "$state_dir/work/apps-$c_pull"
    # The tree apply.json still names is the crash state a revert restores from: it
    # stays, however old it is.
    mkdir -p "$state_dir/work/apps-$c_v2/render.prev"
    jq -nc --arg work "$state_dir/work/apps-$c_v2" \
        '{schema:1,phase:"installing",commit:"'"$c_v2"'",work:$work,
          previousUnits:[],intendedUnits:[],previousPlan:true,previousState:true,
          previousSecrets:{},intendedSecrets:[],startedAt:"2026-11-21T00:00:00Z"}' | apply_write
    touch -d '3 days ago' "$state_dir/work/apps-$c_v2"
    run_sweep
    same "$rc" 0 "the sweep succeeds"
    absent "$state_dir/work/apps-$c_pull" "a stale work tree is swept"
    [[ -d $state_dir/work/apps-$c_v2/render.prev ]] ||
        fail "the tree apply.json names survives the sweep: $(find "$state_dir/work")"
    same "$(journal_field apps-work-swept '.removed')" 1 "the swept tree is journaled"

    # A tree younger than the grace period is a deploy that may still be in flight.
    reset_case
    run_apply "$c_v1"
    mkdir -p "$state_dir/work/apps-$c_changed"
    printf 'plaintext\n' >"$state_dir/work/apps-$c_changed/secrets.json"
    run_sweep
    [[ -d $state_dir/work/apps-$c_changed ]] || fail "a young work tree is left alone"
}

# --- 12. a revert with no record is a no-op ---------------------------------
revert_with_no_record() {
    fixture
    : >"$log/actions"
    run_revert
}

@test "a revert with no record is a no-op" {
    revert_with_no_record
    assert_equal "$rc" 0
}

@test "a no-op revert touches nothing" {
    revert_with_no_record
    assert [ ! -s "$log/actions" ]
}

# --- 13. a forged app name never reaches a unit instance ---------------------
# The tenant's own unit directory is not a trusted source of names: a file with
# the render marker in it is taken as an installed app, so a forged one lands in
# the departed set. It must be refused and journaled, never spelled into a root
# `systemctl` line or a path under the tenant's home.
apply_a_forged_unit_name() {
    fixture
    run_apply "$c_v1"
    same "$rc" 0 "the base revision applies before the forged unit"
    forged='x;reboot'
    printf '# Rendered from apps/forged/app.toml\n[Container]\nImage=ghcr.io/example/alpha@%s\n' "$d_a" \
        >"$APPS_UNIT_DIR/$forged.container"
    : >"$log/actions"
    : >"$state_dir/journal.jsonl"
    run_apply "$c_empty"
}

@test "an apply that meets a forged unit name rolls back" {
    apply_a_forged_unit_name
    assert_equal "$rc" 5
}

@test "the forged name is journaled" {
    apply_a_forged_unit_name
    assert_equal "$(journal_field apps-name-refused '.name' | head -n 1)" "$forged"
}

@test "the refusal names the sink it was refused at" {
    apply_a_forged_unit_name
    assert_equal "$(journal_field apps-name-refused '.sink' | head -n 1)" remove-departed-unit
}

@test "the forged name never reaches a unit command" {
    apply_a_forged_unit_name
    refute grep -qF -- "$forged" "$log/actions"
}

# The revert cannot restore a unit whose name this deploy would never write, so it
# says so and keeps the record instead of claiming the revision is back.
@test "the incomplete revert is journaled as such" {
    apply_a_forged_unit_name
    assert_equal "$(journal_field apps-revert-failed '.reason' | tail -n 1)" restore-incomplete
}

@test "an incomplete revert keeps the crash record" {
    apply_a_forged_unit_name
    assert [ -s "$state_dir/apply.json" ]
}

# --- 14. only this deploy's own work trees are removed ----------------------
# The path a sweep or a revert removes is named by `apply.json`, which an operator
# can edit, and by a glob over the work directory. The shape is checked on the
# canonical path: a symlink out of the tree, a name that is not a commit, and a
# traversal that resolves elsewhere all survive.
sweep_foreign_work_trees() {
    fixture
    run_apply "$c_v1"
    outside=$work/outside
    mkdir -p "$outside/render.prev" "$state_dir/work/apps-notacommit"
    printf 'keep\n' >"$outside/render.prev/plan.json"
    printf 'keep\n' >"$state_dir/work/apps-notacommit/keep"
    ln -s "$outside" "$state_dir/work/apps-$c_changed"
    touch -h -d '3 days ago' "$state_dir/work/apps-notacommit" "$state_dir/work/apps-$c_changed"
    run_sweep
}

@test "the sweep survives the trees it refuses" {
    sweep_foreign_work_trees
    assert_equal "$rc" 0
}

@test "a symlinked work tree is not followed out of the work directory" {
    sweep_foreign_work_trees
    assert [ -d "$outside/render.prev" ]
}

@test "the refused symlink itself stays" {
    sweep_foreign_work_trees
    assert [ -L "$state_dir/work/apps-$c_changed" ]
}

@test "a directory that is not a commit tree stays" {
    sweep_foreign_work_trees
    assert [ -d "$state_dir/work/apps-notacommit" ]
}

@test "the sweep removes nothing it refused" {
    sweep_foreign_work_trees
    assert_equal "$(journal_field apps-work-swept '.removed')" 0
}

@test "the sweep journals the trees it refused" {
    sweep_foreign_work_trees
    assert_equal "$(journal_field apps-work-kept '.dir' | wc -l)" 2
}

# The same check behind a traversal in the record: apply.json names a path that
# resolves outside the work directory, and the revert's own cleanup refuses it
# even after it has restored everything else.
revert_a_traversal_record() {
    sweep_foreign_work_trees
    traversal=$work/state/work/../../outside
    jq -nc --arg work "$traversal" \
        '{schema:1,phase:"installing",commit:"'"$c_v2"'",work:$work,
          previousUnits:[],intendedUnits:[],previousPlan:false,previousState:false,
          previousSecrets:{},intendedSecrets:[],startedAt:"2026-11-21T00:00:00Z"}' | apply_write
    run_revert
}

@test "a traversal in apply.json removes nothing outside the work directory" {
    revert_a_traversal_record
    assert [ -f "$outside/render.prev/plan.json" ]
}

# --- 15. a revert refuses a state document of another schema ----------------
# The saved state.json is what a revert puts back, and it comes from a snapshot of
# whatever revision was running: a document of another schema is not this
# library's truth, so the revert refuses it, journals, pages and keeps its record
# rather than silently rewriting what the host is recorded as running.
revert_a_foreign_schema_state() {
    fixture
    run_apply "$c_v1"
    stage_interrupted "$c_v2" "$trees/$c_v2/homelab-apps-$c_v2"
    state_staged=$(sha "$state_dir/state.json")
    jq -c '.schema = 2' "$state_dir/work/apps-$c_v2/render.prev/state.json" |
        atomic_write "$state_dir/work/apps-$c_v2/render.prev/state.json"
    : >"$log/notify-urls"
    run_revert
}

@test "a revert refuses a state document of another schema" {
    revert_a_foreign_schema_state
    assert_equal "$rc" 1
}

@test "the refused restore leaves the state alone" {
    revert_a_foreign_schema_state
    assert_equal "$(sha "$state_dir/state.json")" "$state_staged"
}

@test "the refused restore is journaled with its reason" {
    revert_a_foreign_schema_state
    assert_equal "$(journal_field apps-revert-failed '.reason' | head -n 1)" state-schema-mismatch
}

@test "the refused restore pages the deploy check" {
    revert_a_foreign_schema_state
    assert_equal "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail"
}

@test "the refused revert keeps the record" {
    revert_a_foreign_schema_state
    assert [ -s "$state_dir/apply.json" ]
}

# --- 16. state.json keeps a top-level key it does not know -------------------
# state.json has three writers -- the library's state_record_verified, the apps
# apply's state_apps_write and the revert restore -- and four readers. A field a
# newer writer added must survive a round trip through each, or a downgrade
# silently drops it while the readers still expect it.
apply_through_an_unknown_key() {
    fixture
    run_apply "$c_v1"
    jq -c '.future = {added: "by-a-newer-writer"}' "$state_dir/state.json" |
        atomic_write "$state_dir/state.json"
    run_apply "$c_v2"
    kept_rc=$rc
    kept_after_apply=$(jq -r '.future.added' "$state_dir/state.json")
    set_secrets "$secrets_v1b"
    export FAKE_SYSTEMCTL_FAIL_ONCE='restart alpha.service'
    run_apply "$c_v1"
    unset FAKE_SYSTEMCTL_FAIL_ONCE
}

@test "the apply after the unknown key succeeds" {
    apply_through_an_unknown_key
    assert_equal "$kept_rc" 0
}

@test "the apps writer and state_record_verified keep an unknown top-level key" {
    apply_through_an_unknown_key
    assert_equal "$kept_after_apply" by-a-newer-writer
}

@test "the failing apply reverts" {
    apply_through_an_unknown_key
    assert_equal "$rc" 5
}

@test "the revert restore keeps an unknown top-level key" {
    apply_through_an_unknown_key
    assert_equal "$(jq -r '.future.added' "$state_dir/state.json")" by-a-newer-writer
}

# An immutable image root is not a place an apply writes: `df /` there is its own
# 8 MB size, always 0 available, and treating that as a full disk refused every
# apply on a host whose /var had 63G free.
apply_on_a_root() { # <filesystem type> [<mount options>]
    fixture
    printf '/ 0\n' >"$FAKE_DF_MAP"
    printf '/ %s\n' "$1" >"$FAKE_FSTYPE_MAP"
    if [[ -n ${2:-} ]]; then export FAKE_MOUNT_OPTS=$2; fi
    export APPS_FREE_ROOT_PATH=/ APPS_FREE_VAR_PATH=/
    run_apply "$c_v1"
    unset FAKE_MOUNT_OPTS
}

@test "an immutable root is not a space floor" {
    apply_on_a_root composefs
    refute grep -q 'below the' <<<"$out"
}

# On this host `findmnt` reports `overlay` for the composefs root; it is not a
# writable disk and must not refuse an apply.
@test "an overlay root is not a space floor" {
    apply_on_a_root overlay
    refute grep -q 'below the' <<<"$out"
}

# A writable overlay is an ordinary disk; the zero-free floor still applies.
@test "a writable overlay root still refuses the apply" {
    apply_on_a_root overlay rw
    assert grep -q 'below the' <<<"$out"
}

# The same zero free on an ordinary root is still refused.
@test "a full ordinary root refuses the apply" {
    apply_on_a_root ext4
    assert_equal "$rc" 4
}

@test "the refusal names the space floor" {
    apply_on_a_root ext4
    assert grep -q 'below the' <<<"$out"
}
