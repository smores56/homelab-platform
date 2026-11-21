#!/usr/bin/env bash
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
#   tests/deploy/apps.sh
# shellcheck disable=SC2154  # deploy-state.sh assigns these at source time
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

apps=scripts/deploy-apps.sh
schema=scripts/apps-schema.py
lib=scripts/deploy-state.sh
drain=scripts/deploy-drain.sh
gate=scripts/smortress-boot-gate.sh
for file in "$apps" "$schema" "$lib" "$drain" "$gate"; do
  [[ -r $file ]] || {
    printf 'FAIL %s is missing\n' "$file" >&2
    exit 1
  }
done
[[ -x $apps ]] || {
  printf 'FAIL %s is not executable\n' "$apps" >&2
  exit 1
}
for tool in jq timeout python3 tar sha256sum; do
  command -v "$tool" >/dev/null || {
    printf 'FAIL %s is required\n' "$tool" >&2
    exit 1
  }
done

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1" >&2
  [[ -n ${2:-} ]] && printf '     %s\n' "${2//$'\n'/$'\n'     }" >&2
  return 0
}
check_eq() { # got want label
  if [[ $1 == "$2" ]]; then ok "$3"; else bad "$3" "want '$2', got '$1'"; fi
}
check_json() { # doc filter want label
  local got
  got=$(jq -r "$2" <<<"$1" 2>/dev/null)
  check_eq "$got" "$3" "$4"
}
check_file() { # path label
  if [[ -s $1 ]]; then ok "$2"; else bad "$2" "missing or empty: $1"; fi
}
check_no_file() { # path label
  if [[ -e $1 ]]; then bad "$2" "$(cat "$1" 2>/dev/null)"; else ok "$2"; fi
}
check_grep() { # file pattern label
  if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3" "no '$2' in $1"; fi
}
check_no_grep() { # file pattern label
  if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3" "$(grep -F -- "$2" "$1")"; else ok "$3"; fi
}
sha() { sha256sum <"$1" | cut -d' ' -f1; }
json_list() {
  if (($# == 0)); then
    printf '[]\n'
    return 0
  fi
  jq -nc '$ARGS.positional' --args -- "$@"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

bin=$work/bin
log=$work/log
fetch_dir=$work/fetch
secret_store=$work/secret-store
state_dir=$work/state
mkdir -p "$bin" "$log" "$fetch_dir" "$secret_store"

export PATH="$bin:$PATH"
export FAKE_LOG=$log
export FAKE_FETCH_DIR=$fetch_dir
export FAKE_SECRET_STORE=$secret_store
export FAKE_SECRETS_JSON=$work/decrypted-secrets.json
export FAKE_DF_MAP=$work/df-map
export FAKE_FSTYPE_MAP=$work/fstype-map

export DEPLOY_STATE_DIR=$state_dir
export DEPLOY_LOCK_FILE=$work/deploy.lock
export DEPLOY_PING_SECRET=$work/deploy-ping-url.yaml
export APPS_SCHEMA=$root/$schema
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
export DEPLOY_APPS_BIN=$root/$apps
export DEPLOY_DRAIN_RESCAN_PAUSE=0

ping_url=https://hc.invalid/ping/abc

# --- the fakes ---------------------------------------------------------------
# `curl` is both the codeload fetch and the deploy ping: an --output names a tar
# this suite published, anything else is a notification URL.
cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG/curl-argv"
out= url=
while (($#)); do
  case $1 in
    --output) out=$2; shift 2 ;;
    # The deploy hands the ping URL over as a config on stdin so it never appears
    # in argv; `-` is that config's file name.
    --config) shift 2 ;;
    --connect-timeout | --retry | --max-time) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
if [[ -n $out ]]; then
  name=$(basename -- "$url")
  src=$FAKE_FETCH_DIR/$name.tar.gz
  [[ -f $src ]] || {
    printf 'fake-curl: no %s\n' "$src" >&2
    exit 22
  }
  cp -- "$src" "$out"
  exit 0
fi
if [[ -z $url ]]; then
  url=$(sed -n 's/^url = "\(.*\)"$/\1/p' | head -n 1)
fi
printf '%s\n' "$url" >>"$FAKE_LOG/notify-urls"
exit "${FAKE_CURL_EXIT:-0}"
EOF

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
    --user) scope=user ;;
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
printf '%s\n' "$fstype"
EOF

cat >"$bin/bootc" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG/bootc-calls"
exit 0
EOF

# The real tar behind a recorder: the extraction flags are part of the contract,
# and a call into it must still extract a real tarball for the rest of the suite.
real_tar=$(command -v tar)
cat >"$bin/tar" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"\$FAKE_LOG/tar-argv"
exec $real_tar "\$@"
EOF
export APPS_TAR_BIN=$bin/tar

chmod 0755 "$bin"/*

# shellcheck source=/dev/null
source "$lib"

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
  local dir=$work/trees/$1/homelab-apps-$1
  rm -rf "$work/trees/$1"
  mkdir -p "$dir/apps"
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
  local dir=$work/trees/$2/homelab-apps-$2
  rm -rf "$work/trees/$2"
  mkdir -p "$work/trees/$2"
  cp -a "$work/trees/$1/homelab-apps-$1" "$dir"
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

tree=$(new_tree "$c_v1")
mkdir -p "$tree/apps/alpha" "$tree/apps/beta"
alpha_toml "$tree" "$d_a" UTC
beta_toml "$tree" "$d_b"
publish "$c_v1" "$tree"

# Same units, different commit: only the decrypted value moves.
clone_tree "$c_v1" "$c_secret"
publish "$c_secret" "$work/trees/$c_secret/homelab-apps-$c_secret"

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

secrets_v1='{"apps":{"alpha":{"api-key":"one"},"beta":{"beta-key":"beta-one"}},"sops":{}}'
secrets_v1b='{"apps":{"alpha":{"api-key":"two"},"beta":{"beta-key":"beta-one"}},"sops":{}}'

# --- drivers -----------------------------------------------------------------
set_secrets() { printf '%s\n' "$1" >"$FAKE_SECRETS_JSON"; }

reset_case() {
  rm -rf "${APPS_HOME:?}" "${work:?}/var" "${work:?}/run" "${state_dir:?}" "${secret_store:?}" "${log:?}"
  mkdir -p "$APPS_HOME" "$work/run/user/1001" "$secret_store" "$log"
  : >"$FAKE_DF_MAP"
  : >"$FAKE_FSTYPE_MAP"
  : >"$log/sequence"
  deploy_state_init || exit 1
  printf '%s\n' "$ping_url" >"$DEPLOY_PING_SECRET"
  printf 'AGE-SECRET-KEY-FAKE\n' >"$SOPS_AGE_KEY_FILE"
  printf 'rules = []\n' >"$APPS_POLICY"
  set_secrets "$secrets_v1"
  unset FAKE_SYSTEMCTL_FAIL FAKE_SYSTEMCTL_FAIL_ONCE FAKE_PULL_FAIL FAKE_CURL_EXIT \
    FAKE_SOPS_EXIT
}

run_apply() { # <commit>
  out=$(bash "$apps" apply --commit "$1" 2>&1)
  rc=$?
}
run_drain() {
  out=$(timeout 60 bash "$drain" 2>&1)
  rc=$?
}
run_gate() {
  out=$(timeout 60 bash "$gate" 2>&1)
  rc=$?
}
journal_field() { # <event> <jq path>
  jq -r "select(.event==\"$1\") | $2" "$state_dir/journal.jsonl" 2>/dev/null
}
line_of() { # <file> <pattern>
  grep -nF -- "$2" "$1" 2>/dev/null | head -n 1 | cut -d: -f1
}
unit_text() { cat "$APPS_UNIT_DIR/$1" 2>/dev/null; }

# --- 1. a first apply installs the plan, the units, the secrets and Serve -----
reset_case
run_apply "$c_v1"
check_eq "$rc" 0 "a clean commit applies" "$out"
check_file "$APPS_PLAN" "the plan is installed"
check_eq "$(jq -r '.apps | keys | join(" ")' "$APPS_PLAN")" 'alpha beta' \
  "the plan names both apps"
check_file "$APPS_UNIT_DIR/alpha.container" "alpha's unit is installed"
check_file "$APPS_UNIT_DIR/beta.container" "beta's unit is installed"
check_file "$APPS_UNIT_DIR/smortress-apps.network" "the internal network is installed for egress none"
check_grep "$APPS_UNIT_DIR/alpha.container" '# Rendered from apps/alpha/app.toml' \
  "the installed unit is the rendered one"
check_eq "$(cat "$secret_store/app-alpha-api-key" 2>/dev/null)" one \
  "alpha's secret value is in the store"
check_eq "$(cat "$secret_store/app-beta-beta-key" 2>/dev/null)" beta-one \
  "beta's secret value is in the store"
check_file "$state_dir/state.json" "the applied revision is recorded"
check_eq "$(jq -r '.repos["homelab-apps"].commit' "$state_dir/state.json")" "$c_v1" \
  "state records the applied commit"
check_eq "$(journal_field state-verified '.repo')" homelab-apps \
  "the commit is recorded through state_record_verified"
check_eq "$(jq -r '.apps.apps.alpha.unit' "$state_dir/state.json")" \
  "$(sha "$APPS_UNIT_DIR/alpha.container")" "the recorded unit hash is the installed unit's"
if [[ -n $(jq -r '.apps.apps.alpha.secrets // ""' "$state_dir/state.json") ]]; then
  ok "the recorded secret hash is present"
else
  bad "the recorded secret hash is present"
fi
check_json "$(cat "$state_dir/state.json")" '.apps.unitsHash | length' 64 \
  "the whole-set unit hash is recorded"
check_no_file "$state_dir/apply.json" "a committed apply clears the crash record"
check_eq "$(tail -n 1 "$log/notify-urls")" "$ping_url" "a clean apply pings the deploy check"
# The ping URL is the capability to keep the check green: it is handed to curl as
# a config on stdin, so no local account can read it out of /proc.
check_no_grep "$log/curl-argv" "$ping_url" "the ping URL never reaches curl's argv"
check_grep "$log/curl-argv" '--config -' "the ping URL is a curl config on stdin"
# The tarball is untrusted bytes extracted as root: tar must not take ownership,
# modes or the tree's own directory mode from it.
extract=$(grep -F -- '-xzf' "$log/tar-argv" | head -n 1)
for flag in --no-same-owner --no-same-permissions --no-overwrite-dir; do
  if grep -qF -- "$flag" <<<"$extract"; then
    ok "the extraction passes $flag"
  else
    bad "the extraction passes $flag" "$extract"
  fi
done
check_grep "$log/actions" 'system start smortress-app-ingress@alpha' \
  "alpha's ingress is started"
check_grep "$log/actions" 'system start smortress-app-ingress@beta' \
  "beta's ingress is started"

# The quota applier must have read the new plan before any container started.
check_eq "$(sha "$log/quota-plan" 2>/dev/null)" "$(sha "$APPS_PLAN")" \
  "the quota restart reads the new plan"
plan_at=$(line_of "$state_dir/journal.jsonl" '"event":"apps-plan-installed"')
quota_at=$(line_of "$state_dir/journal.jsonl" '"event":"apps-quota-applied"')
if [[ -n $plan_at && -n $quota_at && $plan_at -lt $quota_at ]]; then
  ok "the plan is installed before the quota restart"
else
  bad "the plan is installed before the quota restart" "plan='$plan_at' quota='$quota_at'"
fi

# --- 2. a rejected definition changes nothing and is denylisted --------------
plan_before=$(sha "$APPS_PLAN")
unit_before=$(sha "$APPS_UNIT_DIR/alpha.container")
secret_before=$(cat "$secret_store/app-alpha-api-key")
: >"$log/pulls"
: >"$log/actions"
run_apply "$c_bad"
check_eq "$rc" 3 "a rejected definition exits 3" "$out"
check_eq "$(sha "$APPS_PLAN")" "$plan_before" "a rejected definition leaves the plan untouched"
check_eq "$(sha "$APPS_UNIT_DIR/alpha.container")" "$unit_before" \
  "a rejected definition leaves the units untouched"
check_eq "$(cat "$secret_store/app-alpha-api-key")" "$secret_before" \
  "a rejected definition leaves the secrets untouched"
check_no_file "$state_dir/apply.json" "a rejected definition writes no crash record"
check_json "$(cat "$state_dir/denylist.json" 2>/dev/null || printf '{}')" \
  ".commits[\"$c_bad\"].reason" apps:definition-rejected "a rejected commit is denylisted"
check_eq "$(journal_field apps-rejected '.commit')" "$c_bad" "the rejection is journaled"
if [[ -s $log/pulls ]]; then bad "a rejected definition pulls nothing" "$(cat "$log/pulls")"; else ok "a rejected definition pulls nothing"; fi
if [[ -s $log/actions ]]; then bad "a rejected definition mutates nothing" "$(cat "$log/actions")"; else ok "a rejected definition mutates nothing"; fi
check_eq "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail" "a rejection pages the deploy check"

# --- 3. an empty tenant is refused by the renderer alone ---------------------
empty_tree=$work/trees/$c_empty/homelab-apps-$c_empty
if "$schema" render --root "$empty_tree" --out "$work/empty-refused" >"$log/empty.log" 2>&1; then
  bad "the renderer refuses an empty tenant without --allow-empty" "$(cat "$log/empty.log")"
else
  ok "the renderer refuses an empty tenant without --allow-empty"
fi
if [[ ! -e $work/empty-refused/plan.json ]]; then
  ok "the refused empty render writes no plan"
else
  bad "the refused empty render writes no plan"
fi

# --- 4. an empty tenant applies with --allow-empty and empties Serve's routes -
run_apply "$c_empty"
check_eq "$rc" 0 "the deploy applies an empty tenant" "$out"
check_eq "$(jq -r '.apps | length' "$APPS_PLAN")" 0 "the empty plan has no app"
if [[ -z $(find "$APPS_UNIT_DIR" -maxdepth 1 -type f -name '*.container' -print -quit) ]]; then
  ok "the emptied tenant has no app unit"
else
  bad "the emptied tenant has no app unit" "$(ls "$APPS_UNIT_DIR")"
fi
if [[ -e $APPS_UNIT_DIR/smortress-apps.network ]]; then
  bad "the internal network goes with the last egress-none app"
else
  ok "the internal network goes with the last egress-none app"
fi
if [[ -z $(ls -A "$secret_store" 2>/dev/null) ]]; then
  ok "the emptied tenant has no secrets"
else
  bad "the emptied tenant has no secrets" "$(ls "$secret_store")"
fi
check_grep "$log/actions" 'user stop alpha.service' "a departed app is stopped"
check_grep "$log/actions" 'system stop smortress-app-ingress@alpha' \
  "a departed app's ingress is stopped"
check_json "$(cat "$state_dir/state.json")" '.apps.apps | length' 0 \
  "the emptied tenant records no app"
check_grep "$log/actions" 'system restart smortress-tailscale-serve.service' \
  "Serve is regenerated so the removed route is pruned"

# --- 5. a failed pull changes nothing and leaves no crash record -------------
reset_case
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
check_eq "$rc" 4 "a failed pull exits 4 for a retry" "$out"
check_eq "$(sha "$APPS_PLAN")" "$plan_before" "a failed pull leaves the plan untouched"
check_eq "$(sha "$APPS_UNIT_DIR/alpha.container")" "$unit_before" \
  "a failed pull leaves the units untouched"
check_eq "$(cat "$secret_store/app-alpha-api-key")" "$secret_before" \
  "a failed pull leaves the secrets untouched"
check_no_file "$state_dir/apply.json" "a failed pull leaves no crash record"
check_no_file "$state_dir/work/apps-$c_pull" "a failed pull removes its work tree"
check_eq "$(journal_field apps-pull-failed '.commit')" "$c_pull" "the failed pull is journaled"
check_grep "$log/pulls" "ghcr.io/example/alpha@$d_c" "the changed image is the one pulled"
if [[ -s $log/actions ]]; then
  bad "a failed pull happens before any mutation" "$(cat "$log/actions")"
else
  ok "a failed pull happens before any mutation"
fi
check_eq "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail" "a failed pull pages the deploy check"

# --- 6. pull-all-then-change, and the plan before the quota restart ----------
reset_case
run_apply "$c_v1"
: >"$state_dir/journal.jsonl"
: >"$log/pulls"
: >"$log/actions"
: >"$log/sequence"
run_apply "$c_changed"
check_eq "$rc" 0 "a changed commit applies" "$out"
if [[ -s $log/pulls ]]; then ok "the changed image is pulled"; else bad "the changed image is pulled"; fi
last_pull=$(grep -n 'apps-pulled' "$state_dir/journal.jsonl" | tail -n 1 | cut -d: -f1)
plan_at=$(line_of "$state_dir/journal.jsonl" '"event":"apps-plan-installed"')
if [[ -n $last_pull && -n $plan_at && $last_pull -lt $plan_at ]]; then
  ok "every pull completes before the first mutation"
else
  bad "every pull completes before the first mutation" "pull='$last_pull' plan='$plan_at'"
fi
quota_at=$(line_of "$state_dir/journal.jsonl" '"event":"apps-quota-applied"')
if [[ -n $plan_at && -n $quota_at && $plan_at -lt $quota_at ]]; then
  ok "the plan is installed before the quota reads it"
else
  bad "the plan is installed before the quota reads it" "plan='$plan_at' quota='$quota_at'"
fi
check_eq "$(sha "$log/quota-plan" 2>/dev/null)" "$(sha "$APPS_PLAN")" \
  "the quota applier reads the new plan"
# The command log's own order: every pull is a child of this apply, and the
# first thing it changes is the plan's consumer.
last_pull_cmd=$(grep -n '^pull ' "$log/sequence" | tail -n 1 | cut -d: -f1)
quota_cmd=$(line_of "$log/sequence" 'restart smortress-apps-quota.service')
if [[ -n $last_pull_cmd && -n $quota_cmd && $last_pull_cmd -lt $quota_cmd ]]; then
  ok "the command log shows every pull before the quota restart"
else
  bad "the command log shows every pull before the quota restart" \
    "pull='$last_pull_cmd' quota='$quota_cmd'"
fi
check_eq "$(sha "$log/serve-plan" 2>/dev/null)" "$(sha "$APPS_PLAN")" \
  "Serve is regenerated from the new plan"
check_grep "$log/actions" 'user restart alpha.service' "a changed unit is restarted"

# --- 7. a secret-only change restarts the app that mounts it -----------------
reset_case
run_apply "$c_v1"
: >"$log/pulls"
: >"$log/actions"
: >"$log/secret-creates"
set_secrets "$secrets_v1b"
run_apply "$c_secret"
check_eq "$rc" 0 "a secret-only change applies" "$out"
check_eq "$(cat "$secret_store/app-alpha-api-key")" two "the rotated value is in the store"
check_eq "$(cat "$secret_store/app-beta-beta-key")" beta-one "an unchanged secret keeps its value"
if [[ -s $log/pulls ]]; then
  bad "a secret-only change pulls nothing" "$(cat "$log/pulls")"
else
  ok "a secret-only change pulls nothing"
fi
check_grep "$log/actions" 'user restart alpha.service' "the app whose secret changed is restarted"
check_no_grep "$log/actions" 'user restart beta.service' "an app with no change is not restarted"
check_grep "$log/secret-creates" app-alpha-api-key "the changed secret is replaced"
check_no_file "$state_dir/apply.json" "a committed secret change clears the crash record"

# --- 8. a departed app loses its unit, its secret and its Serve route --------
reset_case
run_apply "$c_v1"
: >"$log/actions"
run_apply "$c_depart"
check_eq "$rc" 0 "a commit that removes an app applies" "$out"
check_no_file "$APPS_UNIT_DIR/beta.container" "the departed unit is removed"
check_file "$APPS_UNIT_DIR/alpha.container" "the remaining unit stays"
check_no_file "$secret_store/app-beta-beta-key" "the departed app's secret is removed"
check_file "$secret_store/app-alpha-api-key" "the remaining secret stays"
check_grep "$log/actions" 'user stop beta.service' "the departed app is stopped"
check_grep "$log/actions" 'system stop smortress-app-ingress@beta' \
  "the departed app's ingress is stopped"
check_grep "$log/actions" 'system restart smortress-tailscale-serve.service' \
  "Serve is regenerated so the departed route is pruned"
check_eq "$(jq -r '.apps | keys | join(" ")' "$APPS_PLAN")" alpha "the plan keeps only the remaining app"
check_json "$(cat "$state_dir/state.json")" '.apps.apps | keys | join(" ")' alpha \
  "state keeps only the remaining app"

# --- 9. a failure mid-apply reverts units, plan, secrets and state -----------
reset_case
run_apply "$c_v1"
plan_before=$(sha "$APPS_PLAN")
unit_before=$(sha "$APPS_UNIT_DIR/alpha.container")
state_before=$(sha "$state_dir/state.json")
: >"$log/actions"
set_secrets "$secrets_v1b"
export FAKE_SYSTEMCTL_FAIL_ONCE='restart alpha.service'
run_apply "$c_v2"
unset FAKE_SYSTEMCTL_FAIL_ONCE
check_eq "$rc" 5 "a failure mid-apply exits 5 after the revert" "$out"
check_eq "$(sha "$APPS_PLAN")" "$plan_before" "the revert restores the previous plan"
check_eq "$(sha "$APPS_UNIT_DIR/alpha.container")" "$unit_before" \
  "the revert restores the previous unit"
check_eq "$(cat "$secret_store/app-alpha-api-key")" one "the revert restores the previous secret value"
check_eq "$(cat "$secret_store/app-beta-beta-key")" beta-one "the revert keeps the untouched secret"
check_eq "$(sha "$state_dir/state.json")" "$state_before" "the revert restores the previous state"
check_no_file "$state_dir/apply.json" "the revert clears the crash record"
check_eq "$(journal_field apps-failed '.commit')" "$c_v2" "the failed apply is journaled"
check_eq "$(journal_field apps-reverted '.commit')" "$c_v2" "the revert is journaled"
check_grep "$log/actions" 'user restart alpha.service' "the restored app is restarted"
check_grep "$log/actions" 'system restart smortress-tailscale-serve.service' \
  "Serve is regenerated for the restored plan"
check_eq "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail" "a reverted apply pages the deploy check"
check_grep "$log/runuser-calls" 'restart alpha.service' "the restore ran as the tenant"

# --- 9b. a revert removes the app the failed apply added ---------------------
reset_case
run_apply "$c_depart"
check_eq "$rc" 0 "the single-app revision applies" "$out"
: >"$log/actions"
set_secrets "$secrets_v1"
export FAKE_SYSTEMCTL_FAIL_ONCE='start beta.service'
run_apply "$c_v1"
unset FAKE_SYSTEMCTL_FAIL_ONCE
check_eq "$rc" 5 "an added app that fails to start rolls back" "$out"
check_no_file "$APPS_UNIT_DIR/beta.container" "the revert removes the added unit"
check_no_file "$secret_store/app-beta-beta-key" "the revert removes the added secret"
check_grep "$log/actions" 'user stop beta.service' "the revert stops the added app"
check_grep "$log/actions" 'system stop smortress-app-ingress@beta' \
  "the revert stops the added app's ingress"
check_eq "$(jq -r '.repos["homelab-apps"].commit' "$state_dir/state.json")" "$c_depart" \
  "the revert keeps the previous commit recorded"
check_file "$APPS_UNIT_DIR/alpha.container" "the previous app's unit stays"

# --- 10. a Serve failure after the commit does not revert --------------------
reset_case
run_apply "$c_v1"
set_secrets "$secrets_v1b"
export FAKE_SYSTEMCTL_FAIL=smortress-tailscale-serve.service
run_apply "$c_v2"
unset FAKE_SYSTEMCTL_FAIL
check_eq "$rc" 0 "a Serve failure still leaves the commit running" "$out"
check_eq "$(jq -r '.repos["homelab-apps"].commit' "$state_dir/state.json")" "$c_v2" \
  "the applied commit stays recorded"
check_eq "$(cat "$secret_store/app-alpha-api-key")" two "the applied secret value stays"
check_no_file "$state_dir/apply.json" "a Serve failure leaves no crash record"
check_eq "$(journal_field apps-serve-failed '.commit')" "$c_v2" "the failed Serve restart is journaled"
if [[ -n $(journal_field apps-reverted '.commit') ]]; then
  bad "a Serve failure does not log a revert"
else
  ok "a Serve failure does not log a revert"
fi
check_eq "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail" "a Serve failure pages the deploy check"

# --- 11. an interrupted apply is reverted by the drain and by the boot gate ---
# The state a killed process leaves: apply.json, the new plan and units already
# installed, one secret already replaced, and the previous revision saved under
# work/render.prev. Both entry points must put all of it back.
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

reset_case
run_apply "$c_v1"
plan_before=$(sha "$APPS_PLAN")
unit_before=$(sha "$APPS_UNIT_DIR/alpha.container")
state_before=$(sha "$state_dir/state.json")
stage_interrupted "$c_v2" "$work/trees/$c_v2/homelab-apps-$c_v2"
check_eq "$(sha "$APPS_PLAN")" "$(sha "$state_dir/work/apps-$c_v2/render.next/plan.json")" \
  "the interrupted apply left the new plan installed"
: >"$log/actions"
run_drain
check_eq "$rc" 0 "the drain exits after reverting the interrupted apply" "$out"
check_eq "$(sha "$APPS_PLAN")" "$plan_before" "the drain restores the previous plan"
check_eq "$(sha "$APPS_UNIT_DIR/alpha.container")" "$unit_before" \
  "the drain restores the previous unit"
check_eq "$(cat "$secret_store/app-alpha-api-key")" one "the drain restores the previous secret"
check_eq "$(sha "$state_dir/state.json")" "$state_before" "the drain restores the previous state"
check_no_file "$state_dir/apply.json" "the drain clears the crash record"
check_eq "$(journal_field apply-reverted '.by')" drain "the drain journals the reverted apply"
check_grep "$log/actions" 'system restart smortress-tailscale-serve.service' \
  "the drain regenerates Serve after the revert"

reset_case
run_apply "$c_v1"
plan_before=$(sha "$APPS_PLAN")
unit_before=$(sha "$APPS_UNIT_DIR/alpha.container")
state_before=$(sha "$state_dir/state.json")
stage_interrupted "$c_v2" "$work/trees/$c_v2/homelab-apps-$c_v2"
: >"$log/actions"
: >"$log/bootc-calls"
run_gate
check_eq "$rc" 0 "the boot gate passes on a boot with no pending deploy" "$out"
check_eq "$(sha "$APPS_PLAN")" "$plan_before" "the gate restores the previous plan"
check_eq "$(sha "$APPS_UNIT_DIR/alpha.container")" "$unit_before" \
  "the gate restores the previous unit"
check_eq "$(cat "$secret_store/app-alpha-api-key")" one "the gate restores the previous secret"
check_eq "$(sha "$state_dir/state.json")" "$state_before" "the gate restores the previous state"
check_no_file "$state_dir/apply.json" "the gate clears the crash record"
check_eq "$(journal_field apply-interrupted '.phase')" installing \
  "the gate journals the interrupted phase it found"
check_eq "$(journal_field apply-reverted '.by')" boot-gate \
  "the gate journals the reverted apply"
# The gate reads the booted digest even here, so a boot state.json does not name
# is noticed (tests/deploy/boot.sh owns that check); it must not switch or roll
# back on a boot with no pending deployment.
if grep -qE '^(switch|rollback)' "$log/bootc-calls" 2>/dev/null; then
  bad "a boot with no pending deploy switches nothing" "$(cat "$log/bootc-calls")"
else
  ok "a boot with no pending deploy switches nothing"
fi

# --- 11b. work trees do not outlive their apply ----------------------------
# A work tree holds the decrypted tenant secrets, so an exit that is not the
# revert path has to take it with it -- including the exits nobody wrote a branch
# for, which is what the trap on the way out is for.
reset_case
mkdir -p "$state_dir/work/apps-$c_v1/tree"
printf '{"apps":{}}\n' >"$state_dir/work/apps-$c_v1/tree/secrets.json"
printf 'plaintext\n' >"$state_dir/work/apps-$c_v1/secrets.json"
# A journal that cannot be appended stops the apply before its first mutation.
rm -f "$state_dir/journal.jsonl"
mkdir -p "$state_dir/journal.jsonl"
run_apply "$c_v1"
rmdir "$state_dir/journal.jsonl"
check_eq "$rc" 4 "an exit before the first mutation exits 4" "$out"
if [[ -e $state_dir/work/apps-$c_v1 ]]; then
  bad "a failed apply takes its work tree with it" "$(find "$state_dir/work/apps-$c_v1")"
else
  ok "a failed apply takes its work tree with it"
fi

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
out=$(bash "$apps" sweep 2>&1)
rc=$?
check_eq "$rc" 0 "the sweep succeeds" "$out"
if [[ -e $state_dir/work/apps-$c_pull ]]; then
  bad "a stale work tree is swept" "$(find "$state_dir/work/apps-$c_pull")"
else
  ok "a stale work tree is swept"
fi
if [[ -d $state_dir/work/apps-$c_v2/render.prev ]]; then
  ok "the tree apply.json names survives the sweep"
else
  bad "the tree apply.json names survives the sweep" "$(find "$state_dir/work")"
fi
check_eq "$(journal_field apps-work-swept '.removed')" 1 "the swept tree is journaled"
# A tree younger than the grace period is a deploy that may still be in flight.
reset_case
run_apply "$c_v1"
mkdir -p "$state_dir/work/apps-$c_changed"
printf 'plaintext\n' >"$state_dir/work/apps-$c_changed/secrets.json"
out=$(bash "$apps" sweep 2>&1)
if [[ -d $state_dir/work/apps-$c_changed ]]; then
  ok "a young work tree is left alone"
else
  bad "a young work tree is left alone"
fi

# --- 12. a revert with no record is a no-op ---------------------------------
reset_case
: >"$log/actions"
out=$(bash "$apps" revert 2>&1)
rc=$?
check_eq "$rc" 0 "a revert with no record is a no-op" "$out"
if [[ -s $log/actions ]]; then bad "a no-op revert touches nothing" "$(cat "$log/actions")"; else ok "a no-op revert touches nothing"; fi


# --- 13. a forged app name never reaches a unit instance ---------------------
# The tenant's own unit directory is not a trusted source of names: a file with
# the render marker in it is taken as an installed app, so a forged one lands in
# the departed set. It must be refused and journaled, never spelled into a root
# `systemctl` line or a path under the tenant's home.
reset_case
run_apply "$c_v1"
check_eq "$rc" 0 "the base revision applies before the forged unit" "$out"
forged='x;reboot'
printf '# Rendered from apps/forged/app.toml\n[Container]\nImage=ghcr.io/example/alpha@%s\n' "$d_a" \
  >"$APPS_UNIT_DIR/$forged.container"
: >"$log/actions"
: >"$state_dir/journal.jsonl"
run_apply "$c_empty"
check_eq "$rc" 5 "an apply that meets a forged unit name rolls back" "$out"
check_eq "$(journal_field apps-name-refused '.name' | head -n 1)" "$forged" \
  "the forged name is journaled"
check_eq "$(journal_field apps-name-refused '.sink' | head -n 1)" remove-departed-unit \
  "the refusal names the sink it was refused at"
if grep -qF -- "$forged" "$log/actions" 2>/dev/null; then
  bad "the forged name never reaches a unit command" "$(grep -F -- "$forged" "$log/actions")"
else
  ok "the forged name never reaches a unit command"
fi
# The revert cannot restore a unit whose name this deploy would never write, so it
# says so and keeps the record instead of claiming the revision is back.
check_eq "$(journal_field apps-revert-failed '.reason' | tail -n 1)" restore-incomplete \
  "the incomplete revert is journaled as such"
check_file "$state_dir/apply.json" "an incomplete revert keeps the crash record"

# --- 14. only this deploy's own work trees are removed ----------------------
# The path a sweep or a revert removes is named by `apply.json`, which an operator
# can edit, and by a glob over the work directory. The shape is checked on the
# canonical path: a symlink out of the tree, a name that is not a commit, and a
# traversal that resolves elsewhere all survive.
reset_case
run_apply "$c_v1"
outside=$work/outside
mkdir -p "$outside/render.prev" "$state_dir/work/apps-notacommit"
printf 'keep\n' >"$outside/render.prev/plan.json"
printf 'keep\n' >"$state_dir/work/apps-notacommit/keep"
ln -s "$outside" "$state_dir/work/apps-$c_changed"
touch -h -d '3 days ago' "$state_dir/work/apps-notacommit" "$state_dir/work/apps-$c_changed"
out=$(bash "$apps" sweep 2>&1)
rc=$?
check_eq "$rc" 0 "the sweep survives the trees it refuses" "$out"
if [[ -d $outside/render.prev ]]; then
  ok "a symlinked work tree is not followed out of the work directory"
else
  bad "a symlinked work tree is not followed out of the work directory"
fi
if [[ -L $state_dir/work/apps-$c_changed ]]; then
  ok "the refused symlink itself stays"
else
  bad "the refused symlink itself stays" "$(ls -l "$state_dir/work")"
fi
if [[ -d $state_dir/work/apps-notacommit ]]; then
  ok "a directory that is not a commit tree stays"
else
  bad "a directory that is not a commit tree stays"
fi
check_eq "$(journal_field apps-work-swept '.removed')" 0 "the sweep removes nothing it refused"
check_eq "$(journal_field apps-work-kept '.dir' | wc -l)" 2 "the sweep journals the trees it refused"
# The same check behind a traversal in the record: apply.json names a path that
# resolves outside the work directory, and the revert's own cleanup refuses it
# even after it has restored everything else.
traversal=$work/state/work/../../outside
jq -nc --arg work "$traversal" \
  '{schema:1,phase:"installing",commit:"'"$c_v2"'",work:$work,
    previousUnits:[],intendedUnits:[],previousPlan:false,previousState:false,
    previousSecrets:{},intendedSecrets:[],startedAt:"2026-11-21T00:00:00Z"}' | apply_write
out=$(bash "$apps" revert 2>&1)
if [[ -f $outside/render.prev/plan.json ]]; then
  ok "a traversal in apply.json removes nothing outside the work directory"
else
  bad "a traversal in apply.json removes nothing outside the work directory" "$out"
fi

# --- 15. a revert refuses a state document of another schema ----------------
# The saved state.json is what a revert puts back, and it comes from a snapshot of
# whatever revision was running: a document of another schema is not this
# library's truth, so the revert refuses it, journals, pages and keeps its record
# rather than silently rewriting what the host is recorded as running.
reset_case
run_apply "$c_v1"
stage_interrupted "$c_v2" "$work/trees/$c_v2/homelab-apps-$c_v2"
state_staged=$(sha "$state_dir/state.json")
jq -c '.schema = 2' "$state_dir/work/apps-$c_v2/render.prev/state.json" |
  atomic_write "$state_dir/work/apps-$c_v2/render.prev/state.json"
: >"$log/notify-urls"
out=$(bash "$apps" revert 2>&1)
rc=$?
check_eq "$rc" 1 "a revert refuses a state document of another schema" "$out"
check_eq "$(sha "$state_dir/state.json")" "$state_staged" "the refused restore leaves the state alone"
check_eq "$(journal_field apps-revert-failed '.reason' | head -n 1)" state-schema-mismatch \
  "the refused restore is journaled with its reason"
check_eq "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail" \
  "the refused restore pages the deploy check"
check_file "$state_dir/apply.json" "the refused revert keeps the record"

# --- 16. state.json keeps a top-level key it does not know -------------------
# state.json has three writers -- the library's state_record_verified, the apps
# apply's state_apps_write and the revert restore -- and four readers. A field a
# newer writer added must survive a round trip through each, or a downgrade
# silently drops it while the readers still expect it.
reset_case
run_apply "$c_v1"
jq -c '.future = {added: "by-a-newer-writer"}' "$state_dir/state.json" |
  atomic_write "$state_dir/state.json"
run_apply "$c_v2"
check_eq "$rc" 0 "the apply after the unknown key succeeds" "$out"
check_eq "$(jq -r '.future.added' "$state_dir/state.json")" by-a-newer-writer \
  "the apps writer and state_record_verified keep an unknown top-level key"
set_secrets "$secrets_v1b"
export FAKE_SYSTEMCTL_FAIL_ONCE='restart alpha.service'
run_apply "$c_v1"
unset FAKE_SYSTEMCTL_FAIL_ONCE
check_eq "$rc" 5 "the failing apply reverts" "$out"
check_eq "$(jq -r '.future.added' "$state_dir/state.json")" by-a-newer-writer \
  "the revert restore keeps an unknown top-level key"

# An immutable image root is not a place an apply writes: `df /` there is its own
# 8 MB size, always 0 available, and treating that as a full disk refused every
# apply on a host whose /var had 63G free.
printf '0\n' >"$FAKE_DF_MAP"
printf '/ 0\n' >"$FAKE_DF_MAP"
printf '/ composefs\n' >"$FAKE_FSTYPE_MAP"
reset_case
printf '/ 0\n' >"$FAKE_DF_MAP"
printf '/ composefs\n' >"$FAKE_FSTYPE_MAP"
APPS_FREE_ROOT_PATH=/ APPS_FREE_VAR_PATH=/ run_apply "$c_v1"
if grep -q 'below the' <<<"$out"; then
  bad "an immutable root is not a space floor" "$out"
else
  ok "an immutable root is not a space floor"
fi

# The same zero free on an ordinary root is still refused.
reset_case
printf '/ 0\n' >"$FAKE_DF_MAP"
printf '/ ext4\n' >"$FAKE_FSTYPE_MAP"
APPS_FREE_ROOT_PATH=/ APPS_FREE_VAR_PATH=/ run_apply "$c_v1"
if ((rc == 4)); then
  ok "a full ordinary root refuses the apply"
else
  bad "a full ordinary root refuses the apply" "$out rc=$rc"
fi
if grep -q 'below the' <<<"$out"; then
  ok "the refusal names the space floor"
else
  bad "the refusal names the space floor" "$out"
fi


printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
