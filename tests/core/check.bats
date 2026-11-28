#!/usr/bin/env bats
# bats file_tags=core
# Offline checks for the deploy CLI and the runbook that drives it (SDLC #703).
#
# The privileged half -- restoring from a real repository, reading the host's own
# state -- needs smortress and root. This checks the half that does not: the verbs
# the CLI dispatches and documents, the secret manifest behind them, and the runbook
# steps the state tree depends on.
#
# The harnesses the shell suite chained inline -- restic-plane, the progress
# command, agent-recovery, the Quadlet suites and the agent shell dispatcher --
# are separate suites the runner runs on their own; operator-access was the one
# this task converted. This file keeps only the static assertions.
#
#   bats tests/core/check.bats
load ../helpers

cli=scripts/deploy-cli.sh
runbook=docs/manual-steps.md

# ------------------------------------------------------------- the operator CLI

# The verbs the dispatch implements: the labels of the top-level `case ... in`
# block, which is the command switch. The previous derivation matched any indented
# `word)` line, so a function-local `case` arm or a reformatted block changed the
# answer silently -- and reading only the usage text would accept a CLI whose
# usage lists a verb the dispatch no longer has.
cli_dispatch_verbs() { # <file>
    awk '
    /^case .* in$/ { inside = 1; next }
    inside && /^esac/ { inside = 0; next }
    inside {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^[a-z][a-z0-9-]*\)$/) { sub(/\)$/, "", line); print line }
    }
  ' "$1" | sort -u
}

# The verbs the usage block promises: a line whose first word is the program,
# optionally after `usage: `. Prose does not start with the program name, so a
# sentence like "the smortress-deploy path" is not a verb.
cli_usage_verbs() { # <file>
    sed -nE 's/^[[:space:]]*(usage:[[:space:]]+)?smortress-deploy[[:space:]]+([a-z][a-z0-9-]*).*/\2/p' "$1" |
        sort -u
}

# The usage block must name every verb the dispatch implements, or the CLI has a
# command nobody can find. Fewer documented verbs than dispatched ones is the
# failure this names instead of quietly checking nothing.
cli_usage_complete() { # <file>
    local -a dispatched=() usage=()
    local verb
    mapfile -t dispatched < <(cli_dispatch_verbs "$1")
    mapfile -t usage < <(cli_usage_verbs "$1")
    ((${#dispatched[@]})) || return 1
    for verb in "${dispatched[@]}"; do
        printf '%s\n' "${usage[@]}" | grep -qx -- "$verb" || return 1
    done
}

# A verb a document runs, as opposed to one it mentions: the program is spelled
# as the installed path, at the start of the line (after a prompt, a code fence
# or `sudo`). This is what stops "the smortress-deploy path" being read as a verb
# named `path` and failing the check that every documented verb exists.
cli_documented_verbs() { # <files...>
    grep -rhoE '^[[:space:]]*(```[a-z]*[[:space:]]*)?(\$[[:space:]]+)?(sudo[[:space:]]+)?/usr/libexec/smortress-deploy[[:space:]]+[a-z][a-z0-9-]*' "$@" |
        awk '{ print $NF }' | sort -u
}

runbook_starts_verb() { # <verb>
    grep -qE "smortress-deploy $1([[:space:]]|\`|\\||$)" "$runbook"
}

@test "the operator CLI implements the verbs the design names and documents them all" {
    mapfile -t cli_verbs < <(cli_dispatch_verbs "$cli")
    cli_usage_complete "$cli"
    printf '%s\n' "${cli_verbs[@]}" | grep -qx bootstrap
}

for cli_verb in $(cli_dispatch_verbs "$cli"); do
    register "the runbook starts smortress-deploy $cli_verb" runbook_starts_verb "$cli_verb"
done

# The other direction, over every document an operator reads.
@test "every documented smortress-deploy verb exists" {
    mapfile -t cli_verbs < <(cli_dispatch_verbs "$cli")
    undocumented=''
    while IFS= read -r verb; do
        [[ -n $verb ]] || continue
        printf '%s\n' "${cli_verbs[@]}" | grep -qx -- "$verb" || undocumented+="$verb "
    done < <(cli_documented_verbs docs README.md)
    if [[ -n $undocumented ]]; then
        printf 'the docs run %sbut the CLI does not implement it\n' "$undocumented" >&2
        return 1
    fi
}

# The derivation, held against edits of the files it reads. A reformatted usage
# block still yields the four verbs, a usage block that dropped a dispatched verb
# fails instead of shrinking the set, and a sentence about the program is not an
# invocation.
make_verb_fixture() { # -> the fixture directory
    local fixture=$BATS_TEST_TMPDIR/verbs
    mkdir -p "$fixture"
    cat >"$fixture/cli.sh" <<'FIXTURE'
#!/usr/bin/env bash
usage() {
  cat >&2 <<'EOF'
usage: smortress-deploy status
       smortress-deploy release --force
       smortress-deploy unblock <commit|digest> <value>
       smortress-deploy bootstrap <repo> <commit>

  the smortress-deploy path from the runbook)
EOF
}
cmd=${1-}
case $cmd in
  status)
    shift
    ;;
  release)
    shift
    ;;
  unblock)
    shift
    ;;
  bootstrap)
    shift
    ;;
  *)
    exit 2
    ;;
