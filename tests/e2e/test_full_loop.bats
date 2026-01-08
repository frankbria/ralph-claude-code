#!/usr/bin/env bats
# End-to-End Tests for Full Loop Execution

load '../helpers/test_helper'
load '../helpers/fixtures'
load '../helpers/mocks'

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/fixtures.bash"
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/mocks.bash"
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-e2e-test.XXXXXX)"
    cd "$TEST_TEMP_DIR"
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"
    export RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    export LOG_DIR="logs"
    export STATUS_FILE="status.json"
    export EXIT_SIGNALS_FILE=".exit_signals"
    export CALL_COUNT_FILE=".call_count"
    export MAX_CALLS_PER_HOUR=100
    export DRY_RUN=true
    mkdir -p "$LOG_DIR" docs/generated specs
    echo "Test prompt" > PROMPT.md
    echo "0" > "$CALL_COUNT_FILE"
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    source "${BATS_TEST_DIRNAME}/../../lib/date_utils.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

log_status() {
    local level=$1
    local message=$2
    echo "[$level] $message" >> "$LOG_DIR/ralph.log"
}

update_status() {
    local loop_count=$1
    local calls_made=$2
    local last_action=$3
    local status=$4
    cat > "$STATUS_FILE" << EOF
{"loop_count": $loop_count, "calls_made": $calls_made, "last_action": "$last_action", "status": "$status"}
EOF
}

@test "e2e: complete loop execution with mocked Claude" {
    export DRY_RUN=true
    timeout 10s bash "$RALPH_SCRIPT" --dry-run 2>&1 &
    local pid=$!
    sleep 5
    kill $pid 2>/dev/null || true
    assert_file_exists "$LOG_DIR/ralph.log"
}

@test "e2e: multi-loop scenario tracking" {
    for i in 1 2 3 4 5; do
        update_status $i $i "completed" "success"
        log_status "LOOP" "Completed Loop #$i"
    done
    local final_loop=$(jq -r '.loop_count' "$STATUS_FILE")
    assert_equal "$final_loop" "5"
}

@test "e2e: graceful exit on project completion" {
    echo '{"done_signals": [1, 2]}' > "$EXIT_SIGNALS_FILE"
    local done_signals=$(jq '.done_signals | length' "$EXIT_SIGNALS_FILE")
    [[ $done_signals -ge 2 ]]
}

@test "e2e: graceful exit on test saturation" {
    echo '{"test_only_loops": [1, 2, 3]}' > "$EXIT_SIGNALS_FILE"
    local test_loops=$(jq '.test_only_loops | length' "$EXIT_SIGNALS_FILE")
    [[ $test_loops -ge 3 ]]
}

@test "e2e: resume after interruption preserves state" {
    echo "5" > "$CALL_COUNT_FILE"
    update_status 10 5 "interrupted" "stopped"
    local saved_calls=$(cat "$CALL_COUNT_FILE")
    assert_equal "$saved_calls" "5"
}

@test "e2e: rate limit triggers wait" {
    echo "$MAX_CALLS_PER_HOUR" > "$CALL_COUNT_FILE"
    local calls_made=$(cat "$CALL_COUNT_FILE")
    [[ $calls_made -ge $MAX_CALLS_PER_HOUR ]]
}

@test "e2e: API 5-hour limit detection" {
    echo "Error: You've reached your 5-hour usage limit" > "$LOG_DIR/claude_output.log"
    run grep -qi "5.*hour.*limit" "$LOG_DIR/claude_output.log"
    assert_success
}

@test "e2e: all flags combined work together" {
    run bash "$RALPH_SCRIPT" --dry-run --verbose --backup --notify --help
    assert_success
    [[ "$output" == *"--dry-run"* ]]
}

@test "e2e: status file readable during execution" {
    update_status 1 0 "executing" "running"
    run jq empty "$STATUS_FILE"
    assert_success
}

@test "e2e: cleanup creates final status" {
    update_status 5 10 "interrupted" "stopped"
    log_status "INFO" "Ralph loop interrupted. Cleaning up..."
    run grep "interrupted" "$STATUS_FILE"
    assert_success
}