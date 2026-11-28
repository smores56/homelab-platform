#!/usr/bin/env bats
# bats file_tags=lint
# The `PR gate` required check: what it reports, and what it is held to.
#
#   bats tests/ci-gate.bats
#
# Two halves. scripts/ci-gate.py decides the check from `needs`, and the decision
# is a program so these tests can drive it offline: skipped passes (the area was
# not selected for this diff), failure and cancelled fail, and a job missing from
# `needs` fails, because otherwise deleting an area job would quietly narrow the
# gate while the required check still turned green.
#
# The other half is the wiring those rules depend on: the gate's `needs` is
# exactly the job list scripts/ci-areas.sh names, so a new job cannot be added
# without the gate following it, the gate job is named `PR gate` and carries
# `if: always()`, and an edit to the gate's own definition needs the owner.
load helpers

workflow=.github/workflows/ci.yml

# job_block <id>: one job's lines from ci.yml, in file order.
job_block() {
    awk -v want="  $1:" '
        $0 == want { found = 1; next }
        found && /^  [a-z][a-z0-9-]*:/ { exit }
        found
    ' "$workflow"
}

# gate_needs: the job ids the gate's `needs:` list names.
gate_needs() {
    job_block gate |
        awk '/^    needs:/ { listed = 1; next } listed && /^      - / { print $2 } listed && !/^      - / { exit }'
}

