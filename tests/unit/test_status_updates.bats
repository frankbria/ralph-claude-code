#!/usr/bin/env bats
# Unit Tests for Status Update Functions (Issue #16)
# Tests for update_status() and log_status() in ralph_loop.sh

load '../helpers/test_helper'

RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    export RALPH_DIR="$TEST_DIR/.ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    export STATUS_FILE="$RALPH_DIR/status.json"
    export TOKEN_COUNT_FILE="$RALPH_DIR/.token_count"
    export CALL_COUNT_FILE="$RALPH_DIR/.call_count"
    export TIMESTAMP_FILE="$RALPH_DIR/.last_reset"
    export EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
    export PROMPT_FILE="$RALPH_DIR/PROMPT.md"
    export MAX_CALLS_PER_HOUR="100"
    export MAX_TOKENS_PER_HOUR="0"
    export CLAUDE_CODE_CMD="claude"
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_TIMEOUT_MINUTES="15"

    mkdir -p "$LOG_DIR" "$RALPH_DIR"
    echo "0" > "$CALL_COUNT_FILE"
    echo "0" > "$TOKEN_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# STATUS UPDATE TESTS (6 tests)
# =============================================================================

@test "update_status() creates valid JSON" {
    source "$RALPH_SCRIPT"

    update_status 5 42 "executing" "running" ""

    [ -f "$STATUS_FILE" ]
    run jq empty "$STATUS_FILE"
    assert_success
}

@test "update_status() includes all required fields" {
    source "$RALPH_SCRIPT"

    update_status 5 42 "executing" "running" ""

    local loop_count calls_made last_action status exit_reason
    local max_calls timestamp next_reset tokens_used max_tokens
    loop_count=$(jq -r '.loop_count' "$STATUS_FILE")
    calls_made=$(jq -r '.calls_made_this_hour' "$STATUS_FILE")
    last_action=$(jq -r '.last_action' "$STATUS_FILE")
    status=$(jq -r '.status' "$STATUS_FILE")
    exit_reason=$(jq -r '.exit_reason' "$STATUS_FILE")
    max_calls=$(jq -r '.max_calls_per_hour' "$STATUS_FILE")
    timestamp=$(jq -r '.timestamp' "$STATUS_FILE")
    next_reset=$(jq -r '.next_reset' "$STATUS_FILE")
    tokens_used=$(jq -r '.tokens_used_this_hour' "$STATUS_FILE")
    max_tokens=$(jq -r '.max_tokens_per_hour' "$STATUS_FILE")

    [ "$loop_count" = "5" ]
    [ "$calls_made" = "42" ]
    [ "$last_action" = "executing" ]
    [ "$status" = "running" ]
    [ -z "$exit_reason" ]
    [ "$max_calls" = "100" ]
    [ "$timestamp" != "null" ]
    [ "$next_reset" != "null" ]
    [ "$tokens_used" = "0" ]
    [ "$max_tokens" = "0" ]
}

@test "update_status() with exit reason" {
    source "$RALPH_SCRIPT"

    # Test with empty exit reason
    update_status 1 5 "idle" "stopped" ""
    local exit_reason
    exit_reason=$(jq -r '.exit_reason' "$STATUS_FILE")
    [ "$exit_reason" = "" ]

    # Test with non-empty exit reason
    update_status 3 10 "completing" "exiting" "plan_complete"
    exit_reason=$(jq -r '.exit_reason' "$STATUS_FILE")
    [ "$exit_reason" = "plan_complete" ]
}

@test "update_status() timestamp format (ISO 8601)" {
    source "$RALPH_SCRIPT"

    update_status 1 0 "starting" "running" ""

    local timestamp
    timestamp=$(jq -r '.timestamp' "$STATUS_FILE")

    # Verify full ISO 8601 format: YYYY-MM-DDTHH:MM:SS followed by Z or ±HH:MM
    [[ "$timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$ ]]
}

@test "update_status() overwrites existing file" {
    source "$RALPH_SCRIPT"

    # Write initial status
    update_status 1 5 "first_action" "running" ""
    local first_action
    first_action=$(jq -r '.last_action' "$STATUS_FILE")
    [ "$first_action" = "first_action" ]

    # Overwrite with new values
    update_status 7 20 "second_action" "stopped" "done"
    local loop_count last_action status exit_reason
    loop_count=$(jq -r '.loop_count' "$STATUS_FILE")
    last_action=$(jq -r '.last_action' "$STATUS_FILE")
    status=$(jq -r '.status' "$STATUS_FILE")
    exit_reason=$(jq -r '.exit_reason' "$STATUS_FILE")

    # Old values must be gone
    [ "$loop_count" = "7" ]
    [ "$last_action" = "second_action" ]
    [ "$status" = "stopped" ]
    [ "$exit_reason" = "done" ]
    # The word "first_action" should not appear anywhere in the file
    run grep -c "first_action" "$STATUS_FILE"
    [ "$output" = "0" ]
}

@test "log_status() writes to both log file and stderr" {
    local stdout_tmp stderr_tmp
    stdout_tmp=$(mktemp)
    stderr_tmp=$(mktemp)

    # Redirect stdout and stderr to separate files to verify stderr-only output
    bash -c "
        source \"$RALPH_SCRIPT\"
        log_status 'INFO' 'Test log message'
    " >"$stdout_tmp" 2>"$stderr_tmp"

    # Message must appear on stderr, not stdout
    grep -q "Test log message" "$stderr_tmp"
    grep -q "INFO" "$stderr_tmp"
    [ ! -s "$stdout_tmp" ]

    # Verify the log file was also written
    [ -f "$LOG_DIR/ralph.log" ]
    grep -q "Test log message" "$LOG_DIR/ralph.log"

    rm -f "$stdout_tmp" "$stderr_tmp"
}
