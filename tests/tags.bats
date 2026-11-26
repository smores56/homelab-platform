#!/usr/bin/env bats
# bats file_tags=lint
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

@test "every suite's own row claims it" {
    # Read the row, not the selection: an unclaimed path selects every suite, so
    # a row that forgets its own file would still look right through tags.sh.
    bad=''
    while IFS= read -r suite; do
        name=${suite#tests/}
        name=${name%.bats}
        row=$(grep -F "$name$tab" "$tags_file" | head -n1)
        pattern=$(cut -f2 <<<"$row")
        # shellcheck disable=SC2086  # a row lists its patterns space-separated
        for p in $pattern; do
            [[ $p == "$suite" ]] && continue 2
        done
        bad="$bad $suite"
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
    assert_output --regexp "tests/core/restic-plane-[a-z0-9]+\.bats"
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
# ci.yml runs one job per area. bats selects by tag with a repeated
# `--filter-tags` per alternative: a single `a||b` string is not an expression
# and selects nothing, which is how three suites silently left CI once.
# A suite whose tag no job claims would run nowhere; a claimed tag with no suite
# means a job that can only ever fail on "Found no tests".

local_only='actionlint'

area_tags() {  # the tags the workflow's filter expressions name
    grep -oE -- "--filter-tags '?[a-z-]+'?" "$repo_root/.github/workflows/ci.yml" |
        sed -E "s/--filter-tags '?([a-z-]+)'?/\1/" | sort -u
}

suite_tags() {  # the area each suite declares
    grep -hE '^# bats file_tags=' tests/*.bats tests/*/*.bats | sed -E 's/.*file_tags=//'
}

@test "every suite declares its area exactly once" {
    bad=''
    while IFS= read -r suite; do
        count=$(grep -cE '^# bats file_tags=' "$suite")
        # Zero would drop every test from every area job; two would let a stray
        # line disagree with the one register() reads.
        [[ $count == 1 ]] || bad="$bad $suite($count)"
    done < <(suites)
    assert_equal "$bad" ""
}

@test "every suite's tag is claimed by a CI area job or declared local-only" {
    areas=$(area_tags)
    missing=''
    for tag in $(suite_tags | sort -u); do
        [[ $tag == "$local_only" ]] && continue
        grep -qx "$tag" <<<"$areas" || missing="$missing $tag"
    done
    assert_equal "$missing" ""
}

@test "register derives the area each suite declares" {
    # register() maps a path to a tag without a subprocess; this holds that
    # table to the `# bats file_tags=` line it replaced.
    bad=''
    while IFS= read -r suite; do
        declared=$(grep -hE '^# bats file_tags=' "$suite" | head -n1 | sed -E 's/.*file_tags=//')
        case $suite in
            tests/*/*.bats) expected=${suite#tests/}; expected=${expected%%/*} ;;
            tests/lint.bats | tests/tags.bats) expected=lint ;;
            tests/docs.bats) expected=docs ;;
            tests/actionlint.bats) expected=actionlint ;;
            tests/tofu-fmt.bats) expected=tofu ;;
            *) expected=unmapped ;;
        esac
        [[ $declared == "$expected" ]] || bad="$bad $suite($declared, not $expected)"
    done < <(suites)
    assert_equal "$bad" ""
}

@test "every test in a suite carries the suite's tag" {
    # The area jobs select by tag, so an untagged test runs in no job. A file's
    # `# bats file_tags=` covers its literal @tests but not the ones register()
    # creates, which is why register reads the same line; this counts both.
    bad=''
    while IFS= read -r suite; do
        tag=$(grep -hE '^# bats file_tags=' "$suite" | head -n1 | sed -E 's/.*file_tags=//')
        all=$(bats --count "$suite")
        tagged=$(bats --filter-tags "$tag" --count "$suite" 2>/dev/null | tr -dc 0-9)
        [[ $all == "$tagged" ]] || bad="$bad $suite($tagged/$all)"
    done < <(suites)
    assert_equal "$bad" ""
}

@test "every CI area names a tag a suite carries" {
    tags=$(suite_tags | sort -u)
    stale=''
    for area in $(area_tags); do
        grep -qx "$area" <<<"$tags" || stale="$stale $area"
    done
    assert_equal "$stale" ""
}

@test "the local-only list names a suite that exists" {
    grep -qx "$local_only" <<<"$(suite_tags)" || {
        printf '%s names no suite\n' "$local_only" >&2
        return 1
    }
}
