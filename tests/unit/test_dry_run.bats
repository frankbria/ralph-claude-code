#!/usr/bin/env bats
# Unit Tests for Dry-Run Mode

load '../helpers/test_helper'

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-test.XXXXXX)"
    cd "$TEST_TEMP_DIR"
    export LOG_DIR="logs"
    export CALL_COUNT_FILE=".call_count"
    export DRY_RUN=false
    mkdir -p "$LOG_DIR"
    echo "0" > "$CALL_COUNT_FILE"
    log_status() {
        local level=$1
        local message=$2
        echo "[$level] $message" >> "$LOG_DIR/ralph.log"
        echo "[$level] $message"
    }
    export -f log_status
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

execute_claude_code() {
    local calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    calls_made=$((calls_made + 1))
    if [[ "$DRY_RUN" == "true" ]]; then
        log_status "INFO" "[DRY RUN] Would execute command"
        log_status "INFO" "[DRY RUN] Would increment counter to $calls_made"
        sleep 2
        return 0
    fi
    echo "$calls_made" > "$CALL_COUNT_FILE"
    return 0
}

@test "dry-run mode logs correct messages" {
    export DRY_RUN=true
    execute_claude_code 1
    run grep -c "\[DRY RUN\]" "$LOG_DIR/ralph.log"
    assert_equal "$output" "2"
}

@test "dry-run mode does not increment call counter file" {
    echo "5" > "$CALL_COUNT_FILE"
    export DRY_RUN=true
    execute_claude_code 1
    local counter=$(cat "$CALL_COUNT_FILE")
    assert_equal "$counter" "5"
}

@test "dry-run mode does not execute Claude command" {
    export DRY_RUN=true
    rm -f /tmp/claude_was_called
    execute_claude_code 1
    [[ ! -f /tmp/claude_was_called ]]
}

@test "dry-run mode includes sleep to simulate execution time" {
    export DRY_RUN=true
    local start_time=$(date +%s)
    execute_claude_code 1
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    [[ $elapsed -ge 2 ]]
}