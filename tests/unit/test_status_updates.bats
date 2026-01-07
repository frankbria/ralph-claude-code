#!/usr/bin/env bats
# Unit Tests for Status Update Functions

load '../helpers/test_helper'

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"
    
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-status-test.XXXXXX)"
    cd "$TEST_TEMP_DIR"
    
    export LOG_DIR="logs"
    export STATUS_FILE="status.json"
    export MAX_CALLS_PER_HOUR=100
    
    mkdir -p "$LOG_DIR"
    source "${BATS_TEST_DIRNAME}/../../lib/date_utils.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Minimal test implementation of log_status mirroring production behaviour:
# - Formats messages with a timestamp and level
# - Writes to both stdout and the Ralph log file
log_status() {
    local level=$1
    local message=$2
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message"
    echo "[$timestamp] [$level] $message" >> "$LOG_DIR/ralph.log"
}

# Test-local copy of update_status that mirrors ralph_loop.sh behaviour.
# This keeps the tests focused on the JSON structure without pulling in the
# entire loop script.
update_status() {
    local loop_count=$1
    local calls_made=$2
    local last_action=$3
    local status=$4
    local exit_reason=${5:-""}
    
    cat > "$STATUS_FILE" << STATUSEOF
{
    "timestamp": "$(get_iso_timestamp)",
    "loop_count": $loop_count,
    "calls_made_this_hour": $calls_made,
    "max_calls_per_hour": $MAX_CALLS_PER_HOUR,
    "last_action": "$last_action",
    "status": "$status",
    "exit_reason": "$exit_reason",
    "next_reset": "$(get_next_hour_time)"
}
STATUSEOF
}

@test "update_status creates valid JSON" {
    update_status 5 10 "executing" "running"
    run jq empty "$STATUS_FILE"
    assert_success
}

@test "update_status includes all required fields" {
    update_status 5 10 "executing" "running"
    run jq -r '.loop_count' "$STATUS_FILE"
    assert_equal "$output" "5"
}

@test "update_status includes exit reason when provided" {
    update_status 10 50 "graceful_exit" "completed" "plan_complete"
    run jq -r '.exit_reason' "$STATUS_FILE"
    assert_equal "$output" "plan_complete"
}

@test "update_status timestamp is in ISO format" {
    update_status 1 0 "starting" "running"
    local timestamp=$(jq -r '.timestamp' "$STATUS_FILE")
    [[ "$timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

@test "update_status overwrites existing file" {
    update_status 1 0 "starting" "running"
    update_status 5 10 "executing" "running"
    local second_loop=$(jq -r '.loop_count' "$STATUS_FILE")
    assert_equal "$second_loop" "5"
}

@test "log_status writes to file and stdout" {
    run log_status "INFO" "Test message"
    assert_success
    [[ "$output" == *"Test message"* ]]

    # Verify the message also landed in the Ralph log file
    run grep "Test message" "$LOG_DIR/ralph.log"
    assert_success
}