#!/usr/bin/env bats
# bats file_tags=apps
# Offline checks for the boot reconcile of the root app ingress (#150).
#
# `smortress-app-ingress@<name>` is a static template, so `systemctl enable` has
# nothing to hook and only an apps apply ever starts an instance. A reboot then
# brings the tenant's containers back and leaves every `/apps/<name>` route
# answering nothing -- measured across six boots on 2026-11-25, where the route
# stayed dead until a human started the unit. This drives the real reconcile
# script against a stub manager and asserts it starts one instance per planned
# app, stops the instances the plan dropped, and touches nothing on a host with
# no plan or a plan that does not verify.
#
#   bats tests/apps/ingress-reconcile.bats
#
# The stub manager, the plan and the log are written per test, so no check
# shares a log or a definition with another.
load ../helpers

script=scripts/apps-ingress-reconcile.sh

setup() {
    [ -r "$script" ]
    work=$BATS_TEST_TMPDIR
    mkdir -p "$work/bin"
    export FAKE_LOG=$work/log
    : >"$FAKE_LOG"

    # list-units is the stub's only answer; every other verb is recorded and
    # succeeds, except the one FAKE_FAIL_ON names, so a suite can prove that one
    # app's failure does not abandon the others.
    cat >"$work/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$FAKE_LOG"
if [[ ${1-} == list-units ]]; then
  [[ -n ${FAKE_UNITS:-} ]] && printf '%s\n' "$FAKE_UNITS"
  exit 0
fi
[[ ${FAKE_FAIL_ON:-} == "${1-} ${*: -1}" ]] && exit 1
exit 0
EOF
    # Mimics the shipped CLI: verify-plan takes --plan, anything else is a usage
    # error, so a wrong invocation cannot pass on a lenient stub.
    cat >"$work/bin/schema" <<'EOF'
#!/usr/bin/env bash
printf 'schema %s\n' "$*" >>"$FAKE_LOG"
[[ ${1-} == verify-plan && ${2-} == --plan ]] || { echo 'usage: apps-schema verify-plan --plan PLAN' >&2; exit 2; }
[[ ${FAKE_SCHEMA_REJECT:-} == 1 ]] && { echo "plan: foreign path"; exit 1; }
exit 0
EOF
    chmod +x "$work/bin/"*

    plan=$work/plan.json
    cat >"$plan" <<'JSON'
{"version": 1, "apps": {
  "alpha": {"loopbackPort": 20007, "containerPort": 8080},
  "beta": {"loopbackPort": 20008, "containerPort": 8081}}}
JSON
}

# reconcile_run: one run of the real script against the stubs, log cleared first.
reconcile_run() {
    : >"$FAKE_LOG"
    APPS_SCHEMA=$work/bin/schema APPS_PLAN=${APPS_PLAN:-$plan} \
        SYSTEMCTL=$work/bin/systemctl PATH=$work/bin:$PATH \
        bash "$script" >"$work/out" 2>"$work/err"
}

@test "every app in the plan gets an instance" {
    run reconcile_run
    assert_equal "$status" 0
    assert_contains "$(cat "$FAKE_LOG")" 'smortress-app-ingress@alpha.service'
    assert_contains "$(cat "$FAKE_LOG")" 'smortress-app-ingress@beta.service'
    [[ $(grep -c '^systemctl start' "$FAKE_LOG") == 2 ]]
}

@test "the starts do not wait for the containers" {
    run reconcile_run
    assert_contains "$(cat "$FAKE_LOG")" 'systemctl start --no-block smortress-app-ingress@alpha.service'
}

@test "an instance the plan dropped is stopped" {
    export FAKE_UNITS=$'smortress-app-ingress@gamma.service loaded active running Root ingress'
    run reconcile_run
    assert_equal "$status" 0
    assert_contains "$(cat "$FAKE_LOG")" 'systemctl stop smortress-app-ingress@gamma.service'
    [[ $(grep -c '^systemctl start' "$FAKE_LOG") == 2 ]]
}

@test "a planned app that is already running is not stopped" {
    export FAKE_UNITS=$'smortress-app-ingress@alpha.service loaded active running Root ingress'
    run reconcile_run
    ! grep -q '^systemctl stop' "$FAKE_LOG"
}

@test "no plan is a host with no tenant" {
    export APPS_PLAN=$work/absent.json
    run reconcile_run
    assert_equal "$status" 0
    ! grep -q '^systemctl ' "$FAKE_LOG"
}

@test "the plan is verified before anything is started" {
    run reconcile_run
    assert_equal "$(head -1 "$FAKE_LOG")" "schema verify-plan --plan $plan"
}

@test "a plan that does not verify stops the run" {
    export FAKE_SCHEMA_REJECT=1
    run reconcile_run
    assert_not_equal "$status" 0
    run grep -q '^systemctl ' "$FAKE_LOG"
    assert_failure
    assert_contains "$(cat "$work/err")" 'not accepted'
}

@test "one failing start still reconciles the rest" {
    export FAKE_FAIL_ON='start smortress-app-ingress@beta.service'
    run reconcile_run
    assert_not_equal "$status" 0
    assert_contains "$(cat "$FAKE_LOG")" 'systemctl start --no-block smortress-app-ingress@alpha.service'
    assert_contains "$(cat "$FAKE_LOG")" 'systemctl start --no-block smortress-app-ingress@beta.service'
}

@test "the instance template is configurable" {
    export APPS_INGRESS_TEMPLATE='other-ingress@'
    run reconcile_run
    assert_equal "$status" 0
    assert_contains "$(cat "$FAKE_LOG")" 'systemctl start --no-block other-ingress@alpha.service'
}

# A script that is tested but never shipped is dead code, and a unit that is
# shipped but never enabled never runs.
@test "the image installs the reconcile helper" {
    grep -q 'scripts/apps-ingress-reconcile.sh' bootc/server/Containerfile
}

@test "the unit runs the installed helper" {
    grep -q 'ExecStart=/usr/libexec/apps-ingress-reconcile' units/systemd/smortress-app-ingress-reconcile.service
}

@test "the image enables the reconcile" {
    grep -q 'smortress-app-ingress-reconcile.service' bootc/server/Containerfile
}

@test "the reconcile is ordered after the tenant's prerequisites and logind" {
    grep -qE '^After=.*smortress-apps-quota\.service' units/systemd/smortress-app-ingress-reconcile.service
    grep -qE '^After=.*systemd-logind\.service' units/systemd/smortress-app-ingress-reconcile.service
}
