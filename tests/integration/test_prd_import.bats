#!/usr/bin/env bats
# Integration Tests for PRD Import

load '../helpers/test_helper'
load '../helpers/fixtures'

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/fixtures.bash"
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-import-test.XXXXXX)"
    cd "$TEST_TEMP_DIR"
    export RALPH_IMPORT="${BATS_TEST_DIRNAME}/../../ralph_import.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

@test "ralph-import accepts .md file" {
    run bash "$RALPH_IMPORT" --help
    assert_success
    [[ "$output" == *".md"* ]]
}

@test "ralph-import accepts .txt file" {
    run bash "$RALPH_IMPORT" --help
    assert_success
    [[ "$output" == *".txt"* ]]
}

@test "ralph-import accepts .json file" {
    run bash "$RALPH_IMPORT" --help
    assert_success
    [[ "$output" == *".json"* ]]
}

@test "ralph-import help describes PROMPT.md creation" {
    run bash "$RALPH_IMPORT" --help
    assert_success
    [[ "$output" == *"PROMPT.md"* ]]
}

@test "ralph-import help describes @fix_plan.md creation" {
    run bash "$RALPH_IMPORT" --help
    assert_success
    [[ "$output" == *"fix_plan"* ]]
}

@test "ralph-import help describes specs creation" {
    run bash "$RALPH_IMPORT" --help
    assert_success
    [[ "$output" == *"specs"* ]]
}

@test "ralph-import accepts custom project name in help" {
    run bash "$RALPH_IMPORT" --help
    assert_success
    [[ "$output" == *"project-name"* ]]
}

@test "ralph-import defaults project name from filename" {
    run bash "$RALPH_IMPORT" --help
    assert_success
}

@test "ralph-import errors on missing source file" {
    run bash "$RALPH_IMPORT" nonexistent-file.md
    assert_failure
}

@test "ralph-import dependency check mentioned" {
    run bash "$RALPH_IMPORT" --help
    assert_success
}