#!/usr/bin/env bats
# Unit tests for lib/file_protection.sh
# Tests file integrity validation and reporting for Ralph project files

load '../helpers/test_helper'

# Path to file_protection.sh
FILE_PROTECTION="${BATS_TEST_DIRNAME}/../../lib/file_protection.sh"

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Source the library
    source "$FILE_PROTECTION"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# Helper: create a complete Ralph project structure
create_complete_ralph_project() {
    mkdir -p .ralph
    echo "# Prompt" > .ralph/PROMPT.md
    echo "# Fix Plan" > .ralph/fix_plan.md
    echo "# Agent" > .ralph/AGENT.md
    echo "RALPH_DIR=.ralph" > .ralphrc
}

# =============================================================================
# validate_ralph_integrity - success cases
# =============================================================================

@test "validate_ralph_integrity passes with only required files (optional files absent)" {
    create_complete_ralph_project
    # No .ralph/logs/, .ralph/status.json, .ralph/.call_count, .ralph/.exit_signals — should still pass

    run validate_ralph_integrity
    assert_success
}

# =============================================================================
# validate_ralph_integrity - failure cases
# =============================================================================

@test "validate_ralph_integrity returns 1 when .ralph/ directory is missing" {
    # Only .ralphrc, no .ralph/ dir
    echo "RALPH_DIR=.ralph" > .ralphrc

    run validate_ralph_integrity
    assert_failure
}

@test "validate_ralph_integrity returns 1 when .ralph/PROMPT.md is missing" {
    create_complete_ralph_project
    rm .ralph/PROMPT.md

    run validate_ralph_integrity
    assert_failure
}

@test "validate_ralph_integrity returns 1 when .ralph/fix_plan.md is missing" {
    create_complete_ralph_project
    rm .ralph/fix_plan.md

    run validate_ralph_integrity
    assert_failure
}

@test "validate_ralph_integrity returns 1 when .ralph/AGENT.md is missing" {
    create_complete_ralph_project
    rm .ralph/AGENT.md

    run validate_ralph_integrity
    assert_failure
}

@test "validate_ralph_integrity returns 1 when .ralphrc is missing" {
    create_complete_ralph_project
    rm .ralphrc

    run validate_ralph_integrity
    assert_failure
}

@test "validate_ralph_integrity returns 1 when everything is missing" {
    # Empty directory, nothing exists

    run validate_ralph_integrity
    assert_failure
}

# =============================================================================
# RALPH_MISSING_FILES variable
# =============================================================================

@test "validate_ralph_integrity sets RALPH_MISSING_FILES with missing .ralph/ dir" {
    echo "RALPH_DIR=.ralph" > .ralphrc

    validate_ralph_integrity || true

    [[ "${RALPH_MISSING_FILES[*]}" =~ ".ralph" ]]
}

@test "validate_ralph_integrity sets RALPH_MISSING_FILES with missing PROMPT.md" {
    create_complete_ralph_project
    rm .ralph/PROMPT.md

    validate_ralph_integrity || true

    [[ "${RALPH_MISSING_FILES[*]}" =~ ".ralph/PROMPT.md" ]]
}

@test "validate_ralph_integrity sets RALPH_MISSING_FILES with multiple missing files" {
    mkdir -p .ralph
    # Missing PROMPT.md, fix_plan.md, AGENT.md, and .ralphrc

    validate_ralph_integrity || true

    [[ "${RALPH_MISSING_FILES[*]}" =~ ".ralph/PROMPT.md" ]]
    [[ "${RALPH_MISSING_FILES[*]}" =~ ".ralph/fix_plan.md" ]]
    [[ "${RALPH_MISSING_FILES[*]}" =~ ".ralph/AGENT.md" ]]
    [[ "${RALPH_MISSING_FILES[*]}" =~ ".ralphrc" ]]
}

@test "validate_ralph_integrity clears RALPH_MISSING_FILES on success" {
    create_complete_ralph_project

    # Seed with stale data
    RALPH_MISSING_FILES=("stale_entry")

    validate_ralph_integrity

    assert_equal "${#RALPH_MISSING_FILES[@]}" "0"
}

# =============================================================================
# get_integrity_report
# =============================================================================

@test "get_integrity_report lists missing files" {
    create_complete_ralph_project
    rm .ralph/PROMPT.md
    rm .ralphrc

    validate_ralph_integrity || true

    run get_integrity_report
    assert_success

    [[ "$output" =~ ".ralph/PROMPT.md" ]]
    [[ "$output" =~ ".ralphrc" ]]
}

@test "get_integrity_report contains recovery instructions" {
    create_complete_ralph_project
    rm .ralph/PROMPT.md

    validate_ralph_integrity || true

    run get_integrity_report
    assert_success

    [[ "$output" =~ "ralph-enable --force" ]]
}

@test "get_integrity_report says all good when nothing is missing" {
    create_complete_ralph_project

    validate_ralph_integrity

    run get_integrity_report
    assert_success

    [[ "$output" =~ "intact" ]] || [[ "$output" =~ "valid" ]] || [[ "$output" =~ "All" ]]
}

# =============================================================================
# RALPH_REQUIRED_PATHS array
# =============================================================================

@test "RALPH_REQUIRED_PATHS contains all critical paths and excludes optional files" {
    local expected=(".ralph" ".ralph/PROMPT.md" ".ralph/fix_plan.md" ".ralph/AGENT.md" ".ralphrc")
    for path in "${expected[@]}"; do
        [[ " ${RALPH_REQUIRED_PATHS[*]} " =~ " $path " ]] || fail "Missing required path: $path"
    done
    # Optional paths should NOT be required
    [[ ! " ${RALPH_REQUIRED_PATHS[*]} " =~ "status.json" ]] || fail "Optional path incorrectly required: status.json"
}
