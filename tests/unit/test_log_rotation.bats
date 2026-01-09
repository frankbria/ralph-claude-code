#!/usr/bin/env bats

# Log Rotation Tests for Ralph Loop
# Tests for the log_rotation.sh library functions

load '../helpers/test_helper'

# Path to source files
SCRIPT_DIR="${BATS_TEST_DIRNAME}/../../"

# Test setup
setup() {
    # Create temp directory for test files
    TEST_DIR=$(mktemp -d)
    export TEST_DIR
    cd "$TEST_DIR"

    # Source the log rotation library
    source "${SCRIPT_DIR}/lib/log_rotation.sh"
}

teardown() {
    # Clean up test directory
    cd /
    rm -rf "$TEST_DIR" 2>/dev/null || true
}

# =============================================================================
# File Size Tests
# =============================================================================

@test "get_file_size returns 0 for non-existent file" {
    run get_file_size "/nonexistent/file"
    [ "$output" == "0" ]
}

@test "get_file_size returns correct size for small file" {
    local test_file="$TEST_DIR/test.log"
    echo "hello" > "$test_file"

    run get_file_size "$test_file"
    # "hello\n" = 6 bytes
    [ "$output" == "6" ]
}

@test "get_file_size handles empty file" {
    local test_file="$TEST_DIR/empty.log"
    touch "$test_file"

    run get_file_size "$test_file"
    [ "$output" == "0" ]
}

# =============================================================================
# Rotation Need Detection Tests
# =============================================================================

@test "needs_rotation returns false for non-existent file" {
    run needs_rotation "/nonexistent/file"
    [ "$status" -eq 1 ]
}

@test "needs_rotation returns false for small file" {
    local test_file="$TEST_DIR/small.log"
    echo "small content" > "$test_file"

    # Default max is 10MB, this file is tiny
    run needs_rotation "$test_file"
    [ "$status" -eq 1 ]
}

@test "needs_rotation returns true for oversized file" {
    local test_file="$TEST_DIR/large.log"
    # Create a file larger than 100 bytes (for testing)
    for i in {1..20}; do
        echo "This is line $i of the test file for rotation testing" >> "$test_file"
    done

    # Test with a very small max (100 bytes)
    run needs_rotation "$test_file" 100
    [ "$status" -eq 0 ]
}

# =============================================================================
# Log Rotation Tests
# =============================================================================

@test "rotate_log_file creates rotated backup" {
    local test_file="$TEST_DIR/test.log"
    echo "original content" > "$test_file"

    run rotate_log_file "$test_file"
    [ "$status" -eq 0 ]

    # Original file should be empty/new
    [ -f "$test_file" ]
    [ ! -s "$test_file" ]  # Empty

    # Backup should exist with original content
    [ -f "$test_file.1" ]
    run cat "$test_file.1"
    [ "$output" == "original content" ]
}

@test "rotate_log_file shifts existing backups" {
    local test_file="$TEST_DIR/test.log"

    # Create initial backups
    echo "backup 1" > "$test_file.1"
    echo "backup 2" > "$test_file.2"
    echo "current" > "$test_file"

    run rotate_log_file "$test_file" 5
    [ "$status" -eq 0 ]

    # Check backup chain
    [ -f "$test_file.1" ]
    [ -f "$test_file.2" ]
    [ -f "$test_file.3" ]

    run cat "$test_file.1"
    [ "$output" == "current" ]

    run cat "$test_file.2"
    [ "$output" == "backup 1" ]

    run cat "$test_file.3"
    [ "$output" == "backup 2" ]
}

@test "rotate_log_file removes oldest when at max" {
    local test_file="$TEST_DIR/test.log"

    # Create max backups (5 is default)
    echo "oldest" > "$test_file.5"
    echo "backup 4" > "$test_file.4"
    echo "backup 3" > "$test_file.3"
    echo "backup 2" > "$test_file.2"
    echo "backup 1" > "$test_file.1"
    echo "current" > "$test_file"

    run rotate_log_file "$test_file" 5
    [ "$status" -eq 0 ]

    # Oldest should be removed
    [ ! -f "$test_file.6" ]
    # New oldest should be old backup 4
    [ -f "$test_file.5" ]
    run cat "$test_file.5"
    [ "$output" == "backup 4" ]
}

