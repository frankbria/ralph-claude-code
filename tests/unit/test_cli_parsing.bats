#!/usr/bin/env bats
# Unit Tests for CLI Argument Parsing

load '../helpers/test_helper'

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"
    
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-test.XXXXXX)"
    cd "$TEST_TEMP_DIR"
    
    export RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    
    mkdir -p logs docs/generated
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

@test "--help flag shows usage information" {
    run bash "$RALPH_SCRIPT" --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"Options:"* ]]
}

@test "--calls NUM flag is documented in help output" {
    run bash "$RALPH_SCRIPT" --help
    assert_success
    [[ "$output" == *"--calls"* ]]
}

@test "--prompt FILE flag is recognized" {
    run bash "$RALPH_SCRIPT" --prompt custom.md --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--status flag shows status and exits" {
    echo '{"status": "test"}' > status.json
    run bash "$RALPH_SCRIPT" --status
    assert_success
    [[ "$output" == *"status"* ]]
}

@test "--monitor flag is recognized in help" {
    run bash "$RALPH_SCRIPT" --help
    [[ "$output" == *"--monitor"* ]]
    [[ "$output" == *"tmux"* ]]
}

@test "--verbose flag is recognized in help" {
    run bash "$RALPH_SCRIPT" --help
    [[ "$output" == *"--verbose"* ]]
    [[ "$output" == *"progress"* ]]
}

@test "--timeout MIN flag validates input range" {
    run bash "$RALPH_SCRIPT" --timeout 0 --help
    assert_failure
    [[ "$output" == *"positive integer"* ]] || [[ "$output" == *"1 and 120"* ]]
}

@test "invalid flag shows error and help" {
    run bash "$RALPH_SCRIPT" --invalid-flag
    assert_failure
    [[ "$output" == *"Unknown option"* ]]
}

@test "multiple flags can be combined" {
    run bash "$RALPH_SCRIPT" --verbose --dry-run --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "flag order does not matter" {
    run bash "$RALPH_SCRIPT" --help --verbose
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--dry-run flag is recognized in help" {
    run bash "$RALPH_SCRIPT" --help
    [[ "$output" == *"--dry-run"* ]]
}

@test "--notify flag is recognized in help" {
    run bash "$RALPH_SCRIPT" --help
    [[ "$output" == *"--notify"* ]]
}

@test "--backup flag is recognized in help" {
    run bash "$RALPH_SCRIPT" --help
    [[ "$output" == *"--backup"* ]]
}

@test "--reset-circuit flag is recognized in help" {
    run bash "$RALPH_SCRIPT" --help
    [[ "$output" == *"--reset-circuit"* ]]
}

@test "--circuit-status flag is recognized in help" {
    run bash "$RALPH_SCRIPT" --help
    [[ "$output" == *"--circuit-status"* ]]
}

@test "-h short flag shows help" {
    run bash "$RALPH_SCRIPT" -h
    assert_success
    [[ "$output" == *"Usage:"* ]]
}