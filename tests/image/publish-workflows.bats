#!/usr/bin/env bats
# bats file_tags=image
# The publish pipeline's shape (design #1011): one matrix caller over one
# reusable workflow, and no caller input spliced into a shell script.
#
# The workflow itself cannot run here -- a dispatch needs the environment key and
# a registry -- so everything below is what a static read can prove: the matrix is
# the tree's list of application images, the reusable workflow is the only thing
# that publishes, every input arrives as an environment variable rather than as
# script text, and the name is rejected by an executable check whose refusals this
# file runs. What only a real dispatch can prove is that the images build, sign
# and pass the anonymous pull.
#
#   bats tests/image/publish-workflows.bats
load ../helpers

reusable=.github/workflows/_publish-image.yml
matrix=.github/workflows/publish-images.yml
checker=scripts/check-publish-inputs.sh

# contains <text> <file>: a failure names the line that went missing instead of a
# bare status, because these assertions read files rather than run commands.
contains() {
    grep -qF -- "$1" "$2" || fail "missing '$1' in $2"
}

# interpolated_runs <workflow...>: the lines of every `run:` script that
# interpolate `${{ ... }}`. A workflow expression inside a run block is replaced
# with its value before bash parses the script, so a value carrying `$( )` is
# executed; the workflow hands the same value over in `env:` instead.
interpolated_runs() {
    awk '
        {
            line = $0
            if (inrun) {
                if (line ~ /^[[:space:]]*$/) next
                if (match(line, /[^[:space:]]/) - 1 > runbase) {
                    if (line ~ /\$\{\{/) print FILENAME ":" NR ": " line
                    next
                }
                inrun = 0
            }
            if (!match(line, /^[[:space:]]*(-[[:space:]]+)?run:/)) next
            rest = substr(line, index(line, "run:") + 4)
            if (rest ~ /^[[:space:]]*[|>]/) {
                runbase = index(line, "run:") - 1
                inrun = 1
                next
            }
            if (rest ~ /\$\{\{/) print FILENAME ":" NR ": " line
        }
    ' "$@"
}

@test "the scanner reports an expression inside a run block" {
    # The check below is only worth its green if it fails for the reason it
    # exists, so the fixture is the shape the old workflow had.
    cat >"$BATS_TEST_TMPDIR/bad.yml" <<'YAML'
jobs:
  publish:
    steps:
      - name: build
        run: |
          image="ghcr.io/smores56/homelab-platform/${{ inputs.name }}"
      - name: inline
        run: docker build -f "${{ inputs.dockerfile }}" .
YAML
    run interpolated_runs "$BATS_TEST_TMPDIR/bad.yml"
    assert_output --partial 'bad.yml:6'
    assert_output --partial 'image="ghcr.io/smores56/homelab-platform/${{ inputs.name }}"'
    assert_output --partial 'bad.yml:8'
}

@test "no publish workflow interpolates an expression into a run block" {
    run interpolated_runs "$reusable" "$matrix"
    assert_equal "$output" ""
}

@test "every caller input reaches its step through env, and is used quoted" {
    for variable in NAME DOCKERFILE CONTEXT PIN_PREFIX; do
        contains "          $variable: \${{ inputs." "$reusable"
    done
    # The build is the step the paths reach: an unquoted one would word-split,
    # and a leading `-` would be read as another docker option.
    contains '-f "$DOCKERFILE" \' "$reusable"
    contains '-t "$image:$tag" "$CONTEXT"' "$reusable"
    contains 'image="ghcr.io/smores56/homelab-platform/$NAME"' "$reusable"
    # The name is the value that becomes a registry path, and each of the four
    # steps that reads it -- plus the validator -- takes it from the environment.
    assert_equal "$(grep -cF 'NAME: ${{ inputs.name }}' "$reusable")" 5
}

@test "the publishing job does not exist until the inputs are validated" {
    contains 'run: scripts/check-publish-inputs.sh' "$reusable"
    # The publishing job is the one that installs cosign, holds the key and logs
    # in to the registry; `needs:` is what keeps it off the queue until the
    # validate job has passed, which is the "before any shell runs" claim.
    contains 'needs: validate' "$reusable"
    # One environment-bearing job, and it is not the validator.
    assert_equal "$(grep -cF 'environment: server-image' "$reusable")" 1
}

@test "the matrix is the tree's list of application images" {
    rows=()
    while IFS= read -r dockerfile; do
        directory=${dockerfile#images/}
        directory=${directory%/Containerfile}
        rows+=("$directory")
        contains "          - name: $directory" "$matrix"
        contains "            dockerfile: $dockerfile" "$matrix"
        # The trigger has to name the tree the row builds, or a change to it
        # republishes everything but the image that changed.
        contains "      - \"images/$directory/**\"" "$matrix"
    done < <(git ls-files 'images/*/Containerfile' | sort)
    # Six, and the count is derived from the tree above: a seventh image with no
    # row would pass every other assertion here.
    assert [ "${#rows[@]}" -gt 0 ]
    assert_equal "${#rows[@]}" "$(grep -cF '          - name:' "$matrix")"
}

@test "one caller publishes the application images" {
    run grep -lF 'uses: ./.github/workflows/_publish-image.yml' .github/workflows/*.yml
    assert_success
    assert_equal "$output" "$matrix"
}

@test "the check accepts a name this repository could have written" {
    run env NAME=brave DOCKERFILE=images/brave/Containerfile CONTEXT=. \
        PIN_PREFIX=images/brave/Containerfile bash "$checker"
    assert_success
    assert_output --partial 'check-publish-inputs: brave from images/brave/Containerfile'
}

@test "a name carrying a command substitution is refused and nothing runs" {
    canary=$BATS_TEST_TMPDIR/canary
    run env NAME="\$(touch $canary)" DOCKERFILE=images/brave/Containerfile CONTEXT=. \
        PIN_PREFIX=images/brave/Containerfile bash "$checker"
    assert_failure
    assert_output --partial "name '\$(touch $canary)' does not match ^[a-z0-9-]+\$"
    refute test -e "$canary"
}

@test "a rejected input cannot write a second workflow command" {
    # The failure message carries the offending value, and a workflow command is
    # parsed per line: an unfolded newline would be a command of the caller's.
    run env NAME=$'evil\n::error::pwned' DOCKERFILE=images/brave/Containerfile CONTEXT=. \
        PIN_PREFIX=images/brave/Containerfile bash "$checker"
    assert_failure
    assert_output --partial 'evil ::error::pwned'
    assert_equal "$(grep -c '^::error::' <<<"$output")" 1
}

@test "a name that is a path, not a name, is refused" {
    for name in 'smores/brave' '../images/brave' 'Brave' 'brave$(id)' 'brave;id'; do
        run env NAME="$name" DOCKERFILE=images/brave/Containerfile CONTEXT=. \
            PIN_PREFIX=images/brave/Containerfile bash "$checker"
        assert_failure
        assert_output --partial "name '$name' does not match"
    done
}

@test "an unset or empty input is refused before it is used" {
    for variable in NAME DOCKERFILE CONTEXT PIN_PREFIX; do
        run env NAME=brave DOCKERFILE=images/brave/Containerfile CONTEXT=. \
            PIN_PREFIX=images/brave/Containerfile "$variable=" bash "$checker"
        assert_failure
        assert_output --partial "$variable is unset or empty"
    done
}

@test "a path input outside the checkout is refused" {
    for dockerfile in '/etc/passwd' '../secrets/boot.json' 'images/$(id)/Containerfile'; do
        run env NAME=brave DOCKERFILE="$dockerfile" CONTEXT=. \
            PIN_PREFIX=images/brave/Containerfile bash "$checker"
        assert_failure
        refute_output --partial 'check-publish-inputs: brave from'
    done
    # And a row whose path does not resolve is a matrix typo, named as one.
    run env NAME=brave DOCKERFILE=images/nosuch/Containerfile CONTEXT=. \
        PIN_PREFIX=images/nosuch/Containerfile bash "$checker"
    assert_failure
    assert_output --partial "dockerfile 'images/nosuch/Containerfile' is not a file"
}
