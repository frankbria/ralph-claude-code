#!/usr/bin/env bats
# Integration tests for main Ralph loop behavior
# These tests exercise the top-level ralph_loop.sh entrypoint and verify
# wiring between exit signals, the circuit breaker, and the adapter bridge.

load '../helpers/test_helper'
load '../helpers/mocks'

setup() {
    # Use the shared test helper and mocks
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/mocks.bash"

    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-main-loop.XXXXXX)"
    cd "$TEST_TEMP_DIR"

    # Minimal git repo since some paths inspect git state
    git init >/dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Core Ralph files/dirs
    export RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    export LOG_DIR="logs"
    export DOCS_DIR="docs/generated"
    export STATUS_FILE="status.json"
    export CALL_COUNT_FILE=".call_count"
    export TIMESTAMP_FILE=".last_reset"
    export EXIT_SIGNALS_FILE=".exit_signals"

    mkdir -p "$LOG_DIR" "$DOCS_DIR"
    echo "Test prompt" > PROMPT.md
    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Ensure Claude CLI and related tools are mocked so adapter_init passes
    setup_mocks
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
    teardown_mocks 2>/dev/null || true
}

@test "main loop: exits gracefully when exit signals indicate completion" {
    # Pre-populate exit signals so should_exit_gracefully triggers on first loop
    cat > "$EXIT_SIGNALS_FILE" << 'EOF'
{"test_only_loops": [], "done_signals": [1,2], "completion_indicators": []}
EOF

    run bash "$RALPH_SCRIPT" --dry-run
    assert_success

    # Status file should reflect a graceful completion
    assert_file_exists "$STATUS_FILE"

    # Avoid depending on JSON parsing here; verify key/value pairs directly
    run grep -q '"last_action": "graceful_exit"' "$STATUS_FILE"
    assert_success

    run grep -q '"status": "completed"' "$STATUS_FILE"
    assert_success

    run grep -q '"exit_reason": "completion_signals"' "$STATUS_FILE"
    assert_success

    # Log should mention the graceful exit
    run grep "Graceful exit triggered" "$LOG_DIR/ralph.log"
    assert_success
}

@test "main loop: halts immediately when circuit breaker is OPEN" {
    # Seed a circuit breaker state that is already OPEN before first loop
    cat > ".circuit_breaker_state" << 'EOF'
{
  "state": "OPEN",
  "last_change": "2025-01-01T00:00:00Z",
  "consecutive_no_progress": 3,
  "consecutive_same_error": 0,
  "last_progress_loop": 0,
  "total_opens": 1,
  "reason": "Test open state",
  "current_loop": 0
}
EOF
    echo '[]' > ".circuit_breaker_history"

    run bash "$RALPH_SCRIPT" --dry-run
    # Script may choose a non-zero status; we assert side effects instead

    assert_file_exists "$STATUS_FILE"

    run jq -r '.status' "$STATUS_FILE"
    assert_equal "$output" "halted"

    run jq -r '.exit_reason' "$STATUS_FILE"
    assert_equal "$output" "stagnation_detected"

    run grep "Circuit breaker has opened - execution halted" "$LOG_DIR/ralph.log"
    assert_success
}

@test "main loop: dry-run mode uses adapter bridge without executing adapter" {
    # Ensure exit signals are empty so the loop actually enters execution path
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    run bash "$RALPH_SCRIPT" --dry-run
    assert_success

    # Progress file should reflect a dry-run execution recorded by execute_with_adapter
    assert_file_exists "progress.json"
    run jq -r '.dry_run' "progress.json"
    assert_equal "$output" "true"

    # In dry-run mode, no adapter output logs should be created
    run ls "$LOG_DIR"/*_output_*.log 2>/dev/null
    assert_failure
}

@test "execute_with_adapter: returns 3 when circuit breaker opens" {
    # Force record_loop_result to behave as if the circuit breaker opened by
    # defining it in the environment before invoking ralph_loop.sh. Because the
    # script is run as `bash ralph_loop.sh`, this definition is visible to the
    # child shell and will override the library version.
    export -f record_loop_result
    record_loop_result() {
        # Simulate circuit breaker transition to OPEN state and signal stop
        return 1
    }

    # Ensure we actually reach execution:
    # - EXIT_SIGNALS_FILE is empty
    # - Call count is below limit
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    echo "0" > "$CALL_COUNT_FILE"

    run bash "$RALPH_SCRIPT" --dry-run
    # When record_loop_result returns non-zero, execute_with_adapter should
    # return 3 and main should interpret this as a circuit breaker trip.
    # We assert via status.json and logs rather than the shell exit code.
    assert_file_exists "$STATUS_FILE"

    run jq -r '.status' "$STATUS_FILE"
    assert_equal "$output" "halted"

    run jq -r '.exit_reason' "$STATUS_FILE"
    assert_equal "$output" "stagnation_detected"

    run grep "Circuit breaker opened - halting loop" "$LOG_DIR/ralph.log"
    assert_success
}