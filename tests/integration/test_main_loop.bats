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
    # Exit code may be non-zero depending on how the loop terminates; we assert
    # behavior via side effects rather than the shell status.

    # Status file should be created, indicating the loop ran and updated state
    assert_file_exists "$STATUS_FILE"

    # At minimum, status.json should be non-empty
    run test -s "$STATUS_FILE"
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

    # Wrap in timeout to prevent infinite loops if exit conditions are not met
    run timeout 10s bash "$RALPH_SCRIPT" --dry-run

    # Progress file should reflect a dry-run execution recorded by execute_with_adapter
    assert_file_exists "progress.json"
    run jq -r '.dry_run' "progress.json"
    assert_equal "$output" "true"

    # In dry-run mode, no adapter output logs should be created
    run ls "$LOG_DIR"/*_output_*.log 2>/dev/null
    assert_failure
}

@test "execute_with_adapter: returns 3 when circuit breaker opens" {
    # Seed circuit breaker state so the next no-progress loop will immediately
    # open the circuit (consecutive_no_progress just below threshold).
    cat > ".circuit_breaker_state" << 'EOF'
{
  "state": "CLOSED",
  "last_change": "2025-01-01T00:00:00Z",
  "consecutive_no_progress": 2,
  "consecutive_same_error": 0,
  "last_progress_loop": 0,
  "total_opens": 0,
  "reason": "seeded for test",
  "current_loop": 0
}
EOF
    echo '[]' > ".circuit_breaker_history"

    # Ensure we actually reach execution:
    # - EXIT_SIGNALS_FILE is empty so should_exit_gracefully does not fire
    # - Call count is below limit so can_make_call succeeds
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    echo "0" > "$CALL_COUNT_FILE"

    # Run the main loop with a timeout safety net. The first iteration should
    # open the circuit breaker via record_loop_result, causing execute_with_adapter
    # to return 3 and main to halt with a circuit-breaker exit path.
    run timeout 10s bash "$RALPH_SCRIPT"

    # Verify status reflects a circuit-breaker-driven halt
    assert_file_exists "$STATUS_FILE"

    run jq -r '.status' "$STATUS_FILE"
    assert_equal "$output" "halted"

    run jq -r '.exit_reason' "$STATUS_FILE"
    assert_equal "$output" "stagnation_detected"

    # Log should contain the circuit breaker halt message
    run grep "Circuit breaker opened - halting loop" "$LOG_DIR/ralph.log"
    assert_success
}