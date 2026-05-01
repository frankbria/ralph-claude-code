#!/usr/bin/env bats
# TAP-1209: Unit tests for ralph_should_skip_resume() helper.
#
# Helper governs whether `--resume <session_id>` is appended to the Claude
# CLI invocation. When a fresh LINOPT locality hint is on disk, resumed
# sessions silently replay the prior "nothing actionable" judgment and
# never read the hint — so the helper signals a cold start for that loop.
#
# We slice the helper out of ralph_loop.sh via awk (same pattern as
# tests/unit/test_atomic_write.bats) so we don't have to source the entire
# loop script.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

RALPH_LOOP_SH="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"

    local slice="$TEST_TEMP_DIR/_should_skip_resume_slice.sh"
    awk '/^ralph_should_skip_resume\(\) \{/,/^\}/' "$RALPH_LOOP_SH" > "$slice"
    # shellcheck disable=SC1090
    source "$slice"

    declare -F ralph_should_skip_resume >/dev/null \
        || skip "ralph_should_skip_resume not defined after source"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

@test "TAP-1209: returns true when .linear_next_issue exists" {
    mkdir -p "$TEST_TEMP_DIR/.ralph"
    printf 'TAP-1196\n' > "$TEST_TEMP_DIR/.ralph/.linear_next_issue"
    run ralph_should_skip_resume "$TEST_TEMP_DIR/.ralph"
    [ "$status" -eq 0 ]
}

@test "TAP-1209: returns false when no hint file exists" {
    mkdir -p "$TEST_TEMP_DIR/.ralph"
    run ralph_should_skip_resume "$TEST_TEMP_DIR/.ralph"
    [ "$status" -ne 0 ]
}

@test "TAP-1209: returns false when .ralph dir is missing" {
    run ralph_should_skip_resume "$TEST_TEMP_DIR/.ralph"
    [ "$status" -ne 0 ]
}

@test "TAP-1209: defaults to RALPH_DIR when no arg passed" {
    mkdir -p "$TEST_TEMP_DIR/custom_ralph"
    printf 'TAP-1196\n' > "$TEST_TEMP_DIR/custom_ralph/.linear_next_issue"
    export RALPH_DIR="$TEST_TEMP_DIR/custom_ralph"
    run ralph_should_skip_resume
    [ "$status" -eq 0 ]
}

@test "TAP-1209: defaults to .ralph when neither arg nor RALPH_DIR is set" {
    mkdir -p "$TEST_TEMP_DIR/.ralph"
    printf 'TAP-1196\n' > "$TEST_TEMP_DIR/.ralph/.linear_next_issue"
    unset RALPH_DIR
    cd "$TEST_TEMP_DIR"
    run ralph_should_skip_resume
    [ "$status" -eq 0 ]
}

@test "TAP-1209: empty hint file still triggers skip (file presence is the signal)" {
    # Production path always writes an issue ID, but the helper's contract
    # is "file exists" — if a hint file got truncated, we still cold-start
    # rather than risk the resume-cached state ignoring something.
    mkdir -p "$TEST_TEMP_DIR/.ralph"
    : > "$TEST_TEMP_DIR/.ralph/.linear_next_issue"
    run ralph_should_skip_resume "$TEST_TEMP_DIR/.ralph"
    [ "$status" -eq 0 ]
}