@test "rotate_log_file handles missing file gracefully" {
    run rotate_log_file "/nonexistent/file.log"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Rotate If Needed Tests
# =============================================================================

@test "rotate_if_needed skips small files" {
    local test_file="$TEST_DIR/small.log"
    echo "small" > "$test_file"

    run rotate_if_needed "$test_file"
    [ "$status" -eq 1 ]  # No rotation happened

    # File should still have content
    run cat "$test_file"
    [ "$output" == "small" ]
}

@test "rotate_if_needed rotates large files" {
    local test_file="$TEST_DIR/large.log"
    # Create oversized file
    for i in {1..100}; do
        echo "Line $i: This is test content for log rotation testing" >> "$test_file"
    done

    # Override max size to force rotation
    LOG_MAX_SIZE_BYTES=100

    run rotate_if_needed "$test_file"
    [ "$status" -eq 0 ]  # Rotation happened

    # Backup should exist
    [ -f "$test_file.1" ]
}

# =============================================================================
# Old Log Cleanup Tests
# =============================================================================

@test "cleanup_old_logs removes old files" {
    local log_dir="$TEST_DIR/logs"
    mkdir -p "$log_dir"

    # Create a "new" log file
    echo "new log" > "$log_dir/new.log"

    # Create an "old" log file (touch with old date)
    echo "old log" > "$log_dir/old.log"
    # Make it old (this might not work on all systems)
    touch -d "10 days ago" "$log_dir/old.log" 2>/dev/null || skip "Cannot set old timestamp"

    run cleanup_old_logs "$log_dir" 7
    [ "$status" -eq 0 ]

    # New file should remain
    [ -f "$log_dir/new.log" ]
    # Old file should be removed
    [ ! -f "$log_dir/old.log" ]
}

@test "cleanup_old_logs handles non-existent directory" {
    run cleanup_old_logs "/nonexistent/directory"
    [ "$status" -eq 0 ]
}

@test "cleanup_old_logs ignores non-log files" {
    local log_dir="$TEST_DIR/logs"
    mkdir -p "$log_dir"

    # Create non-log files
    echo "config" > "$log_dir/config.json"
    echo "readme" > "$log_dir/README.md"

    run cleanup_old_logs "$log_dir" 0  # 0 days = remove everything old

    # Non-log files should remain
    [ -f "$log_dir/config.json" ]
    [ -f "$log_dir/README.md" ]
}

# =============================================================================
# Rotate All Logs Tests
# =============================================================================

@test "rotate_all_logs processes multiple log files" {
    local log_dir="$TEST_DIR/logs"
    mkdir -p "$log_dir"

    # Create multiple large log files
    for name in "app" "error" "access"; do
        for i in {1..50}; do
            echo "Log entry $i for $name" >> "$log_dir/$name.log"
        done
    done

    # Set small max size to trigger rotation
    LOG_MAX_SIZE_BYTES=100

    run rotate_all_logs "$log_dir"
    [ "$status" -eq 0 ]

    # All should have backups
    [ -f "$log_dir/app.log.1" ]
    [ -f "$log_dir/error.log.1" ]
    [ -f "$log_dir/access.log.1" ]
}

@test "rotate_all_logs handles empty directory" {
    local log_dir="$TEST_DIR/empty_logs"
    mkdir -p "$log_dir"

    run rotate_all_logs "$log_dir"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Maintain Logs Tests
# =============================================================================

@test "maintain_logs performs full maintenance" {
    local log_dir="$TEST_DIR/logs"
    mkdir -p "$log_dir"

    # Create some log files
    echo "current log" > "$log_dir/app.log"

    run maintain_logs "$log_dir"
    [ "$status" -eq 0 ]
}

@test "maintain_logs handles non-existent directory" {
    run maintain_logs "/nonexistent/logs"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Log Stats Tests
# =============================================================================

@test "get_log_stats returns correct counts" {
    local log_dir="$TEST_DIR/logs"
    mkdir -p "$log_dir"

    # Create a few log files
    echo "content1" > "$log_dir/app.log"
    echo "content2" > "$log_dir/error.log"
    echo "content3" > "$log_dir/app.log.1"

    run get_log_stats "$log_dir"
    [ "$status" -eq 0 ]

    # Should return JSON with total_files = 3
    [[ "$output" == *'"total_files": 3'* ]]
}

@test "get_log_stats handles empty directory" {
    local log_dir="$TEST_DIR/empty"
    mkdir -p "$log_dir"

    run get_log_stats "$log_dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"total_files": 0'* ]]
}

@test "get_log_stats handles non-existent directory" {
    run get_log_stats "/nonexistent/dir"
    [ "$output" == '{"total_files": 0, "total_size_mb": 0}' ]
}
