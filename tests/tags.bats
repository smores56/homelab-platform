#!/usr/bin/env bats
# tests/tags.tsv decides which suites a change selects; these hold it to the
# tree, so a new suite without a row, a stale pattern, or a row naming nothing
# fails here instead of going unnoticed.
load helpers

tags_file=$repo_root/tests/tags.tsv
tags_sh=$repo_root/tests/tags.sh
tab=$(printf '\t')

suites() {  # every suite path under tests/, one per line
    find tests -name '*.bats' -type f | sort
}

@test "every suite has a row in tags.tsv" {
    missing=''
    while IFS= read -r suite; do
        name=${suite#tests/}
        name=${name%.bats}
        grep -qF "$name$tab" "$tags_file" || missing="$missing $name"
    done < <(suites)
    assert_equal "$missing" ""
}

@test "no tag has two rows" {
    # Two rows for one tag select the same suite twice and hide which claim is
    # stale; a merge that resolves by keeping both is the way it happens.
    dups=$(cut -f1 "$tags_file" | grep -v '^#' | sort | uniq -d | tr '\n' ' ')
    assert_equal "$dups" ""
}

@test "every suite selects itself" {
    bad=''
    while IFS= read -r suite; do
        selected=$(sh "$tags_sh" "$suite")
        # A path may select several rows and the output is one suite per line, so
        # membership is per line. `all` selects the suite too; either is fine.
        [[ $selected == all ]] && continue
        grep -Fqx -- "$suite" <<<"$selected" || bad="$bad $suite"
    done < <(suites)
    assert_equal "$bad" ""
}

@test "every tags.tsv row names a suite that exists" {
    bad=''
    while IFS=$tab read -r tag patterns || [ -n "$tag" ]; do
        case $tag in ''|'#'*|all|none) continue ;; esac
        [ -f "tests/$tag.bats" ] || bad="$bad $tag"
    done <"$tags_file"
    assert_equal "$bad" ""
}

@test "every tags.tsv pattern names a path in the tree" {
    set -f  # a pattern is a glob to match with, not one to expand against the tree
    stale=''
    while IFS=$tab read -r tag patterns || [ -n "$tag" ]; do
        case $tag in ''|'#'*) continue ;; esac
        for pattern in $patterns; do
            found=$(git ls-files --cached --others --exclude-standard -- "$pattern")
            [ -n "$found" ] || stale="$stale $pattern"
        done
    done <"$tags_file"
    set +f
    assert_equal "$stale" ""
}

@test "a path a row claims selects that row's suite" {
    # The table is shared: six suites read it, so the row for one of them must
    # not have to enumerate the others. Membership, not an exact list.
    run sh "$tags_sh" scripts/storage-layout.sh
    assert_output --partial "tests/core/storage-layout.bats"
    assert_output --partial "tests/core/restic-plane.bats"
}

@test "a path several rows claim selects all of them" {
    repo=$BATS_TEST_TMPDIR/repo
    mkdir -p "$repo/tests"
    cp "$tags_sh" "$repo/tests/tags.sh"
    printf 'aaa\tREADME.md\ncore/storage-layout\tREADME.md\n' >"$repo/tests/tags.tsv"
    run sh "$repo/tests/tags.sh" README.md
    assert_output "tests/aaa.bats
tests/core/storage-layout.bats"
}

@test "a path no row claims selects every suite" {
    run sh "$tags_sh" brand/new/thing
    assert_equal "$(printf '%s\n' "$output" | wc -l)" "$(find tests -name '*.bats' | wc -l)"
}

@test "a harness change selects every suite" {
    run sh "$tags_sh" tests/helpers.bash
    assert_equal "$(printf '%s\n' "$output" | wc -l)" "$(find tests -name '*.bats' | wc -l)"
}

@test "a documentation change selects nothing" {
    run sh "$tags_sh" docs/core/pool-rebuild.md
    assert_output ""
}

@test "--changed reads the diff against the base" {
    repo=$BATS_TEST_TMPDIR/repo
    mkdir -p "$repo/tests"
    cp "$tags_sh" "$repo/tests/tags.sh"
    cp "$tags_file" "$repo/tests/tags.tsv"
    git -C "$repo" init -q
    git -C "$repo" add tests
    git -C "$repo" -c user.name=t -c user.email=t@t commit -qm base
    mkdir -p "$repo/scripts"
    cp "$repo_root/scripts/storage-layout.sh" "$repo/scripts/"
    run sh -c "cd '$repo' && sh tests/tags.sh --changed --base HEAD"
    assert_output --partial "tests/core/storage-layout.bats"
}

# --- CI areas ----------------------------------------------------------------
# ci.yml runs one job per area, selected by `--filter-tags`. A suite whose tag
# no job claims would run nowhere, and a claimed tag with no suite means a job
# that can only ever fail on "Found no tests".

area_tags() {  # the tags the workflow's filter expressions name
    grep -oE -- "--filter-tags '[^']+'" "$repo_root/.github/workflows/ci.yml" |
        sed -E "s/--filter-tags '(.*)'/\1/" | tr '|' '\n' | sed '/^$/d' | sort -u
}

@test "every suite's tag is claimed by a CI area job" {
    areas=$(area_tags)
    missing=''
    for tag in $(grep -hE '^# bats file_tags=' tests/*.bats tests/*/*.bats | sed -E 's/.*file_tags=//' | sort -u); do
        grep -qx "$tag" <<<"$areas" || missing="$missing $tag"
    done
    assert_equal "$missing" ""
}

@test "every CI area names a tag a suite carries" {
    tags=$(grep -hE '^# bats file_tags=' tests/*.bats tests/*/*.bats | sed -E 's/.*file_tags=//' | sort -u)
    stale=''
    for area in $(area_tags); do
        grep -qx "$area" <<<"$tags" || stale="$stale $area"
    done
    assert_equal "$stale" ""
}
