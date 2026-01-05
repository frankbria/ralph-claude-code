#!/usr/bin/env bats
# Integration Tests for Monitor Dashboard

load '../helpers/test_helper'

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-monitor-test.XXXXXX)"
    cd "$TEST_TEMP_DIR"
    export MONITOR_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_monitor.sh"
    export STATUS_FILE="status.json"
    export LOG_FILE="logs/ralph.log"
    mkdir -p logs
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

display_status() {
    if [[ -f "$STATUS_FILE" ]]; then
        local loop_count=$(jq -r '.loop_count // "0"' "$STATUS_FILE" 2>/dev/null || echo "0")
        local status=$(jq -r '.status // "unknown"' "$STATUS_FILE" 2>/dev/null || echo "unknown")
        echo "Loop Count: #$loop_count"
        echo "Status: $status"
    else
        echo "Status file not found"
    fi
    if [[ -f "$LOG_FILE" ]]; then
        echo "Recent logs:"
        tail -n 3 "$LOG_FILE"
    fi
}

@test "monitor reads status.json correctly" {
    echo '{"loop_count": 5, "status": "running"}' > "$STATUS_FILE"
    run display_status
    assert_success
    [[ "$output" == *"5"* ]]
}

@test "monitor displays loop count" {
    echo '{"loop_count": 42, "status": "running"}' > "$STATUS_FILE"
    run display_status
    [[ "$output" == *"42"* ]]
}

@test "monitor displays API calls" {
    echo '{"loop_count": 5, "calls_made_this_hour": 25}' > "$STATUS_FILE"
    run jq -r '.calls_made_this_hour' "$STATUS_FILE"
    assert_equal "$output" "25"
}

@test "monitor shows recent logs" {
    echo '{"loop_count": 1, "status": "running"}' > "$STATUS_FILE"
    echo "[INFO] Test log entry" >> "$LOG_FILE"
    run display_status
    [[ "$output" == *"Test log entry"* ]]
}

@test "monitor handles missing status file" {
    rm -f "$STATUS_FILE"
    run display_status
    assert_success
    [[ "$output" == *"not found"* ]]
}

@test "monitor handles corrupted JSON gracefully" {
    echo "not valid json" > "$STATUS_FILE"
    run display_status
    assert_success
}

@test "monitor displays progress indicator" {
    echo '{"status": "executing", "indicator": "*"}' > "progress.json"
    local indicator=$(jq -r '.indicator' "progress.json")
    assert_equal "$indicator" "*"
}

@test "monitor has cursor control functions" {
    run grep -c "cursor" "$MONITOR_SCRIPT"
    [[ "$output" -ge 2 ]]
}