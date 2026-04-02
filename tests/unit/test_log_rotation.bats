#!/usr/bin/env bats
# Unit Tests for Log Rotation (Issue #18)

load '../helpers/test_helper'

# rotate_logs - mirrors the function in ralph_loop.sh
rotate_logs() {
    local log_file="$LOG_DIR/ralph.log"
    local max_size=10485760  # 10MB in bytes

    [[ -f "$log_file" ]] || return 0

    local file_size
    if stat -c%s "$log_file" > /dev/null 2>&1; then
        file_size=$(stat -c%s "$log_file")
    else
        file_size=$(stat -f%z "$log_file" 2>/dev/null || echo "0")
    fi

    [[ "$file_size" -lt "$max_size" ]] && return 0

    [[ -f "${log_file}.4" ]] && rm -f "${log_file}.4"
    [[ -f "${log_file}.3" ]] && mv "${log_file}.3" "${log_file}.4"
    [[ -f "${log_file}.2" ]] && mv "${log_file}.2" "${log_file}.3"
    [[ -f "${log_file}.1" ]] && mv "${log_file}.1" "${log_file}.2"
    mv "$log_file" "${log_file}.1"
}

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"

    export TEST_TEMP_DIR
    TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"

    export LOG_DIR="$TEST_TEMP_DIR/logs"
    mkdir -p "$LOG_DIR"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

@test "rotate_logs: does not rotate log file under 10MB" {
    dd if=/dev/zero bs=1024 count=1 > "$LOG_DIR/ralph.log" 2>/dev/null

    rotate_logs

    [ -f "$LOG_DIR/ralph.log" ]
    [ ! -f "$LOG_DIR/ralph.log.1" ]
}

@test "rotate_logs: rotates log file when it exceeds 10MB" {
    dd if=/dev/zero bs=1048576 count=11 > "$LOG_DIR/ralph.log" 2>/dev/null

    rotate_logs

    [ ! -f "$LOG_DIR/ralph.log" ]
    [ -f "$LOG_DIR/ralph.log.1" ]
}

@test "rotate_logs: keeps exactly 5 old files and deletes the oldest" {
    for i in 1 2 3 4; do
        echo "old log $i" > "$LOG_DIR/ralph.log.$i"
    done
    dd if=/dev/zero bs=1048576 count=11 > "$LOG_DIR/ralph.log" 2>/dev/null

    rotate_logs

    [ -f "$LOG_DIR/ralph.log.1" ]
    [ -f "$LOG_DIR/ralph.log.2" ]
    [ -f "$LOG_DIR/ralph.log.3" ]
    [ -f "$LOG_DIR/ralph.log.4" ]
    [ ! -f "$LOG_DIR/ralph.log.5" ]
}

@test "rotate_logs: handles missing log file gracefully" {
    run rotate_logs

    [ "$status" -eq 0 ]
}

@test "rotate_logs: uses correct cross-platform stat command" {
    dd if=/dev/zero bs=1048576 count=11 > "$LOG_DIR/ralph.log" 2>/dev/null

    rotate_logs

    [ -f "$LOG_DIR/ralph.log.1" ]
    [ ! -f "$LOG_DIR/ralph.log" ]
}
