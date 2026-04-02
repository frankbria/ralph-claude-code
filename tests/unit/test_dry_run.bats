#!/usr/bin/env bats
# Unit tests for --dry-run mode in ralph_loop.sh
# Linked to GitHub Issue #19
# TDD: Tests written before implementation

load '../helpers/test_helper'
load '../helpers/fixtures'

RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    export RALPH_DIR=".ralph"
    export PROMPT_FILE="$RALPH_DIR/PROMPT.md"
    export LOG_DIR="$RALPH_DIR/logs"
    export STATUS_FILE="$RALPH_DIR/status.json"
    export EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
    export CALL_COUNT_FILE="$RALPH_DIR/.call_count"
    export TIMESTAMP_FILE="$RALPH_DIR/.last_reset"
    export CLAUDE_SESSION_FILE="$RALPH_DIR/.claude_session_id"
    export CLAUDE_CODE_CMD="claude"
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_TIMEOUT_MINUTES="15"
    export MAX_CALLS_PER_HOUR="100"

    mkdir -p "$LOG_DIR"

    echo "# Test Prompt" > "$PROMPT_FILE"
    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# DRY-RUN FLAG TESTS (4 tests)
# =============================================================================

@test "--dry-run flag is accepted without error" {
    run bash "$RALPH_SCRIPT" --dry-run --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--dry-run flag appears in help text" {
    run bash "$RALPH_SCRIPT" --help

    assert_success
    [[ "$output" == *"--dry-run"* ]]
}

@test "--dry-run mode skips actual Claude execution and logs what would run" {
    # Source the real script to exercise the actual execute_claude_code implementation
    # The guard `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` prevents main() from running
    source "$RALPH_SCRIPT"

    # Override build_loop_context to keep the test fast (no file I/O needed)
    build_loop_context() { echo ""; }

    export DRY_RUN=true

    run execute_claude_code 1

    assert_success
    [[ "$output" == *"[DRY RUN]"* ]]
    [[ "$output" == *"Skipping actual Claude Code execution"* ]]
    [[ "$output" == *"no API call was made"* ]]
}

@test "--dry-run mode does not increment the API call counter" {
    # Source the real script
    source "$RALPH_SCRIPT"

    build_loop_context() { echo ""; }

    export DRY_RUN=true
    echo "0" > "$CALL_COUNT_FILE"

    execute_claude_code 1

    local counter
    counter=$(cat "$CALL_COUNT_FILE")
    [[ "$counter" == "0" ]]
}
