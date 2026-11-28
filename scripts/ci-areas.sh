#!/bin/sh
# scripts/ci-areas.sh: which CI areas a diff needs, read once, in one place.
#
# usage: scripts/ci-areas.sh [<path>...]
#        scripts/ci-areas.sh --changed [--base <ref>] [--guard]
#        ... | scripts/ci-areas.sh
#        scripts/ci-areas.sh --areas      # every area the selector can name
#        scripts/ci-areas.sh --jobs       # every job the gate depends on
#
# One area per line, in the order .github/workflows/ci.yml declares the jobs.
# `.github/workflows/ci.yml` reads this answer once per run and every area job
# then gates itself on it, so the diff is read here and nowhere else.
#
# Most areas are selected through the suites already: tests/tags.sh says which
# suites a path touches, each suite's `# bats file_tags=` says which tag it
# carries, and the `--filter-tags` line of the job that claims that tag is the
# job to run. That mapping is read out of ci.yml rather than repeated here, and
# tests/tags.bats already holds every suite's tag to those same lines.
#
# `drift`, `fork-pr-secret-boundary` and `plan` run a script instead of a suite,
# so no tags.tsv row can name them: script_areas() below is the whole of their
# selection. A path that no tags.tsv row claims selects every suite, and then
# every area, including those three -- a table that stops covering the tree runs
# more than needed, never less.
set -uf

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
workflow=$root/.github/workflows/ci.yml
tab=$(printf '\t')
changed=false
base=origin/main
guard=false
paths=''

while [ $# -gt 0 ]; do
    case $1 in
        --changed) changed=true ;;
        --base) base=${2:?--base needs a ref}; shift ;;
        --guard) guard=true ;;
        --areas) mode='areas' ;;
        --jobs) mode='jobs' ;;
        -*) printf 'usage: %s [--changed [--base <ref>] [--guard]] [--areas|--jobs] [<path>...]\n' "$0" >&2; exit 2 ;;
        *) paths="$paths$1
" ;;
    esac
    shift
done

# gated_jobs: every ci.yml job except the gate itself, in file order. The gate's
# `needs:` list is held to this by tests/ci-gate.bats, so a job cannot be added
# without the gate following it, or dropped without the gate noticing.
gated_jobs() {
    awk '
        /^jobs:/ { jobs = 1; next }
        jobs && /^  [a-z][a-z0-9-]*:[[:space:]]*$/ {
            job = $1
            sub(/:$/, "", job)
            if (job != "gate") print job
        }
    ' "$workflow"
}

# area_jobs: gated_jobs without the selector, which always runs.
area_jobs() {
    gated_jobs | grep -vx changes
}

case ${mode:-select} in
    areas) area_jobs; exit 0 ;;
    jobs) gated_jobs; exit 0 ;;
esac

if [ -z "$paths" ]; then
    if $changed; then
        compare=$(git -C "$root" merge-base "$base" HEAD) || {
            printf 'ci-areas: %s has no merge base with HEAD\n' "$base" >&2
            exit 2
        }
        paths=$(
            git -C "$root" diff --name-only "$compare" || exit 1
            git -C "$root" ls-files --others --exclude-standard || exit 1
        ) || exit 1
    else
        paths=$(cat)
    fi
fi

# --- the gate's own definition ----------------------------------------------
# On a pull_request event a same-repo branch runs the head's workflow file, so a
# diff that edits the gate is judged by the code it ships: only the owner may
# edit it. A fork PR cannot edit the file that runs (it gets the base's), but the
# file that merges is still the head's, so the refusal does not depend on where
# the branch came from.
gate_definition() {
    case $1 in
        .github/workflows/* | scripts/ci-areas.sh | scripts/ci-gate.py) return 0 ;;
    esac
    return 1
}

if $guard; then
    : "${OWNER:?--guard needs OWNER}"
    : "${ACTOR:?--guard needs ACTOR}"
    edits=''
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        gate_definition "$path" && edits="$edits $path"
    done <<EOF
$paths
EOF
    if [ -n "$edits" ]; then
        if [ "$ACTOR" != "$OWNER" ]; then
            printf 'ci-areas: this diff edits the gate itself, and %s is not %s:%s\n' \
                "$ACTOR" "$OWNER" "$edits" >&2
            printf 'ci-areas: the workflow that runs on the pull request is the head file, so only %s may change it.\n' \
                "$OWNER" >&2
            exit 1
        fi
        printf 'ci-areas: gate definition edited by the owner:%s\n' "$edits" >&2
    fi
fi

# --- selection ---------------------------------------------------------------

# script_areas <path>: the areas no suite names.
script_areas() {
    case $1 in
        *.md | docs/*) printf 'lint\n' ;;
        tofu/*) printf 'plan\n' ;;
        .github/* | scripts/check-pr-secret-boundary.sh) printf 'fork-pr-secret-boundary\n' ;;
        .sops.yaml | lib/* | bootc/* | hosts/* | scripts/check-sops-drift.sh | scripts/check-lib-drift.sh | scripts/sops-policy.py) printf 'drift\n' ;;
    esac
    return 0
}

work=$(mktemp) || exit 1
trap 'rm -f "$work"' EXIT HUP INT TERM

# The tag each job claims, read out of ci.yml: one row per `--filter-tags`.
awk '
    /^jobs:/ { jobs = 1; next }
    jobs && /^  [a-z][a-z0-9-]*:[[:space:]]*$/ {
        job = $1
        sub(/:$/, "", job)
        next
    }
    jobs && /--filter-tags/ {
        n = split($0, token, /[[:space:]]+/)
        for (i = 1; i < n; i++) {
            if (token[i] != "--filter-tags") continue
            tag = token[i + 1]
            gsub(/['"'"'"]/, "", tag)
            print tag "\t" job
        }
    }
' "$workflow" >"$work"

want=''
add() {
    case " $want " in
        *" $1 "*) ;;
        *) want="$want $1" ;;
    esac
}

selected=$(printf '%s\n' "$paths" | sh "$root/tests/tags.sh" | sort) || exit 1
all_suites=$(
    find "$root/tests" -name '*.bats' -type f | sed "s#^$root/##" | sort
)

if [ "$selected" = "$all_suites" ]; then
    # tags.sh selected every suite because some path in the diff claims no row:
    # every area runs, the script-only ones included.
    want=" $(area_jobs | tr '\n' ' ')"
else
    while IFS= read -r suite; do
        [ -n "$suite" ] || continue
        tag=$(sed -nE 's/^# bats file_tags=(.*)$/\1/p' "$root/$suite" | head -n1)
        [ -n "$tag" ] || continue
        job=$(awk -F"$tab" -v want="$tag" '$1 == want { print $2; exit }' "$work")
        # A local-only tag (actionlint) no job claims: it runs where it is
        # installed, which no runner is.
        [ -n "$job" ] && add "$job"
    done <<EOF
$selected
EOF
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        # shellcheck disable=SC2046 # an area names no space: the split is the loop
        for area in $(script_areas "$path"); do
            add "$area"
        done
    done <<EOF
$paths
EOF
fi

for job in $(area_jobs); do
    case " $want " in
        *" $job "*) printf '%s\n' "$job" ;;
    esac
done
