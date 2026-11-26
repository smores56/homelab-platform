# The shared half of the apps apply/revert suites: the fakes, the published
# commits, the per-test fixture, the drivers and the assertions (§1-§16 of the
# suite that was tests/deploy/apps.sh, split by section for parallel files).
#
# Sourced by tests/deploy/apps-*.bats through `load ./apps_lib`; bats sources it
# afresh for every test, so it only defines functions and the paths they read.
# `repo_root` comes from tests/helpers.bash, and the fixtures and driver outputs
# here are read by the section files that source this one, so a check of this
# file alone sees them unassigned or unused.
# shellcheck disable=SC2154,SC2034

apps=scripts/deploy-apps.sh
schema=scripts/apps-schema.py
lib=scripts/deploy-state.sh
drain=scripts/deploy-drain.sh
gate=scripts/smortress-boot-gate.sh
ping_url=https://hc.invalid/ping/abc

# The fakes, the published commits and the published tarballs are the same for
# every test, so they are built once for the file under $BATS_FILE_TMPDIR and
# read-only afterwards; each test's own tree is under $BATS_TEST_TMPDIR.
apps_setup_file() {
    bin=$BATS_FILE_TMPDIR/bin
    trees=$BATS_FILE_TMPDIR/trees
    fetch_dir=$BATS_FILE_TMPDIR/fetch
    mkdir -p "$bin" "$trees" "$fetch_dir"
    install_fakes "$bin"
    build_fixtures
}

apps_setup() {
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
# install_fake_curl in the old lib.sh did.
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
    # Three knobs the suite has to bend. Transport failures are retried with a
    # hardcoded `sleep 1` between attempts (scripts/deploy/apps/transport.sh); 3
    # bounds an exhausted retry loop at three seconds instead of the host's 180,
    # and the window stays at the host's default unless a case is proving it;
    # `sleep` itself is not shadowed on PATH, because the settle window §9e/§9i
    # prove is paced by it -- a fake sleep would turn that window into a fork
    # storm. The boot gate pauses 4 s before its rescan on a real boot; that pause
    # is off here.
    export APPS_CTL_RETRIES=3
    unset APPS_CTL_RETRY_WINDOW
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
# tests/deploy/receiver.bats' reader of the journal this library writes. The shell
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

# --- the assertions §1-§4 make through ---------------------------------------
# bats gives a test one name, and §1-§4 are one test, so the text the shell suite
# printed after `ok` rides along as the last argument of each assertion instead:
# it is the same text the conversion compared by name, it survives a failure message, and
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
