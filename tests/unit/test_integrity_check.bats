#!/usr/bin/env bats
# Unit tests for pre-loop integrity check in ralph_loop.sh (Issue #149)
# Verifies that the loop halts when critical Ralph files are deleted mid-loop

load '../helpers/test_helper'
load '../helpers/fixtures'

# Path to file_protection.sh
FILE_PROTECTION="${BATS_TEST_DIRNAME}/../../lib/file_protection.sh"
RALPH_LOOP="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Source file protection library
    source "$FILE_PROTECTION"

    # Set up environment
    export RALPH_DIR=".ralph"

    # Define log_status stub for tests
    log_status() {
        local level=$1
        local message=$2
        echo "[$level] $message"
    }
    export -f log_status
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# Helper to create a complete project for integrity tests
create_integrity_project() {
    mkdir -p .ralph/logs .ralph/docs/generated
    echo "# Prompt" > .ralph/PROMPT.md
    echo "# Fix Plan" > .ralph/fix_plan.md
    echo "# Agent" > .ralph/AGENT.md
    echo "RALPH_DIR=.ralph" > .ralphrc
}

# =============================================================================
# ralph_loop.sh sources file_protection.sh
# =============================================================================

@test "ralph_loop.sh sources lib/file_protection.sh" {
    run grep 'source.*file_protection.sh' "$RALPH_LOOP"
    assert_success
}

@test "ralph_loop.sh sources file_protection.sh after circuit_breaker.sh" {
    # file_protection.sh should be sourced after the other libs
    local cb_line=$(grep -n 'source.*circuit_breaker.sh' "$RALPH_LOOP" | head -1 | cut -d: -f1)
    local fp_line=$(grep -n 'source.*file_protection.sh' "$RALPH_LOOP" | head -1 | cut -d: -f1)

    [[ -n "$cb_line" ]]
    [[ -n "$fp_line" ]]
    [[ "$fp_line" -gt "$cb_line" ]]
}

# =============================================================================
# Integrity check exists in main loop
# =============================================================================

@test "ralph_loop.sh has integrity check inside main loop" {
    run grep 'validate_ralph_integrity' "$RALPH_LOOP"
    assert_success
}

@test "ralph_loop.sh calls get_integrity_report on failure" {
    run grep 'get_integrity_report' "$RALPH_LOOP"
    assert_success
}

@test "ralph_loop.sh logs integrity failure as ERROR" {
    run grep -E 'integrity.*fail|files.*missing' "$RALPH_LOOP"
    assert_success
}

# =============================================================================
# Simulated loop integrity behavior
# =============================================================================

@test "integrity check passes with complete project" {
    create_integrity_project

    run validate_ralph_integrity
    assert_success
}

@test "integrity check fails when .ralph/ removed mid-loop" {
    create_integrity_project

    # Simulate .ralph/ being deleted mid-loop
    rm -rf .ralph

    run validate_ralph_integrity
    assert_failure
}

@test "integrity check fails when PROMPT.md removed mid-loop" {
    create_integrity_project

    # Simulate PROMPT.md being deleted
    rm .ralph/PROMPT.md

    run validate_ralph_integrity
    assert_failure
}

@test "integrity check fails when .ralphrc removed mid-loop" {
    create_integrity_project

    # Simulate .ralphrc being deleted
    rm .ralphrc

    run validate_ralph_integrity
    assert_failure
}

@test "integrity report includes recovery instructions for mid-loop damage" {
    create_integrity_project
    rm .ralph/PROMPT.md
    rm .ralphrc

    validate_ralph_integrity || true

    run get_integrity_report
    assert_success

    [[ "$output" =~ "ralph-enable --force" ]]
    [[ "$output" =~ ".ralph/PROMPT.md" ]]
    [[ "$output" =~ ".ralphrc" ]]
}

@test "integrity check passes when only optional state files missing" {
    create_integrity_project
    # Remove all optional state files
    rm -rf .ralph/logs
    rm -f .ralph/status.json
    rm -f .ralph/.call_count
    rm -f .ralph/.exit_signals

    run validate_ralph_integrity
    assert_success
}

# =============================================================================
# Pre-loop startup check
# =============================================================================

@test "ralph_loop.sh has startup integrity check before main loop" {
    # The integrity check should appear before the 'while true' main loop
    local integrity_line=$(grep -n 'validate_ralph_integrity' "$RALPH_LOOP" | head -1 | cut -d: -f1)
    local while_line=$(grep -n 'while true' "$RALPH_LOOP" | head -1 | cut -d: -f1)

    [[ -n "$integrity_line" ]]
    [[ -n "$while_line" ]]
    [[ "$integrity_line" -lt "$while_line" ]]
}