# results [<job>=<result>...]: a needs context with every gated job passing,
# then the overrides applied. The fixture is generated from the workflow rather
# than pasted, so a job added to ci.yml arrives here without an edit.
results() {
    local job result sep=''
    printf '{'
    while IFS= read -r job; do
        result=success
        for override in "$@"; do
            if [[ $override == "$job="* ]]; then result=${override#*=}; fi
        done
        printf '%s"%s":{"result":"%s","outputs":{}}' "$sep" "$job" "$result"
        sep=,
    done < <(scripts/ci-areas.sh --jobs)
    printf '}\n'
}

# without <job>: the same context with one key deleted.
without() {
    python3 -c 'import json, sys
needs = json.load(sys.stdin)
del needs[sys.argv[1]]
print(json.dumps(needs))' "$1"
}

# extra <job>: the same context plus one job the selector does not name.
extra() {
    python3 -c 'import json, sys
needs = json.load(sys.stdin)
needs[sys.argv[1]] = {"result": "success", "outputs": {}}
print(json.dumps(needs))' "$1"
}

# gate <json> [<ci-gate.py args>...]: the decision, driven from a fixture.
gate() {
    local json=$1
    shift
    local -a jobs
    mapfile -t jobs < <(scripts/ci-areas.sh --jobs)
    printf '%s' "$json" >"$BATS_TEST_TMPDIR/needs.json"
    run scripts/ci-gate.py --needs "$BATS_TEST_TMPDIR/needs.json" \
        --expected "${jobs[@]}" --require-success changes "$@"
}

# --- the decision ------------------------------------------------------------

@test "every job passing passes the gate" {
    gate "$(results)"
    assert_success
    assert_output --partial 'pr gate:'
}

@test "a skipped area passes the gate" {
    # The selector did not name the area for this diff. Treating that as a fail
    # would put every area back on every pull request.
    gate "$(results core=skipped deploy=skipped)"
    assert_success
    assert_output --partial 'ok   core'
}

@test "a failed area fails the gate" {
    gate "$(results deploy=failure)"
    assert_failure
    assert_output --partial 'deploy: failure'
}

@test "a cancelled area fails the gate" {
    gate "$(results apps=cancelled)"
    assert_failure
    assert_output --partial 'apps: cancelled'
}

@test "a job missing from needs fails the gate" {
    # The area job was deleted from ci.yml. Without this rule the gate would go
    # green on a diff that job used to cover.
    gate "$(results | without core)"
    assert_failure
    assert_output --partial 'core: missing from needs'
}

@test "the selector itself cannot be skipped" {
    # Every area reads the selector's answer: a skipped selector means nothing is
    # known about the diff, which is not the same as nothing being needed.
    gate "$(results changes=skipped)"
    assert_failure
    assert_output --partial 'changes: skipped'
}

@test "a dependency the selector does not name fails the gate" {
    gate "$(results | extra surprise)"
    assert_failure
    assert_output --partial 'surprise: needs it'
}

@test "a needs context that is not JSON fails the gate" {
    gate 'not json'
    assert_failure
    assert_output --partial 'needs is not JSON'
}

# --- the wiring --------------------------------------------------------------

@test "the gate reports as PR gate and always reports" {
    # The name is the required check's identity: the ruleset names it, so it is
    # asserted literally. always() is what keeps a failed dependency from turning
    # into a skipped required check the pull request waits on forever.
    run job_block gate
    assert_success
    assert_output --partial '    name: PR gate'
    assert_output --partial '    if: always()'
}

@test "the gate needs every job the selector names" {
    local -a expected
    mapfile -t expected < <(scripts/ci-areas.sh --jobs)
    assert_equal "$(gate_needs)" "$(printf '%s\n' "${expected[@]}")"
}

@test "every area waits on the selector" {
    bad=''
    for area in $(scripts/ci-areas.sh --areas); do
        grep -qx '    needs: changes' <<<"$(job_block "$area")" || bad="$bad $area"
    done
    assert_equal "$bad" ""
}

@test "the selector names only jobs ci.yml declares" {
    declared=$(
        awk '/^jobs:/ { injobs = 1; next }
             injobs && /^  [a-z][a-z0-9-]*:[[:space:]]*$/ {
                 job = $1; sub(/:$/, "", job); print job
             }' "$workflow"
    )
    missing=''
    for job in $(scripts/ci-areas.sh --jobs); do
        grep -qx "$job" <<<"$declared" || missing="$missing $job"
    done
    assert_equal "$missing" ""
    assert_equal \
        "$(scripts/ci-areas.sh --areas)" \
        "$(scripts/ci-areas.sh --jobs | grep -vx changes)"
}

@test "the pull request trigger names no paths" {
    # A `paths:` filter leaves a required check Pending instead of skipping it;
    # the selector answer inside the run is what narrows the work.
    triggers=$(
        awk '/^on:/ { on = 1; next } on && /^[A-Za-z_]/ { on = 0; next } on' "$workflow" |
            grep -cE '^    paths(-ignore)?:' || true
    )
    assert_equal "$triggers" "0"
}

# --- the gate's own definition ----------------------------------------------

@test "a diff that edits the gate needs the owner" {
    # On a pull_request a same-repo branch runs the head's workflow file, so the
    # diff judges itself: only the owner may ship one.
    for path in .github/workflows/ci.yml scripts/ci-areas.sh scripts/ci-gate.py; do
        run env ACTOR=machine-user OWNER=smores56 scripts/ci-areas.sh --guard "$path"
        assert_failure
        assert_output --partial 'is not smores56'
    done
}

@test "the owner may edit the gate" {
    run env ACTOR=smores56 OWNER=smores56 scripts/ci-areas.sh --guard .github/workflows/ci.yml
    assert_success
    assert_output --partial 'edited by the owner'
    assert_output --partial 'fork-pr-secret-boundary'
}

@test "a diff outside the gate needs no owner" {
    run env ACTOR=machine-user OWNER=smores56 scripts/ci-areas.sh --guard docs/core/apps-tenant.md
    assert_success
    assert_output "lint"
}

@test "the guard fails closed with no actor" {
    run env -u ACTOR OWNER=smores56 scripts/ci-areas.sh --guard .github/workflows/ci.yml
    assert_failure
}

# --- selection ---------------------------------------------------------------

@test "a docs-only diff selects the lint area alone" {
    # check-doc-refs.py is what reads docs/, so a documentation change needs the
    # area that runs it -- and nothing else.
    run scripts/ci-areas.sh docs/core/apps-tenant.md
    assert_success
    assert_output "lint"
}

@test "a tofu change selects the plan" {
    run scripts/ci-areas.sh tofu/dns.tf
    assert_success
    assert_output --partial 'plan'
}

@test "a workflow change selects the secret boundary" {
    run scripts/ci-areas.sh .github/workflows/ci.yml
    assert_success
    assert_output --partial 'fork-pr-secret-boundary'
}

@test "a path no row claims selects every area" {
    # tags.tsv's own rule, carried through: the table fails open, so a path
    # nobody thought of runs everything rather than nothing.
    run scripts/ci-areas.sh brand/new/thing
    assert_success
    assert_equal "$output" "$(scripts/ci-areas.sh --areas)"
}

@test "an unclaimed script selects every area too" {
    run scripts/ci-areas.sh lib/deploy/verify.py
    assert_output --partial 'drift'
    assert_output --partial 'deploy'
}