esac
FIXTURE
    sed '/smortress-deploy bootstrap <repo>/d' "$fixture/cli.sh" >"$fixture/cli-dropped.sh"
    printf 'See the smortress-deploy path from the runbook.\n' >"$fixture/runbook.md"
    printf '%s\n' "$fixture"
}

@test "the verb derivation survives a reformatted usage block and prose" {
    fixture=$(make_verb_fixture)
    cli_usage_complete "$fixture/cli.sh"
    assert_equal "$(cli_dispatch_verbs "$fixture/cli.sh" | tr '\n' ' ')" 'bootstrap release status unblock '
}

@test "a usage block missing a dispatched verb fails loudly" {
    fixture=$(make_verb_fixture)
    ! cli_usage_complete "$fixture/cli-dropped.sh"
}

@test "prose about the program is not a documented verb" {
    fixture=$(make_verb_fixture)
    assert_equal "$(cli_documented_verbs "$fixture/runbook.md")" ""
}

# `--force` is not decoration: release refuses without it, so a runbook that
# dropped the flag would document a command that always exits 2.
@test "release --force is documented and required" {
    grep -q -- '--force' "$runbook"
    grep -q 'force=1' "$cli"
}

# ----------------------------------------------------------- the runbook steps

runbook_names() { # <step>
    grep -qF -- "$1" "$runbook"
}

# Every human step this feature needs, by the name the code or the console uses.
# No tag name and no retired secret is asserted here: the runbook is being
# rewritten per host (#1038), and the names this feature deleted belong to neither
# version of it.
for step in deploy-notify TS_OAUTH_CLIENT_ID TS_OAUTH_CLIENT_SECRET \
    bootupctl /boot/grub2/custom.cfg journal.jsonl \
    greenboot-set-rollback-trigger deploy-ping-url.yaml; do
    register "the runbook names $step" runbook_names "$step"
done

# The secrets the deploy programs read are the secrets the runbook seeds: the
# names come from the readers, not from a list here, so a second file cannot ship
# without a step that fills it.
@test "every secret the deploy path reads has a manifest line and a runbook step" {
    seeded=0
    while IFS= read -r secret; do
        grep -qE "^${secret//./\\.}[[:space:]]" bootc/server/rootfs/usr/share/smortress/secrets.manifest || {
            printf '%s is read by the deploy path but is not in the decrypt manifest\n' "$secret" >&2
            seeded=1
        }
        grep -qF -- "$secret" "$runbook" || {
            printf '%s is read by the deploy path but the runbook never seeds it\n' "$secret" >&2
            seeded=1
        }
    done < <(grep -rhoE '(deploy-ping-url)\.yaml' \
        scripts bootc/server/rootfs/usr/libexec | sort -u)
    [[ $seeded -eq 0 ]]
}

# The state paths the runbook tells an operator to read are the library's own
# defaults, not a path someone remembered once.
@test "the runbook reads the state tree the deploy library writes" {
    state_dir=$(sed -nE 's/^deploy_state_dir=\$\{DEPLOY_STATE_DIR:-([^}]+)\}$/\1/p' scripts/deploy-state.sh)
    [[ -n $state_dir ]]
    grep -qF -- "$state_dir" "$runbook"
    grep -qF 'journal.jsonl' "$runbook"
}

# --------------------------------------------------------------- the image doc

image_document_names() { # <unit file>
    grep -qF -- "$(basename "$1")" docs/core/server-image.md
}

# The drain applies the apps tenant through `systemctl --user --machine=apps@.host`,
# and that path needs systemd-machined. On 2026-11-25 the socket was active, the
# service was not, and every drain died at "Transport endpoint is not connected"
# until an operator started it by hand; the queue held every image behind it.
deploy_unit_starts_machined() {
    grep -qx 'Wants=systemd-machined.service' units/systemd/smortress-deploy.service &&
        grep -qx 'After=systemd-machined.service' units/systemd/smortress-deploy.service
}
register "the drain starts systemd-machined, which the apps apply needs" deploy_unit_starts_machined

# A deploy unit that ships without a line in the image document is a service an
# operator meets for the first time during an incident.
for unit in units/systemd/smortress-deploy* units/systemd/smortress-boot-gate.service; do
    register "the image document names $(basename "$unit")" image_document_names "$unit"
done

# The poll is the only deploy trigger design #1010 leaves, and a host's /etc can
# outlive the image with a disabled override on it (the drift #1014 exists to
# clear): the build is where enablement has to be stated, so a fresh image boots
# with a trigger whatever the last window left in /etc. The retry timer is the
# backstop that a deferred queue entry waits on, so it ships enabled beside it.
deploy_triggers_enabled_at_build() {
    local timer
    for timer in smortress-deploy-poll.timer smortress-deploy-retry.timer; do
        grep -qE "^[[:space:]]+${timer//./\\.} \\\\$" bootc/server/Containerfile || return 1
    done
}
register "the image enables the deploy poll and its retry backstop" deploy_triggers_enabled_at_build

# Enablement in the enable list is not the same as enablement on the box: the build
# reads the symlink systemctl wrote, which is what a boot follows.
deploy_triggers_verified_at_build() {
    grep -qF 'test -e /etc/systemd/system/timers.target.wants/smortress-deploy-poll.timer' \
        bootc/server/Containerfile
}
register "the build fails when the poll timer is not enabled" deploy_triggers_verified_at_build
