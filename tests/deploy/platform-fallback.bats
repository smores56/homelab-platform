#!/usr/bin/env bats
# bats file_tags=deploy
# An absent SSD falls back to the HDD (§3).
#
# One file of the suite that was tests/deploy/platform.bats, split so bats can
# run the sections in parallel (a single file is one job); the fakes, the
# fixture, the drivers and the assertions are in platform_lib.bash.
#
#   bats tests/deploy/platform-fallback.bats
load ../helpers
load ./platform_lib

setup_file() { pt_setup_file; }
setup() { pt_setup; }

# --- 3. an absent SSD falls back to the HDD ---------------------------------
# Neither unit is fresh and the SSD is unusable: every backup lands on the HDD.
no_usable_ssd() {
    seed_doc false true ""
    run_platform prepare --commit "$commit" --digests "$digests"
}

@test "an unusable SSD still passes on the HDD" {
    no_usable_ssd
    assert_equal "$rc" 0
}

@test "every missing unit is backed up to the HDD" {
    no_usable_ssd
    assert_equal "$(grep -c '^hdd|' "$log/backup-calls" || true)" "${#units[@]}"
}

@test "no backup is written to an unusable SSD" {
    no_usable_ssd
    assert_equal "$(grep -c '^ssd|' "$log/backup-calls" || true)" 0
}

@test "the green gate names the HDD as the backend" {
    no_usable_ssd
    assert_equal "$(journal_field gate-green '.units.files')" hdd
}
